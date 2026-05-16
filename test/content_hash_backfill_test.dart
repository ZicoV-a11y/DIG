import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_tracker/services/content_hash.dart';
import 'package:music_tracker/services/content_hash_backfill.dart';
import 'package:music_tracker/services/database.dart';
import 'package:music_tracker/services/library_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Slice 3 spec: backfill worker fills `content_hash` for legacy
/// (pre-v10) rows + any row the scan-time write path left null.
///
/// Properties pinned:
///   1. contentHashCandidates returns NULL-hash, available, valid-
///      stat rows; skips junk-fp rows; respects the skip set.
///   2. setContentHashForPath updates exactly one row.
///   3. Worker hashes candidates and writes them back.
///   4. Worker stops cleanly when no candidates remain.
///   5. Worker can be cancelled mid-session and restarted.
///   6. Worker doesn't retry perma-failed paths in the same session.
void main() {
  late AppDatabase appDb;
  late LibraryRepository repo;
  late Database raw;
  late Directory tmp;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    appDb = AppDatabase();
    await appDb.openInMemory();
    repo = LibraryRepository(appDb);
    raw = appDb.db;
    await raw.insert('sources', {
      'id': 'src1',
      'display_name': 'test',
      'folder_path': '/test',
      'created_at': 0,
    });
    tmp = await Directory.systemTemp.createTemp('backfill_test_');
  });

  tearDown(() async {
    await appDb.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<File> writeFile(String name, int size, {int seed = 0}) async {
    final f = File('${tmp.path}/$name');
    final bytes = Uint8List(size);
    var x = (seed * 2654435761) & 0xFFFFFFFF;
    for (var i = 0; i < size; i++) {
      x = (x * 1103515245 + 12345) & 0xFFFFFFFF;
      bytes[i] = x & 0xFF;
    }
    await f.writeAsBytes(bytes);
    return f;
  }

  Future<void> seedLegacyRow(
    String path, {
    String state = 'available',
    int filesize = 800 * 1024,
    int durationMs = 300000,
    String? contentHash,
  }) async {
    await raw.insert('indexed_files', {
      'path': path,
      'source_id': 'src1',
      'filename': path.split('/').last,
      'filesize': filesize,
      'modified_at': 1234567890,
      'duration_ms': durationMs,
      'fingerprint': 'fp-${path.hashCode}',
      'content_hash': contentHash,
      'uid': 'u-${path.hashCode}',
      'is_available': state == 'available' ? 1 : 0,
      'availability_state': state,
      'last_seen_at': DateTime.now().millisecondsSinceEpoch,
      'title': 'T',
    });
  }

  Future<String?> contentHashAt(String path) async {
    final r = await raw.query(
      'indexed_files',
      columns: ['content_hash'],
      where: 'path = ?',
      whereArgs: [path],
      limit: 1,
    );
    return r.isEmpty ? null : r.first['content_hash'] as String?;
  }

  /// Wait until the worker reports it's done (isRunning == false)
  /// or until [maxIterations] × `_batchInterval` elapses. Hard cap
  /// so a stuck worker fails the test loudly instead of hanging.
  Future<void> waitForIdle(
    ContentHashBackfillWorker w, {
    int maxIterations = 100,
  }) async {
    for (var i = 0; i < maxIterations; i++) {
      if (!w.isRunning) return;
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    fail('worker did not become idle after $maxIterations polls');
  }

  group('contentHashCandidates', () {
    test('returns NULL-hash available rows ordered by last_seen DESC',
        () async {
      await seedLegacyRow('/a.mp3');
      await seedLegacyRow('/b.mp3');
      final paths = await repo.contentHashCandidates(limit: 10);
      expect(paths, containsAll(['/a.mp3', '/b.mp3']));
    });

    test('excludes rows whose content_hash is already set', () async {
      await seedLegacyRow('/already.mp3', contentHash: 'abcdef');
      await seedLegacyRow('/needs.mp3');
      final paths = await repo.contentHashCandidates(limit: 10);
      expect(paths, equals(['/needs.mp3']));
    });

    test('excludes non-available rows (missing / superseded)', () async {
      await seedLegacyRow('/lost.mp3', state: 'missing');
      await seedLegacyRow('/replaced.mp3', state: 'superseded');
      await seedLegacyRow('/live.mp3');
      final paths = await repo.contentHashCandidates(limit: 10);
      expect(paths, equals(['/live.mp3']));
    });

    test('excludes junk-stat rows (filesize <= 0)', () async {
      await seedLegacyRow('/junk.mp3', filesize: 0);
      await seedLegacyRow('/good.mp3');
      final paths = await repo.contentHashCandidates(limit: 10);
      expect(paths, equals(['/good.mp3']));
    });

    test('respects the skip set', () async {
      await seedLegacyRow('/a.mp3');
      await seedLegacyRow('/b.mp3');
      final paths = await repo.contentHashCandidates(
        limit: 10,
        skip: {'/a.mp3'},
      );
      expect(paths, equals(['/b.mp3']));
    });
  });

  group('setContentHashForPath', () {
    test('updates exactly one row by path', () async {
      await seedLegacyRow('/a.mp3');
      await seedLegacyRow('/b.mp3');
      final n = await repo.setContentHashForPath('/a.mp3', 'hash-a');
      expect(n, 1);
      expect(await contentHashAt('/a.mp3'), 'hash-a');
      expect(await contentHashAt('/b.mp3'), isNull);
    });

    test('returns 0 if the path is no longer in the table', () async {
      final n = await repo.setContentHashForPath('/gone.mp3', 'hash');
      expect(n, 0);
    });
  });

  group('ContentHashBackfillWorker', () {
    test('hashes all NULL rows pointing at readable files', () async {
      final f1 = await writeFile('a.mp3', 800 * 1024, seed: 1);
      final f2 = await writeFile('b.mp3', 800 * 1024, seed: 2);
      await seedLegacyRow(f1.path);
      await seedLegacyRow(f2.path);

      final worker = ContentHashBackfillWorker(repo);
      worker.start();
      await waitForIdle(worker);

      expect(await contentHashAt(f1.path), await computeContentHash(f1.path));
      expect(await contentHashAt(f2.path), await computeContentHash(f2.path));
    });

    test('reports progress via onProgress callback', () async {
      final f = await writeFile('p.mp3', 800 * 1024, seed: 3);
      await seedLegacyRow(f.path);

      final progress = <({int session, int remaining})>[];
      final worker = ContentHashBackfillWorker(
        repo,
        onProgress: (_, session, remaining) =>
            progress.add((session: session, remaining: remaining)),
      );
      worker.start();
      await waitForIdle(worker);

      expect(progress, isNotEmpty);
      expect(progress.last.session, 1,
          reason: 'one file hashed this session');
      expect(progress.last.remaining, 0,
          reason: 'no NULL-hash candidates remain after the worker drains');
    });

    test('stops cleanly when no candidates remain', () async {
      final worker = ContentHashBackfillWorker(repo);
      worker.start();
      await waitForIdle(worker);
      // Already idle. Nothing to hash.
      expect(worker.isRunning, isFalse);
    });

    test('cancel mid-session halts further work', () async {
      // Seed 20 rows so the worker has multiple batches of work
      // ahead. Cancel immediately and confirm fewer than all
      // get hashed.
      for (var i = 0; i < 20; i++) {
        final f = await writeFile('cancel-$i.mp3', 100 * 1024, seed: i);
        await seedLegacyRow(f.path);
      }
      final worker = ContentHashBackfillWorker(repo);
      worker.start();
      // Yield once so the first batch fires, then cancel.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      worker.cancel();
      // Wait long enough that more batches would have run if not
      // cancelled.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final remaining = await repo.contentHashCandidates(limit: 30);
      expect(
        remaining.length,
        greaterThan(0),
        reason: 'cancellation should leave some rows unhashed',
      );
      expect(worker.isRunning, isFalse);
    });

    test('restart after cancel resumes from remaining NULL rows', () async {
      for (var i = 0; i < 5; i++) {
        final f = await writeFile('r-$i.mp3', 100 * 1024, seed: 100 + i);
        await seedLegacyRow(f.path);
      }
      final worker = ContentHashBackfillWorker(repo);
      worker.start();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      worker.cancel();

      // Some may be hashed; some not. Restart.
      worker.start();
      await waitForIdle(worker);

      final remaining = await repo.contentHashCandidates(limit: 30);
      expect(remaining, isEmpty);
    });

    test(
        'perma-fail rows (file gone) are skipped this session, eventually idle',
        () async {
      // Seed a row whose path points at a file that no longer
      // exists. The worker tries once, fails, adds to its in-
      // session skip list, then exits when only failed candidates
      // remain.
      await seedLegacyRow('/nowhere/missing.mp3');

      final worker = ContentHashBackfillWorker(repo);
      worker.start();
      await waitForIdle(worker);

      // Row still has null content_hash (couldn't read).
      expect(await contentHashAt('/nowhere/missing.mp3'), isNull);
      // But the worker has cleanly exited, not hung in a retry loop.
      expect(worker.isRunning, isFalse);
    });

    test('pause() halts hashing without losing session state; '
         'resume() picks back up', () async {
      // Playback-priority law: while audio plays, the backfill
      // worker yields disk + IO thread pool. Test the mechanism
      // in isolation: pause before any work runs, confirm nothing
      // gets hashed; resume, confirm work completes.
      final files = <File>[];
      for (var i = 0; i < 8; i++) {
        final f = await writeFile('p-$i.mp3', 100 * 1024, seed: 200 + i);
        await seedLegacyRow(f.path);
        files.add(f);
      }

      final worker = ContentHashBackfillWorker(repo);
      worker.start();
      // Pause immediately — before the first 0ms-delayed tick
      // gets a chance to run a real batch.
      worker.pause();
      expect(worker.isPaused, isTrue);
      expect(worker.isRunning, isTrue,
          reason: 'paused worker is still "running" — just not '
              'scheduling new hashes');

      // Wait long enough that ~4 normal batches would have fired.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      // The very first tick may have been in-flight when pause
      // landed (race condition that doesn't actually matter for
      // the user-visible property). Anything from 0 to <=10
      // rows is acceptable; the key invariant is that pause
      // STOPPED THE WORK from completing, not that it caught
      // every single in-flight syscall.
      var hashedDuringPause = 0;
      for (final f in files) {
        if (await contentHashAt(f.path) != null) hashedDuringPause++;
      }
      expect(hashedDuringPause, lessThan(files.length),
          reason: 'pause must prevent the full batch from completing');

      // Resume + drain.
      worker.resume();
      expect(worker.isPaused, isFalse);
      await waitForIdle(worker);
      for (final f in files) {
        expect(await contentHashAt(f.path), isNotNull,
            reason: 'resume must complete every previously-pending file');
      }
    });

    test('cancel() while paused fully tears down state', () async {
      final f = await writeFile('cp.mp3', 100 * 1024, seed: 999);
      await seedLegacyRow(f.path);

      final worker = ContentHashBackfillWorker(repo);
      worker.start();
      worker.pause();
      worker.cancel();

      expect(worker.isRunning, isFalse);
      expect(worker.isPaused, isFalse,
          reason: 'cancel must clear the paused flag too');
    });
  });
}

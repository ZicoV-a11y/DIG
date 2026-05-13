import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_tracker/models/source.dart' show Source, ScanMode;
import 'package:music_tracker/services/database.dart';
import 'package:music_tracker/services/library_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Slice 1: temporal foundation stabilization.
///
/// `first_seen_at` is the per-File-Instance temporal anchor that
/// Phase 2 supersession will use for the temporal-after check.
/// This slice ships ONLY the column + INSERT-time wiring +
/// backfill; no supersession behavior changes yet. Tests pin the
/// temporal-integrity properties so Phase 2 can lean on them
/// confidently.
///
/// Properties pinned here:
///   - Fresh INSERT sets first_seen_at to ~now (both batch + per-file).
///   - UPDATE preserves the existing first_seen_at across re-scans.
///   - content_hash recompute does NOT reset first_seen_at.
///   - Availability transitions do NOT reset first_seen_at.
///   - Move destination gets a fresh first_seen_at (it's a new
///     Instance at a new path).
///   - Copy destination gets a fresh first_seen_at.
///   - Migration backfill: pre-migration rows (first_seen_at = 0)
///     get first_seen_at = last_seen_at.
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
      'display_name': 'A',
      'folder_path': '/test',
      'created_at': 0,
    });
    tmp = await Directory.systemTemp.createTemp('first_seen_at_test_');
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

  Future<Map<String, Object?>?> rowAt(String path) async {
    final rows = await raw.query(
      'indexed_files',
      where: 'path = ?',
      whereArgs: [path],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  ({
    String path,
    String filename,
    int filesize,
    int modifiedAtMs,
    String fallbackTitle,
    int durationMs
  }) entryFor(File f) {
    final st = f.statSync();
    return (
      path: f.path,
      filename: f.path.split('/').last,
      filesize: st.size,
      modifiedAtMs: st.modified.millisecondsSinceEpoch,
      fallbackTitle: 'T',
      durationMs: 300000,
    );
  }

  test('fresh schema includes first_seen_at column', () async {
    final cols = await raw.rawQuery('PRAGMA table_info(indexed_files)');
    expect(cols.any((c) => c['name'] == 'first_seen_at'), isTrue);
  });

  group('batch upsert', () {
    test('INSERT sets first_seen_at to ~now', () async {
      final f = await writeFile('a.mp3', 100, seed: 1);
      final before = DateTime.now().millisecondsSinceEpoch;
      await repo.upsertIndexedFilesBatch(
        sourceId: 'src1',
        files: [entryFor(f)],
      );
      final after = DateTime.now().millisecondsSinceEpoch;

      final row = await rowAt(f.path);
      expect(row, isNotNull);
      final fsa = row!['first_seen_at'] as int;
      expect(fsa, greaterThanOrEqualTo(before));
      expect(fsa, lessThanOrEqualTo(after));
    });

    test('UPDATE preserves first_seen_at across re-scans', () async {
      final f = await writeFile('a.mp3', 100, seed: 1);
      await repo.upsertIndexedFilesBatch(
        sourceId: 'src1',
        files: [entryFor(f)],
      );
      final firstRow = await rowAt(f.path);
      final originalFsa = firstRow!['first_seen_at'] as int;

      // Force a small wall-clock gap so a bug that re-wrote
      // first_seen_at on UPDATE would produce a visibly larger value.
      await Future<void>.delayed(const Duration(milliseconds: 25));
      await repo.upsertIndexedFilesBatch(
        sourceId: 'src1',
        files: [entryFor(f)],
      );

      final secondRow = await rowAt(f.path);
      expect(secondRow!['first_seen_at'], originalFsa);
      // last_seen_at, by contrast, SHOULD bump.
      expect(
        (secondRow['last_seen_at'] as int) >=
            (firstRow['last_seen_at'] as int),
        isTrue,
      );
    });

    test('content_hash recompute does NOT reset first_seen_at',
        () async {
      // First scan: row gets first_seen_at = now-ish, content_hash
      // null (batch upsert defers hash to backfill worker).
      final f = await writeFile('a.mp3', 1024, seed: 1);
      await repo.upsertIndexedFilesBatch(
        sourceId: 'src1',
        files: [entryFor(f)],
      );
      final originalFsa =
          (await rowAt(f.path))!['first_seen_at'] as int;

      // Backfill the hash manually (mimics what the background
      // worker would do), then re-write the file bytes so the
      // next scan recomputes the hash.
      await raw.update(
        'indexed_files',
        {'content_hash': 'old-hash-value'},
        where: 'path = ?',
        whereArgs: [f.path],
      );
      // Mutate bytes + bump mtime so the next batch sees the row
      // as "stat changed" and recomputes content_hash.
      await Future<void>.delayed(const Duration(milliseconds: 25));
      final newer = await writeFile('a.mp3', 2048, seed: 2);
      expect(newer.path, f.path); // same path, different bytes

      await repo.upsertIndexedFilesBatch(
        sourceId: 'src1',
        files: [entryFor(newer)],
      );

      final updated = await rowAt(f.path);
      expect(updated!['first_seen_at'], originalFsa);
    });
  });

  group('per-file upsertIndexedFile', () {
    test('INSERT sets first_seen_at to ~now', () async {
      final f = await writeFile('a.mp3', 100, seed: 3);
      final before = DateTime.now().millisecondsSinceEpoch;
      await repo.upsertIndexedFile(
        sourceId: 'src1',
        file: ScannedFile(
          path: f.path,
          filename: 'a.mp3',
          filesize: f.statSync().size,
          modifiedAt: f.statSync().modified.millisecondsSinceEpoch,
          fallbackTitle: 'T',
        ),
        durationMs: 300000,
      );
      final after = DateTime.now().millisecondsSinceEpoch;

      final row = await rowAt(f.path);
      final fsa = row!['first_seen_at'] as int;
      expect(fsa, greaterThanOrEqualTo(before));
      expect(fsa, lessThanOrEqualTo(after));
    });

    test('UPDATE preserves first_seen_at', () async {
      final f = await writeFile('a.mp3', 100, seed: 3);
      final entry = ScannedFile(
        path: f.path,
        filename: 'a.mp3',
        filesize: f.statSync().size,
        modifiedAt: f.statSync().modified.millisecondsSinceEpoch,
        fallbackTitle: 'T',
      );
      await repo.upsertIndexedFile(
        sourceId: 'src1',
        file: entry,
        durationMs: 300000,
      );
      final originalFsa =
          (await rowAt(f.path))!['first_seen_at'] as int;

      await Future<void>.delayed(const Duration(milliseconds: 25));
      await repo.upsertIndexedFile(
        sourceId: 'src1',
        file: entry,
        durationMs: 300000,
      );

      final updated = await rowAt(f.path);
      expect(updated!['first_seen_at'], originalFsa);
    });
  });

  group('availability transitions', () {
    test('markIndexedFilesMissing does NOT reset first_seen_at',
        () async {
      final f = await writeFile('a.mp3', 100, seed: 4);
      await repo.upsertIndexedFilesBatch(
        sourceId: 'src1',
        files: [entryFor(f)],
      );
      final originalFsa =
          (await rowAt(f.path))!['first_seen_at'] as int;

      // Mark missing: simulates a scan where the file vanished.
      // markUnseenAvailability takes the set of currently-seen
      // paths under the source; an empty set means "nothing was
      // seen, everything is now missing" for that source.
      await repo.markUnseenAvailability('src1', const <String>{});

      final missing = await rowAt(f.path);
      expect(missing!['availability_state'], 'missing');
      expect(missing['first_seen_at'], originalFsa);
    });
  });

  group('Move / Copy destinations', () {
    late Source srcA;
    late Source srcB;

    setUp(() async {
      final folderA = await Directory('${tmp.path}/A').create();
      final folderB = await Directory('${tmp.path}/B').create();
      srcA = Source(
        id: 'srcA',
        displayName: 'A',
        folderPath: folderA.path,
        createdAt: 0,
        scanMode: ScanMode.recursive,
      );
      srcB = Source(
        id: 'srcB',
        displayName: 'B',
        folderPath: folderB.path,
        createdAt: 0,
        scanMode: ScanMode.recursive,
      );
      await raw.insert('sources', {
        'id': srcA.id,
        'display_name': srcA.displayName,
        'folder_path': srcA.folderPath,
        'created_at': 0,
      });
      await raw.insert('sources', {
        'id': srcB.id,
        'display_name': srcB.displayName,
        'folder_path': srcB.folderPath,
        'created_at': 0,
      });
    });

    test('move destination gets fresh first_seen_at', () async {
      final f = await writeFile('A/song.mp3', 100, seed: 5);
      await repo.upsertIndexedFilesBatch(
        sourceId: srcA.id,
        files: [entryFor(f)],
      );
      final originalFsa = (await rowAt(f.path))!['first_seen_at'] as int;

      // Force enough wall-clock gap so the move's "now" is strictly
      // after the original first_seen_at — that's the property
      // Phase 2 supersession depends on.
      await Future<void>.delayed(const Duration(milliseconds: 25));

      final result = await repo.moveTrackFile(
        sourcePath: f.path,
        destSource: srcB,
      );
      expect(result.success, isTrue);

      final destPath = result.newPath!;
      final destRow = await rowAt(destPath);
      expect(destRow, isNotNull);
      final destFsa = destRow!['first_seen_at'] as int;
      expect(destFsa, greaterThan(originalFsa));
      // Sanity: source row is gone (Move).
      expect(await rowAt(f.path), isNull);
    });

    test('copy destination gets fresh first_seen_at; source untouched',
        () async {
      final f = await writeFile('A/song.mp3', 100, seed: 6);
      await repo.upsertIndexedFilesBatch(
        sourceId: srcA.id,
        files: [entryFor(f)],
      );
      final originalFsa = (await rowAt(f.path))!['first_seen_at'] as int;

      await Future<void>.delayed(const Duration(milliseconds: 25));

      final result = await repo.copyTrackFile(
        sourcePath: f.path,
        destSource: srcB,
      );
      expect(result.success, isTrue);

      // Source row's first_seen_at unchanged.
      final sourceRow = await rowAt(f.path);
      expect(sourceRow!['first_seen_at'], originalFsa);

      // Destination row has a fresh first_seen_at.
      final destPath = result.newPath!;
      final destRow = await rowAt(destPath);
      final destFsa = destRow!['first_seen_at'] as int;
      expect(destFsa, greaterThan(originalFsa));
    });
  });

  group('migration backfill', () {
    test('rows with first_seen_at = 0 are backfilled to last_seen_at',
        () async {
      // Simulate pre-migration state: insert a row with a known
      // last_seen_at and first_seen_at = 0 (the column default for
      // pre-existing rows when the v13 migration runs).
      await raw.insert('indexed_files', {
        'path': '/legacy/path.mp3',
        'source_id': 'src1',
        'filename': 'path.mp3',
        'filesize': 100,
        'modified_at': 1234567890000,
        'duration_ms': 240000,
        'fingerprint': 'fp-legacy',
        'uid': 'uid-legacy',
        'is_available': 1,
        'availability_state': 'missing',
        'last_seen_at': 1234567890000,
        'first_seen_at': 0, // pre-migration zero
        'title': 'Legacy',
      });

      // Run the exact backfill SQL the migration applies.
      await raw.execute(
        'UPDATE indexed_files '
        'SET first_seen_at = last_seen_at '
        'WHERE first_seen_at = 0',
      );

      final row = await rowAt('/legacy/path.mp3');
      expect(row!['first_seen_at'], 1234567890000);
    });

    test('rows with non-zero first_seen_at are NOT clobbered by backfill',
        () async {
      // Defensive: the backfill must only touch rows that match
      // the legacy-zero sentinel. A row that has a real first_seen_at
      // (newly INSERTed post-migration) must not be rewritten to
      // last_seen_at.
      await raw.insert('indexed_files', {
        'path': '/fresh/path.mp3',
        'source_id': 'src1',
        'filename': 'path.mp3',
        'filesize': 100,
        'modified_at': 2000000000000,
        'duration_ms': 240000,
        'fingerprint': 'fp-fresh',
        'uid': 'uid-fresh',
        'is_available': 1,
        'availability_state': 'available',
        'last_seen_at': 2000000000000,
        'first_seen_at': 1900000000000, // explicit, non-zero
        'title': 'Fresh',
      });

      await raw.execute(
        'UPDATE indexed_files '
        'SET first_seen_at = last_seen_at '
        'WHERE first_seen_at = 0',
      );

      final row = await rowAt('/fresh/path.mp3');
      expect(row!['first_seen_at'], 1900000000000);
    });
  });
}

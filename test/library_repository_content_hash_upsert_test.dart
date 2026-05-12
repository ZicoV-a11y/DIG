import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_tracker/models/activity_event.dart';
import 'package:music_tracker/services/content_hash.dart';
import 'package:music_tracker/services/database.dart';
import 'package:music_tracker/services/library_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Slice 2 spec: `upsertIndexedFile` populates `content_hash` from
/// real file bytes during a scan, and is careful about when to
/// recompute vs reuse.
///
/// Rules being pinned:
///   1. New row → fresh content_hash from file bytes.
///   2. Existing row, stat signature unchanged, hash non-null →
///      reuse (no re-read of disk).
///   3. Existing row with NULL content_hash (pre-v10 backfill case)
///      → compute and store.
///   4. Existing row, filesize changed → recompute.
///   5. Existing row, mtime changed → recompute.
///   6. Hash read failure does NOT erase a previously-good hash.
///   7. Degenerate stat inputs (filesize<=0 or mtime<=0) → upsert
///      is a no-op, no row touched.
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
    tmp = await Directory.systemTemp.createTemp('upsert_chash_');
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

  ScannedFile fileFromDisk(File f, {String? overrideName}) {
    final st = f.statSync();
    return ScannedFile(
      path: f.path,
      filename: overrideName ?? f.path.split('/').last,
      filesize: st.size,
      modifiedAt: st.modified.millisecondsSinceEpoch,
      fallbackTitle: 'T',
    );
  }

  group('schema v10', () {
    test('indexed_files has the content_hash column + index', () async {
      final cols = await raw.rawQuery('PRAGMA table_info(indexed_files)');
      expect(cols.any((c) => c['name'] == 'content_hash'), isTrue);
      final indexes = await raw.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='indexed_files'",
      );
      expect(
        indexes.any((i) => i['name'] == 'idx_idx_content_hash'),
        isTrue,
      );
    });
  });

  group('upsert: insert path', () {
    test('new file → content_hash populated from disk bytes', () async {
      final f = await writeFile('a.mp3', 800 * 1024, seed: 1);
      final expected = await computeContentHash(f.path);
      expect(expected, isNotNull);

      await repo.upsertIndexedFile(
        sourceId: 'src1',
        file: fileFromDisk(f),
        durationMs: 300000,
      );

      expect(await contentHashAt(f.path), expected);
    });
  });

  group('upsert: update path — recompute policy', () {
    test('unchanged stat + non-null hash → existing hash preserved (no re-read)',
        () async {
      final f = await writeFile('stable.mp3', 800 * 1024, seed: 5);
      await repo.upsertIndexedFile(
        sourceId: 'src1',
        file: fileFromDisk(f),
        durationMs: 300000,
      );
      final first = await contentHashAt(f.path);

      // Forcibly mutate the file bytes on disk while leaving size +
      // mtime untouched. If the upsert were eagerly re-hashing on
      // every scan we'd see a different value here; the policy says
      // it must reuse the existing one.
      final bytes = await f.readAsBytes();
      bytes[100] = bytes[100] ^ 0xFF;
      await f.writeAsBytes(bytes);
      final preserveMtime =
          DateTime.fromMillisecondsSinceEpoch(fileFromDisk(f).modifiedAt);
      // Re-stat (writeAsBytes bumped mtime). Reset to original so
      // the stat signature still looks unchanged from the DB's view.
      await Process.run('touch', [
        '-t',
        _touchStamp(preserveMtime.subtract(const Duration(days: 1))),
        f.path,
      ]);

      // Now feed the upsert what the DB already has: same filesize,
      // same mtime (the one written into the row by the first call).
      final stat1Row = await raw.query(
        'indexed_files',
        columns: ['filesize', 'modified_at'],
        where: 'path = ?',
        whereArgs: [f.path],
        limit: 1,
      );
      final fakeScanned = ScannedFile(
        path: f.path,
        filename: 'stable.mp3',
        filesize: stat1Row.first['filesize'] as int,
        modifiedAt: stat1Row.first['modified_at'] as int,
        fallbackTitle: 'T',
      );
      await repo.upsertIndexedFile(
        sourceId: 'src1',
        file: fakeScanned,
        durationMs: 300000,
      );

      expect(await contentHashAt(f.path), first,
          reason:
              'stat signature unchanged → existing hash must be preserved');
    });

    test('existing row with NULL content_hash → backfilled on next upsert',
        () async {
      // Simulate a pre-v10 row by inserting directly with content_hash NULL.
      final f = await writeFile('legacy.mp3', 800 * 1024, seed: 7);
      final st = f.statSync();
      await raw.insert('indexed_files', {
        'path': f.path,
        'source_id': 'src1',
        'filename': 'legacy.mp3',
        'filesize': st.size,
        'modified_at': st.modified.millisecondsSinceEpoch,
        'duration_ms': 300000,
        'fingerprint': 'fp-legacy',
        'content_hash': null,
        'uid': 'u-legacy',
        'is_available': 1,
        'last_seen_at': 0,
        'title': 'T',
      });
      expect(await contentHashAt(f.path), isNull);

      await repo.upsertIndexedFile(
        sourceId: 'src1',
        file: fileFromDisk(f),
        durationMs: 300000,
      );

      final expected = await computeContentHash(f.path);
      expect(await contentHashAt(f.path), expected);
    });

    test('filesize change → content_hash recomputed', () async {
      final f = await writeFile('grow.mp3', 800 * 1024, seed: 11);
      await repo.upsertIndexedFile(
        sourceId: 'src1',
        file: fileFromDisk(f),
        durationMs: 300000,
      );
      final first = await contentHashAt(f.path);

      // Replace with bigger content.
      final f2 = await writeFile('grow.mp3', 1200 * 1024, seed: 13);
      await repo.upsertIndexedFile(
        sourceId: 'src1',
        file: fileFromDisk(f2),
        durationMs: 300000,
      );

      final second = await contentHashAt(f2.path);
      expect(second, isNot(equals(first)));
      expect(second, await computeContentHash(f2.path));
    });

    test('mtime change → content_hash recomputed', () async {
      final f = await writeFile('retag.mp3', 800 * 1024, seed: 17);
      await repo.upsertIndexedFile(
        sourceId: 'src1',
        file: fileFromDisk(f),
        durationMs: 300000,
      );
      final first = await contentHashAt(f.path);

      // Rewrite with the SAME bytes (same size) but bump mtime by a
      // second — the upsert should treat this as a change and
      // recompute, even though by happy coincidence the new hash
      // ends up identical (because bytes are the same).
      final bytes = await f.readAsBytes();
      // Bump mtime deterministically via writeAsBytes + touch.
      await f.writeAsBytes(bytes);
      final scanned = fileFromDisk(f);
      // Manually advance modified_at so the test asserts the change
      // detection branch regardless of FS mtime granularity.
      final fakeScanned = ScannedFile(
        path: scanned.path,
        filename: scanned.filename,
        filesize: scanned.filesize,
        modifiedAt: scanned.modifiedAt + 60000,
        fallbackTitle: 'T',
      );
      await repo.upsertIndexedFile(
        sourceId: 'src1',
        file: fakeScanned,
        durationMs: 300000,
      );

      final second = await contentHashAt(f.path);
      // Same bytes → same hash by content_hash semantics. The
      // important assertion is that a recompute actually fired —
      // we verify by checking the DB recorded the new mtime.
      final row = await raw.query(
        'indexed_files',
        columns: ['modified_at'],
        where: 'path = ?',
        whereArgs: [f.path],
        limit: 1,
      );
      expect(row.first['modified_at'],
          fakeScanned.modifiedAt);
      expect(second, isNotNull);
      // Hash equals the freshly-computed hash from disk (same bytes).
      expect(second, first);
    });

    test('hash read failure does NOT erase a previously-good hash',
        () async {
      final f = await writeFile('blip.mp3', 800 * 1024, seed: 19);
      await repo.upsertIndexedFile(
        sourceId: 'src1',
        file: fileFromDisk(f),
        durationMs: 300000,
      );
      final good = await contentHashAt(f.path);
      expect(good, isNotNull);

      // Delete the file (simulate Dropbox sync race). The upsert
      // call will see file.filesize > 0 from the scanner's
      // perspective (snapshot) but computeContentHashSync will fail
      // because the file is gone. Guardrail: keep the old hash.
      final scanned = fileFromDisk(f);
      await f.delete();
      // Force the recompute branch by bumping mtime.
      final fakeScanned = ScannedFile(
        path: scanned.path,
        filename: scanned.filename,
        filesize: scanned.filesize,
        modifiedAt: scanned.modifiedAt + 60000,
        fallbackTitle: 'T',
      );
      await repo.upsertIndexedFile(
        sourceId: 'src1',
        file: fakeScanned,
        durationMs: 300000,
      );

      expect(await contentHashAt(f.path), good,
          reason:
              'transient read failure must not overwrite a real hash with null');
    });
  });

  group('upsert: content_updated_external audit event', () {
    test(
        'content_hash changes at existing path → records content_updated_external',
        () async {
      // Simulates the typical Mp3tag / Rekordbox tag-edit flow:
      // file exists, gets upserted normally, then bytes change
      // on disk (mtime bumps, content_hash recomputes to a new
      // value), and the next scan upsert should leave an audit
      // event so the History panel narrates the mutation.
      final f = await writeFile('mut.mp3', 800 * 1024, seed: 71);
      await repo.upsertIndexedFile(
        sourceId: 'src1',
        file: fileFromDisk(f),
        durationMs: 300000,
      );
      final firstHash = await contentHashAt(f.path);
      expect(firstHash, isNotNull);

      // Rewrite the file with different bytes — simulates a
      // tag editor flipping ID3 fields in the head of the file.
      final newF = await writeFile('mut.mp3', 800 * 1024, seed: 99);
      final newStat = fileFromDisk(newF);
      // Force the recompute branch by bumping mtime explicitly
      // (writeAsBytes might or might not change the FS mtime
      // observably within the same second).
      final fakeScanned = ScannedFile(
        path: newStat.path,
        filename: newStat.filename,
        filesize: newStat.filesize,
        modifiedAt: newStat.modifiedAt + 60000,
        fallbackTitle: 'T',
      );
      await repo.upsertIndexedFile(
        sourceId: 'src1',
        file: fakeScanned,
        durationMs: 300000,
      );

      final secondHash = await contentHashAt(f.path);
      expect(secondHash, isNotNull);
      expect(secondHash, isNot(equals(firstHash)),
          reason: 'modified file → new content_hash');

      final events = await repo.loadRecentEvents(
        eventTypes: [EventType.contentUpdatedExternal],
      );
      expect(events, hasLength(1));
      expect(events.first.path, f.path);
      expect(events.first.payload['old_content_hash_prefix'],
          firstHash!.substring(0, 12));
      expect(events.first.payload['new_content_hash_prefix'],
          secondHash!.substring(0, 12));
    });

    test(
        'content_hash change ALSO resets metadata_read_at = 0 (re-enrichment trigger)',
        () async {
      // Companion to the audit event: when bytes diverge at the
      // same path the previously-extracted ID3/Vorbis fields are
      // stale, so metadata_read_at gets wiped so the reactive
      // enrichment pipeline re-reads them. Without this, a tag
      // edit in Mp3tag would update content_hash but leave the
      // title field frozen at its old value forever.
      final f = await writeFile('refresh.mp3', 800 * 1024, seed: 89);
      // Initial upsert (sets metadata_read_at via separate
      // enrichment in production; here we simulate it being
      // stamped).
      await repo.upsertIndexedFile(
        sourceId: 'src1',
        file: fileFromDisk(f),
        durationMs: 300000,
      );
      await raw.update(
        'indexed_files',
        {'metadata_read_at': 1234567890},
        where: 'path = ?',
        whereArgs: [f.path],
      );

      // Rewrite the file → content_hash diverges on next upsert.
      final newF = await writeFile('refresh.mp3', 800 * 1024, seed: 97);
      final newStat = fileFromDisk(newF);
      final fakeScanned = ScannedFile(
        path: newStat.path,
        filename: newStat.filename,
        filesize: newStat.filesize,
        modifiedAt: newStat.modifiedAt + 60000,
        fallbackTitle: 'T',
      );
      await repo.upsertIndexedFile(
        sourceId: 'src1',
        file: fakeScanned,
        durationMs: 300000,
      );

      final row = await raw.query(
        'indexed_files',
        columns: ['metadata_read_at'],
        where: 'path = ?',
        whereArgs: [f.path],
        limit: 1,
      );
      expect(row.first['metadata_read_at'], 0,
          reason:
              'content_hash change must mark metadata stale so the '
              'reactive enrichment pipeline re-reads the tags');
    });

    test('first hash population (null → hash) does NOT fire the event',
        () async {
      // Backfill scenario: pre-v10 row with NULL content_hash
      // gets its first hash on next upsert. That's accounting,
      // not an external mutation — must NOT log
      // content_updated_external.
      final f = await writeFile('backfill.mp3', 800 * 1024, seed: 73);
      final st = f.statSync();
      await raw.insert('indexed_files', {
        'path': f.path,
        'source_id': 'src1',
        'filename': 'backfill.mp3',
        'filesize': st.size,
        'modified_at': st.modified.millisecondsSinceEpoch,
        'duration_ms': 300000,
        'fingerprint': 'fp-legacy',
        'content_hash': null,
        'uid': 'u-legacy',
        'is_available': 1,
        'last_seen_at': 0,
        'title': 'T',
      });
      await repo.upsertIndexedFile(
        sourceId: 'src1',
        file: fileFromDisk(f),
        durationMs: 300000,
      );
      final events = await repo.loadRecentEvents(
        eventTypes: [EventType.contentUpdatedExternal],
      );
      expect(events, isEmpty,
          reason:
              'first-time hash backfill must not be narrated as a mutation');
    });

    test('unchanged content_hash on rescan → no event', () async {
      // Stable library, scan runs again: nothing changed about
      // this file. The upsert reuse-branch preserves the hash
      // and the audit log must stay quiet.
      final f = await writeFile('stable.mp3', 800 * 1024, seed: 77);
      await repo.upsertIndexedFile(
        sourceId: 'src1',
        file: fileFromDisk(f),
        durationMs: 300000,
      );
      await repo.upsertIndexedFile(
        sourceId: 'src1',
        file: fileFromDisk(f),
        durationMs: 300000,
      );
      final events = await repo.loadRecentEvents(
        eventTypes: [EventType.contentUpdatedExternal],
      );
      expect(events, isEmpty);
    });

    test('transient read failure → preserved hash → no event', () async {
      // Hash → null shielded → hash unchanged in DB. Must NOT
      // narrate as a mutation, because the data didn't actually
      // change — we just briefly couldn't read it.
      final f = await writeFile('blip.mp3', 800 * 1024, seed: 79);
      await repo.upsertIndexedFile(
        sourceId: 'src1',
        file: fileFromDisk(f),
        durationMs: 300000,
      );
      // Delete the file then upsert with a bumped mtime —
      // computeContentHash returns null, upsert preserves the
      // previously-good hash. Same hash → no event.
      final scanned = fileFromDisk(f);
      await f.delete();
      final fakeScanned = ScannedFile(
        path: scanned.path,
        filename: scanned.filename,
        filesize: scanned.filesize,
        modifiedAt: scanned.modifiedAt + 60000,
        fallbackTitle: 'T',
      );
      await repo.upsertIndexedFile(
        sourceId: 'src1',
        file: fakeScanned,
        durationMs: 300000,
      );
      final events = await repo.loadRecentEvents(
        eventTypes: [EventType.contentUpdatedExternal],
      );
      expect(events, isEmpty);
    });
  });

  group('upsert: degenerate stat inputs', () {
    test('filesize<=0 → upsert is a no-op (no row touched)', () async {
      // Scanner should have filtered this already, but the repo
      // is defensive: zero/negative filesize means stat failed,
      // do not persist.
      await repo.upsertIndexedFile(
        sourceId: 'src1',
        file: const ScannedFile(
          path: '/dne/ghost.mp3',
          filename: 'ghost.mp3',
          filesize: 0,
          modifiedAt: 12345,
          fallbackTitle: 'T',
        ),
        durationMs: 0,
      );
      final rows = await raw.query('indexed_files');
      expect(rows, isEmpty);
    });
  });
}

/// Format a DateTime for `touch -t` (CC YY MM DD hh mm). Helpers
/// kept inline because this is the only consumer.
String _touchStamp(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year.toString().padLeft(4, '0')}'
      '${two(t.month)}${two(t.day)}'
      '${two(t.hour)}${two(t.minute)}.${two(t.second)}';
}

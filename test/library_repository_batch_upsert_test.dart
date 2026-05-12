import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_tracker/models/activity_event.dart';
import 'package:music_tracker/services/content_hash.dart';
import 'package:music_tracker/services/database.dart';
import 'package:music_tracker/services/library_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Regression: the scan flow uses `upsertIndexedFilesBatch`, not the
/// per-file `upsertIndexedFile`. Both paths must handle content_hash
/// mutation the same way:
///
///   - new file → INSERT with content_hash NULL (backfill worker
///     fills it later)
///   - existing file, stat unchanged → reuse old hash, no event
///   - existing file, stat changed (filesize OR mtime) → recompute
///     hash; if non-null AND differs from old → set
///     `metadata_read_at = 0` AND record
///     `content_updated_external` event
///   - existing file, hash read fails → preserve previously-good
///     hash (no event)
///
/// The bug this test guards against: my Stage 1/2 fixes for the
/// "edit a tag externally and see it propagate" flow landed on the
/// per-file path only. The scan-driven batch path silently ignored
/// content mutations, leaving title/artist frozen in the DB and no
/// audit entry in the History panel.
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
    tmp = await Directory.systemTemp.createTemp('batch_upsert_test_');
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

  ({String path, String filename, int filesize, int modifiedAtMs,
   String fallbackTitle, int durationMs}) entryFor(File f) {
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

  test('INSERT path leaves content_hash NULL (backfill catches up)',
      () async {
    final f = await writeFile('fresh.mp3', 800 * 1024, seed: 1);
    await repo.upsertIndexedFilesBatch(
      sourceId: 'src1',
      files: [entryFor(f)],
    );
    final row = await rowAt(f.path);
    expect(row!['content_hash'], isNull,
        reason:
            'bulk INSERT defers hashing to the background worker; '
            'inline compute on 12k initial files would be too slow');
  });

  test('UPDATE with unchanged stat → preserves content_hash, no event',
      () async {
    final f = await writeFile('stable.mp3', 800 * 1024, seed: 3);
    // First call inserts.
    await repo.upsertIndexedFilesBatch(
      sourceId: 'src1',
      files: [entryFor(f)],
    );
    // Manually seed a content_hash so the unchanged path has
    // something to preserve.
    await raw.update(
      'indexed_files',
      {'content_hash': 'preexisting-hash'},
      where: 'path = ?',
      whereArgs: [f.path],
    );
    // Second call: same stat → reuse path.
    await repo.upsertIndexedFilesBatch(
      sourceId: 'src1',
      files: [entryFor(f)],
    );
    final row = await rowAt(f.path);
    expect(row!['content_hash'], 'preexisting-hash');
    final events = await repo.loadRecentEvents(
      eventTypes: [EventType.contentUpdatedExternal],
    );
    expect(events, isEmpty);
  });

  test(
      'UPDATE with changed bytes → recomputes hash + records content_updated_external + resets metadata_read_at',
      () async {
    // The user's reported scenario: tag editor writes new bytes
    // at the same path, scan re-runs, the bucket should pick up
    // the change.
    final f = await writeFile('mut.mp3', 800 * 1024, seed: 5);
    await repo.upsertIndexedFilesBatch(
      sourceId: 'src1',
      files: [entryFor(f)],
    );
    // Compute the real content_hash and stamp it into the row
    // (the INSERT path left it null per the previous test).
    final initialHash = await computeContentHash(f.path);
    await raw.update(
      'indexed_files',
      {
        'content_hash': initialHash,
        // Pretend a prior enrichment pass already ran so we can
        // verify the reset.
        'metadata_read_at': 1234567890,
      },
      where: 'path = ?',
      whereArgs: [f.path],
    );

    // Rewrite the file with different bytes — simulates Mp3tag
    // appending tag bytes / DAW re-rendering audio at the same
    // path. mtime bumps automatically (writeAsBytes touches it),
    // but we also force the entry to advertise a different mtime
    // so the stat-unchanged branch can't false-positive within
    // a single second.
    final newF = await writeFile('mut.mp3', 800 * 1024, seed: 6);
    final newSt = newF.statSync();
    final entry = (
      path: newF.path,
      filename: 'mut.mp3',
      filesize: newSt.size,
      modifiedAtMs: newSt.modified.millisecondsSinceEpoch + 60000,
      fallbackTitle: 'T',
      durationMs: 300000,
    );
    await repo.upsertIndexedFilesBatch(
      sourceId: 'src1',
      files: [entry],
    );

    final row = await rowAt(newF.path);
    expect(row!['content_hash'], isNot(equals(initialHash)),
        reason: 'changed bytes must yield a new content_hash');
    expect(row['metadata_read_at'], 0,
        reason:
            'content mutation must mark metadata stale so the '
            'reactive enrichment re-reads the tags');

    final events = await repo.loadRecentEvents(
      eventTypes: [EventType.contentUpdatedExternal],
    );
    expect(events, hasLength(1));
    expect(events.first.path, newF.path);
    expect(events.first.payload['old_content_hash_prefix'],
        initialHash!.substring(0, 12));
    expect(events.first.payload['new_content_hash_prefix'],
        (row['content_hash'] as String).substring(0, 12));
  });

  test('hash read failure preserves previously-good hash (no event)',
      () async {
    final f = await writeFile('blip.mp3', 800 * 1024, seed: 9);
    await repo.upsertIndexedFilesBatch(
      sourceId: 'src1',
      files: [entryFor(f)],
    );
    final initialHash = await computeContentHash(f.path);
    await raw.update(
      'indexed_files',
      {'content_hash': initialHash},
      where: 'path = ?',
      whereArgs: [f.path],
    );

    // Delete the file → hash compute returns null. Force the
    // recompute branch via a bumped mtime.
    final st = f.statSync();
    final entry = (
      path: f.path,
      filename: 'blip.mp3',
      filesize: st.size,
      modifiedAtMs: st.modified.millisecondsSinceEpoch + 60000,
      fallbackTitle: 'T',
      durationMs: 300000,
    );
    await f.delete();
    await repo.upsertIndexedFilesBatch(
      sourceId: 'src1',
      files: [entry],
    );

    final row = await rowAt(f.path);
    expect(row!['content_hash'], initialHash,
        reason:
            'transient read failure must not overwrite a real hash '
            'with null');
    final events = await repo.loadRecentEvents(
      eventTypes: [EventType.contentUpdatedExternal],
    );
    expect(events, isEmpty);
  });
}

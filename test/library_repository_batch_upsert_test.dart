import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_tracker/models/activity_event.dart';
import 'package:music_tracker/services/content_hash.dart';
import 'package:music_tracker/services/database.dart';
import 'package:music_tracker/services/library_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Regression: the scan flow uses `upsertIndexedFilesBatch`. Bulk-
/// scan rules (post cloud-storage hang fix — 2026-05-16):
///
///   - new file → INSERT with content_hash NULL (backfill worker
///     fills it later).
///   - existing file, stat unchanged → reuse old hash, no event.
///   - existing file, stat changed → set content_hash NULL,
///     reset metadata_read_at = 0, stash the old hash so the
///     backfill worker can record `contentUpdatedExternal` when
///     it computes the new hash and finds it differs.
///   - inline file I/O in the bulk path is FORBIDDEN. The whole
///     point of this rule is to keep the DB write transaction
///     short so the UI can keep querying tracks while a 1000-file
///     Dropbox burst is being processed. A previous design ran
///     `computeContentHash` inside the transaction and hung the
///     app for minutes on cloud-storage paths.
///
/// The audit event for content mutation still fires — just from
/// the backfill path (`setContentHashForPath`) rather than from
/// the batch upsert. Same data, deferred timing.
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
      'UPDATE with changed bytes → batch nulls hash, marks metadata stale; '
      'backfill records content_updated_external when it writes the new hash',
      () async {
    // The user's reported scenario: tag editor writes new bytes at
    // the same path, scan re-runs, the system must pick up the
    // change without blocking the UI on inline I/O.
    final f = await writeFile('mut.mp3', 800 * 1024, seed: 5);
    await repo.upsertIndexedFilesBatch(
      sourceId: 'src1',
      files: [entryFor(f)],
    );
    // Compute the real content_hash and stamp it into the row.
    // The INSERT path left it null per the previous test; we seed
    // it here to mimic the state after the backfill worker has
    // hashed this row.
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
    // path. We force a bumped mtime so the stat-unchanged branch
    // can't false-positive within a single second.
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

    // Post-batch: hash is nulled (deferred to backfill); metadata
    // stale-marked eagerly; no event yet.
    final mid = await rowAt(newF.path);
    expect(mid!['content_hash'], isNull,
        reason:
            'stat-changed bulk update must defer rehash to the '
            'backfill worker (no inline file I/O in the bulk path)');
    expect(mid['metadata_read_at'], 0,
        reason:
            'metadata marked stale eagerly so the enrichment '
            'pipeline re-reads before backfill catches up');
    final midEvents = await repo.loadRecentEvents(
      eventTypes: [EventType.contentUpdatedExternal],
    );
    expect(midEvents, isEmpty,
        reason: 'event is deferred to when the backfill writes the new hash');

    // Simulate the backfill worker: compute and write the fresh
    // hash. setContentHashForPath consults the pending-compare
    // map and records the event when the hashes differ.
    final newHash = await computeContentHash(newF.path);
    expect(newHash, isNotNull);
    expect(newHash, isNot(equals(initialHash)));
    await repo.setContentHashForPath(newF.path, newHash!);

    final row = await rowAt(newF.path);
    expect(row!['content_hash'], newHash);
    final events = await repo.loadRecentEvents(
      eventTypes: [EventType.contentUpdatedExternal],
    );
    expect(events, hasLength(1));
    expect(events.first.path, newF.path);
    expect(events.first.payload['old_content_hash_prefix'],
        initialHash!.substring(0, 12));
    expect(events.first.payload['new_content_hash_prefix'],
        newHash.substring(0, 12));
  });

  test(
      'backfill never runs (hash perma-fails) → row stays NULL, '
      'no spurious event',
      () async {
    // Cloud-storage equivalent: stat changes but the backfill
    // worker can't read the bytes (placeholder pending download,
    // permission flap). The row sits at content_hash=NULL until a
    // later backfill pass succeeds. No event is recorded until
    // the real new hash lands — defensive: never narrate a change
    // we can't back up with evidence.
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

    // Bump mtime so the upsert takes the stat-changed branch.
    final st = f.statSync();
    final entry = (
      path: f.path,
      filename: 'blip.mp3',
      filesize: st.size,
      modifiedAtMs: st.modified.millisecondsSinceEpoch + 60000,
      fallbackTitle: 'T',
      durationMs: 300000,
    );
    await repo.upsertIndexedFilesBatch(
      sourceId: 'src1',
      files: [entry],
    );

    // The bulk path always nulls the hash on stat change; no
    // inline read attempted, so no read failure to recover from.
    final row = await rowAt(f.path);
    expect(row!['content_hash'], isNull);

    // No backfill has run → no event yet.
    final events = await repo.loadRecentEvents(
      eventTypes: [EventType.contentUpdatedExternal],
    );
    expect(events, isEmpty);
  });

  test(
      'backfill writing the SAME hash (no real mutation) does not '
      'record a spurious event',
      () async {
    // Edge case: a watcher fires on a metadata-only filesystem
    // touch that bumps mtime but doesn't actually change bytes
    // (some sync tools, some shell scripts). The bulk upsert
    // nulls the hash + stashes the old one; the backfill
    // recomputes and gets the SAME hash. No mutation event.
    final f = await writeFile('touched.mp3', 800 * 1024, seed: 11);
    await repo.upsertIndexedFilesBatch(
      sourceId: 'src1',
      files: [entryFor(f)],
    );
    final hash = await computeContentHash(f.path);
    await raw.update(
      'indexed_files',
      {'content_hash': hash},
      where: 'path = ?',
      whereArgs: [f.path],
    );

    // Bump mtime only — leave the bytes (and therefore hash)
    // unchanged.
    final st = f.statSync();
    final entry = (
      path: f.path,
      filename: 'touched.mp3',
      filesize: st.size,
      modifiedAtMs: st.modified.millisecondsSinceEpoch + 60000,
      fallbackTitle: 'T',
      durationMs: 300000,
    );
    await repo.upsertIndexedFilesBatch(
      sourceId: 'src1',
      files: [entry],
    );
    // Backfill writes the same hash back.
    await repo.setContentHashForPath(f.path, hash!);

    final events = await repo.loadRecentEvents(
      eventTypes: [EventType.contentUpdatedExternal],
    );
    expect(events, isEmpty,
        reason: 'mtime touch with identical bytes is not a mutation');
  });
}

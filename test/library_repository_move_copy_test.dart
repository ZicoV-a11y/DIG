import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_tracker/models/activity_event.dart';
import 'package:music_tracker/models/source.dart' show Source, ScanMode;
import 'package:music_tracker/services/database.dart';
import 'package:music_tracker/services/library_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Move/Copy slice A: repo-level FS + DB primitives that the
/// controller wraps in sub-slice B and the right-click menu wires
/// up in sub-slice C.
///
/// Properties pinned:
///   move:
///     - happy path: FS rename, old DB row gone, new DB row at
///       dest path with intel carried over
///     - records app_initiated_move event with via='rename'
///     - destination collision → no FS change, no DB change,
///       failure result
///     - source missing → no FS change, no DB change, failure
///     - source == destination (same path) → fails cleanly
///   copy:
///     - happy path: FS copy, source row unchanged, new row at
///       dest path with shared intel_uid
///     - records app_initiated_copy event
///     - destination collision → no FS change, no DB change,
///       failure
///   atomicity:
///     - FS + DB land together — no half-states
void main() {
  late AppDatabase appDb;
  late LibraryRepository repo;
  late Database raw;
  late Directory tmp;
  late Source srcA;
  late Source srcB;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    appDb = AppDatabase();
    await appDb.openInMemory();
    repo = LibraryRepository(appDb);
    raw = appDb.db;

    tmp = await Directory.systemTemp.createTemp('move_copy_test_');
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

  tearDown(() async {
    await appDb.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<File> writeFile(String name, int size, {int seed = 0}) async {
    final f = File('${srcA.folderPath}/$name');
    final bytes = Uint8List(size);
    var x = (seed * 2654435761) & 0xFFFFFFFF;
    for (var i = 0; i < size; i++) {
      x = (x * 1103515245 + 12345) & 0xFFFFFFFF;
      bytes[i] = x & 0xFF;
    }
    await f.writeAsBytes(bytes);
    return f;
  }

  Future<void> seedIndexedRow({
    required File file,
    required String sourceId,
    String? intelUid,
    String? contentHash,
    String? identityOverride,
  }) async {
    final st = file.statSync();
    await raw.insert('indexed_files', {
      'path': file.path,
      'source_id': sourceId,
      'filename': file.path.split('/').last,
      'filesize': st.size,
      'modified_at': st.modified.millisecondsSinceEpoch,
      'duration_ms': 300000,
      'fingerprint': 'fp-${file.path.hashCode}',
      'content_hash': contentHash,
      'uid': 'u-${file.path.hashCode}',
      'intel_uid': intelUid,
      'identity_override': identityOverride,
      'is_available': 1,
      'availability_state': 'available',
      'last_seen_at': 1,
      'title': 'T',
    });
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

  // ─────────────────────────────────────────────────────────────
  // MOVE
  // ─────────────────────────────────────────────────────────────
  group('moveTrackFile — happy path', () {
    test('FS file moves, old DB row gone, new DB row inserted',
        () async {
      final f = await writeFile('song.mp3', 800 * 1024, seed: 1);
      await seedIndexedRow(
        file: f,
        sourceId: srcA.id,
        intelUid: 'intel-X',
        contentHash: 'ch-X',
      );

      final result = await repo.moveTrackFile(
        sourcePath: f.path,
        destSource: srcB,
      );

      expect(result.success, isTrue);
      expect(result.newPath, '${srcB.folderPath}/song.mp3');

      // FS: source gone, dest present.
      expect(File(f.path).existsSync(), isFalse);
      expect(File(result.newPath!).existsSync(), isTrue);

      // DB: old row gone, new row at dest.
      expect(await rowAt(f.path), isNull);
      final newRow = await rowAt(result.newPath!);
      expect(newRow, isNotNull);
      expect(newRow!['source_id'], srcB.id);
      expect(newRow['intel_uid'], 'intel-X');
      expect(newRow['content_hash'], 'ch-X');
      expect(newRow['availability_state'], 'available');
    });

    test('records app_initiated_move event with via=rename', () async {
      final f = await writeFile('song.mp3', 800 * 1024, seed: 2);
      await seedIndexedRow(file: f, sourceId: srcA.id);

      await repo.moveTrackFile(sourcePath: f.path, destSource: srcB);

      final events = await repo.loadRecentEvents(
        eventTypes: [EventType.appInitiatedMove],
      );
      expect(events, hasLength(1));
      expect(events.first.path, f.path);
      expect(events.first.payload['dest_path'],
          '${srcB.folderPath}/song.mp3');
      expect(events.first.payload['dest_source_id'], srcB.id);
      expect(events.first.payload['via'], 'rename');
    });
  });

  group('moveTrackFile — failure paths', () {
    test('destination collision → no FS change, no DB change', () async {
      final src = await writeFile('song.mp3', 800 * 1024, seed: 3);
      // Pre-existing file at the dest path.
      final dest = File('${srcB.folderPath}/song.mp3');
      await dest.writeAsBytes([1, 2, 3]);

      await seedIndexedRow(file: src, sourceId: srcA.id);

      final result = await repo.moveTrackFile(
        sourcePath: src.path,
        destSource: srcB,
      );

      expect(result.success, isFalse);
      expect(result.errorReason, contains('already exists'));

      expect(File(src.path).existsSync(), isTrue,
          reason: 'source must remain on disk on failure');
      expect(dest.readAsBytesSync(), [1, 2, 3],
          reason: 'destination file must NOT be overwritten');
      expect(await rowAt(src.path), isNotNull);
      expect(await rowAt(dest.path), isNull);
    });

    test('source file gone from disk → clean failure', () async {
      final result = await repo.moveTrackFile(
        sourcePath: '${srcA.folderPath}/nope.mp3',
        destSource: srcB,
      );
      expect(result.success, isFalse);
      expect(result.errorReason, contains('no longer exists'));
    });

    test('source == destination (same source folder) → no-op failure',
        () async {
      final f = await writeFile('song.mp3', 800 * 1024, seed: 5);
      await seedIndexedRow(file: f, sourceId: srcA.id);

      final result = await repo.moveTrackFile(
        sourcePath: f.path,
        destSource: srcA,
      );

      expect(result.success, isFalse);
      expect(result.errorReason, contains('same path'));
      expect(File(f.path).existsSync(), isTrue);
      expect(await rowAt(f.path), isNotNull);
    });
  });

  // ─────────────────────────────────────────────────────────────
  // COPY
  // ─────────────────────────────────────────────────────────────
  group('copyTrackFile — happy path', () {
    test('FS copy lands at dest, source row unchanged, new row shares intel_uid',
        () async {
      final f = await writeFile('song.mp3', 800 * 1024, seed: 7);
      await seedIndexedRow(
        file: f,
        sourceId: srcA.id,
        intelUid: 'intel-Y',
        contentHash: 'ch-Y',
      );

      final result = await repo.copyTrackFile(
        sourcePath: f.path,
        destSource: srcB,
      );

      expect(result.success, isTrue);
      expect(result.via, 'copy');

      // FS: both files exist.
      expect(File(f.path).existsSync(), isTrue);
      expect(File(result.newPath!).existsSync(), isTrue);

      // DB: source row preserved, new row inserted.
      final srcRow = await rowAt(f.path);
      expect(srcRow, isNotNull);
      expect(srcRow!['intel_uid'], 'intel-Y');

      final destRow = await rowAt(result.newPath!);
      expect(destRow, isNotNull);
      expect(destRow!['source_id'], srcB.id);
      expect(destRow['intel_uid'], 'intel-Y',
          reason: 'copies share intel at the song-identity layer');
      expect(destRow['content_hash'], 'ch-Y',
          reason: 'bytes are identical, content_hash carries over');
      expect(destRow['availability_state'], 'available');
    });

    test(
        'destination uid differs from source — no Map collision in _trackByUid',
        () async {
      // Regression: on macOS, Dart's `File.copySync` uses
      // `copyfile` which preserves the source's mtime by default.
      // Because computeTrackUid hashes mtime, naive recompute on
      // the destination produces the same uid as the source —
      // collides in LibraryController's _trackByUid Map, breaks
      // playback for the visible row (whichever Track instance
      // was inserted last wins, click dispatches to the wrong
      // path). copyTrackFile must explicitly stamp the dest with
      // a fresh mtime to keep uids unique.
      final f = await writeFile('clash.mp3', 800 * 1024, seed: 17);
      await seedIndexedRow(file: f, sourceId: srcA.id);

      await repo.copyTrackFile(sourcePath: f.path, destSource: srcB);

      final src = await rowAt(f.path);
      final dest = await rowAt('${srcB.folderPath}/clash.mp3');
      expect(src, isNotNull);
      expect(dest, isNotNull);
      expect(
        dest!['uid'],
        isNot(equals(src!['uid'])),
        reason:
            'destination uid must NOT collide with source uid; '
            'mtime should have been bumped after copySync',
      );
    });

    test('records app_initiated_copy event', () async {
      final f = await writeFile('song.mp3', 800 * 1024, seed: 11);
      await seedIndexedRow(file: f, sourceId: srcA.id);

      await repo.copyTrackFile(sourcePath: f.path, destSource: srcB);

      final events = await repo.loadRecentEvents(
        eventTypes: [EventType.appInitiatedCopy],
      );
      expect(events, hasLength(1));
      expect(events.first.path, f.path);
      expect(events.first.payload['dest_path'],
          '${srcB.folderPath}/song.mp3');
      expect(events.first.payload['dest_source_id'], srcB.id);
    });
  });

  group('copyTrackFile — shared identity_override', () {
    test(
        'source has no identity_override → generates one and stamps both rows',
        () async {
      final f = await writeFile('share.mp3', 800 * 1024, seed: 53);
      await seedIndexedRow(file: f, sourceId: srcA.id);
      // Source's identity_override is null by default.

      final result = await repo.copyTrackFile(
        sourcePath: f.path,
        destSource: srcB,
      );
      expect(result.success, isTrue);

      final src = await rowAt(f.path);
      final dest = await rowAt('${srcB.folderPath}/share.mp3');
      final srcOverride = src!['identity_override'] as String?;
      final destOverride = dest!['identity_override'] as String?;

      expect(srcOverride, isNotNull,
          reason:
              'source row should have been stamped with a fresh '
              'identity_override during Copy');
      expect(destOverride, equals(srcOverride),
          reason:
              'destination should share the same identity_override '
              'so the variants stay bucketed after metadata edits');

      final events = await repo.loadRecentEvents();
      final copyEvents =
          events.where((e) => e.eventType == 'app_initiated_copy').toList();
      expect(copyEvents, hasLength(1));
      expect(copyEvents.first.payload['shared_identity_override'],
          equals(srcOverride));
    });

    test(
        'source already has identity_override → reused for the new row',
        () async {
      final f = await writeFile('reuse.mp3', 800 * 1024, seed: 57);
      await seedIndexedRow(
        file: f,
        sourceId: srcA.id,
        identityOverride: 'preexisting-link',
      );

      final result = await repo.copyTrackFile(
        sourcePath: f.path,
        destSource: srcB,
      );
      expect(result.success, isTrue);

      final src = await rowAt(f.path);
      final dest = await rowAt('${srcB.folderPath}/reuse.mp3');
      expect(src!['identity_override'], 'preexisting-link',
          reason: 'existing override on source must NOT be overwritten');
      expect(dest!['identity_override'], 'preexisting-link');
    });

    test(
        '4-field-matched siblings get widened so codecs stay grouped',
        () async {
      // Three-row bucket: 2 MP3s + 1 AIFF, all using the SAME
      // basename-no-ext / title / artist / duration → grouped by
      // the 4-field song-identity key (no identity_override on
      // any of them yet).
      //
      // Bug this guards against: Copy used to stamp identity_override
      // on source + dest only, orphaning the AIFF sibling in a
      // different bucket — collapsing codec coexistence into
      // filename duplication. Fix: widen the override across every
      // 4-field-matched sibling.
      final mp3 =
          await writeFile('right_now.mp3', 800 * 1024, seed: 71);
      final aiff =
          await writeFile('right_now.aiff', 800 * 1024, seed: 72);
      await seedIndexedRow(file: mp3, sourceId: srcA.id);
      await seedIndexedRow(file: aiff, sourceId: srcA.id);

      final result = await repo.copyTrackFile(
        sourcePath: mp3.path,
        destSource: srcB,
      );
      expect(result.success, isTrue);

      final src = await rowAt(mp3.path);
      final dest = await rowAt('${srcB.folderPath}/right_now.mp3');
      final aiffRow = await rowAt(aiff.path);

      final override = src!['identity_override'] as String?;
      expect(override, isNotNull);
      expect(dest!['identity_override'], override);
      expect(aiffRow!['identity_override'], override,
          reason: 'AIFF sibling (4-field-matched) must inherit the '
              'shared override so the Track Identity bucket survives');
    });

    test(
        "siblings with their OWN override are not hijacked",
        () async {
      // Two MP3s share basename-no-ext / title / artist / duration,
      // but one of them was manually linked previously (already
      // has identity_override = "their-preexisting-link"). Copy
      // must NOT overwrite that — the manual link decision wins.
      final mp3A =
          await writeFile('lonely.mp3', 800 * 1024, seed: 80);
      final mp3B =
          await writeFile('lonely.aiff', 800 * 1024, seed: 81);
      await seedIndexedRow(file: mp3A, sourceId: srcA.id);
      await seedIndexedRow(
        file: mp3B,
        sourceId: srcA.id,
        identityOverride: 'their-preexisting-link',
      );

      final result = await repo.copyTrackFile(
        sourcePath: mp3A.path,
        destSource: srcB,
      );
      expect(result.success, isTrue);

      final mp3BRow = await rowAt(mp3B.path);
      expect(
        mp3BRow!['identity_override'],
        'their-preexisting-link',
        reason: 'rows with their own override must never be hijacked '
            'by an unrelated Copy operation',
      );
    });

    test(
        'rows with different basename-no-ext are not widened',
        () async {
      // Two files share title/artist/duration but have completely
      // different basenames → NOT the same 4-field key. Copy
      // must not pull the unrelated row into the new bucket.
      final mp3 =
          await writeFile('apples.mp3', 800 * 1024, seed: 90);
      final other =
          await writeFile('oranges.mp3', 800 * 1024, seed: 91);
      await seedIndexedRow(file: mp3, sourceId: srcA.id);
      await seedIndexedRow(file: other, sourceId: srcA.id);

      final result = await repo.copyTrackFile(
        sourcePath: mp3.path,
        destSource: srcB,
      );
      expect(result.success, isTrue);

      final otherRow = await rowAt(other.path);
      expect(otherRow!['identity_override'], isNull,
          reason: 'unrelated row (different basename) must NOT be '
              'pulled into the new bucket');
    });
  });

  group('copyTrackFile — stale row at dest', () {
    test(
        'superseded row at destPath gets auto-purged inside the copy txn',
        () async {
      // Real-world scenario: user copied A→B earlier, then deleted
      // the file at B in Finder. Scan marked the B row 'superseded'
      // (cross-source supersession matched the A original by
      // content_hash). The path-PK row at B still exists. Now the
      // user copies A→B again. Without the auto-purge fix this
      // would fail with UNIQUE constraint failed: indexed_files.path.
      final src = await writeFile('reuse.mp3', 800 * 1024, seed: 41);
      await seedIndexedRow(file: src, sourceId: srcA.id);
      // Seed a stale superseded row at the destination path
      // (file no longer on disk — represents the leftover from a
      // prior copy + delete-in-Finder cycle).
      await raw.insert('indexed_files', {
        'path': '${srcB.folderPath}/reuse.mp3',
        'source_id': srcB.id,
        'filename': 'reuse.mp3',
        'filesize': 800 * 1024,
        'modified_at': 0,
        'duration_ms': 300000,
        'fingerprint': 'fp-stale',
        'uid': 'u-stale_dup1',
        'intel_uid': null,
        'is_available': 0,
        'availability_state': 'superseded',
        'last_seen_at': 0,
        'title': 'T',
      });

      final result = await repo.copyTrackFile(
        sourcePath: src.path,
        destSource: srcB,
      );

      expect(result.success, isTrue,
          reason: 'stale row at dest must not block re-copy');

      // New row replaced the stale one — same path, different uid
      // (fresh copy with bumped mtime).
      final destRow = await rowAt('${srcB.folderPath}/reuse.mp3');
      expect(destRow, isNotNull);
      expect(destRow!['availability_state'], 'available');
      expect(destRow['uid'], isNot('u-stale_dup1'));

      // Audit trail: implicit purge event recorded with the
      // auto_purge_reason set so a future History panel can
      // narrate "stale row replaced by copy" honestly.
      final purgeEvents = await repo.loadRecentEvents(
        eventTypes: [EventType.purged],
      );
      expect(purgeEvents, hasLength(1));
      expect(purgeEvents.first.path,
          '${srcB.folderPath}/reuse.mp3');
      expect(purgeEvents.first.payload['auto_purge_reason'],
          'replaced_by_app_initiated_copy');
      expect(purgeEvents.first.payload['prior_state'], 'superseded');
    });

    test(
        'missing row at destPath also gets auto-purged (legacy pre-supersession case)',
        () async {
      // Same flow, but the leftover row never advanced past
      // 'missing' (e.g. cross-source supersession blocked by the
      // uniqueness rule because >1 byte-twins existed).
      final src = await writeFile('reuse2.mp3', 800 * 1024, seed: 43);
      await seedIndexedRow(file: src, sourceId: srcA.id);
      await raw.insert('indexed_files', {
        'path': '${srcB.folderPath}/reuse2.mp3',
        'source_id': srcB.id,
        'filename': 'reuse2.mp3',
        'filesize': 800 * 1024,
        'modified_at': 0,
        'duration_ms': 300000,
        'fingerprint': 'fp-stale2',
        'uid': 'u-stale2',
        'intel_uid': null,
        'is_available': 0,
        'availability_state': 'missing',
        'last_seen_at': 0,
        'title': 'T',
      });

      final result = await repo.copyTrackFile(
        sourcePath: src.path,
        destSource: srcB,
      );
      expect(result.success, isTrue);
      final destRow = await rowAt('${srcB.folderPath}/reuse2.mp3');
      expect(destRow!['availability_state'], 'available');
    });
  });

  group('moveTrackFile — stale row at dest', () {
    test(
        'superseded row at destPath gets auto-purged inside the move txn',
        () async {
      final src = await writeFile('mv.mp3', 800 * 1024, seed: 47);
      await seedIndexedRow(file: src, sourceId: srcA.id);
      // Stale row at the move destination path.
      await raw.insert('indexed_files', {
        'path': '${srcB.folderPath}/mv.mp3',
        'source_id': srcB.id,
        'filename': 'mv.mp3',
        'filesize': 800 * 1024,
        'modified_at': 0,
        'duration_ms': 300000,
        'fingerprint': 'fp-stale-mv',
        'uid': 'u-stale-mv',
        'intel_uid': null,
        'is_available': 0,
        'availability_state': 'superseded',
        'last_seen_at': 0,
        'title': 'T',
      });

      final result = await repo.moveTrackFile(
        sourcePath: src.path,
        destSource: srcB,
      );

      expect(result.success, isTrue);
      expect(await rowAt(src.path), isNull,
          reason: 'source row gone after move');
      final destRow = await rowAt('${srcB.folderPath}/mv.mp3');
      expect(destRow!['availability_state'], 'available');
      expect(destRow['uid'], isNot('u-stale-mv'));

      final purgeEvents = await repo.loadRecentEvents(
        eventTypes: [EventType.purged],
      );
      expect(purgeEvents, hasLength(1));
      expect(purgeEvents.first.payload['auto_purge_reason'],
          'replaced_by_app_initiated_move');
    });
  });

  group('copyTrackFile — failure paths', () {
    test('destination collision → no FS change, source row preserved',
        () async {
      final src = await writeFile('song.mp3', 800 * 1024, seed: 13);
      final dest = File('${srcB.folderPath}/song.mp3');
      await dest.writeAsBytes([9, 9, 9]);
      await seedIndexedRow(file: src, sourceId: srcA.id);

      final result = await repo.copyTrackFile(
        sourcePath: src.path,
        destSource: srcB,
      );

      expect(result.success, isFalse);
      expect(dest.readAsBytesSync(), [9, 9, 9]);
      expect(await rowAt(dest.path), isNull);
      expect(await rowAt(src.path), isNotNull);
    });

    test('source file gone from disk → clean failure', () async {
      final result = await repo.copyTrackFile(
        sourcePath: '${srcA.folderPath}/ghost.mp3',
        destSource: srcB,
      );
      expect(result.success, isFalse);
    });
  });
}

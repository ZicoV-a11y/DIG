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

import 'package:flutter_test/flutter_test.dart';
import 'package:music_tracker/models/activity_event.dart';
import 'package:music_tracker/services/database.dart';
import 'package:music_tracker/services/library_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Sub-slice B: every lifecycle-decision repo method records an
/// event when it changes a row's state. The events themselves
/// don't drive behavior; they exist for the History panel
/// (sub-slice C) and for the user to inspect *why* a row is
/// where it is.
///
/// Properties pinned here:
///   - markUnseenAvailability records a `removed_external` event
///     for every row that transitions from 'available' to
///     'missing'. Rows that stay available, or were already
///     missing, do NOT generate events.
///   - markMovedSupersessions records `auto_move_same_source`
///     with the matched successor's path in the payload.
///   - markCrossSourceMoves records `auto_move_cross_source`
///     with `matched_on` set to `content_hash` or `fingerprint`
///     to reflect which signal triggered the supersession.
///   - purgeIndexedFiles records `purged` for every row removed,
///     with `prior_state` capturing what that row's
///     availability_state was before the delete.
void main() {
  late AppDatabase appDb;
  late LibraryRepository repo;
  late Database raw;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    appDb = AppDatabase();
    await appDb.openInMemory();
    repo = LibraryRepository(appDb);
    raw = appDb.db;
    await raw.insert('sources', {
      'id': 'srcA',
      'display_name': 'A',
      'folder_path': '/srcA',
      'created_at': 0,
    });
    await raw.insert('sources', {
      'id': 'srcB',
      'display_name': 'B',
      'folder_path': '/srcB',
      'created_at': 0,
    });
  });

  tearDown(() async {
    await appDb.close();
  });

  Future<void> seedFile({
    required String path,
    required String sourceId,
    required String fingerprint,
    String state = 'available',
    int filesize = 1024,
    int durationMs = 300000,
    String? contentHash,
  }) async {
    await raw.insert('indexed_files', {
      'path': path,
      'source_id': sourceId,
      'filename': path.split('/').last,
      'filesize': filesize,
      'modified_at': 0,
      'duration_ms': durationMs,
      'fingerprint': fingerprint,
      'content_hash': contentHash,
      'uid': 'u-${path.hashCode}',
      'is_available': state == 'available' ? 1 : 0,
      'availability_state': state,
      'last_seen_at': 0,
      'title': 'T',
    });
  }

  Future<List<ActivityEvent>> eventsOfType(String type) async {
    return await repo.loadRecentEvents(eventTypes: [type]);
  }

  group('markUnseenAvailability records removed_external', () {
    test('one event per row that transitions available → missing',
        () async {
      await seedFile(
          path: '/srcA/keep.mp3', sourceId: 'srcA', fingerprint: 'fp1');
      await seedFile(
          path: '/srcA/gone.mp3', sourceId: 'srcA', fingerprint: 'fp2');
      await seedFile(
          path: '/srcA/also-gone.mp3', sourceId: 'srcA', fingerprint: 'fp3');

      await repo.markUnseenAvailability('srcA', {'/srcA/keep.mp3'});

      final events = await eventsOfType(EventType.removedExternal);
      final paths = events.map((e) => e.path).toSet();
      expect(paths, {'/srcA/gone.mp3', '/srcA/also-gone.mp3'});
      for (final e in events) {
        expect(e.sourceId, 'srcA');
      }
    });

    test('rows that stay available produce NO event', () async {
      await seedFile(
          path: '/srcA/keep.mp3', sourceId: 'srcA', fingerprint: 'fp1');
      await repo.markUnseenAvailability('srcA', {'/srcA/keep.mp3'});
      expect(await repo.eventCount(), 0);
    });

    test('rows that were already missing produce NO event', () async {
      await seedFile(
          path: '/srcA/x.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp1',
          state: 'missing');
      await repo.markUnseenAvailability('srcA', {});
      expect(await repo.eventCount(), 0);
    });

    test('cross-source isolation: other source unaffected', () async {
      await seedFile(
          path: '/srcA/x.mp3', sourceId: 'srcA', fingerprint: 'fp1');
      await seedFile(
          path: '/srcB/y.mp3', sourceId: 'srcB', fingerprint: 'fp2');

      await repo.markUnseenAvailability('srcA', {});

      final events = await eventsOfType(EventType.removedExternal);
      expect(events, hasLength(1));
      expect(events.first.path, '/srcA/x.mp3');
    });
  });

  group('markMovedSupersessions records auto_move_same_source', () {
    test('one event per superseded row, with successor_path in payload',
        () async {
      await seedFile(
          path: '/srcA/old.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp1',
          state: 'missing');
      await seedFile(
          path: '/srcA/new.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp1');

      await repo.markMovedSupersessions('srcA');

      final events = await eventsOfType(EventType.autoMoveSameSource);
      expect(events, hasLength(1));
      expect(events.first.path, '/srcA/old.mp3');
      expect(events.first.payload['successor_path'], '/srcA/new.mp3');
    });

    test('no supersession → no event', () async {
      await seedFile(
          path: '/srcA/lost.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp1',
          state: 'missing');
      await repo.markMovedSupersessions('srcA');
      expect(await eventsOfType(EventType.autoMoveSameSource), isEmpty);
    });
  });

  group('markCrossSourceMoves records auto_move_cross_source', () {
    test('content_hash match → matched_on = "content_hash"', () async {
      await seedFile(
          path: '/srcA/old.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp-old',
          contentHash: 'ch-1',
          state: 'missing');
      await seedFile(
          path: '/srcB/new.mp3',
          sourceId: 'srcB',
          fingerprint: 'fp-new',
          contentHash: 'ch-1');

      await repo.markCrossSourceMoves();

      final events = await eventsOfType(EventType.autoMoveCrossSource);
      expect(events, hasLength(1));
      expect(events.first.path, '/srcA/old.mp3');
      expect(events.first.payload['matched_on'], 'content_hash');
      expect(events.first.payload['successor_path'], '/srcB/new.mp3');
    });

    test('fingerprint fallback → matched_on = "fingerprint"', () async {
      await seedFile(
          path: '/srcA/old.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp1',
          state: 'missing'); // content_hash null → fallback path
      await seedFile(
          path: '/srcB/new.mp3',
          sourceId: 'srcB',
          fingerprint: 'fp1',
          contentHash: 'ch-1');

      await repo.markCrossSourceMoves();

      final events = await eventsOfType(EventType.autoMoveCrossSource);
      expect(events, hasLength(1));
      expect(events.first.payload['matched_on'], 'fingerprint');
      expect(events.first.payload['successor_path'], '/srcB/new.mp3');
    });

    test('uniqueness failure (2+ matches) records no event', () async {
      // Same setup as the uniqueness-blocking test in the matrix:
      // missing row with two same-content_hash available rows.
      await seedFile(
          path: '/srcA/missing.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp1',
          contentHash: 'ch-1',
          state: 'missing');
      await seedFile(
          path: '/srcB/copy1.mp3',
          sourceId: 'srcB',
          fingerprint: 'fp2',
          contentHash: 'ch-1');
      await seedFile(
          path: '/srcB/copy2.mp3',
          sourceId: 'srcB',
          fingerprint: 'fp3',
          contentHash: 'ch-1');

      await repo.markCrossSourceMoves();
      expect(await eventsOfType(EventType.autoMoveCrossSource), isEmpty);
    });
  });

  group('purgeIndexedFiles records purged', () {
    test('one event per purged path, capturing prior_state', () async {
      await seedFile(
          path: '/srcA/dead.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp1',
          state: 'missing');
      await seedFile(
          path: '/srcA/moved.mp3',
          sourceId: 'srcA',
          fingerprint: 'fp2',
          state: 'superseded');

      await repo.purgeIndexedFiles(['/srcA/dead.mp3', '/srcA/moved.mp3']);

      final events = await eventsOfType(EventType.purged);
      final byPath = {for (final e in events) e.path: e};
      expect(byPath.keys, containsAll(['/srcA/dead.mp3', '/srcA/moved.mp3']));
      expect(byPath['/srcA/dead.mp3']!.payload['prior_state'], 'missing');
      expect(byPath['/srcA/moved.mp3']!.payload['prior_state'], 'superseded');
    });

    test('empty input → no events, no work', () async {
      await repo.purgeIndexedFiles(const []);
      expect(await repo.eventCount(), 0);
    });

    test('paths not in DB → no events', () async {
      await repo.purgeIndexedFiles(['/dne.mp3']);
      expect(await eventsOfType(EventType.purged), isEmpty);
    });
  });
}

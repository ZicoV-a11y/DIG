import 'package:flutter_test/flutter_test.dart';
import 'package:music_tracker/models/activity_event.dart';
import 'package:music_tracker/services/database.dart';
import 'package:music_tracker/services/library_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Sub-slice A: schema v11 events table + recordEvent /
/// loadRecentEvents repo plumbing. Lifecycle wiring lives in
/// sub-slice B (next commit).
///
/// Properties pinned here:
///   1. Schema v11 creates the events table + its three indexes.
///   2. recordEvent appends a row with the right shape.
///   3. payload is round-tripped as JSON.
///   4. recordEvent failures don't propagate (observability
///      must never block the caller's lifecycle decision).
///   5. loadRecentEvents returns newest-first.
///   6. loadRecentEvents supports limit + offset + type filter.
///   7. eventCount returns the lifetime total.
///   8. Malformed payload JSON doesn't crash hydration.
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
  });

  tearDown(() async {
    await appDb.close();
  });

  group('schema v11', () {
    test('events table exists with the expected columns', () async {
      final cols = await raw.rawQuery('PRAGMA table_info(events)');
      final names = cols.map((c) => c['name'] as String).toSet();
      expect(
        names,
        containsAll(
          ['id', 'recorded_at', 'event_type', 'path', 'source_id', 'payload'],
        ),
      );
    });

    test('three event-table indexes exist', () async {
      final idx = await raw.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='events'",
      );
      final names = idx.map((r) => r['name'] as String).toSet();
      expect(names, contains('idx_events_recorded_at'));
      expect(names, contains('idx_events_type'));
      expect(names, contains('idx_events_path'));
    });
  });

  group('recordEvent', () {
    test('appends a row with type, path, source, payload', () async {
      await repo.recordEvent(
        type: EventType.removedExternal,
        path: '/srcA/lost.mp3',
        sourceId: 'srcA',
        payload: {'reason': 'scan miss'},
      );
      final rows = await raw.query('events');
      expect(rows, hasLength(1));
      final r = rows.first;
      expect(r['event_type'], EventType.removedExternal);
      expect(r['path'], '/srcA/lost.mp3');
      expect(r['source_id'], 'srcA');
      expect(r['payload'], contains('"reason"'));
      expect(r['recorded_at'], isNonZero);
    });

    test('payload-less event stores null', () async {
      await repo.recordEvent(type: EventType.removedExternal);
      final r = (await raw.query('events')).first;
      expect(r['payload'], isNull);
      expect(r['path'], isNull);
      expect(r['source_id'], isNull);
    });

    test('multiple events accumulate', () async {
      for (var i = 0; i < 5; i++) {
        await repo.recordEvent(
          type: EventType.purged,
          path: '/p$i.mp3',
        );
      }
      expect(await repo.eventCount(), 5);
    });
  });

  group('loadRecentEvents', () {
    test('newest first', () async {
      await repo.recordEvent(type: 't1', path: '/a');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await repo.recordEvent(type: 't2', path: '/b');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await repo.recordEvent(type: 't3', path: '/c');

      final events = await repo.loadRecentEvents();
      expect(events.map((e) => e.eventType).toList(), ['t3', 't2', 't1']);
    });

    test('limit + offset paginate', () async {
      for (var i = 0; i < 10; i++) {
        await repo.recordEvent(type: 'x', path: '/$i');
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      final firstPage = await repo.loadRecentEvents(limit: 3);
      expect(firstPage, hasLength(3));
      final secondPage = await repo.loadRecentEvents(limit: 3, offset: 3);
      expect(secondPage, hasLength(3));
      // Pages don't overlap.
      final ids = {
        ...firstPage.map((e) => e.id),
        ...secondPage.map((e) => e.id),
      };
      expect(ids.length, 6);
    });

    test('eventTypes filter narrows to matching types', () async {
      await repo.recordEvent(type: EventType.removedExternal, path: '/a');
      await repo.recordEvent(type: EventType.purged, path: '/b');
      await repo.recordEvent(type: EventType.autoMoveCrossSource, path: '/c');

      final purges =
          await repo.loadRecentEvents(eventTypes: [EventType.purged]);
      expect(purges.map((e) => e.eventType).toList(), [EventType.purged]);

      final movesAndRemoves = await repo.loadRecentEvents(eventTypes: [
        EventType.removedExternal,
        EventType.autoMoveCrossSource,
      ]);
      expect(
        movesAndRemoves.map((e) => e.eventType).toSet(),
        {EventType.removedExternal, EventType.autoMoveCrossSource},
      );
    });

    test('payload round-trips as Map', () async {
      await repo.recordEvent(
        type: EventType.autoMoveCrossSource,
        path: '/old.mp3',
        payload: {
          'successor_path': '/new.mp3',
          'matched_on': 'content_hash',
        },
      );
      final events = await repo.loadRecentEvents();
      expect(events.first.payload['successor_path'], '/new.mp3');
      expect(events.first.payload['matched_on'], 'content_hash');
    });

    test('malformed payload JSON does not crash hydration', () async {
      // Insert directly with a garbage payload string.
      await raw.insert('events', {
        'recorded_at': 1,
        'event_type': 'bogus',
        'path': null,
        'source_id': null,
        'payload': '{this is not json',
      });
      final events = await repo.loadRecentEvents();
      expect(events, hasLength(1));
      expect(events.first.payload, isEmpty);
      expect(events.first.eventType, 'bogus');
    });
  });
}

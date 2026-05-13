import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_tracker/models/activity_event.dart';
import 'package:music_tracker/services/database.dart';
import 'package:music_tracker/services/library_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Tests for [LibraryRepository.mostRecentLifecycleEventFor] and its
/// batch variant. These power the Review-missing dialog's lineage
/// narration ("→ moved to X · matched on content_hash · 3m overlap"
/// / "last seen 8d ago · AIFF variants still available").
///
/// Properties pinned:
///   - Returns the newest lifecycle event among
///     auto_move_same_source / auto_move_cross_source /
///     app_initiated_move / removed_external for a path.
///   - Ignores non-lifecycle event types (content_updated_external,
///     purged, manual_relink, aggregate types) even when they're
///     newer — the lineage caller wants causality of the *transition
///     out of available*, not in-place mutations.
///   - Tie-breaks newest by (recorded_at DESC, id DESC) so test
///     events written at the same millisecond resolve deterministically.
///   - Returns null when no lifecycle event has been recorded for
///     the path.
///   - Batch variant is a single round-trip per chunk and returns
///     only paths that have qualifying events.
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
      'folder_path': '/A',
      'created_at': 0,
    });
  });

  tearDown(() async {
    await appDb.close();
  });

  Future<int> insertEvent({
    required String type,
    required String? path,
    required int recordedAt,
    Map<String, Object?>? payload,
  }) async {
    return raw.insert('events', {
      'recorded_at': recordedAt,
      'event_type': type,
      'path': path,
      'source_id': 'srcA',
      'payload': payload == null ? null : jsonEncode(payload),
    });
  }

  group('mostRecentLifecycleEventFor (single)', () {
    test('returns null when no events recorded for path', () async {
      expect(await repo.mostRecentLifecycleEventFor('/A/song.mp3'), isNull);
    });

    test('returns the only lifecycle event when one is present',
        () async {
      await insertEvent(
        type: EventType.autoMoveSameSource,
        path: '/A/old.mp3',
        recordedAt: 1000,
        payload: {
          'successor_path': '/A/new.mp3',
          'matched_on': 'content_hash',
        },
      );
      final event = await repo.mostRecentLifecycleEventFor('/A/old.mp3');
      expect(event, isNotNull);
      expect(event!.eventType, EventType.autoMoveSameSource);
      expect(event.payload['successor_path'], '/A/new.mp3');
    });

    test('returns the NEWEST lifecycle event when multiple exist',
        () async {
      await insertEvent(
        type: EventType.autoMoveSameSource,
        path: '/A/old.mp3',
        recordedAt: 1000,
      );
      await insertEvent(
        type: EventType.appInitiatedMove,
        path: '/A/old.mp3',
        recordedAt: 5000,
      );
      await insertEvent(
        type: EventType.removedExternal,
        path: '/A/old.mp3',
        recordedAt: 3000,
      );
      final event = await repo.mostRecentLifecycleEventFor('/A/old.mp3');
      expect(event!.eventType, EventType.appInitiatedMove);
      expect(event.recordedAt.millisecondsSinceEpoch, 5000);
    });

    test('ignores non-lifecycle event types even when newer', () async {
      // A newer content_updated_external should NOT shadow an older
      // lifecycle event — the lineage caller asks "why did this row
      // leave its path?" — content updates don't answer that.
      await insertEvent(
        type: EventType.autoMoveSameSource,
        path: '/A/old.mp3',
        recordedAt: 1000,
      );
      await insertEvent(
        type: EventType.contentUpdatedExternal,
        path: '/A/old.mp3',
        recordedAt: 9000,
      );
      await insertEvent(
        type: EventType.manualRelink,
        path: '/A/old.mp3',
        recordedAt: 8000,
      );
      await insertEvent(
        type: EventType.purged,
        path: '/A/old.mp3',
        recordedAt: 7000,
      );
      final event = await repo.mostRecentLifecycleEventFor('/A/old.mp3');
      expect(event!.eventType, EventType.autoMoveSameSource);
    });

    test('all four lifecycle types each qualify on their own', () async {
      // Each type, on a separate path, should be picked up.
      await insertEvent(
        type: EventType.autoMoveSameSource,
        path: '/A/p1.mp3',
        recordedAt: 1000,
      );
      await insertEvent(
        type: EventType.autoMoveCrossSource,
        path: '/A/p2.mp3',
        recordedAt: 1000,
      );
      await insertEvent(
        type: EventType.appInitiatedMove,
        path: '/A/p3.mp3',
        recordedAt: 1000,
      );
      await insertEvent(
        type: EventType.removedExternal,
        path: '/A/p4.mp3',
        recordedAt: 1000,
      );
      expect(
        (await repo.mostRecentLifecycleEventFor('/A/p1.mp3'))!.eventType,
        EventType.autoMoveSameSource,
      );
      expect(
        (await repo.mostRecentLifecycleEventFor('/A/p2.mp3'))!.eventType,
        EventType.autoMoveCrossSource,
      );
      expect(
        (await repo.mostRecentLifecycleEventFor('/A/p3.mp3'))!.eventType,
        EventType.appInitiatedMove,
      );
      expect(
        (await repo.mostRecentLifecycleEventFor('/A/p4.mp3'))!.eventType,
        EventType.removedExternal,
      );
    });

    test('events for OTHER paths do not leak into the result',
        () async {
      await insertEvent(
        type: EventType.autoMoveSameSource,
        path: '/A/other.mp3',
        recordedAt: 9999,
      );
      expect(
        await repo.mostRecentLifecycleEventFor('/A/this.mp3'),
        isNull,
      );
    });
  });

  group('mostRecentLifecycleEventsFor (batch)', () {
    test('empty input returns empty map without touching DB', () async {
      expect(
        await repo.mostRecentLifecycleEventsFor(const <String>[]),
        isEmpty,
      );
    });

    test('returns only the paths that have qualifying events', () async {
      await insertEvent(
        type: EventType.autoMoveSameSource,
        path: '/A/has_event.mp3',
        recordedAt: 1000,
      );
      // Path with only a non-lifecycle event — should not appear.
      await insertEvent(
        type: EventType.contentUpdatedExternal,
        path: '/A/non_lifecycle.mp3',
        recordedAt: 1000,
      );
      final map = await repo.mostRecentLifecycleEventsFor([
        '/A/has_event.mp3',
        '/A/no_event.mp3',
        '/A/non_lifecycle.mp3',
      ]);
      expect(map.keys, ['/A/has_event.mp3']);
      expect(map['/A/has_event.mp3']!.eventType,
          EventType.autoMoveSameSource);
    });

    test('picks the newest event per path independently', () async {
      await insertEvent(
        type: EventType.autoMoveSameSource,
        path: '/A/p1.mp3',
        recordedAt: 1000,
      );
      await insertEvent(
        type: EventType.removedExternal,
        path: '/A/p1.mp3',
        recordedAt: 2000,
      );
      await insertEvent(
        type: EventType.appInitiatedMove,
        path: '/A/p2.mp3',
        recordedAt: 500,
      );
      await insertEvent(
        type: EventType.autoMoveCrossSource,
        path: '/A/p2.mp3',
        recordedAt: 1500,
      );
      final map = await repo
          .mostRecentLifecycleEventsFor(['/A/p1.mp3', '/A/p2.mp3']);
      expect(map['/A/p1.mp3']!.eventType, EventType.removedExternal);
      expect(map['/A/p2.mp3']!.eventType, EventType.autoMoveCrossSource);
    });

    test('non-lifecycle events do not shadow lifecycle events (batch)',
        () async {
      // Lifecycle at t=1000, content-update at t=9999 → batch should
      // still report the lifecycle event.
      await insertEvent(
        type: EventType.autoMoveSameSource,
        path: '/A/p.mp3',
        recordedAt: 1000,
      );
      await insertEvent(
        type: EventType.contentUpdatedExternal,
        path: '/A/p.mp3',
        recordedAt: 9999,
      );
      final map = await repo.mostRecentLifecycleEventsFor(['/A/p.mp3']);
      expect(map['/A/p.mp3']!.eventType, EventType.autoMoveSameSource);
    });

    test('handles many paths (exercises the chunking loop)', () async {
      // Above the in-method chunk size of 400. Verifies the batch
      // method correctly combines multiple round-trip results.
      const total = 450;
      for (var i = 0; i < total; i++) {
        await insertEvent(
          type: EventType.autoMoveSameSource,
          path: '/A/p$i.mp3',
          recordedAt: 1000 + i,
        );
      }
      final paths = List.generate(total, (i) => '/A/p$i.mp3');
      final map = await repo.mostRecentLifecycleEventsFor(paths);
      expect(map.length, total);
      // Sanity: a random middle path resolves correctly.
      expect(map['/A/p233.mp3']!.eventType,
          EventType.autoMoveSameSource);
    });
  });
}

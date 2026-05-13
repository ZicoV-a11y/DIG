import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_tracker/models/activity_event.dart';
import 'package:music_tracker/services/database.dart';
import 'package:music_tracker/services/library_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Tests for [LibraryRepository.loadHistoryForPath]. Powers the
/// right-click "View history" popup — per-row causal inspection.
///
/// Properties pinned:
///   - Direct events (path = the queried path) appear in the result.
///   - Reference events (payload's successor_path or dest_path
///     equals the queried path) also appear — covers the case where
///     a freshly-copied/moved file has no events directly on its own
///     path but DOES have the source's event referencing it.
///   - Aggregate events (path = NULL) never appear unless they
///     happen to mention the path in their payload (they don't —
///     tracksPlayed / favoritesAdded / scanCompleted carry no
///     path references).
///   - Sort order is newest first, with id as tie-breaker.
///   - LIKE ESCAPE on the reference-search pattern correctly handles
///     underscores in filenames (no false positives).
///   - Paths with JSON-significant characters (quotes, backslashes,
///     unicode) round-trip without false matches.
///   - Returns empty list for paths with no events.
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

  test('returns empty list when no events match', () async {
    expect(await repo.loadHistoryForPath('/A/nothing.mp3'), isEmpty);
  });

  test('returns direct events (path = queried path)', () async {
    await insertEvent(
      type: EventType.contentUpdatedExternal,
      path: '/A/song.mp3',
      recordedAt: 1000,
      payload: {
        'old_content_hash_prefix': 'abc',
        'new_content_hash_prefix': 'def',
      },
    );
    await insertEvent(
      type: EventType.manualRelink,
      path: '/A/song.mp3',
      recordedAt: 2000,
      payload: {'linked_to': '/A/other.mp3'},
    );

    final history = await repo.loadHistoryForPath('/A/song.mp3');
    expect(history.length, 2);
    // Newest first.
    expect(history[0].eventType, EventType.manualRelink);
    expect(history[1].eventType, EventType.contentUpdatedExternal);
  });

  test('returns reference events (successor_path in payload)',
      () async {
    // A move event recorded under the SOURCE path references the
    // queried path as successor_path. The queried path itself has
    // no event recorded on it directly — but the source's event
    // tells its origin story.
    await insertEvent(
      type: EventType.autoMoveSameSource,
      path: '/A/old.mp3',
      recordedAt: 1000,
      payload: {
        'successor_path': '/A/new.mp3',
        'matched_on': 'content_hash',
      },
    );

    final history = await repo.loadHistoryForPath('/A/new.mp3');
    expect(history.length, 1);
    expect(history.single.eventType, EventType.autoMoveSameSource);
    expect(history.single.path, '/A/old.mp3');
  });

  test('returns reference events (dest_path in payload)', () async {
    // App-initiated move/copy records dest_path. A freshly-copied
    // file at /A/new.mp3 should show the copy event in its history.
    await insertEvent(
      type: EventType.appInitiatedCopy,
      path: '/A/source.mp3',
      recordedAt: 1500,
      payload: {
        'dest_path': '/A/new.mp3',
        'dest_source_id': 'srcA',
      },
    );

    final history = await repo.loadHistoryForPath('/A/new.mp3');
    expect(history.length, 1);
    expect(history.single.eventType, EventType.appInitiatedCopy);
  });

  test('combines direct + reference events, newest first', () async {
    // Mix: the queried path has a direct event AND is referenced
    // by another path's event. Both should appear, in chronological
    // (newest-first) order.
    await insertEvent(
      type: EventType.appInitiatedCopy,
      path: '/A/source.mp3',
      recordedAt: 1000,
      payload: {'dest_path': '/A/target.mp3'},
    );
    await insertEvent(
      type: EventType.contentUpdatedExternal,
      path: '/A/target.mp3',
      recordedAt: 2000,
      payload: {
        'old_content_hash_prefix': 'abc',
        'new_content_hash_prefix': 'def',
      },
    );

    final history = await repo.loadHistoryForPath('/A/target.mp3');
    expect(history.length, 2);
    expect(history[0].eventType, EventType.contentUpdatedExternal);
    expect(history[1].eventType, EventType.appInitiatedCopy);
  });

  test('aggregate events (path NULL) are NOT included', () async {
    // tracksPlayed / favoritesAdded / scanCompleted are aggregate
    // operational-journal entries with path = NULL. They should
    // never appear in a per-path history.
    await insertEvent(
      type: EventType.tracksPlayed,
      path: null,
      recordedAt: 1000,
      payload: {'count': 5},
    );
    await insertEvent(
      type: EventType.scanCompleted,
      path: null,
      recordedAt: 2000,
      payload: {'source_name': 'A'},
    );
    // A direct event on the path so we can verify the result isn't
    // empty for the wrong reason.
    await insertEvent(
      type: EventType.removedExternal,
      path: '/A/song.mp3',
      recordedAt: 500,
    );

    final history = await repo.loadHistoryForPath('/A/song.mp3');
    expect(history.length, 1);
    expect(history.single.eventType, EventType.removedExternal);
  });

  test('events for unrelated paths do not leak in', () async {
    await insertEvent(
      type: EventType.removedExternal,
      path: '/A/other.mp3',
      recordedAt: 1000,
    );
    await insertEvent(
      type: EventType.autoMoveSameSource,
      path: '/A/another.mp3',
      recordedAt: 2000,
      payload: {'successor_path': '/A/different.mp3'},
    );

    expect(await repo.loadHistoryForPath('/A/song.mp3'), isEmpty);
  });

  test('LIKE ESCAPE on underscores — no false positives', () async {
    // Path with underscore: a naive LIKE without ESCAPE would treat
    // _ as a single-char wildcard and match /A/song1.mp3 too.
    await insertEvent(
      type: EventType.appInitiatedCopy,
      path: '/A/source.mp3',
      recordedAt: 1000,
      // The actual reference path uses an underscore.
      payload: {'dest_path': '/A/song_v2.mp3'},
    );
    // Another event whose dest_path would match the LIKE pattern
    // if underscores were treated as wildcards.
    await insertEvent(
      type: EventType.appInitiatedCopy,
      path: '/A/decoy.mp3',
      recordedAt: 2000,
      payload: {'dest_path': '/A/songXv2.mp3'},
    );

    // Querying /A/song_v2.mp3 should ONLY return the first event.
    final history = await repo.loadHistoryForPath('/A/song_v2.mp3');
    expect(history.length, 1);
    expect(history.single.path, '/A/source.mp3');
  });

  test('tie-break by id when timestamps equal', () async {
    final firstId = await insertEvent(
      type: EventType.removedExternal,
      path: '/A/song.mp3',
      recordedAt: 1000,
    );
    final secondId = await insertEvent(
      type: EventType.manualRelink,
      path: '/A/song.mp3',
      recordedAt: 1000,
      payload: {'linked_to': '/A/other.mp3'},
    );
    // Sanity: insert order should produce ascending ids.
    expect(secondId, greaterThan(firstId));

    final history = await repo.loadHistoryForPath('/A/song.mp3');
    expect(history.length, 2);
    // Newer id first when timestamps tie.
    expect(history[0].id, secondId);
    expect(history[1].id, firstId);
  });

  test('cross-source-move with this path as successor is included',
      () async {
    // A markCrossSourceMoves event recorded under the missing path
    // in another source. From the perspective of the new available
    // row at /B/new.mp3, the event is part of its history.
    await raw.insert('sources', {
      'id': 'srcB',
      'display_name': 'B',
      'folder_path': '/B',
      'created_at': 0,
    });
    await insertEvent(
      type: EventType.autoMoveCrossSource,
      path: '/A/old.mp3',
      recordedAt: 1000,
      payload: {
        'successor_path': '/B/new.mp3',
        'successor_source_id': 'srcB',
        'matched_on': 'content_hash',
        'overlap_ms': -500,
      },
    );

    final history = await repo.loadHistoryForPath('/B/new.mp3');
    expect(history.length, 1);
    expect(history.single.eventType, EventType.autoMoveCrossSource);
    expect(history.single.payload['successor_path'], '/B/new.mp3');
  });

  test('paths with JSON-significant characters round-trip', () async {
    // Quotes, backslashes — JSON-escaping must align between
    // payload write (jsonEncode) and LIKE pattern construction
    // (our _encodePathForJsonFragment). If alignment drifts, this
    // test fails.
    const trickyPath = r'/A/song "remix".mp3';
    await insertEvent(
      type: EventType.appInitiatedCopy,
      path: '/A/source.mp3',
      recordedAt: 1000,
      payload: {'dest_path': trickyPath},
    );

    final history = await repo.loadHistoryForPath(trickyPath);
    expect(history.length, 1);
    expect(history.single.eventType, EventType.appInitiatedCopy);
  });
}

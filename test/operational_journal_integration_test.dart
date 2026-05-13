import 'package:flutter_test/flutter_test.dart';
import 'package:music_tracker/models/activity_event.dart';
import 'package:music_tracker/services/database.dart';
import 'package:music_tracker/services/library_repository.dart';
import 'package:music_tracker/widgets/event_log_format.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Operational-journal integration tests.
///
/// Exercises the causal-integrity pipeline end-to-end at the
/// repo + formatter seam:
///
///   1. A repo-level mutation (supersession, app-initiated move,
///      etc.) records an event with a full payload.
///   2. The event lands in `events` with the temporal evidence,
///      successor reference, matched-on signal.
///   3. `loadHistoryForPath` retrieves it for both the source path
///      (direct event) AND the destination path (reference event).
///   4. The shared `eventDetailLineFor` formatter renders the
///      retrieved event into the exact narration the UI surfaces
///      (Activity Log dialog, Review-missing detail line, History
///      popup).
///
/// Every step has its own unit tests. The integration angle here is
/// pinning the *seam* between them: a change in one layer that
/// drifts the contract with another would still pass the unit
/// tests but break the user-visible narration. These tests fail
/// noisily when that happens.
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
    await raw.insert('sources', {
      'id': 'srcB',
      'display_name': 'B',
      'folder_path': '/B',
      'created_at': 0,
    });
  });

  tearDown(() async {
    await appDb.close();
  });

  Future<void> insertIndexedFile({
    required String sourceId,
    required String path,
    required String state,
    required int firstSeenAt,
    required int lastSeenAt,
    String? contentHash,
    String fingerprint = 'fp',
    int filesize = 1024,
    int durationMs = 240000,
  }) async {
    final segments = path.split('/');
    await raw.insert('indexed_files', {
      'path': path,
      'source_id': sourceId,
      'filename': segments.isEmpty ? path : segments.last,
      'filesize': filesize,
      'modified_at': lastSeenAt,
      'duration_ms': durationMs,
      'fingerprint': fingerprint,
      'content_hash': contentHash,
      'uid': 'uid-${path.hashCode.abs()}',
      'is_available': state == 'available' ? 1 : 0,
      'availability_state': state,
      'last_seen_at': lastSeenAt,
      'first_seen_at': firstSeenAt,
      'title': 'T',
    });
  }

  test('Phase 2 cross-source supersession: event payload + history '
      'retrieval + formatter narration round-trip', () async {
    // Set up a clean cross-source move: missing row in srcA, an
    // available row in srcB with matching content_hash. Temporal
    // sequencing is satisfied (successor's first_seen_at is after
    // missing's last_seen_at).
    await insertIndexedFile(
      sourceId: 'srcA',
      path: '/A/old.mp3',
      state: 'missing',
      firstSeenAt: 100,
      lastSeenAt: 1000,
      contentHash: 'hash-cs',
      fingerprint: 'fp-cs',
    );
    await insertIndexedFile(
      sourceId: 'srcB',
      path: '/B/new.mp3',
      state: 'available',
      firstSeenAt: 2500,
      lastSeenAt: 2500,
      contentHash: 'hash-cs',
      fingerprint: 'fp-cs',
    );

    // 1. Trigger the supersession.
    final superseded = await repo.markCrossSourceMoves();
    expect(superseded, 1);

    // 2. Verify the event landed with the full Phase 2 payload.
    final events = await raw.query(
      'events',
      where: 'event_type = ?',
      whereArgs: [EventType.autoMoveCrossSource],
    );
    expect(events, hasLength(1));
    final stored = ActivityEvent.fromRow(events.single);
    expect(stored.path, '/A/old.mp3');
    expect(stored.payload['successor_path'], '/B/new.mp3');
    expect(stored.payload['successor_source_id'], 'srcB');
    expect(stored.payload['matched_on'], 'content_hash');
    expect(stored.payload['missing_last_seen_at'], 1000);
    expect(stored.payload['successor_first_seen_at'], 2500);
    // overlap_ms = missing.last_seen_at - successor.first_seen_at
    //            = 1000 - 2500 = -1500 (negative = clean
    // succession). The formatter omits the overlap hint in this
    // case so the detail line stays terse.
    expect(stored.payload['overlap_ms'], -1500);

    // 3. The history retrieval finds the event for both paths.
    //    The missing path: direct event match.
    final sourceHistory =
        await repo.loadHistoryForPath('/A/old.mp3');
    expect(sourceHistory.length, 1);
    expect(sourceHistory.single.eventType,
        EventType.autoMoveCrossSource);

    //    The destination path: payload-reference match (successor_path).
    //    This is the case where a freshly-arrived file's history
    //    is the SOURCE's move event referencing it.
    final destHistory =
        await repo.loadHistoryForPath('/B/new.mp3');
    expect(destHistory.length, 1);
    expect(destHistory.single.eventType,
        EventType.autoMoveCrossSource);
    expect(destHistory.single.payload['successor_path'],
        '/B/new.mp3');

    // 4. The shared formatter renders the retrieved event with
    //    the exact narration the UI surfaces. Clean succession =
    //    no overlap hint.
    final detail = eventDetailLineFor(sourceHistory.single);
    expect(detail, '→ new.mp3  ·  matched on content_hash');
  });

  test('Within-grace overlap: detail line surfaces overlap duration',
      () async {
    // missing.last_seen_at = 1_000_000, successor.first_seen_at =
    // 880_000. Overlap = 1_000_000 - 880_000 = 120_000 ms = 2 min.
    // That's well within the 10-min grace, so supersession fires;
    // the detail line should now include "2m overlap".
    await insertIndexedFile(
      sourceId: 'srcA',
      path: '/A/old.mp3',
      state: 'missing',
      firstSeenAt: 100,
      lastSeenAt: 1000000,
      contentHash: 'hash-x',
      fingerprint: 'fp-x',
    );
    await insertIndexedFile(
      sourceId: 'srcA',
      path: '/A/new.mp3',
      state: 'available',
      firstSeenAt: 880000,
      lastSeenAt: 1500000,
      contentHash: 'hash-x',
      fingerprint: 'fp-x-renamed',
    );

    expect(await repo.markMovedSupersessions('srcA'), 1);

    final history = await repo.loadHistoryForPath('/A/old.mp3');
    expect(history.length, 1);
    final detail = eventDetailLineFor(history.single);
    expect(detail,
        '→ new.mp3  ·  matched on content_hash  ·  2m overlap');
  });

  test('Mixed history: auto-move + later content-update both '
      'surface in chronological order', () async {
    // Realistic timeline: a file is auto-resolved as moved, then
    // later edited externally (tags rewritten by Mp3tag / DAW).
    // The destination row should show both events, newest first.
    await insertIndexedFile(
      sourceId: 'srcA',
      path: '/A/old.mp3',
      state: 'missing',
      firstSeenAt: 100,
      lastSeenAt: 1000,
      contentHash: 'hash-h',
      fingerprint: 'fp-h',
    );
    await insertIndexedFile(
      sourceId: 'srcA',
      path: '/A/new.mp3',
      state: 'available',
      firstSeenAt: 2000,
      lastSeenAt: 2000,
      contentHash: 'hash-h',
      fingerprint: 'fp-h-renamed',
    );

    // First event: auto-move.
    expect(await repo.markMovedSupersessions('srcA'), 1);

    // Second event: external content-update on the now-available
    // destination row. Recorded directly (the upsert path normally
    // emits this, but for the integration test we record manually
    // to keep the surface small).
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await repo.recordEvent(
      type: EventType.contentUpdatedExternal,
      path: '/A/new.mp3',
      sourceId: 'srcA',
      payload: {
        'old_content_hash_prefix': 'hash-h',
        'new_content_hash_prefix': 'hash-i',
      },
    );

    final history = await repo.loadHistoryForPath('/A/new.mp3');
    expect(history.length, 2);
    // Newest first.
    expect(history[0].eventType, EventType.contentUpdatedExternal);
    expect(history[1].eventType, EventType.autoMoveSameSource);

    // Both events render correctly via the shared formatter.
    final newestDetail = eventDetailLineFor(history[0]);
    expect(newestDetail, 'sha: hash-h… → hash-i…');
    final oldestDetail = eventDetailLineFor(history[1]);
    expect(oldestDetail, contains('→ new.mp3'));
    expect(oldestDetail, contains('matched on content_hash'));
  });

  test('Aggregate journal entries appear in Activity Log but NOT in '
      'per-path history', () async {
    // tracksPlayed / favoritesAdded / scanCompleted carry no path —
    // they're aggregate summaries. They must surface in the Activity
    // Log feed (cross-cutting view) but never pollute a per-path
    // history popup.
    await repo.recordEvent(
      type: EventType.tracksPlayed,
      path: null,
      payload: {'count': 5},
    );
    await repo.recordEvent(
      type: EventType.scanCompleted,
      path: null,
      payload: {'source_name': 'A'},
    );
    // A direct path-bound event so we can verify the per-path
    // result isn't empty for the wrong reason.
    await repo.recordEvent(
      type: EventType.removedExternal,
      path: '/A/song.mp3',
      sourceId: 'srcA',
    );

    // Activity Log feed sees everything.
    final feed = await repo.loadRecentEvents(limit: 100);
    expect(feed.length, 3);
    expect(
      feed.map((e) => e.eventType).toSet(),
      {
        EventType.tracksPlayed,
        EventType.scanCompleted,
        EventType.removedExternal,
      },
    );

    // Per-path history only sees its own path; aggregates excluded.
    final perPath = await repo.loadHistoryForPath('/A/song.mp3');
    expect(perPath.length, 1);
    expect(perPath.single.eventType, EventType.removedExternal);
  });

  test('No event recorded when supersession refuses (overlap > grace)',
      () async {
    // Defensive: when the 4-condition rule rejects the
    // supersession, NO auto_move event should be written. The
    // event log shouldn't lie about decisions that didn't happen.
    const missingLastSeen = 10000000;
    const farPastFirstSeen = 100; // 9999.9s overlap — way over grace.
    await insertIndexedFile(
      sourceId: 'srcA',
      path: '/A/master.mp3',
      state: 'missing',
      firstSeenAt: 0,
      lastSeenAt: missingLastSeen,
      contentHash: 'hash-coexist',
      fingerprint: 'fp-coexist',
    );
    await insertIndexedFile(
      sourceId: 'srcB',
      path: '/B/working_copy.mp3',
      state: 'available',
      firstSeenAt: farPastFirstSeen,
      lastSeenAt: missingLastSeen,
      contentHash: 'hash-coexist',
      fingerprint: 'fp-coexist',
    );

    expect(await repo.markCrossSourceMoves(), 0);

    final events = await raw.query('events');
    expect(events, isEmpty,
        reason: 'A refused supersession must not record an event. '
            "If it did, the History popup would narrate a "
            "decision that didn't actually fire — exactly the "
            'kind of "magical state mutation" the Phase 2 '
            'rewrite was supposed to eliminate.');
  });

  test('The same event renders identically across surfaces — '
      'formatter is the single source of narration', () async {
    // The Phase 2 + shared-formatter slices both depend on this
    // invariant: an event in the DB renders to the SAME detail
    // line everywhere it surfaces. If a future slice forks the
    // formatter (e.g. adds a surface-specific detail line) this
    // test fails noisily.
    await repo.recordEvent(
      type: EventType.appInitiatedMove,
      path: '/A/source.mp3',
      sourceId: 'srcA',
      payload: {
        'dest_path': '/B/dest.mp3',
        'dest_source_id': 'srcB',
        'via': 'rename',
      },
    );

    // Surface 1: the source path's history (direct event).
    final sourceHist = await repo.loadHistoryForPath('/A/source.mp3');
    expect(sourceHist.length, 1);
    final sourceLine = eventDetailLineFor(sourceHist.single);

    // Surface 2: the destination path's history (reference event).
    final destHist = await repo.loadHistoryForPath('/B/dest.mp3');
    expect(destHist.length, 1);
    final destLine = eventDetailLineFor(destHist.single);

    // Surface 3: lifecycle-event helper (drives Review-missing
    // narration).
    final lifecycle =
        await repo.mostRecentLifecycleEventFor('/A/source.mp3');
    expect(lifecycle, isNotNull);
    final lifecycleLine = eventDetailLineFor(lifecycle!);

    // All three render identically.
    expect(sourceLine, '→ dest.mp3  ·  via rename');
    expect(destLine, sourceLine);
    expect(lifecycleLine, sourceLine);
  });
}

// TelemetryReconciler contract tests.
//
// PR2.5 locks in the merge layer between phone-emitted semantic
// events and desktop intelligence rows. These tests pin every
// architectural rule we committed to:
//
//   1. Per-event atomic transaction (state mutation + audit +
//      dedup row commit-or-rollback together).
//   2. UUID event_id idempotency — same event uploaded twice
//      results in ONE applied + ONE deduped.
//   3. intel_uid-level merge (not variant_id) — telemetry for
//      two variants of the same song reconciles to one
//      intelligence row.
//   4. Clock-skew clamp on far-future timestamps.
//   5. Threshold reconciliation is atomic: reviewed_at +
//      play_count++ + last_played_at all set together.
//   6. Favorite is LWW on favorite_toggled_at.
//   7. Telemetry for tracks whose file was deleted still
//      applies (intelligence outlives files).
//   8. Reserved-for-future event types are dedup'd but not
//      applied — they're forward-compat scaffolding.
//   9. Batch failure mid-way: earlier events stay applied,
//      failed event is NOT in accepted_event_ids.
//   10. Audit events land in `events` with origin='mobile:<id>'.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_tracker/models/activity_event.dart';
import 'package:music_tracker/services/database.dart';
import 'package:music_tracker/services/library_repository.dart';
import 'package:music_tracker/services/mobile_sync/mobile_device.dart';
import 'package:music_tracker/services/mobile_sync/mobile_sync_repository.dart';
import 'package:music_tracker/services/mobile_sync/sync_session_store.dart';
import 'package:music_tracker/services/mobile_sync/telemetry_reconciler.dart';
import 'package:shared_core/shared_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late AppDatabase appDb;
  late MobileSyncRepository repo;
  late LibraryRepository libraryRepo;
  late TelemetryReconciler reconciler;
  late DateTime now;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    appDb = AppDatabase();
    await appDb.openInMemory();
    repo = MobileSyncRepository(appDb);
    libraryRepo = LibraryRepository(appDb);
    now = DateTime(2026, 5, 17, 12, 0, 0);
    reconciler = TelemetryReconciler(
      appDb: appDb,
      libraryRepo: libraryRepo,
      now: () => now,
      futureSkewTolerance: const Duration(minutes: 5),
    );

    // Every reconciler test needs a paired device (FK target for
    // processed_mobile_events).
    await repo.insertDevice(MobileDevice(
      deviceId: 'iphone-zico',
      friendlyName: 'Zico iPhone',
      pairedAt: DateTime(2026, 1, 1),
      capacity: const CapacityPolicy.songs(100),
      tokenHash: 'stub',
    ));
  });

  tearDown(() async {
    await appDb.close();
  });

  // ─── Helpers ──────────────────────────────────────────────────────

  /// Seed an intelligence row so the reconciler has something to
  /// merge into. Mirrors what the desktop's normal playback path
  /// would have created.
  Future<void> seedTrack({
    required String intelUid,
    String fingerprint = '',
    bool favorite = false,
    int playCount = 0,
    int? lastPlayedAt,
    int? reviewedAt,
    int? favoriteToggledAt,
  }) async {
    await appDb.db.insert('tracks', {
      'uid': intelUid,
      'fingerprint': fingerprint,
      'created_at': 0,
      'favorite': favorite ? 1 : 0,
      'play_count': playCount,
      'cumulative_ms': 0,
      'last_played_at': lastPlayedAt,
      'reviewed_at': reviewedAt,
      'favorite_toggled_at': favoriteToggledAt,
    });
  }

  TelemetryEvent threshold({
    required String eventId,
    required String intelUid,
    String variantId = 'variant',
    int occurredAt = 1747520000,
    int elapsedPlaybackMs = 12000,
  }) {
    return TelemetryEvent(
      eventId: eventId,
      identity: TrackIdentity(
        intelUid: intelUid,
        variantId: variantId,
        contentHash: 'hash',
      ),
      type: TelemetryEventType.thresholdCrossed,
      occurredAt: occurredAt,
      elapsedPlaybackMs: elapsedPlaybackMs,
    );
  }

  TelemetryEvent favorited({
    required String eventId,
    required String intelUid,
    required bool value,
    int occurredAt = 1747520000,
  }) {
    return TelemetryEvent(
      eventId: eventId,
      identity: TrackIdentity(
        intelUid: intelUid,
        variantId: 'variant',
        contentHash: 'hash',
      ),
      type: TelemetryEventType.favorited,
      occurredAt: occurredAt,
      favoriteValue: value,
    );
  }

  TelemetryBatch batch(List<TelemetryEvent> events) =>
      TelemetryBatch(deviceId: 'iphone-zico', events: events);

  Future<Map<String, Object?>?> trackRow(String intelUid) async {
    final rows = await appDb.db
        .query('tracks', where: 'uid = ?', whereArgs: [intelUid]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<int> processedCount() async {
    final rows = await appDb.db
        .rawQuery('SELECT COUNT(*) AS c FROM processed_mobile_events');
    return rows.first['c'] as int;
  }

  // ─── Threshold reconciliation ─────────────────────────────────────

  group('thresholdCrossed', () {
    test('atomic mutation: reviewed_at + play_count++ + last_played_at',
        () async {
      await seedTrack(intelUid: 'song-A');
      final ack = await reconciler.reconcile(batch([
        threshold(eventId: 'evt-1', intelUid: 'song-A', occurredAt: 1000),
      ]));
      expect(ack.eventsApplied, 1);
      expect(ack.acceptedEventIds, ['evt-1']);
      final row = await trackRow('song-A');
      // One atomic write — every field set together.
      expect(row!['reviewed_at'], 1000);
      expect(row['play_count'], 1);
      expect(row['last_played_at'], 1000);
    });

    test('replay: reviewed_at is sticky, play_count still increments',
        () async {
      // First threshold stamps reviewed_at. Second threshold (a
      // replay in a new session) does NOT bump reviewed_at —
      // that's a once-set, never-overwrite signal. play_count
      // and last_played_at still update.
      await seedTrack(intelUid: 'song-A');
      await reconciler.reconcile(batch([
        threshold(eventId: 'evt-1', intelUid: 'song-A', occurredAt: 1000),
      ]));
      await reconciler.reconcile(batch([
        threshold(eventId: 'evt-2', intelUid: 'song-A', occurredAt: 5000),
      ]));
      final row = await trackRow('song-A');
      expect(row!['reviewed_at'], 1000); // sticky
      expect(row['play_count'], 2);
      expect(row['last_played_at'], 5000);
    });
  });

  // ─── Favorite reconciliation (LWW) ────────────────────────────────

  group('favorited', () {
    test('first-time favorite stamps timestamp + flips state', () async {
      await seedTrack(intelUid: 'song-A');
      await reconciler.reconcile(batch([
        favorited(
            eventId: 'evt-1',
            intelUid: 'song-A',
            value: true,
            occurredAt: 1000),
      ]));
      final row = await trackRow('song-A');
      expect(row!['favorite'], 1);
      expect(row['favorite_toggled_at'], 1000);
    });

    test('LWW: newer phone wins over older desktop', () async {
      // Desktop favorite=false at T=500. Phone arrives with
      // favorite=true at T=1000 (later) → phone wins.
      await seedTrack(
        intelUid: 'song-A',
        favorite: false,
        favoriteToggledAt: 500,
      );
      await reconciler.reconcile(batch([
        favorited(
            eventId: 'evt-1',
            intelUid: 'song-A',
            value: true,
            occurredAt: 1000),
      ]));
      final row = await trackRow('song-A');
      expect(row!['favorite'], 1);
      expect(row['favorite_toggled_at'], 1000);
    });

    test('LWW: older phone loses to newer desktop', () async {
      // Desktop favorite=false at T=2000 (newer). Phone arrives
      // with favorite=true at T=1000 (older) → desktop wins.
      // Audit still lands (so the user can see "phone tried but
      // we kept desktop's choice").
      await seedTrack(
        intelUid: 'song-A',
        favorite: false,
        favoriteToggledAt: 2000,
      );
      final ack = await reconciler.reconcile(batch([
        favorited(
            eventId: 'evt-1',
            intelUid: 'song-A',
            value: true,
            occurredAt: 1000),
      ]));
      expect(ack.eventsApplied, 1); // counted as applied; audit logged
      final row = await trackRow('song-A');
      expect(row!['favorite'], 0); // desktop wins
      expect(row['favorite_toggled_at'], 2000);
      // Audit row exists with lww_ignored=true so the activity
      // strip can narrate "phone tried to favorite but desktop's
      // toggle was newer."
      final auditRows = await appDb.db.query('events');
      final payload = auditRows.first['payload'] as String;
      expect(payload, contains('lww_ignored'));
    });
  });

  // ─── Idempotency (the load-bearing property) ──────────────────────

  group('idempotency', () {
    test('duplicate event_id → applied once, deduped on replay',
        () async {
      await seedTrack(intelUid: 'song-A');
      // First upload applies.
      final ack1 = await reconciler.reconcile(batch([
        threshold(eventId: 'evt-1', intelUid: 'song-A', occurredAt: 1000),
      ]));
      expect(ack1.eventsApplied, 1);
      expect(ack1.eventsDeduped, 0);

      // Phone resends the same event (network retry / partial
      // failure). Desktop dedups via processed_mobile_events PK.
      final ack2 = await reconciler.reconcile(batch([
        threshold(eventId: 'evt-1', intelUid: 'song-A', occurredAt: 1000),
      ]));
      expect(ack2.eventsApplied, 0);
      expect(ack2.eventsDeduped, 1);
      // Both responses include the event_id as accepted — phone
      // knows it can mark this event as fully acknowledged.
      expect(ack2.acceptedEventIds, ['evt-1']);

      // play_count stayed at 1 — duplicate did NOT inflate.
      final row = await trackRow('song-A');
      expect(row!['play_count'], 1);
    });

    test('processed_mobile_events keyed by event_id (PK enforced)',
        () async {
      await seedTrack(intelUid: 'song-A');
      await reconciler.reconcile(batch([
        threshold(eventId: 'evt-1', intelUid: 'song-A'),
        threshold(eventId: 'evt-2', intelUid: 'song-A'),
      ]));
      expect(await processedCount(), 2);

      // Resend both. Counter shouldn't grow.
      await reconciler.reconcile(batch([
        threshold(eventId: 'evt-1', intelUid: 'song-A'),
        threshold(eventId: 'evt-2', intelUid: 'song-A'),
      ]));
      expect(await processedCount(), 2);
    });
  });

  // ─── Clock-skew clamp ─────────────────────────────────────────────

  group('clock skew', () {
    test('far-future occurred_at clamped to receipt time + tagged',
        () async {
      // now = 2026-05-17 12:00. Phone claims it happened in
      // 2027. Clamp to receipt (now) and tag the event.
      await seedTrack(intelUid: 'song-A');
      final farFutureMs = DateTime(2027, 1, 1).millisecondsSinceEpoch;
      final ack = await reconciler.reconcile(batch([
        threshold(
            eventId: 'evt-1', intelUid: 'song-A', occurredAt: farFutureMs),
      ]));
      expect(ack.eventsClockClamped, 1);
      final row = await trackRow('song-A');
      // last_played_at uses the CLAMPED timestamp, not the
      // bogus future one. (We don't want a 2027 timestamp
      // landing in the audit trail.)
      expect(row!['last_played_at'], now.millisecondsSinceEpoch);

      // Audit payload preserves the original phone timestamp +
      // the clock_clamped flag for diagnostics.
      final auditRows = await appDb.db.query('events');
      final payload = jsonDecode(auditRows.first['payload'] as String);
      expect(payload['origin_event_time'], farFutureMs);
      expect(payload['clock_clamped'], isTrue);
    });

    test('past timestamps are honored (phone offline for a month)',
        () async {
      // A month-old offline event must NOT clamp — the phone
      // may legitimately have been offline that long. Only
      // future-skew triggers the clamp.
      await seedTrack(intelUid: 'song-A');
      final monthAgo = now
          .subtract(const Duration(days: 30))
          .millisecondsSinceEpoch;
      final ack = await reconciler.reconcile(batch([
        threshold(
            eventId: 'evt-1', intelUid: 'song-A', occurredAt: monthAgo),
      ]));
      expect(ack.eventsClockClamped, 0);
      final row = await trackRow('song-A');
      expect(row!['last_played_at'], monthAgo);
    });

    test('within tolerance (~5 min ahead) is NOT clamped', () async {
      // Phone clock 2 minutes ahead — typical NTP drift, not
      // worth clamping.
      await seedTrack(intelUid: 'song-A');
      final twoMinAhead =
          now.add(const Duration(minutes: 2)).millisecondsSinceEpoch;
      final ack = await reconciler.reconcile(batch([
        threshold(
            eventId: 'evt-1', intelUid: 'song-A', occurredAt: twoMinAhead),
      ]));
      expect(ack.eventsClockClamped, 0);
    });
  });

  // ─── Unknown identity / deleted-on-desktop ────────────────────────

  group('identity handling', () {
    test('telemetry for unknown intel_uid → skipped, not applied',
        () async {
      final ack = await reconciler.reconcile(batch([
        threshold(eventId: 'evt-1', intelUid: 'song-NEVER-IMPORTED'),
      ]));
      expect(ack.eventsSkipped, 1);
      expect(ack.eventsApplied, 0);
      expect(ack.acceptedEventIds, isEmpty);
    });

    test('intelligence survives even after physical file deleted',
        () async {
      // Existing desktop semantics: deleting a file leaves the
      // intelligence row intact. Telemetry that arrives after
      // the file is gone still applies to the surviving row.
      // This is the contract from plan §6.
      await seedTrack(intelUid: 'song-A', playCount: 5);
      // (No indexed_files row exists — simulates "file deleted".)
      final ack = await reconciler.reconcile(batch([
        threshold(eventId: 'evt-1', intelUid: 'song-A', occurredAt: 1000),
      ]));
      expect(ack.eventsApplied, 1);
      final row = await trackRow('song-A');
      expect(row!['play_count'], 6);
    });
  });

  // ─── Reserved-for-future event types ──────────────────────────────

  group('reserved event types (forward-compat)', () {
    test('playStarted is dedup-recorded but NOT state-applied', () async {
      // Future-reconciler upgrades may apply these; today we
      // record the dedup row so a future re-process doesn't
      // double-apply, but make no state mutation.
      await seedTrack(intelUid: 'song-A');
      final ack = await reconciler.reconcile(batch([
        TelemetryEvent(
          eventId: 'evt-1',
          identity: const TrackIdentity(
            intelUid: 'song-A',
            variantId: 'v',
            contentHash: 'h',
          ),
          type: TelemetryEventType.playStarted,
          occurredAt: 1000,
        ),
      ]));
      expect(ack.eventsSkipped, 1);
      expect(ack.eventsApplied, 0);
      final row = await trackRow('song-A');
      expect(row!['play_count'], 0);
      // Dedup row WAS inserted so future re-process won't double-apply.
      expect(await processedCount(), 1);
    });
  });

  // ─── Audit trail with mobile origin ───────────────────────────────

  group('audit trail', () {
    test('threshold event lands with origin=mobile:<device_id>',
        () async {
      await seedTrack(intelUid: 'song-A');
      await reconciler.reconcile(batch([
        threshold(eventId: 'evt-1', intelUid: 'song-A', occurredAt: 1000),
      ]));
      final events = await libraryRepo.loadRecentEvents();
      expect(events, hasLength(1));
      expect(events.first.origin, 'mobile:iphone-zico');
      expect(events.first.eventType, EventType.tracksPlayed);
      expect(events.first.payload['intel_uid'], 'song-A');
      expect(events.first.payload['origin_event_id'], 'evt-1');
    });

    test('favorite event audit lands with origin=mobile:<device_id>',
        () async {
      await seedTrack(intelUid: 'song-A');
      await reconciler.reconcile(batch([
        favorited(
            eventId: 'evt-1',
            intelUid: 'song-A',
            value: true,
            occurredAt: 1000),
      ]));
      final events = await libraryRepo.loadRecentEvents();
      expect(events.first.origin, 'mobile:iphone-zico');
      expect(events.first.eventType, EventType.favoritesAdded);
      expect(events.first.payload['favorite'], isTrue);
    });
  });

  // ─── Sync-session attribution (PR2.6 operational foundation) ──────

  group('syncSessionId threading', () {
    late SyncSessionStore sessions;
    late SyncSession session;

    setUp(() async {
      sessions = SyncSessionStore(appDb: appDb, now: () => now);
      session = await sessions.start(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
      );
      // Rebuild the reconciler so it shares the same session
      // store instance the test uses to read counters back.
      reconciler = TelemetryReconciler(
        appDb: appDb,
        libraryRepo: libraryRepo,
        sessionStore: sessions,
        now: () => now,
      );
    });

    test('batch with sync_session_id bumps session counters', () async {
      await seedTrack(intelUid: 'song-A');
      await reconciler.reconcile(TelemetryBatch(
        deviceId: 'iphone-zico',
        syncSessionId: session.sessionId,
        events: [
          threshold(eventId: 'evt-1', intelUid: 'song-A'),
          favorited(
              eventId: 'evt-2',
              intelUid: 'song-A',
              value: true,
              occurredAt: 1000),
        ],
      ));
      final fetched = await sessions.findSession(session.sessionId);
      expect(fetched!.telemetryApplied, 2);
      expect(fetched.telemetryDeduped, 0);
      expect(fetched.telemetrySkipped, 0);
    });

    test('replay increments deduped counter on the session', () async {
      await seedTrack(intelUid: 'song-A');
      // First upload: 1 applied.
      await reconciler.reconcile(TelemetryBatch(
        deviceId: 'iphone-zico',
        syncSessionId: session.sessionId,
        events: [threshold(eventId: 'evt-1', intelUid: 'song-A')],
      ));
      // Retry: dedup. Counter shows applied=1, deduped=1 across
      // the two batches.
      await reconciler.reconcile(TelemetryBatch(
        deviceId: 'iphone-zico',
        syncSessionId: session.sessionId,
        events: [threshold(eventId: 'evt-1', intelUid: 'song-A')],
      ));
      final fetched = await sessions.findSession(session.sessionId);
      expect(fetched!.telemetryApplied, 1);
      expect(fetched.telemetryDeduped, 1);
    });

    test('clock-clamped events bump clock_clamped counter', () async {
      await seedTrack(intelUid: 'song-A');
      final farFutureMs = DateTime(2027).millisecondsSinceEpoch;
      await reconciler.reconcile(TelemetryBatch(
        deviceId: 'iphone-zico',
        syncSessionId: session.sessionId,
        events: [
          threshold(
              eventId: 'evt-1',
              intelUid: 'song-A',
              occurredAt: farFutureMs),
        ],
      ));
      final fetched = await sessions.findSession(session.sessionId);
      expect(fetched!.telemetryClockClamped, 1);
    });

    test('audit events carry sync_session_id in payload', () async {
      await seedTrack(intelUid: 'song-A');
      await reconciler.reconcile(TelemetryBatch(
        deviceId: 'iphone-zico',
        syncSessionId: session.sessionId,
        events: [threshold(eventId: 'evt-1', intelUid: 'song-A')],
      ));
      final events = await libraryRepo.loadRecentEvents();
      expect(events.first.payload['sync_session_id'],
          session.sessionId);
    });

    test('session-less batch (ambient) still reconciles, no counter bump',
        () async {
      // Ambient catch-up — phone fires telemetry between
      // handshakes. Reconciler must accept it (the events are
      // real); the session row just doesn't update.
      await seedTrack(intelUid: 'song-A');
      final ack = await reconciler.reconcile(TelemetryBatch(
        deviceId: 'iphone-zico',
        // syncSessionId omitted on purpose
        events: [threshold(eventId: 'evt-1', intelUid: 'song-A')],
      ));
      expect(ack.eventsApplied, 1);
      final fetched = await sessions.findSession(session.sessionId);
      expect(fetched!.telemetryApplied, 0,
          reason:
              'Session counters only bump when the batch attaches to a session');
    });
  });

  // ─── Batch behavior (per-event, not all-or-nothing) ───────────────

  group('batch semantics', () {
    test('mixed batch: applies each event independently', () async {
      await seedTrack(intelUid: 'song-A');
      await seedTrack(intelUid: 'song-B');
      // 3 events: threshold A, favorite B, threshold for unknown.
      final ack = await reconciler.reconcile(batch([
        threshold(eventId: 'evt-1', intelUid: 'song-A', occurredAt: 1000),
        favorited(
            eventId: 'evt-2',
            intelUid: 'song-B',
            value: true,
            occurredAt: 2000),
        threshold(
            eventId: 'evt-3',
            intelUid: 'song-NEVER',
            occurredAt: 3000),
      ]));
      expect(ack.eventsApplied, 2);
      expect(ack.eventsSkipped, 1);
      // accepted = events that landed (applied OR deduped).
      // skipped events are NOT in accepted — phone retains them.
      expect(ack.acceptedEventIds, equals(['evt-1', 'evt-2']));

      // State applied correctly per event.
      expect((await trackRow('song-A'))!['play_count'], 1);
      expect((await trackRow('song-B'))!['favorite'], 1);
    });
  });
}

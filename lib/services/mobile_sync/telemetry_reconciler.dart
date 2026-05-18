import 'dart:convert';

import 'package:shared_core/shared_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../models/activity_event.dart';
import '../database.dart';
import '../library_repository.dart';
import 'sync_orchestrator.dart';
import 'sync_session_store.dart';

/// Outcome of reconciling one event. Tracks accept-and-applied
/// vs accept-and-deduped vs skip-with-reason so the ACK envelope
/// can carry accurate counters.
enum _ReconcileOutcome {
  applied,
  deduped,
  skippedUnknownIdentity,
  skippedNotApplicable,
}

class _ReconcileResult {
  final _ReconcileOutcome outcome;
  final bool clockClamped;
  const _ReconcileResult(this.outcome, {this.clockClamped = false});
}

/// Reconciles phone-emitted telemetry into the desktop's
/// canonical intelligence rows.
///
/// **Architectural rules** (locked in pre-PR2.5):
///
///   1. Per-event atomic transaction wraps:
///        INSERT INTO processed_mobile_events  ← dedup gate
///        applyState (updateIntelligence / favorite LWW)
///        recordEvent (audit trail, `origin='mobile:<device_id>'`)
///      Either all three commit or none. If processed_mobile_events
///      insert fails (PK conflict = already processed), the event
///      is reported as `deduped` — a SUCCESS outcome from the
///      phone's perspective. Replay-safe.
///
///   2. Batch is NOT atomic. Each event applies independently.
///      Mid-batch failure leaves earlier events processed; the
///      phone retries the rest on next sync. UUID dedup makes
///      this safe.
///
///   3. Identity layer: telemetry merges on `intel_uid` (song
///      identity), NOT `variant_id`. Review/favorite/play counts
///      belong to the song, not the byte payload. Phone may
///      coincidentally hold two variants of the same song; the
///      reconciler unifies them.
///
///   4. Clock-skew: `occurred_at` is honored unless it's more
///      than [futureSkewTolerance] (default 5 min) ahead of
///      receipt time. Beyond tolerance, clamp to receipt time
///      and tag the event as clock_clamped. Past skew is fine
///      — the phone may have been offline for weeks.
///
///   5. Only [TelemetryEventType.thresholdCrossed] and
///      [TelemetryEventType.favorited] apply state in Slice 1.
///      Other types are logged + skipped via
///      `skippedNotApplicable` outcome. They still occupy an
///      event_id in `processed_mobile_events` so a future
///      reconciler upgrade doesn't re-process them.
///
///   6. If the phone reports telemetry for an `intel_uid` that
///      no longer exists on desktop (file deleted), the
///      reconciler still applies the state mutation to the
///      surviving `tracks` row — intelligence outlives files
///      (existing desktop semantics). If the `intel_uid` truly
///      can't be resolved (e.g., never imported), the event is
///      skipped with `skippedUnknownIdentity`.
class TelemetryReconciler {
  TelemetryReconciler({
    required this.appDb,
    required this.libraryRepo,
    SyncSessionStore? sessionStore,
    this.orchestrator,
    Duration? futureSkewTolerance,
    DateTime Function()? now,
  })  : sessionStore = sessionStore ??
            SyncSessionStore(appDb: appDb, now: now),
        _futureSkewTolerance =
            futureSkewTolerance ?? const Duration(minutes: 5),
        _now = now ?? DateTime.now;

  final AppDatabase appDb;
  final LibraryRepository libraryRepo;

  /// Session lifecycle owner. When a [TelemetryBatch] carries a
  /// `syncSessionId`, the reconciler bumps that session's
  /// counters (`telemetry_applied`, `telemetry_deduped`,
  /// `telemetry_skipped`, `telemetry_clock_clamped`) so the
  /// "Last Sync" summary card and the floating progress window
  /// see the same numbers the reconciler reports back to the
  /// phone. Session-less batches (ambient catch-up telemetry)
  /// skip this bump silently.
  final SyncSessionStore sessionStore;

  /// Optional orchestrator dependency. When provided AND the
  /// batch's `syncSessionId` matches the orchestrator's active
  /// session, counter bumps route through
  /// [SyncOrchestrator.recordProgress] — that way the
  /// orchestrator's in-memory snapshot stays in lockstep with
  /// the DB rows. Without this, two writers (reconciler →
  /// sessionStore + orchestrator → its cache) would drift,
  /// breaking the "snapshot matches DB" invariant the
  /// simulator enforces.
  ///
  /// Null for session-less reconciliation (ambient catch-up
  /// telemetry) and for tests that don't exercise the
  /// orchestrator path.
  final SyncOrchestrator? orchestrator;

  final Duration _futureSkewTolerance;
  final DateTime Function() _now;

  Database get _db => appDb.db;

  /// Reconcile one batch. Returns a [TelemetryAck] safe to ship
  /// back to the phone — `acceptedEventIds` includes both
  /// freshly-applied and dedup-hit events. The phone marks all of
  /// them acknowledged + trims its local pending queue.
  Future<TelemetryAck> reconcile(TelemetryBatch batch) async {
    final accepted = <String>[];
    var applied = 0;
    var deduped = 0;
    var skipped = 0;
    var clockClamped = 0;

    for (final event in batch.events) {
      try {
        final result = await _reconcileOne(
          deviceId: batch.deviceId,
          event: event,
          syncSessionId: batch.syncSessionId,
        );
        switch (result.outcome) {
          case _ReconcileOutcome.applied:
            accepted.add(event.eventId);
            applied++;
          case _ReconcileOutcome.deduped:
            accepted.add(event.eventId);
            deduped++;
          case _ReconcileOutcome.skippedUnknownIdentity:
          case _ReconcileOutcome.skippedNotApplicable:
            // Not accepted — phone keeps these in pending. (For
            // the not-applicable case the dedup row WAS inserted
            // so a future-reconciler upgrade still has a unique
            // record — but Slice 1 treats them as unacked so the
            // phone has a chance to retry if the desktop later
            // adds support.)
            skipped++;
        }
        if (result.clockClamped) clockClamped++;
      } catch (_) {
        // Per-event failure does NOT halt the batch. The event
        // is simply not in `accepted`; the phone retries.
        // (Swallowed silently here; controller-level callers
        // observe via the ack counts.)
        skipped++;
      }
    }

    // Bump session counters if this batch is attached to one.
    // Session-less ambient batches skip this — they predate the
    // current session lifecycle.
    //
    // Routing rule: when an orchestrator is wired AND its active
    // session matches the batch's syncSessionId, route through
    // `orchestrator.recordProgress` so the in-memory snapshot
    // and the DB stay in lockstep (the "snapshot matches DB"
    // invariant the simulator enforces). Otherwise (no
    // orchestrator wired, or batch targets a different session),
    // fall back to the direct DB bump.
    if (batch.syncSessionId != null) {
      final o = orchestrator;
      if (o != null &&
          o.activeSession?.sessionId == batch.syncSessionId) {
        await o.recordProgress(
          telemetryApplied: applied,
          telemetryDeduped: deduped,
          telemetrySkipped: skipped,
          telemetryClockClamped: clockClamped,
        );
      } else {
        await sessionStore.bumpCounters(
          sessionId: batch.syncSessionId!,
          telemetryApplied: applied,
          telemetryDeduped: deduped,
          telemetrySkipped: skipped,
          telemetryClockClamped: clockClamped,
        );
      }
    }

    return TelemetryAck(
      acceptedEventIds: accepted,
      eventsApplied: applied,
      eventsDeduped: deduped,
      eventsSkipped: skipped,
      eventsClockClamped: clockClamped,
    );
  }

  Future<_ReconcileResult> _reconcileOne({
    required String deviceId,
    required TelemetryEvent event,
    String? syncSessionId,
  }) async {
    final receiptMs = _now().millisecondsSinceEpoch;

    // Clock-skew clamp. Past timestamps are fine; future ones
    // beyond tolerance get clamped to receipt time. The original
    // is preserved in the audit payload so we can spot devices
    // with broken clocks.
    var occurredAt = event.occurredAt;
    var clampDelta = 0;
    final tolerance = _futureSkewTolerance.inMilliseconds;
    if (occurredAt > receiptMs + tolerance) {
      clampDelta = occurredAt - receiptMs;
      occurredAt = receiptMs;
    }

    return await _db.transaction((txn) async {
      // Dedup gate. Query first — if the event_id is already
      // recorded, this is a replay; the phone sees it as
      // accepted (idempotency), no state mutation runs.
      //
      // Why not "INSERT OR IGNORE then check timestamp": when
      // the receiver clock is stable (e.g., tests with a fixed
      // `now()`), the inserted processed_at can equal an existing
      // one, making "newly inserted vs replay" ambiguous. A
      // SELECT-first check is unambiguous regardless of clock
      // resolution.
      final existing = await txn.rawQuery(
        'SELECT 1 FROM processed_mobile_events WHERE event_id = ? LIMIT 1',
        [event.eventId],
      );
      if (existing.isNotEmpty) {
        return _ReconcileResult(_ReconcileOutcome.deduped);
      }
      await txn.insert('processed_mobile_events', {
        'event_id': event.eventId,
        'device_id': deviceId,
        'event_type': event.type.wireName,
        'intel_uid': event.identity.intelUid,
        'occurred_at': occurredAt,
        'processed_at': receiptMs,
      });

      // Only the Slice-1 applied types proceed past the dedup.
      // Reserved-for-future types insert their dedup row above
      // (so a future-reconciler upgrade still gets idempotency)
      // but otherwise no-op.
      if (!event.type.isAppliedSlice1) {
        return _ReconcileResult(
          _ReconcileOutcome.skippedNotApplicable,
          clockClamped: clampDelta > 0,
        );
      }

      // CRITICAL: read intelligence via the transaction handle,
      // NOT through libraryRepo. Calling libraryRepo here would
      // try to acquire the DB lock the transaction already holds
      // → deadlock on single-isolate sqflite. The transaction
      // object is the only safe path for reads inside this scope.
      final intelUid = event.identity.intelUid;
      final intelRows = await txn.query(
        'tracks',
        where: 'uid = ?',
        whereArgs: [intelUid],
        limit: 1,
      );
      if (intelRows.isEmpty) {
        return _ReconcileResult(
          _ReconcileOutcome.skippedUnknownIdentity,
          clockClamped: clampDelta > 0,
        );
      }
      final intelRow = intelRows.first;

      switch (event.type) {
        case TelemetryEventType.thresholdCrossed:
          await _applyThreshold(
            txn: txn,
            deviceId: deviceId,
            event: event,
            intelUid: intelUid,
            occurredAt: occurredAt,
            currentPlayCount: (intelRow['play_count'] as int?) ?? 0,
            currentReviewedAt: intelRow['reviewed_at'] as int?,
            clockClamped: clampDelta > 0,
            syncSessionId: syncSessionId,
          );
        case TelemetryEventType.favorited:
          await _applyFavorite(
            txn: txn,
            deviceId: deviceId,
            event: event,
            intelUid: intelUid,
            occurredAt: occurredAt,
            currentFavoriteToggledAt:
                intelRow['favorite_toggled_at'] as int?,
            currentFavorite:
                ((intelRow['favorite'] as int?) ?? 0) != 0,
            clockClamped: clampDelta > 0,
            syncSessionId: syncSessionId,
          );
        default:
          // Defensive — isAppliedSlice1 guard above already
          // prevented this, but the switch's exhaustiveness
          // check would otherwise complain.
          return _ReconcileResult(
            _ReconcileOutcome.skippedNotApplicable,
            clockClamped: clampDelta > 0,
          );
      }

      return _ReconcileResult(
        _ReconcileOutcome.applied,
        clockClamped: clampDelta > 0,
      );
    });
  }

  // ─── Per-event-type appliers ──────────────────────────────────────

  /// thresholdCrossed: stamp `reviewed_at ??= occurred_at`,
  /// `play_count++`, `last_played_at = occurred_at`, plus an
  /// audit event. The whole mutation lands via
  /// `repo.updateIntelligence` so the bucket-mirror semantics
  /// (favorite/playCount cascade across variants of the same
  /// song) match what local playback does.
  ///
  /// Per-event-atomic: inside the existing transaction, so a
  /// post-write crash leaves the dedup row + state mutation +
  /// audit event committed together (or not at all).
  Future<void> _applyThreshold({
    required Transaction txn,
    required String deviceId,
    required TelemetryEvent event,
    required String intelUid,
    required int occurredAt,
    required int currentPlayCount,
    required int? currentReviewedAt,
    required bool clockClamped,
    String? syncSessionId,
  }) async {
    final values = <String, Object?>{
      'play_count': currentPlayCount + 1,
      'last_played_at': occurredAt,
      if (currentReviewedAt == null) 'reviewed_at': occurredAt,
    };
    await txn.update(
      'tracks',
      values,
      where: 'uid = ?',
      whereArgs: [intelUid],
    );

    await _recordAudit(
      txn: txn,
      deviceId: deviceId,
      eventType: EventType.tracksPlayed,
      intelUid: intelUid,
      occurredAt: occurredAt,
      payload: {
        'origin_event_id': event.eventId,
        'origin_event_type': event.type.wireName,
        'origin_event_time': event.occurredAt,
        if (event.elapsedPlaybackMs != null)
          'elapsed_playback_ms': event.elapsedPlaybackMs,
        if (clockClamped) 'clock_clamped': true,
        'sync_session_id': ?syncSessionId,
      },
    );
  }

  /// favorited: LWW on `favorite_toggled_at`. The desktop's
  /// repo.updateIntelligence already supports an explicit
  /// `favoriteToggledAt` parameter — we pass the event's
  /// `occurred_at` and only write if it's newer than the stored
  /// timestamp. Either way (apply or skip), we leave an audit
  /// entry so the user can see the phone tried.
  Future<void> _applyFavorite({
    required Transaction txn,
    required String deviceId,
    required TelemetryEvent event,
    required String intelUid,
    required int occurredAt,
    required int? currentFavoriteToggledAt,
    required bool currentFavorite,
    required bool clockClamped,
    String? syncSessionId,
  }) async {
    final newValue = event.favoriteValue ?? false;
    final shouldApply = currentFavoriteToggledAt == null ||
        occurredAt > currentFavoriteToggledAt;

    if (shouldApply) {
      await txn.update(
        'tracks',
        {
          'favorite': newValue ? 1 : 0,
          'favorite_toggled_at': occurredAt,
        },
        where: 'uid = ?',
        whereArgs: [intelUid],
      );
    }

    await _recordAudit(
      txn: txn,
      deviceId: deviceId,
      eventType: EventType.favoritesAdded,
      intelUid: intelUid,
      occurredAt: occurredAt,
      payload: {
        'origin_event_id': event.eventId,
        'origin_event_type': event.type.wireName,
        'origin_event_time': event.occurredAt,
        'favorite': newValue,
        if (!shouldApply) 'lww_ignored': true,
        if (clockClamped) 'clock_clamped': true,
        'sync_session_id': ?syncSessionId,
      },
    );
  }

  /// Append to `events` with `origin='mobile:<device_id>'` so
  /// the activity strip can render "Zico played 1 track on
  /// iPhone" distinctly from local plays.
  Future<void> _recordAudit({
    required Transaction txn,
    required String deviceId,
    required String eventType,
    required String intelUid,
    required int occurredAt,
    required Map<String, Object?> payload,
  }) async {
    await txn.insert('events', {
      // Recorded_at = wall clock at the moment we wrote, NOT the
      // event's occurred_at. Lets the audit log show "received
      // at" ordering even when phones replay months of offline
      // history. The phone-side time is preserved in payload.
      'recorded_at': _now().millisecondsSinceEpoch,
      'event_type': eventType,
      'path': null,
      'source_id': null,
      'payload': jsonEncode({
        'intel_uid': intelUid,
        'origin_device_id': deviceId,
        ...payload,
      }),
      'origin': 'mobile:$deviceId',
    });
  }
}

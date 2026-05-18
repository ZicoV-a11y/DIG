// Structural invariants — properties the desktop sync stack
// must preserve regardless of which chaos scenario runs.
//
// Each invariant throws on violation with a precise reason so
// the simulator's per-invariant report points directly at the
// broken contract. Implementations read live state via the
// simulator's exposed layers; no scenario-specific knowledge.

import 'package:shared_core/shared_core.dart';

import 'sync_simulator.dart';

/// "At most one active (non-completed) sync_sessions row per
/// device." Replays / re-pairs / interrupted sessions must not
/// leave orphans that would confuse the sidebar + orchestrator.
class NoOrphanedActiveSession extends SyncInvariant {
  @override
  String get name => 'no_orphaned_active_session';

  @override
  Future<void> check(SyncSimulator sim) async {
    final rows = await sim.appDb.db.rawQuery(
      'SELECT device_id, COUNT(*) AS c FROM sync_sessions '
      'WHERE completed_at IS NULL GROUP BY device_id',
    );
    for (final r in rows) {
      final count = r['c'] as int;
      if (count > 1) {
        throw 'device ${r['device_id']} has $count active sessions';
      }
    }
  }
}

/// "Orchestrator's in-memory active session matches the DB
/// row." Drift here means UI surfaces would render different
/// truth than the audit trail.
class OrchestratorSnapshotMatchesDb extends SyncInvariant {
  @override
  String get name => 'orchestrator_snapshot_matches_db';

  @override
  Future<void> check(SyncSimulator sim) async {
    final active = sim.orchestrator.activeSession;
    if (active == null) return; // nothing to compare
    final row = await sim.sessions.findSession(active.sessionId);
    if (row == null) {
      throw 'orchestrator holds session ${active.sessionId} '
          'but DB has no row';
    }
    if (row.currentState != active.currentState) {
      throw 'state drift — orchestrator: ${active.currentState.wireName}, '
          'DB: ${row.currentState.wireName}';
    }
    if (row.telemetryApplied != active.telemetryApplied) {
      throw 'telemetry_applied drift — orchestrator: '
          '${active.telemetryApplied}, DB: ${row.telemetryApplied}';
    }
  }
}

/// "Every event_id in processed_mobile_events is unique." The
/// dedup table is the load-bearing idempotency primitive — a
/// duplicate row would imply two reconciliations of the same
/// event slipped through.
class ProcessedEventsUniqueByEventId extends SyncInvariant {
  @override
  String get name => 'processed_events_unique_by_event_id';

  @override
  Future<void> check(SyncSimulator sim) async {
    final rows = await sim.appDb.db.rawQuery(
      'SELECT event_id, COUNT(*) AS c FROM processed_mobile_events '
      'GROUP BY event_id HAVING COUNT(*) > 1',
    );
    if (rows.isNotEmpty) {
      throw 'duplicate event_ids in processed_mobile_events: '
          '${rows.map((r) => r['event_id']).toList()}';
    }
  }
}

/// "play_count was incremented at most once per submitted
/// event_id." Even if telemetry was sent N times, the
/// reconciler's dedup means desktop intelligence sees exactly
/// one increment.
class PlayCountMatchesUniqueThresholdEvents extends SyncInvariant {
  @override
  String get name => 'play_count_matches_unique_threshold_events';

  @override
  Future<void> check(SyncSimulator sim) async {
    // Count of threshold events recorded in processed_mobile_events
    // (i.e., events that actually applied) — grouped by intel_uid.
    final processed = await sim.appDb.db.rawQuery(
      "SELECT intel_uid, COUNT(*) AS c "
      "FROM processed_mobile_events "
      "WHERE event_type = 'threshold_crossed' AND intel_uid IS NOT NULL "
      "GROUP BY intel_uid",
    );

    // Tracks table — actual play_count per intel_uid the
    // reconciler bumped.
    final tracks = await sim.appDb.db.rawQuery(
      "SELECT uid AS intel_uid, play_count FROM tracks",
    );
    final playCountByIntel = {
      for (final r in tracks)
        r['intel_uid'] as String: (r['play_count'] as int?) ?? 0,
    };

    for (final p in processed) {
      final intel = p['intel_uid'] as String;
      final expected = p['c'] as int;
      final actual = playCountByIntel[intel] ?? 0;
      if (actual != expected) {
        throw 'play_count inflation/loss for intel=$intel — '
            'processed=$expected, tracks.play_count=$actual';
      }
    }
  }
}

/// "Failed sessions never bumped the device's
/// last_manifest_version." A network drop mid-transfer must
/// NOT advance the cursor — otherwise the next sync would
/// skip the un-delivered tracks.
class FailedSessionsDoNotAdvanceManifestVersion extends SyncInvariant {
  @override
  String get name => 'failed_sessions_do_not_advance_manifest_version';

  @override
  Future<void> check(SyncSimulator sim) async {
    // Slice 1 baseline: last_manifest_version on mobile_devices
    // is bumped by `SyncSessionStore.markSynced`, called only
    // after a successful sync completes. A failed session that
    // touched it would be a contract break.
    final device = await sim.syncRepo.getDevice(sim.device.deviceId);
    if (device == null) return; // device deleted in scenario

    // Count failed sessions for this device.
    final failed = await sim.appDb.db.rawQuery(
      "SELECT COUNT(*) AS c FROM sync_sessions "
      "WHERE device_id = ? AND completed_at IS NOT NULL "
      "AND current_state != 'rotation_complete'",
      [sim.device.deviceId],
    );
    final failedCount = failed.first['c'] as int;

    // Successful sessions for this device.
    final succeeded = await sim.appDb.db.rawQuery(
      "SELECT COUNT(*) AS c FROM sync_sessions "
      "WHERE device_id = ? AND completed_at IS NOT NULL "
      "AND current_state = 'rotation_complete'",
      [sim.device.deviceId],
    );
    final succeededCount = succeeded.first['c'] as int;

    // If only failed sessions exist, last_manifest_version
    // must still be 0 (or whatever it was before any sync).
    if (failedCount > 0 && succeededCount == 0) {
      if (device.lastManifestVersion != 0) {
        throw 'last_manifest_version advanced to '
            '${device.lastManifestVersion} despite only failed sessions';
      }
    }
  }
}

/// "Total processed events ≤ total unique event_ids submitted
/// across all reconciliations." Drift detection: if more rows
/// in processed_mobile_events than there were unique events,
/// something is duplicating phantom events.
class ProcessedEventsCountIsBounded extends SyncInvariant {
  @override
  String get name => 'processed_events_count_is_bounded';

  /// The scenario's expected upper bound — must be set by the
  /// scenario before invariants run. Defaults to unbounded if
  /// the scenario doesn't care.
  int? expectedMax;

  @override
  Future<void> check(SyncSimulator sim) async {
    final rows = await sim.appDb.db.rawQuery(
      'SELECT COUNT(*) AS c FROM processed_mobile_events',
    );
    final count = rows.first['c'] as int;
    final cap = expectedMax;
    if (cap != null && count > cap) {
      throw 'processed_mobile_events has $count rows, expected ≤ $cap';
    }
  }
}

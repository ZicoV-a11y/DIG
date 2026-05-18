import 'package:shared_core/shared_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../database.dart';

/// Persistence + lifecycle API for `sync_sessions`. Owns the
/// transitions of a single handshake's operational record:
///   start → state transitions → bump counters → complete
///
/// Per the PR2.6 framing ("sync operations console"): EVERY
/// sync handshake gets a row. Every transport byte, telemetry
/// event, and audit entry attaches by session_id. The UI binds
/// to the resulting rows; no other source of truth.
class SyncSessionStore {
  SyncSessionStore({
    required this.appDb,
    DateTime Function()? now,
    Uuid? uuid,
  })  : _now = now ?? DateTime.now,
        _uuid = uuid ?? const Uuid();

  final AppDatabase appDb;
  final DateTime Function() _now;
  final Uuid _uuid;

  Database get _db => appDb.db;

  /// Open a new session. Caller is the side that initiated the
  /// handshake (phone or desktop). Returns the persisted row.
  ///
  /// Slice 1: opens in [SyncState.negotiating]. The caller drives
  /// subsequent transitions via [recordStateTransition].
  Future<SyncSession> start({
    required String deviceId,
    required SyncInitiator initiatedBy,
    SyncState initialState = SyncState.negotiating,
    String? sessionId,
  }) async {
    final id = sessionId ?? _uuid.v4();
    final nowMs = _now().millisecondsSinceEpoch;
    await _db.insert('sync_sessions', {
      'session_id': id,
      'device_id': deviceId,
      'initiated_by': initiatedBy.wireName,
      'started_at': nowMs,
      'current_state': initialState.wireName,
    });
    return SyncSession(
      sessionId: id,
      deviceId: deviceId,
      initiatedBy: initiatedBy,
      startedAt: nowMs,
      currentState: initialState,
    );
  }

  /// Transition a session to a new SyncState. Idempotent —
  /// re-recording the same state is a no-op. Terminal states
  /// trigger completion stamping; callers should use [complete]
  /// for that path so failure metadata is captured.
  Future<void> recordStateTransition({
    required String sessionId,
    required SyncState state,
  }) async {
    await _db.update(
      'sync_sessions',
      {'current_state': state.wireName},
      where: 'session_id = ? AND completed_at IS NULL',
      whereArgs: [sessionId],
    );
  }

  /// Bump one or more counters atomically. Used by the
  /// reconciler (telemetry_*), the transport layer (bytes,
  /// tracks_added/removed), and the manifest delivery
  /// (manifest_version).
  Future<void> bumpCounters({
    required String sessionId,
    int tracksAdded = 0,
    int tracksRemoved = 0,
    int bytesTransferred = 0,
    int telemetryApplied = 0,
    int telemetryDeduped = 0,
    int telemetrySkipped = 0,
    int telemetryClockClamped = 0,
    int? manifestVersion,
  }) async {
    final updates = <String>[];
    final args = <Object?>[];
    void incIfNonZero(String column, int delta) {
      if (delta == 0) return;
      updates.add('$column = $column + ?');
      args.add(delta);
    }

    incIfNonZero('tracks_added', tracksAdded);
    incIfNonZero('tracks_removed', tracksRemoved);
    incIfNonZero('bytes_transferred', bytesTransferred);
    incIfNonZero('telemetry_applied', telemetryApplied);
    incIfNonZero('telemetry_deduped', telemetryDeduped);
    incIfNonZero('telemetry_skipped', telemetrySkipped);
    incIfNonZero('telemetry_clock_clamped', telemetryClockClamped);
    if (manifestVersion != null) {
      updates.add('manifest_version = ?');
      args.add(manifestVersion);
    }
    if (updates.isEmpty) return;

    args.add(sessionId);
    await _db.rawUpdate(
      'UPDATE sync_sessions SET ${updates.join(', ')} '
      'WHERE session_id = ?',
      args,
    );
  }

  /// Mark a session complete. [finalState] should be the terminal
  /// SyncState reached: [SyncState.rotationComplete] for success,
  /// or a failure state ([SyncState.approvalDeclined],
  /// [SyncState.transferFailed], [SyncState.networkLost]).
  ///
  /// For failure terminations, [failureReason] surfaces in the
  /// audit log + the "Last Sync" summary so the user can see why
  /// the session ended.
  Future<void> complete({
    required String sessionId,
    required SyncState finalState,
    String? failureReason,
  }) async {
    final isFailure = finalState != SyncState.rotationComplete;
    await _db.update(
      'sync_sessions',
      {
        'current_state': finalState.wireName,
        'completed_at': _now().millisecondsSinceEpoch,
        if (isFailure) 'failure_state': finalState.wireName,
        if (isFailure && failureReason != null) 'failure_reason': failureReason,
      },
      where: 'session_id = ? AND completed_at IS NULL',
      whereArgs: [sessionId],
    );
  }

  Future<SyncSession?> findSession(String sessionId) async {
    final rows = await _db.query(
      'sync_sessions',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return SyncSession.fromJson(_rowToJson(rows.first));
  }

  /// The currently-active session for [deviceId], if any. Drives
  /// the sidebar Devices panel's "Syncing now…" / "Awaiting
  /// approval" state derivation. Returns null when no session
  /// is open for this device.
  Future<SyncSession?> activeForDevice(String deviceId) async {
    final rows = await _db.query(
      'sync_sessions',
      where: 'device_id = ? AND completed_at IS NULL',
      whereArgs: [deviceId],
      orderBy: 'started_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return SyncSession.fromJson(_rowToJson(rows.first));
  }

  /// The most recently-completed session for [deviceId]. Drives
  /// the "Last Sync" summary card. Returns null for never-synced.
  Future<SyncSession?> lastCompletedForDevice(String deviceId) async {
    final rows = await _db.query(
      'sync_sessions',
      where: 'device_id = ? AND completed_at IS NOT NULL',
      whereArgs: [deviceId],
      orderBy: 'completed_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return SyncSession.fromJson(_rowToJson(rows.first));
  }

  Map<String, Object?> _rowToJson(Map<String, Object?> r) => {
        'session_id': r['session_id'],
        'device_id': r['device_id'],
        'initiated_by': r['initiated_by'],
        'started_at': r['started_at'],
        'current_state': r['current_state'],
        if (r['completed_at'] != null) 'completed_at': r['completed_at'],
        if (r['manifest_version'] != null)
          'manifest_version': r['manifest_version'],
        'tracks_added': r['tracks_added'],
        'tracks_removed': r['tracks_removed'],
        'bytes_transferred': r['bytes_transferred'],
        'telemetry_applied': r['telemetry_applied'],
        'telemetry_deduped': r['telemetry_deduped'],
        'telemetry_skipped': r['telemetry_skipped'],
        'telemetry_clock_clamped': r['telemetry_clock_clamped'],
        if (r['failure_state'] != null) 'failure_state': r['failure_state'],
        if (r['failure_reason'] != null)
          'failure_reason': r['failure_reason'],
      };
}

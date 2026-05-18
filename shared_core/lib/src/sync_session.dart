import 'sync_state.dart';

/// Who started the handshake.
enum SyncInitiator {
  phone,
  desktop;

  String get wireName => switch (this) {
        SyncInitiator.phone => 'phone',
        SyncInitiator.desktop => 'desktop',
      };

  static SyncInitiator fromWire(String s) => switch (s) {
        'phone' => SyncInitiator.phone,
        'desktop' => SyncInitiator.desktop,
        _ => throw FormatException('Unknown SyncInitiator: $s'),
      };
}

/// A single sync handshake's operational record. Every audit
/// event, progress UI update, telemetry batch, transferred byte,
/// and reconciliation row attaches to this session_id so the
/// "last sync" panel can show:
///
///   42 tracks added · 18 tracks removed
///   84 telemetry events applied · 3 deduped
///   1 future timestamp clamped
///
/// Persisted in `sync_sessions` table. The model is shared (lives
/// in shared_core) so phone-side UI can render an identically-
/// shaped summary card.
class SyncSession {
  /// UUID. Generated when the handshake begins; carried by every
  /// subsequent operation (manifest delivery, file transport,
  /// telemetry upload, audit event payload). The load-bearing
  /// observability primitive.
  final String sessionId;

  final String deviceId;
  final SyncInitiator initiatedBy;

  /// ms since epoch when the session was opened.
  final int startedAt;

  /// Current SyncState. NULL transitions are not allowed —
  /// every transition is observed.
  final SyncState currentState;

  /// ms since epoch. Non-null exactly when the session reached
  /// a terminal state ([SyncState.rotationComplete],
  /// [SyncState.approvalDeclined], [SyncState.transferFailed],
  /// [SyncState.networkLost]).
  final int? completedAt;

  /// The manifest version this session computed. Filled in once
  /// the manifest builder emits.
  final int? manifestVersion;

  /// Operational counters. Bumped as the session progresses; the
  /// final values are the body of the "Last Sync" summary card.
  final int tracksAdded;
  final int tracksRemoved;
  final int bytesTransferred;
  final int telemetryApplied;
  final int telemetryDeduped;
  final int telemetrySkipped;
  final int telemetryClockClamped;

  /// If the session ended in a failure state, the wireName of
  /// that state ([SyncState.approvalDeclined] etc.) plus an
  /// optional human-readable reason.
  final String? failureState;
  final String? failureReason;

  const SyncSession({
    required this.sessionId,
    required this.deviceId,
    required this.initiatedBy,
    required this.startedAt,
    required this.currentState,
    this.completedAt,
    this.manifestVersion,
    this.tracksAdded = 0,
    this.tracksRemoved = 0,
    this.bytesTransferred = 0,
    this.telemetryApplied = 0,
    this.telemetryDeduped = 0,
    this.telemetrySkipped = 0,
    this.telemetryClockClamped = 0,
    this.failureState,
    this.failureReason,
  });

  bool get isActive => completedAt == null;

  /// True only on a clean finish (RotationComplete). False for
  /// declined / failed / lost-network terminations.
  bool get isSuccessful =>
      completedAt != null && currentState == SyncState.rotationComplete;

  /// Immutable update — every orchestrator transition produces a
  /// new snapshot rather than mutating loose fields. The
  /// floating progress window, sidebar, audit trail, and history
  /// panel all key off the returned snapshot, so a single shared
  /// reference moves them all in lockstep.
  SyncSession copyWith({
    SyncState? currentState,
    int? completedAt,
    int? manifestVersion,
    int? tracksAdded,
    int? tracksRemoved,
    int? bytesTransferred,
    int? telemetryApplied,
    int? telemetryDeduped,
    int? telemetrySkipped,
    int? telemetryClockClamped,
    String? failureState,
    String? failureReason,
  }) {
    return SyncSession(
      sessionId: sessionId,
      deviceId: deviceId,
      initiatedBy: initiatedBy,
      startedAt: startedAt,
      currentState: currentState ?? this.currentState,
      completedAt: completedAt ?? this.completedAt,
      manifestVersion: manifestVersion ?? this.manifestVersion,
      tracksAdded: tracksAdded ?? this.tracksAdded,
      tracksRemoved: tracksRemoved ?? this.tracksRemoved,
      bytesTransferred: bytesTransferred ?? this.bytesTransferred,
      telemetryApplied: telemetryApplied ?? this.telemetryApplied,
      telemetryDeduped: telemetryDeduped ?? this.telemetryDeduped,
      telemetrySkipped: telemetrySkipped ?? this.telemetrySkipped,
      telemetryClockClamped:
          telemetryClockClamped ?? this.telemetryClockClamped,
      failureState: failureState ?? this.failureState,
      failureReason: failureReason ?? this.failureReason,
    );
  }

  Map<String, Object?> toJson() => {
        'session_id': sessionId,
        'device_id': deviceId,
        'initiated_by': initiatedBy.wireName,
        'started_at': startedAt,
        'current_state': currentState.wireName,
        if (completedAt != null) 'completed_at': completedAt,
        if (manifestVersion != null) 'manifest_version': manifestVersion,
        'tracks_added': tracksAdded,
        'tracks_removed': tracksRemoved,
        'bytes_transferred': bytesTransferred,
        'telemetry_applied': telemetryApplied,
        'telemetry_deduped': telemetryDeduped,
        'telemetry_skipped': telemetrySkipped,
        'telemetry_clock_clamped': telemetryClockClamped,
        if (failureState != null) 'failure_state': failureState,
        if (failureReason != null) 'failure_reason': failureReason,
      };

  static SyncSession fromJson(Map<String, Object?> j) {
    final sid = j['session_id'];
    final did = j['device_id'];
    final initiated = j['initiated_by'];
    final startedAt = _asInt(j['started_at']);
    final stateWire = j['current_state'];
    if (sid is! String || sid.isEmpty) {
      throw const FormatException('SyncSession.session_id required');
    }
    if (did is! String) {
      throw const FormatException('SyncSession.device_id required');
    }
    if (initiated is! String) {
      throw const FormatException('SyncSession.initiated_by required');
    }
    if (startedAt == null) {
      throw const FormatException('SyncSession.started_at required');
    }
    if (stateWire is! String) {
      throw const FormatException('SyncSession.current_state required');
    }
    return SyncSession(
      sessionId: sid,
      deviceId: did,
      initiatedBy: SyncInitiator.fromWire(initiated),
      startedAt: startedAt,
      currentState: syncStateFromWire(stateWire),
      completedAt: _asInt(j['completed_at']),
      manifestVersion: _asInt(j['manifest_version']),
      tracksAdded: _asInt(j['tracks_added']) ?? 0,
      tracksRemoved: _asInt(j['tracks_removed']) ?? 0,
      bytesTransferred: _asInt(j['bytes_transferred']) ?? 0,
      telemetryApplied: _asInt(j['telemetry_applied']) ?? 0,
      telemetryDeduped: _asInt(j['telemetry_deduped']) ?? 0,
      telemetrySkipped: _asInt(j['telemetry_skipped']) ?? 0,
      telemetryClockClamped: _asInt(j['telemetry_clock_clamped']) ?? 0,
      failureState: j['failure_state'] as String?,
      failureReason: j['failure_reason'] as String?,
    );
  }
}

int? _asInt(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

/// **Playback-exclusive contract** (per Q1 decision): a sync is
/// an operational maintenance window, not a live hot-swap.
/// While a session is in flight, BOTH the desktop and the phone
/// pause / refuse playback so inventory mutation never races a
/// playback engine traversing the same tracks.
///
/// Returns `true` when [active] is non-null AND the session
/// hasn't reached a terminal state. The brief window after
/// [SyncSession.completeSuccess] / [SyncSession.completeFailure]
/// — when the snapshot is still set but currentState is terminal
/// — is NOT blocking, so the post-sync RotationSummary modal can
/// show next to a resumed playback bar without flicker.
bool isSyncBlockingPlayback(SyncSession? active) {
  if (active == null) return false;
  return !isTerminalSyncState(active.currentState);
}

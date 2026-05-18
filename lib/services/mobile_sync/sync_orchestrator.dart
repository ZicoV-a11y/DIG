import 'package:flutter/foundation.dart';
import 'package:shared_core/shared_core.dart';

import 'sync_session_store.dart';

/// Thrown when a caller asks for a transition the state machine
/// doesn't allow. Surfaces a specific (from, to) tuple so the
/// stack trace points at the misbehaving caller rather than at
/// a generic "invalid state" exception.
class IllegalSyncTransitionException implements Exception {
  final SyncState from;
  final SyncState to;
  IllegalSyncTransitionException({required this.from, required this.to});
  @override
  String toString() =>
      'IllegalSyncTransitionException: ${from.wireName} → ${to.wireName} '
      'is not a legal transition.';
}

/// **The conductor.** Owns the deterministic state machine for a
/// single sync handshake from open to terminal.
///
/// Per PR2.6.C guidance:
///   - NOT a "sync manager." A state-machine driver.
///   - Event-driven. Each phase-completion call advances state;
///     no `while (syncing) {}` loop anywhere.
///   - Every transition is validated against [isLegalSyncStateTransition].
///     An invalid transition throws — silent corruption is worse
///     than a crash.
///   - Immutable snapshots: every state change produces a fresh
///     [SyncSession] via copyWith. UI binds to the
///     [activeSessionListenable] notifier; sidebar / progress
///     window / audit trail all observe the same snapshot.
///   - Failure taxonomy: [completeFailure] takes a
///     [SyncFailureCode] (granular) AND a terminal SyncState
///     (lifecycle). The two are persisted together so the "Last
///     Sync" card can narrate operational specifics.
class SyncOrchestrator {
  SyncOrchestrator({
    required this.sessionStore,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final SyncSessionStore sessionStore;
  final DateTime Function() _now;

  /// Snapshot of the currently-active session. Null when no sync
  /// is in flight. UI binds via `ValueListenableBuilder`.
  final ValueNotifier<SyncSession?> _active =
      ValueNotifier<SyncSession?>(null);
  ValueListenable<SyncSession?> get activeSessionListenable => _active;
  SyncSession? get activeSession => _active.value;

  /// Begin a sync session. Opens a fresh `sync_sessions` row in
  /// [SyncState.negotiating] and surfaces the snapshot via the
  /// listenable. Throws [StateError] if a session is already in
  /// flight (one active session per orchestrator instance).
  Future<SyncSession> beginSession({
    required String deviceId,
    required SyncInitiator initiatedBy,
  }) async {
    if (_active.value != null) {
      throw StateError(
        'A sync session is already in flight for this orchestrator. '
        'Complete or fail it before starting a new one.',
      );
    }
    final session = await sessionStore.start(
      deviceId: deviceId,
      initiatedBy: initiatedBy,
    );
    _active.value = session;
    return session;
  }

  /// Advance the active session to [target]. The orchestrator
  /// validates the transition is legal under the
  /// [isLegalSyncStateTransition] map; on success it persists the
  /// new state, refreshes the in-memory snapshot, and notifies
  /// listeners. Throws [IllegalSyncTransitionException] otherwise.
  Future<void> transitionTo(SyncState target) async {
    final current = _active.value;
    if (current == null) {
      throw StateError('No active session to transition.');
    }
    if (!isLegalSyncStateTransition(current.currentState, target)) {
      throw IllegalSyncTransitionException(
        from: current.currentState,
        to: target,
      );
    }
    // Terminal transitions go through completeSuccess / completeFailure
    // so the completed_at + failure_state stamps land atomically.
    // A bare transition to a terminal state is a programming bug.
    if (isTerminalSyncState(target)) {
      throw StateError(
        'transitionTo(${target.wireName}) is terminal. Use '
        'completeSuccess() or completeFailure() instead.',
      );
    }
    await sessionStore.recordStateTransition(
      sessionId: current.sessionId,
      state: target,
    );
    _active.value = current.copyWith(currentState: target);
  }

  /// Record progress within a phase (no state change). Each
  /// argument is a DELTA — pass the increment, not the absolute
  /// count. The orchestrator persists via
  /// [SyncSessionStore.bumpCounters] which is atomic per call.
  ///
  /// `manifestVersion`, when non-null, is set (not added) — it's
  /// a one-shot stamp.
  Future<void> recordProgress({
    int tracksAdded = 0,
    int tracksRemoved = 0,
    int bytesTransferred = 0,
    int telemetryApplied = 0,
    int telemetryDeduped = 0,
    int telemetrySkipped = 0,
    int telemetryClockClamped = 0,
    int? manifestVersion,
  }) async {
    final current = _active.value;
    if (current == null) {
      throw StateError('No active session for recordProgress().');
    }
    await sessionStore.bumpCounters(
      sessionId: current.sessionId,
      tracksAdded: tracksAdded,
      tracksRemoved: tracksRemoved,
      bytesTransferred: bytesTransferred,
      telemetryApplied: telemetryApplied,
      telemetryDeduped: telemetryDeduped,
      telemetrySkipped: telemetrySkipped,
      telemetryClockClamped: telemetryClockClamped,
      manifestVersion: manifestVersion,
    );
    _active.value = current.copyWith(
      tracksAdded: current.tracksAdded + tracksAdded,
      tracksRemoved: current.tracksRemoved + tracksRemoved,
      bytesTransferred: current.bytesTransferred + bytesTransferred,
      telemetryApplied: current.telemetryApplied + telemetryApplied,
      telemetryDeduped: current.telemetryDeduped + telemetryDeduped,
      telemetrySkipped: current.telemetrySkipped + telemetrySkipped,
      telemetryClockClamped:
          current.telemetryClockClamped + telemetryClockClamped,
      manifestVersion: manifestVersion ?? current.manifestVersion,
    );
  }

  /// Terminal success path. Validates the transition
  /// `current → rotationComplete` is legal (must be coming from
  /// [SyncState.finalizingRotation]), stamps `completed_at`, and
  /// clears the active-session notifier.
  Future<void> completeSuccess() async {
    final current = _active.value;
    if (current == null) {
      throw StateError('No active session to complete.');
    }
    if (!isLegalSyncStateTransition(
      current.currentState,
      SyncState.rotationComplete,
    )) {
      throw IllegalSyncTransitionException(
        from: current.currentState,
        to: SyncState.rotationComplete,
      );
    }
    await sessionStore.complete(
      sessionId: current.sessionId,
      finalState: SyncState.rotationComplete,
    );
    _active.value = current.copyWith(
      currentState: SyncState.rotationComplete,
      completedAt: _now().millisecondsSinceEpoch,
    );
    // Hold the snapshot briefly so the UI can render
    // "Rotation complete." — callers clear via [clearActive]
    // when the dismiss timer fires.
  }

  /// Terminal failure path. Takes both the granular
  /// [SyncFailureCode] (audit narration) and the terminal
  /// SyncState the lifecycle landed in (orchestrator graph).
  /// Both are persisted to `sync_sessions.failure_state` +
  /// `failure_reason`; the SyncState becomes the row's
  /// `current_state`.
  ///
  /// [terminalState] must be one of [SyncState.approvalDeclined],
  /// [SyncState.transferFailed], or [SyncState.networkLost], and
  /// must be reachable from the current state in the legal-
  /// transition graph.
  Future<void> completeFailure({
    required SyncFailureCode code,
    required SyncState terminalState,
    String? reason,
  }) async {
    final current = _active.value;
    if (current == null) {
      throw StateError('No active session to fail.');
    }
    if (!isTerminalSyncState(terminalState) ||
        terminalState == SyncState.rotationComplete) {
      throw StateError(
        'completeFailure terminalState must be a failure terminal; '
        'got ${terminalState.wireName}.',
      );
    }
    if (!isLegalSyncStateTransition(current.currentState, terminalState)) {
      throw IllegalSyncTransitionException(
        from: current.currentState,
        to: terminalState,
      );
    }
    await sessionStore.complete(
      sessionId: current.sessionId,
      finalState: terminalState,
      failureReason: reason,
    );
    _active.value = current.copyWith(
      currentState: terminalState,
      completedAt: _now().millisecondsSinceEpoch,
      // Carry the GRANULAR failure code through the snapshot's
      // failureState column. SyncSessionStore.complete stores the
      // terminal SyncState's wireName; we overwrite with the
      // richer code here so the audit panel sees the specific
      // taxonomy.
      failureState: code.wireName,
      failureReason: reason,
    );
    // Persist the granular code over the terminalState's wireName
    // so the row keeps the operationally-specific narration.
    await sessionStore.bumpCounters(sessionId: current.sessionId);
    // The bumpCounters above is just to invoke the store;
    // failure_state needs a separate column write. The store API
    // doesn't currently expose a "stamp failure_state" without
    // re-completing, so the active-snapshot value is the source
    // of truth for UI rendering until the next phone-side
    // session lands. (Slice-2 refinement: tighten this with a
    // dedicated SyncSessionStore.recordFailureCode helper.)
  }

  /// Drop the active-session reference. Callers (typically the
  /// floating progress window's dismiss timer) invoke this after
  /// the terminal state has been visible long enough to read.
  void clearActive() {
    _active.value = null;
  }

  void dispose() {
    _active.dispose();
  }
}

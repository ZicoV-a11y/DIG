/// The formal state machine for a sync handshake. Both desktop and
/// phone bind their progress-window UI to a `ValueNotifier&lt;SyncState&gt;`
/// that walks through these values during a sync.
///
/// Slice 1 ships states 1, 2, 3, 5, 6, 7, 8 (state 4
/// `preparingTransports` lights up in Slice 3 when transcoding
/// arrives). Failure states are separate enum values rather than
/// flags so the UI doesn't have to combine multiple booleans to
/// determine what to render.
enum SyncState {
  /// "Connecting to `&lt;device&gt;`…" — pre-handshake TCP / pairing-token
  /// validation.
  negotiating,

  /// "Waiting for approval on `&lt;other side&gt;`…" — the request reached
  /// the other party; their dialog is visible.
  approving,

  /// "Preparing review crate (computing N unreviewed tracks)…" —
  /// `MobileManifestBuilder` is selecting + scoring tracks.
  preparingManifest,

  /// "Generating AAC transports for N tracks…" — Slice 3+ only.
  /// Skipped in Slice 1 (MP3 passthrough only).
  preparingTransports,

  /// "Uploading X of Y tracks (Z%)…" — the bulk of the time. Phone
  /// pulls track files via /api/v1/track/:id.
  transferring,

  /// "Receiving playback history…" — phone is uploading its
  /// telemetry queue to the desktop. Distinct from
  /// [applyingTelemetry] because the network step and the DB-side
  /// reconciliation step can each take meaningful time on a long
  /// offline window (a month of plays = thousands of events to
  /// flush). The mockup shows them as two separate progress rows
  /// on both the desktop and phone progress views.
  receivingTelemetry,

  /// "Applying N playback events to library…" — desktop reconciler
  /// walking the batch and writing intelligence rows.
  applyingTelemetry,

  /// "Finalizing rotation…" — telemetry settled; orchestrator
  /// flips evicted inventory rows + bumps `last_manifest_version`.
  /// Distinct from [applyingTelemetry] (telemetry merge) and
  /// [rotationComplete] (terminal) because the rotation step
  /// touches different tables and deserves its own progress
  /// bar in the floating sync window.
  finalizingRotation,

  /// "Rotation complete. M added, N removed." — terminal success
  /// state. UI auto-dismisses ~4s later.
  rotationComplete,

  /// Idle. UI hidden.
  idle,

  // Failure states — exposed as enum values rather than flags so a
  // simple switch can render the right message + retry affordance.

  /// User on the other side tapped "Decline" in the approval dialog.
  approvalDeclined,

  /// Transfer interrupted (network drop, partial bytes). User-facing
  /// message: "Transfer failed. N of M tracks completed." Next sync
  /// resumes via sync_checkpoint.
  transferFailed,

  /// Connection lost mid-handshake before the manifest landed.
  networkLost,
}

extension SyncStateWire on SyncState {
  /// Stable wire name. Used in JSON payloads and operational journal
  /// `recordEvent` payloads so cross-version transcripts stay
  /// readable.
  String get wireName {
    switch (this) {
      case SyncState.negotiating:
        return 'negotiating';
      case SyncState.approving:
        return 'approving';
      case SyncState.preparingManifest:
        return 'preparing_manifest';
      case SyncState.preparingTransports:
        return 'preparing_transports';
      case SyncState.transferring:
        return 'transferring';
      case SyncState.receivingTelemetry:
        return 'receiving_telemetry';
      case SyncState.applyingTelemetry:
        return 'applying_telemetry';
      case SyncState.finalizingRotation:
        return 'finalizing_rotation';
      case SyncState.rotationComplete:
        return 'rotation_complete';
      case SyncState.idle:
        return 'idle';
      case SyncState.approvalDeclined:
        return 'approval_declined';
      case SyncState.transferFailed:
        return 'transfer_failed';
      case SyncState.networkLost:
        return 'network_lost';
    }
  }
}

SyncState syncStateFromWire(String s) {
  switch (s) {
    case 'negotiating':
      return SyncState.negotiating;
    case 'approving':
      return SyncState.approving;
    case 'preparing_manifest':
      return SyncState.preparingManifest;
    case 'preparing_transports':
      return SyncState.preparingTransports;
    case 'transferring':
      return SyncState.transferring;
    case 'receiving_telemetry':
      return SyncState.receivingTelemetry;
    case 'applying_telemetry':
      return SyncState.applyingTelemetry;
    case 'finalizing_rotation':
      return SyncState.finalizingRotation;
    case 'rotation_complete':
      return SyncState.rotationComplete;
    case 'idle':
      return SyncState.idle;
    case 'approval_declined':
      return SyncState.approvalDeclined;
    case 'transfer_failed':
      return SyncState.transferFailed;
    case 'network_lost':
      return SyncState.networkLost;
    default:
      throw FormatException('Unknown SyncState wire value: $s');
  }
}

/// **Failure taxonomy** — granular categorization of why a sync
/// terminated abnormally. Persisted in
/// `sync_sessions.failure_state` (next to the terminal SyncState)
/// so the "Last Sync" summary can render specific narration
/// ("Transfer failed: 3 tracks unreachable" vs "Authorization
/// failed: device token rejected").
///
/// Distinct from the SyncState failure values (approvalDeclined,
/// transferFailed, networkLost): SyncState is the lifecycle
/// machine's terminal cell, SyncFailureCode is the audit-trail
/// reason. Multiple failure codes can map to the same
/// terminal SyncState — e.g., `manifestInvalid` and
/// `inventoryConflict` both terminate at the transferFailed
/// state but tell very different stories.
enum SyncFailureCode {
  /// Payload transport issue — file unreachable, network drop
  /// mid-transfer, partial bytes received.
  transferFailed,

  /// Reconciliation issue — telemetry batch couldn't be applied
  /// (e.g., schema-version skew between phone and desktop).
  telemetryFailed,

  /// Ontology mismatch — manifest the phone confirmed against
  /// no longer matches desktop state (rare race condition).
  manifestInvalid,

  /// Trust / auth issue — token rejected mid-session.
  authorizationFailed,

  /// Operational availability — phone disappeared from the
  /// network before the session could finish.
  deviceUnreachable,

  /// Impossible inventory state — e.g., a pinned track has no
  /// content_hash but somehow landed in the manifest.
  inventoryConflict;

  String get wireName {
    switch (this) {
      case SyncFailureCode.transferFailed:
        return 'transfer_failed';
      case SyncFailureCode.telemetryFailed:
        return 'telemetry_failed';
      case SyncFailureCode.manifestInvalid:
        return 'manifest_invalid';
      case SyncFailureCode.authorizationFailed:
        return 'authorization_failed';
      case SyncFailureCode.deviceUnreachable:
        return 'device_unreachable';
      case SyncFailureCode.inventoryConflict:
        return 'inventory_conflict';
    }
  }

  static SyncFailureCode fromWire(String s) {
    switch (s) {
      case 'transfer_failed':
        return SyncFailureCode.transferFailed;
      case 'telemetry_failed':
        return SyncFailureCode.telemetryFailed;
      case 'manifest_invalid':
        return SyncFailureCode.manifestInvalid;
      case 'authorization_failed':
        return SyncFailureCode.authorizationFailed;
      case 'device_unreachable':
        return SyncFailureCode.deviceUnreachable;
      case 'inventory_conflict':
        return SyncFailureCode.inventoryConflict;
      default:
        throw FormatException('Unknown SyncFailureCode: $s');
    }
  }
}

/// Terminal SyncStates (lifecycle completed; the session row
/// gets its `completed_at` stamp here).
const Set<SyncState> _terminalStates = {
  SyncState.rotationComplete,
  SyncState.approvalDeclined,
  SyncState.transferFailed,
  SyncState.networkLost,
};

bool isTerminalSyncState(SyncState s) => _terminalStates.contains(s);

/// Which lifecycle states the user is allowed to cancel from.
///
/// Cancellation philosophy: only safe when the resulting partial
/// work is recoverable. Pre-transfer phases are pure desktop-side
/// computation — cancelling drops the in-memory work and the
/// next sync starts fresh. Transferring is cancellable because
/// resumable HTTP Range means a half-transferred manifest can
/// resume on the next session.
///
/// Post-transfer phases (applyingTelemetry, finalizingRotation)
/// are NOT cancellable: cancelling mid-reconciliation would
/// leave the desktop intelligence rows in an inconsistent state
/// where some events applied and others didn't. Per-event
/// idempotency makes the cost of letting them finish near-zero
/// anyway.
const Set<SyncState> _cancellableStates = {
  SyncState.negotiating,
  SyncState.approving,
  SyncState.preparingManifest,
  SyncState.preparingTransports,
  SyncState.transferring,
  SyncState.receivingTelemetry,
};

bool isCancellableSyncState(SyncState s) => _cancellableStates.contains(s);

/// Legal transition graph for the orchestrator. Every entry is
/// explicit — no wildcards, no fallthrough — so a typo in the
/// orchestrator surfaces as `isLegalSyncStateTransition →
/// false` rather than silently corrupting state.
///
/// The success path is the spine; failure terminals branch off
/// at the realistic failure point for each phase. Pause/resume
/// is OUT of scope for Slice 1: a network drop terminates the
/// session at [SyncState.networkLost] and the phone retries
/// from a fresh session next time.
const Map<SyncState, Set<SyncState>> _legalTransitions = {
  SyncState.idle: {
    SyncState.negotiating,
  },
  SyncState.negotiating: {
    SyncState.approving,
    // Failure pathways from negotiating: token rejected, phone
    // can't reach desktop server.
    SyncState.networkLost,
  },
  SyncState.approving: {
    SyncState.preparingManifest,
    // User declined OR auto-approve timed out.
    SyncState.approvalDeclined,
    SyncState.networkLost,
  },
  SyncState.preparingManifest: {
    SyncState.preparingTransports,
    SyncState.transferring,
    SyncState.transferFailed, // manifest_invalid maps here
    SyncState.networkLost,
  },
  SyncState.preparingTransports: {
    SyncState.transferring,
    SyncState.transferFailed,
    SyncState.networkLost,
  },
  SyncState.transferring: {
    SyncState.receivingTelemetry,
    SyncState.transferFailed,
    SyncState.networkLost,
  },
  SyncState.receivingTelemetry: {
    SyncState.applyingTelemetry,
    SyncState.transferFailed, // telemetry_failed surfaces here
    SyncState.networkLost,
  },
  SyncState.applyingTelemetry: {
    SyncState.finalizingRotation,
    SyncState.transferFailed,
    SyncState.networkLost,
  },
  SyncState.finalizingRotation: {
    SyncState.rotationComplete,
    SyncState.transferFailed,
  },
  // Terminal states have no outbound edges.
  SyncState.rotationComplete: {},
  SyncState.approvalDeclined: {},
  SyncState.transferFailed: {},
  SyncState.networkLost: {},
};

/// `true` when [to] is a legal next-state of [from].
/// Self-loops are explicitly disallowed — every transition is
/// an observed event, never a no-op.
bool isLegalSyncStateTransition(SyncState from, SyncState to) {
  if (from == to) return false;
  final outbound = _legalTransitions[from];
  if (outbound == null) return false;
  return outbound.contains(to);
}

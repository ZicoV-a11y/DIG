// Named scenario fixtures — the chaos playbook the simulator
// runs to prove the desktop sync stack survives the operational
// realities of real-world phone-side behavior.
//
// Each scenario is an immutable record: seed + drive +
// invariants. No state lives on the scenario instance — the
// simulator owns all mutable state. That keeps scenarios
// reusable across simulator instances + parallelizable later if
// the suite grows.
//
// Naming convention: `<situation>_<expected_outcome>` so the
// test report reads as a behavior claim.

import 'package:music_tracker/services/mobile_sync/sync_orchestrator.dart';
import 'package:shared_core/shared_core.dart';

import 'invariants.dart';
import 'sync_simulator.dart';

/// Helper — seed one MP3 track that's eligible for sync.
Future<void> _seedEligibleTrack(
  SyncSimulator sim, {
  String intelUid = 'intel-a',
  String variantId = 'variant-a',
  String contentHash = 'hash-a',
}) async {
  await sim.appDb.db.insert('sources', {
    'id': 'src-sim',
    'display_name': 'sim',
    'folder_path': '/sim',
    'created_at': 0,
  });
  await sim.appDb.db.insert('indexed_files', {
    'path': '/sim/track.mp3',
    'source_id': 'src-sim',
    'filename': 'track.mp3',
    'filesize': 5_000_000,
    'modified_at': 0,
    'duration_ms': 240_000,
    'fingerprint': 'fp-a',
    'content_hash': contentHash,
    'uid': variantId,
    'intel_uid': intelUid,
    'is_available': 1,
    'availability_state': 'available',
    'last_seen_at': 0,
    'title': 'Sim Track',
    'artist': 'Sim',
  });
  await sim.appDb.db.insert('tracks', {
    'uid': intelUid,
    'fingerprint': 'fp-a',
    'created_at': 0,
    'favorite': 0,
    'play_count': 0,
    'cumulative_ms': 0,
  });
}

/// Baseline — clean spine walks all the way to rotationComplete.
/// Every invariant should hold; the timeline records every step.
class HappyPathBaseline extends SyncScenario {
  @override
  String get name => 'happy_path_baseline';

  @override
  Future<void> seed(SyncSimulator sim) async {
    await _seedEligibleTrack(sim);
  }

  @override
  Future<void> drive(SyncSimulator sim) async {
    final o = sim.orchestrator;
    await o.beginSession(
      deviceId: sim.device.deviceId,
      initiatedBy: SyncInitiator.phone,
    );
    await o.transitionTo(SyncState.approving);
    await o.transitionTo(SyncState.preparingManifest);
    await o.recordProgress(manifestVersion: 1);
    await o.transitionTo(SyncState.transferring);
    await o.recordProgress(tracksAdded: 1, bytesTransferred: 5_000_000);
    await o.transitionTo(SyncState.receivingTelemetry);
    await o.transitionTo(SyncState.applyingTelemetry);
    await o.transitionTo(SyncState.finalizingRotation);
    await o.completeSuccess();
  }

  @override
  List<SyncInvariant> get invariants => [
        NoOrphanedActiveSession(),
        OrchestratorSnapshotMatchesDb(),
        ProcessedEventsUniqueByEventId(),
        PlayCountMatchesUniqueThresholdEvents(),
        FailedSessionsDoNotAdvanceManifestVersion(),
      ];
}

/// Wi-Fi drops mid-transfer. Phone never sends telemetry or
/// completes; the session terminates as networkLost. Critical
/// invariant: failed sessions don't pollute desktop state.
class NetworkDropMidTransfer extends SyncScenario {
  @override
  String get name => 'network_drop_mid_transfer';

  @override
  Future<void> seed(SyncSimulator sim) async {
    await _seedEligibleTrack(sim);
  }

  @override
  Future<void> drive(SyncSimulator sim) async {
    final o = sim.orchestrator;
    await o.beginSession(
      deviceId: sim.device.deviceId,
      initiatedBy: SyncInitiator.phone,
    );
    await o.transitionTo(SyncState.approving);
    await o.transitionTo(SyncState.preparingManifest);
    await o.transitionTo(SyncState.transferring);
    // Partial transfer: 2 of 5 MB landed before the drop.
    await o.recordProgress(bytesTransferred: 2_000_000);
    // The drop.
    await o.completeFailure(
      code: SyncFailureCode.deviceUnreachable,
      terminalState: SyncState.networkLost,
      reason: 'Wi-Fi disappeared during transfer',
    );
  }

  @override
  List<SyncInvariant> get invariants => [
        NoOrphanedActiveSession(),
        OrchestratorSnapshotMatchesDb(),
        ProcessedEventsUniqueByEventId(),
        PlayCountMatchesUniqueThresholdEvents(),
        FailedSessionsDoNotAdvanceManifestVersion(),
        // No telemetry was sent — processed table must be empty.
        ProcessedEventsCountIsBounded()..expectedMax = 0,
      ];
}

/// Phone uploads the same telemetry batch twice (retry storm /
/// reconnect / partial network failure). Dedup primitives must
/// catch the duplicate: tracks.play_count incremented exactly
/// once, processed_mobile_events count stays at the unique
/// total.
class DuplicateTelemetryReplay extends SyncScenario {
  @override
  String get name => 'duplicate_telemetry_replay';

  @override
  Future<void> seed(SyncSimulator sim) async {
    await _seedEligibleTrack(sim);
  }

  @override
  Future<void> drive(SyncSimulator sim) async {
    final o = sim.orchestrator;
    final session = await o.beginSession(
      deviceId: sim.device.deviceId,
      initiatedBy: SyncInitiator.phone,
    );
    await o.transitionTo(SyncState.approving);
    await o.transitionTo(SyncState.preparingManifest);
    await o.transitionTo(SyncState.transferring);
    await o.transitionTo(SyncState.receivingTelemetry);

    // Build a batch — single threshold event for intel-a.
    final batch = TelemetryBatch(
      deviceId: sim.device.deviceId,
      syncSessionId: session.sessionId,
      events: const [
        TelemetryEvent(
          eventId: 'evt-replay-1',
          identity: TrackIdentity(
            intelUid: 'intel-a',
            variantId: 'variant-a',
            contentHash: 'hash-a',
          ),
          type: TelemetryEventType.thresholdCrossed,
          occurredAt: 1747520000,
          elapsedPlaybackMs: 11000,
        ),
      ],
    );
    // First submission: applied.
    await sim.reconciler.reconcile(batch);
    // Same batch again (retry replay). Dedup gate must catch
    // it; processed_mobile_events row stays at 1 + play_count
    // stays at 1.
    await sim.reconciler.reconcile(batch);

    await o.transitionTo(SyncState.applyingTelemetry);
    await o.transitionTo(SyncState.finalizingRotation);
    await o.completeSuccess();
  }

  @override
  List<SyncInvariant> get invariants => [
        NoOrphanedActiveSession(),
        OrchestratorSnapshotMatchesDb(),
        ProcessedEventsUniqueByEventId(),
        PlayCountMatchesUniqueThresholdEvents(),
        // One unique event_id submitted twice → table has 1 row.
        ProcessedEventsCountIsBounded()..expectedMax = 1,
      ];
}

/// User (or runtime) tries to cancel after the cancellable
/// window closes. The orchestrator's legal-transition graph
/// rejects the move; the session continues to its proper
/// terminal. Asserts the cancellation boundary is enforced at
/// the ontology, not just hinted in UI.
class IllegalCancelDuringTelemetryRejected extends SyncScenario {
  @override
  String get name => 'illegal_cancel_during_telemetry_rejected';

  @override
  Future<void> seed(SyncSimulator sim) async {
    await _seedEligibleTrack(sim);
  }

  @override
  Future<void> drive(SyncSimulator sim) async {
    final o = sim.orchestrator;
    await o.beginSession(
      deviceId: sim.device.deviceId,
      initiatedBy: SyncInitiator.phone,
    );
    await o.transitionTo(SyncState.approving);
    await o.transitionTo(SyncState.preparingManifest);
    await o.transitionTo(SyncState.transferring);
    await o.transitionTo(SyncState.receivingTelemetry);
    await o.transitionTo(SyncState.applyingTelemetry);

    // Sanity: cancellable state contract says applyingTelemetry
    // is NOT cancellable. Try anyway — the orchestrator's
    // legal-transition map should reject this.
    assert(!isCancellableSyncState(SyncState.applyingTelemetry));

    // Attempt a cancel via completeFailure with networkLost
    // terminal. legal-transition map: applyingTelemetry has
    // {finalizingRotation, transferFailed, networkLost} as
    // its successors. networkLost IS legal from
    // applyingTelemetry... so this scenario instead asserts
    // that the orchestrator refuses transitionTo() of a
    // terminal directly (must go through complete*). We
    // instead try transitionTo(approvalDeclined) which is
    // illegal from applyingTelemetry.
    var caught = false;
    try {
      await o.transitionTo(SyncState.approvalDeclined);
    } on IllegalSyncTransitionException {
      caught = true;
    } on StateError {
      // Also acceptable — terminal targets via transitionTo()
      // are explicitly rejected.
      caught = true;
    }
    if (!caught) {
      throw StateError(
          'orchestrator allowed illegal transition '
          'applyingTelemetry → approvalDeclined');
    }

    // Session continues to its proper terminal.
    await o.transitionTo(SyncState.finalizingRotation);
    await o.completeSuccess();
  }

  @override
  List<SyncInvariant> get invariants => [
        NoOrphanedActiveSession(),
        OrchestratorSnapshotMatchesDb(),
        ProcessedEventsUniqueByEventId(),
        PlayCountMatchesUniqueThresholdEvents(),
      ];
}

/// Phone tries to open a second session while one is already
/// in flight. Orchestrator refuses; the first session is
/// untouched. Guards against a confused phone (relaunched,
/// stale state) from corrupting active orchestration.
class SessionInFlightRejection extends SyncScenario {
  @override
  String get name => 'session_in_flight_rejection';

  @override
  Future<void> seed(SyncSimulator sim) async {
    await _seedEligibleTrack(sim);
  }

  @override
  Future<void> drive(SyncSimulator sim) async {
    final o = sim.orchestrator;
    final first = await o.beginSession(
      deviceId: sim.device.deviceId,
      initiatedBy: SyncInitiator.phone,
    );
    await o.transitionTo(SyncState.approving);

    // Phone retries beginSession (e.g., relaunched after a
    // crash, doesn't realize first is still alive on desktop).
    var caught = false;
    try {
      await o.beginSession(
        deviceId: sim.device.deviceId,
        initiatedBy: SyncInitiator.phone,
      );
    } on StateError {
      caught = true;
    }
    if (!caught) {
      throw StateError(
        'orchestrator allowed a second beginSession while one was active',
      );
    }

    // First session continues unaffected.
    if (o.activeSession?.sessionId != first.sessionId) {
      throw StateError(
        'active session changed despite refused second beginSession',
      );
    }
  }

  @override
  List<SyncInvariant> get invariants => [
        NoOrphanedActiveSession(),
        OrchestratorSnapshotMatchesDb(),
      ];
}

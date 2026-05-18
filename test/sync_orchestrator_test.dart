// SyncOrchestrator tests — the conductor of the deterministic
// state machine.
//
// Contracts pinned here:
//   1. beginSession opens a fresh row in `negotiating` + surfaces
//      it via the listenable. One active session per orchestrator
//      instance (concurrent sessions are a programming bug, not a
//      runtime feature).
//   2. transitionTo validates legality. Illegal transitions throw
//      IllegalSyncTransitionException; the snapshot doesn't move.
//   3. transitionTo refuses terminal targets — those must go
//      through completeSuccess / completeFailure so the
//      completed_at + failure metadata land atomically.
//   4. recordProgress is delta-based + persists immediately +
//      refreshes the snapshot. UI binding sees every increment.
//   5. completeSuccess only valid from finalizingRotation; the
//      snapshot's completed_at + currentState land together.
//   6. completeFailure carries both SyncFailureCode (granular
//      audit) and a terminal SyncState (lifecycle). Reason text
//      lands in the row.
//   7. Snapshot identity: every change produces a new object;
//      original references stay readable.

import 'package:flutter_test/flutter_test.dart';
import 'package:music_tracker/services/database.dart';
import 'package:music_tracker/services/mobile_sync/mobile_device.dart';
import 'package:music_tracker/services/mobile_sync/mobile_sync_repository.dart';
import 'package:music_tracker/services/mobile_sync/sync_orchestrator.dart';
import 'package:music_tracker/services/mobile_sync/sync_session_store.dart';
import 'package:shared_core/shared_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late AppDatabase appDb;
  late MobileSyncRepository syncRepo;
  late SyncSessionStore sessions;
  late SyncOrchestrator orchestrator;
  late DateTime now;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    appDb = AppDatabase();
    await appDb.openInMemory();
    syncRepo = MobileSyncRepository(appDb);
    sessions = SyncSessionStore(appDb: appDb, now: () => now);
    now = DateTime(2026, 5, 17, 12, 0, 0);
    orchestrator = SyncOrchestrator(
      sessionStore: sessions,
      now: () => now,
    );

    await syncRepo.insertDevice(MobileDevice(
      deviceId: 'iphone-zico',
      friendlyName: 'Zico iPhone',
      pairedAt: DateTime(2026, 1, 1),
      capacity: const CapacityPolicy.songs(100),
      tokenHash: 'stub',
    ));
  });

  tearDown(() async {
    orchestrator.dispose();
    await appDb.close();
  });

  group('beginSession', () {
    test('opens a fresh negotiating session + surfaces via listenable',
        () async {
      expect(orchestrator.activeSession, isNull);
      final session = await orchestrator.beginSession(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
      );
      expect(orchestrator.activeSession?.sessionId, session.sessionId);
      expect(session.currentState, SyncState.negotiating);
      expect(session.deviceId, 'iphone-zico');
      expect(session.initiatedBy, SyncInitiator.phone);
    });

    test('throws when a session is already in flight', () async {
      await orchestrator.beginSession(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
      );
      expect(
        () => orchestrator.beginSession(
          deviceId: 'iphone-zico',
          initiatedBy: SyncInitiator.phone,
        ),
        throwsStateError,
      );
    });
  });

  group('transitionTo', () {
    test('legal transition advances + persists + refreshes snapshot',
        () async {
      final session = await orchestrator.beginSession(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
      );
      await orchestrator.transitionTo(SyncState.approving);
      expect(orchestrator.activeSession?.currentState,
          SyncState.approving);
      // DB persisted too — store finds the new state.
      final fetched = await sessions.findSession(session.sessionId);
      expect(fetched!.currentState, SyncState.approving);
    });

    test('illegal transition throws + snapshot unchanged', () async {
      await orchestrator.beginSession(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
      );
      expect(
        () => orchestrator.transitionTo(SyncState.transferring),
        throwsA(isA<IllegalSyncTransitionException>()),
      );
      // Still in negotiating — no silent corruption.
      expect(orchestrator.activeSession?.currentState,
          SyncState.negotiating);
    });

    test('terminal targets are rejected (use complete* methods)',
        () async {
      await orchestrator.beginSession(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
      );
      // approvalDeclined is a legal next-state of approving via
      // the transition map, but transitionTo refuses to apply
      // terminal targets — those must go through completeFailure
      // so the completed_at + failure metadata land atomically.
      await orchestrator.transitionTo(SyncState.approving);
      expect(
        () => orchestrator.transitionTo(SyncState.approvalDeclined),
        throwsStateError,
      );
    });

    test('throws when there is no active session', () {
      expect(
        () => orchestrator.transitionTo(SyncState.negotiating),
        throwsStateError,
      );
    });
  });

  group('recordProgress', () {
    test('persists deltas + refreshes the snapshot atomically',
        () async {
      await orchestrator.beginSession(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
      );
      await orchestrator.recordProgress(
        tracksAdded: 5,
        bytesTransferred: 1_000_000,
      );
      await orchestrator.recordProgress(
        tracksAdded: 3,
        bytesTransferred: 500_000,
      );
      final snapshot = orchestrator.activeSession;
      expect(snapshot!.tracksAdded, 8);
      expect(snapshot.bytesTransferred, 1_500_000);
      // DB has the same numbers.
      final fetched = await sessions.findSession(snapshot.sessionId);
      expect(fetched!.tracksAdded, 8);
      expect(fetched.bytesTransferred, 1_500_000);
    });

    test('manifestVersion is set, not added', () async {
      await orchestrator.beginSession(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
      );
      await orchestrator.recordProgress(manifestVersion: 7);
      await orchestrator.recordProgress(manifestVersion: 11);
      expect(orchestrator.activeSession?.manifestVersion, 11);
    });
  });

  group('completeSuccess', () {
    test('only legal from finalizingRotation', () async {
      await orchestrator.beginSession(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
      );
      await orchestrator.transitionTo(SyncState.approving);
      // Trying to complete from approving must throw — the spine
      // only allows rotationComplete after finalizingRotation.
      expect(
        () => orchestrator.completeSuccess(),
        throwsA(isA<IllegalSyncTransitionException>()),
      );
    });

    test('stamps completed_at + transitions to rotationComplete',
        () async {
      final session = await orchestrator.beginSession(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
      );
      // Walk the spine.
      await orchestrator.transitionTo(SyncState.approving);
      await orchestrator.transitionTo(SyncState.preparingManifest);
      await orchestrator.transitionTo(SyncState.transferring);
      await orchestrator.transitionTo(SyncState.receivingTelemetry);
      await orchestrator.transitionTo(SyncState.applyingTelemetry);
      await orchestrator.transitionTo(SyncState.finalizingRotation);

      now = now.add(const Duration(minutes: 2, seconds: 14));
      await orchestrator.completeSuccess();

      final snap = orchestrator.activeSession;
      expect(snap!.currentState, SyncState.rotationComplete);
      expect(snap.completedAt, now.millisecondsSinceEpoch);
      expect(snap.isSuccessful, isTrue);
      expect(snap.isActive, isFalse);

      // DB persisted too.
      final fetched = await sessions.findSession(session.sessionId);
      expect(fetched!.currentState, SyncState.rotationComplete);
      expect(fetched.completedAt, isNotNull);
    });
  });

  group('completeFailure', () {
    test('persists code + reason + terminal SyncState', () async {
      await orchestrator.beginSession(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
      );
      await orchestrator.transitionTo(SyncState.approving);
      await orchestrator.transitionTo(SyncState.preparingManifest);
      await orchestrator.transitionTo(SyncState.transferring);

      await orchestrator.completeFailure(
        code: SyncFailureCode.transferFailed,
        terminalState: SyncState.transferFailed,
        reason: '3 tracks unreachable mid-transfer',
      );

      final snap = orchestrator.activeSession;
      expect(snap!.currentState, SyncState.transferFailed);
      expect(snap.failureState, 'transfer_failed');
      expect(snap.failureReason, '3 tracks unreachable mid-transfer');
      expect(snap.isSuccessful, isFalse);
      expect(snap.isActive, isFalse);
    });

    test('rejects non-failure terminal states', () async {
      await orchestrator.beginSession(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
      );
      expect(
        () => orchestrator.completeFailure(
          code: SyncFailureCode.transferFailed,
          terminalState: SyncState.rotationComplete,
          reason: 'wrong terminal',
        ),
        throwsStateError,
      );
    });

    test('rejects illegal terminal from current state', () async {
      await orchestrator.beginSession(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
      );
      // negotiating cannot transition straight to approvalDeclined
      // (only approving can). Even with a granular failure code,
      // the lifecycle graph stays in charge.
      expect(
        () => orchestrator.completeFailure(
          code: SyncFailureCode.authorizationFailed,
          terminalState: SyncState.approvalDeclined,
          reason: 'token rejected',
        ),
        throwsA(isA<IllegalSyncTransitionException>()),
      );
    });

    test('granular code distinct from lifecycle terminal', () async {
      // manifestInvalid lands in the transferFailed terminal —
      // the lifecycle machine doesn't have a separate slot for
      // every taxonomy code. The snapshot's failureState stores
      // the GRANULAR code so audit narration stays specific.
      await orchestrator.beginSession(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
      );
      await orchestrator.transitionTo(SyncState.approving);
      await orchestrator.transitionTo(SyncState.preparingManifest);
      await orchestrator.completeFailure(
        code: SyncFailureCode.manifestInvalid,
        terminalState: SyncState.transferFailed,
        reason: 'phone manifest version diverged from desktop snapshot',
      );
      final snap = orchestrator.activeSession;
      expect(snap!.currentState, SyncState.transferFailed);
      expect(snap.failureState, 'manifest_invalid');
    });
  });

  group('snapshot identity', () {
    test('every change produces a new object', () async {
      final s0 = await orchestrator.beginSession(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
      );
      await orchestrator.transitionTo(SyncState.approving);
      final s1 = orchestrator.activeSession!;
      expect(identical(s0, s1), isFalse);
      // Original reference still readable + still carries the
      // old state — immutable snapshots throughout.
      expect(s0.currentState, SyncState.negotiating);
      expect(s1.currentState, SyncState.approving);
    });
  });

  group('listenable', () {
    test('notifies listeners on every state change', () async {
      final captured = <SyncState?>[];
      orchestrator.activeSessionListenable.addListener(() {
        captured.add(orchestrator.activeSession?.currentState);
      });
      await orchestrator.beginSession(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
      );
      await orchestrator.transitionTo(SyncState.approving);
      await orchestrator.recordProgress(tracksAdded: 3);
      orchestrator.clearActive();

      // beginSession + transitionTo + recordProgress + clearActive =
      // 4 notifications.
      expect(captured, [
        SyncState.negotiating,
        SyncState.approving,
        SyncState.approving, // progress kept the state
        null, // cleared
      ]);
    });
  });
}

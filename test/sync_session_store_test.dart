// SyncSessionStore lifecycle tests.
//
// PR2.6 operational foundation. Every sync handshake gets a row;
// the sidebar Devices panel and floating progress window both
// bind to these rows. These tests pin:
//
//   1. start() persists with the initial state + bumps a UUID
//      session_id by default.
//   2. recordStateTransition() flips current_state but only on
//      active sessions — completed sessions are immutable.
//   3. bumpCounters() is additive + atomic (multi-field bumps
//      land together).
//   4. complete() stamps completed_at + the failure metadata
//      when the final state is non-rotationComplete.
//   5. activeForDevice / lastCompletedForDevice resolve the
//      right rows for the UI.

import 'package:flutter_test/flutter_test.dart';
import 'package:music_tracker/services/database.dart';
import 'package:music_tracker/services/mobile_sync/mobile_device.dart';
import 'package:music_tracker/services/mobile_sync/mobile_sync_repository.dart';
import 'package:music_tracker/services/mobile_sync/sync_session_store.dart';
import 'package:shared_core/shared_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

void main() {
  late AppDatabase appDb;
  late MobileSyncRepository repo;
  late SyncSessionStore sessions;
  late DateTime now;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    appDb = AppDatabase();
    await appDb.openInMemory();
    repo = MobileSyncRepository(appDb);
    now = DateTime(2026, 5, 17, 12, 0, 0);
    sessions = SyncSessionStore(appDb: appDb, now: () => now);

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

  group('start', () {
    test('persists with a UUID session_id by default', () async {
      final session = await sessions.start(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
      );
      expect(session.sessionId, hasLength(36),
          reason: 'UUID v4 string is 36 chars');
      expect(session.deviceId, 'iphone-zico');
      expect(session.initiatedBy, SyncInitiator.phone);
      expect(session.currentState, SyncState.negotiating);
      expect(session.startedAt, now.millisecondsSinceEpoch);
      expect(session.isActive, isTrue);
    });

    test('honors a caller-supplied session_id', () async {
      final session = await sessions.start(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.desktop,
        sessionId: 'custom-id',
      );
      expect(session.sessionId, 'custom-id');
      expect(await sessions.findSession('custom-id'), isNotNull);
    });

    test('honors a non-default initial state', () async {
      final session = await sessions.start(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
        initialState: SyncState.preparingManifest,
      );
      expect(session.currentState, SyncState.preparingManifest);
    });
  });

  group('recordStateTransition', () {
    test('updates current_state on an active session', () async {
      final session = await sessions.start(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
      );
      await sessions.recordStateTransition(
        sessionId: session.sessionId,
        state: SyncState.transferring,
      );
      final fetched = await sessions.findSession(session.sessionId);
      expect(fetched!.currentState, SyncState.transferring);
    });

    test('is a no-op on completed sessions (terminal-state lock)',
        () async {
      // Once a session completes, its row is immutable. A late
      // transition (e.g., racing transport tick after rotation
      // complete) must NOT clobber the failure metadata.
      final session = await sessions.start(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
      );
      await sessions.complete(
        sessionId: session.sessionId,
        finalState: SyncState.rotationComplete,
      );
      await sessions.recordStateTransition(
        sessionId: session.sessionId,
        state: SyncState.transferring,
      );
      final fetched = await sessions.findSession(session.sessionId);
      expect(fetched!.currentState, SyncState.rotationComplete);
    });
  });

  group('bumpCounters', () {
    test('additive across multiple calls', () async {
      final session = await sessions.start(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
      );
      await sessions.bumpCounters(
        sessionId: session.sessionId,
        telemetryApplied: 5,
        telemetryDeduped: 2,
      );
      await sessions.bumpCounters(
        sessionId: session.sessionId,
        telemetryApplied: 3,
        telemetryClockClamped: 1,
      );
      final fetched = await sessions.findSession(session.sessionId);
      expect(fetched!.telemetryApplied, 8);
      expect(fetched.telemetryDeduped, 2);
      expect(fetched.telemetryClockClamped, 1);
    });

    test('manifest_version is set (not added)', () async {
      // manifest_version is a one-shot stamp, not a counter.
      // Bumping it twice should land the second value, not the
      // sum.
      final session = await sessions.start(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
      );
      await sessions.bumpCounters(
        sessionId: session.sessionId,
        manifestVersion: 5,
      );
      await sessions.bumpCounters(
        sessionId: session.sessionId,
        manifestVersion: 7,
      );
      final fetched = await sessions.findSession(session.sessionId);
      expect(fetched!.manifestVersion, 7);
    });

    test('zero-delta call is a no-op', () async {
      final session = await sessions.start(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
      );
      // Should not throw; should not bump anything.
      await sessions.bumpCounters(sessionId: session.sessionId);
      final fetched = await sessions.findSession(session.sessionId);
      expect(fetched!.telemetryApplied, 0);
    });
  });

  group('complete', () {
    test('rotationComplete: stamps completed_at, no failure metadata',
        () async {
      final session = await sessions.start(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
      );
      now = now.add(const Duration(seconds: 30));
      await sessions.complete(
        sessionId: session.sessionId,
        finalState: SyncState.rotationComplete,
      );
      final fetched = await sessions.findSession(session.sessionId);
      expect(fetched!.completedAt, now.millisecondsSinceEpoch);
      expect(fetched.currentState, SyncState.rotationComplete);
      expect(fetched.failureState, isNull);
      expect(fetched.failureReason, isNull);
      expect(fetched.isSuccessful, isTrue);
      expect(fetched.isActive, isFalse);
    });

    test('failure state stamps failure_state + reason', () async {
      final session = await sessions.start(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
      );
      await sessions.complete(
        sessionId: session.sessionId,
        finalState: SyncState.approvalDeclined,
        failureReason: 'User tapped Decline on desktop modal.',
      );
      final fetched = await sessions.findSession(session.sessionId);
      expect(fetched!.failureState, 'approval_declined');
      expect(fetched.failureReason,
          'User tapped Decline on desktop modal.');
      expect(fetched.isSuccessful, isFalse);
    });
  });

  group('activeForDevice / lastCompletedForDevice', () {
    test('activeForDevice returns the open session, null otherwise',
        () async {
      expect(await sessions.activeForDevice('iphone-zico'), isNull);

      final session = await sessions.start(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
      );
      final active = await sessions.activeForDevice('iphone-zico');
      expect(active!.sessionId, session.sessionId);

      await sessions.complete(
        sessionId: session.sessionId,
        finalState: SyncState.rotationComplete,
      );
      expect(await sessions.activeForDevice('iphone-zico'), isNull);
    });

    test('lastCompletedForDevice returns most-recent completion',
        () async {
      final s1 = await sessions.start(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
      );
      now = now.add(const Duration(seconds: 30));
      await sessions.complete(
        sessionId: s1.sessionId,
        finalState: SyncState.rotationComplete,
      );
      now = now.add(const Duration(minutes: 5));

      final s2 = await sessions.start(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
      );
      now = now.add(const Duration(seconds: 30));
      await sessions.complete(
        sessionId: s2.sessionId,
        finalState: SyncState.rotationComplete,
      );

      final last = await sessions.lastCompletedForDevice('iphone-zico');
      expect(last!.sessionId, s2.sessionId);
    });
  });

  group('UUID generation', () {
    test('every default-id session gets a fresh UUID', () async {
      final ids = <String>{};
      for (var i = 0; i < 3; i++) {
        final s = await sessions.start(
          deviceId: 'iphone-zico',
          initiatedBy: SyncInitiator.phone,
        );
        ids.add(s.sessionId);
      }
      expect(ids, hasLength(3));
      // Sanity: each id is a valid UUID v4.
      for (final id in ids) {
        expect(Uuid.isValidUUID(fromString: id), isTrue);
      }
    });
  });
}

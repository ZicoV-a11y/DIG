// PR2.6.D widget smoke tests — SyncProgressWindow + LastSyncSummaryCard.
//
// What these tests pin (and what they DON'T pin):
//
//   - Pin: correctness of state-driven rendering. Each SyncState
//     surfaces a phase-specific narration string. Failure
//     sessions render the granular code's human label. Idle
//     orchestrator renders empty.
//   - Pin: deterministic-progress philosophy — no fake percentages
//     leaking into the widget tree.
//   - Don't pin: pixel layout. Designs evolve; semantics shouldn't.
//
// LastSyncSummaryCard is exercised by passing SyncSession
// fixtures directly so the test doesn't need a real DB.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' show ProcessingState;
import 'package:music_tracker/services/database.dart';
import 'package:music_tracker/services/library_repository.dart';
import 'package:music_tracker/services/mobile_sync/mobile_device.dart';
import 'package:music_tracker/services/mobile_sync/mobile_sync_repository.dart';
import 'package:music_tracker/services/mobile_sync/sync_session_store.dart';
import 'package:music_tracker/services/playback_engine.dart';
import 'package:music_tracker/state/library_controller.dart';
import 'package:music_tracker/widgets/last_sync_summary_card.dart';
import 'package:music_tracker/widgets/sync_progress_window.dart';
import 'package:shared_core/shared_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  group('SyncProgressWindow', () {
    late AppDatabase appDb;
    late LibraryRepository libRepo;
    late MobileSyncRepository syncRepo;
    late SyncSessionStore sessions;
    late LibraryController controller;

    setUpAll(() {
      TestWidgetsFlutterBinding.ensureInitialized();
    });

    setUp(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      appDb = AppDatabase();
      await appDb.openInMemory();
      libRepo = LibraryRepository(appDb);
      syncRepo = MobileSyncRepository(appDb);
      sessions = SyncSessionStore(appDb: appDb);
      controller = LibraryController(
        engine: _NoopPlaybackEngine(),
        repo: libRepo,
        mobileSync: syncRepo,
        sessionStore: sessions,
      );
      await syncRepo.insertDevice(MobileDevice(
        deviceId: 'iphone-zico',
        friendlyName: 'Zico iPhone',
        pairedAt: DateTime(2026, 1, 1),
        capacity: const CapacityPolicy.songs(100),
        tokenHash: 'stub',
      ));
      await controller.refreshPairedDevices();
    });

    tearDown(() async {
      controller.dispose();
      await appDb.close();
    });

    Widget wrap(Widget child) {
      return MaterialApp(home: Scaffold(body: child));
    }

    testWidgets('renders nothing when no active session', (tester) async {
      await tester.pumpWidget(wrap(SyncProgressWindow(
        controller: controller,
      )));
      expect(find.text('Review Sync — Zico iPhone'), findsNothing);
      expect(find.byType(SizedBox), findsWidgets);
    });

    testWidgets('renders the phase narration once a session begins',
        (tester) async {
      final orchestrator = controller.syncOrchestrator!;
      await orchestrator.beginSession(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
      );
      await tester.pumpWidget(wrap(SyncProgressWindow(
        controller: controller,
      )));
      expect(find.text('Review Sync — Zico iPhone'), findsOneWidget);
      expect(find.text('Connecting…'), findsOneWidget);
    });

    testWidgets('phase narration tracks orchestrator transitions',
        (tester) async {
      final orchestrator = controller.syncOrchestrator!;
      await orchestrator.beginSession(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
      );
      await orchestrator.transitionTo(SyncState.approving);
      await orchestrator.transitionTo(SyncState.preparingManifest);
      await tester.pumpWidget(wrap(SyncProgressWindow(
        controller: controller,
      )));
      await tester.pump();
      expect(find.text('Preparing review crate…'), findsOneWidget);

      await orchestrator.transitionTo(SyncState.transferring);
      await tester.pump();
      expect(find.text('Uploading tracks…'), findsOneWidget);

      await orchestrator.transitionTo(SyncState.receivingTelemetry);
      await tester.pump();
      expect(find.text('Receiving playback history…'), findsOneWidget);
    });

    testWidgets('cancel button visible only in cancellable phases',
        (tester) async {
      final orchestrator = controller.syncOrchestrator!;
      await orchestrator.beginSession(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
      );
      var cancelCount = 0;
      await tester.pumpWidget(wrap(SyncProgressWindow(
        controller: controller,
        onCancel: (_) => cancelCount++,
      )));
      // Negotiating is cancellable → close icon visible.
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);

      await orchestrator.transitionTo(SyncState.approving);
      await orchestrator.transitionTo(SyncState.preparingManifest);
      await orchestrator.transitionTo(SyncState.transferring);
      await orchestrator.transitionTo(SyncState.receivingTelemetry);
      await orchestrator.transitionTo(SyncState.applyingTelemetry);
      await tester.pump();
      // applyingTelemetry is NOT cancellable — close button gone.
      expect(find.byIcon(Icons.close_rounded), findsNothing);
      expect(cancelCount, 0);
    });

    testWidgets('failure renders phase-specific narration',
        (tester) async {
      // Larger surface — the widget renders multiple sections so
      // the default 800×600 test viewport can clip the failure
      // narration in mid-column if not given headroom.
      await tester.binding.setSurfaceSize(const Size(1200, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final orchestrator = controller.syncOrchestrator!;
      await orchestrator.beginSession(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
      );
      await orchestrator.transitionTo(SyncState.approving);
      await orchestrator.transitionTo(SyncState.preparingManifest);
      await orchestrator.completeFailure(
        code: SyncFailureCode.manifestInvalid,
        terminalState: SyncState.transferFailed,
        reason: 'phone manifest_version diverged from desktop',
      );
      await tester.pumpWidget(wrap(SyncProgressWindow(
        controller: controller,
      )));
      await tester.pump();
      // Granular code, not generic "sync failed".
      expect(find.text('Manifest version mismatch'), findsOneWidget);
      expect(
          find.text('phone manifest_version diverged from desktop'),
          findsOneWidget);
    });

    testWidgets('counter sections show telemetry deltas', (tester) async {
      final orchestrator = controller.syncOrchestrator!;
      await orchestrator.beginSession(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
      );
      await orchestrator.recordProgress(
        telemetryApplied: 42,
        telemetryDeduped: 3,
        telemetryClockClamped: 1,
      );
      await tester.pumpWidget(wrap(SyncProgressWindow(
        controller: controller,
      )));
      await tester.pump();
      expect(find.text('• 42 applied'), findsOneWidget);
      expect(find.text('• 3 deduped'), findsOneWidget);
      expect(find.text('• 1 clock adjusted'), findsOneWidget);
    });
  });

  group('LastSyncSummaryCard', () {
    Widget wrap(Widget child) =>
        MaterialApp(home: Scaffold(body: child));

    testWidgets('successful session shows counters + duration',
        (tester) async {
      final startedAt = DateTime(2026, 5, 17, 17, 40);
      final completedAt = startedAt.add(const Duration(minutes: 2, seconds: 14));
      final session = SyncSession(
        sessionId: 's1',
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
        startedAt: startedAt.millisecondsSinceEpoch,
        currentState: SyncState.rotationComplete,
        completedAt: completedAt.millisecondsSinceEpoch,
        tracksAdded: 50,
        tracksRemoved: 48,
        telemetryApplied: 84,
        telemetryDeduped: 3,
        telemetryClockClamped: 1,
      );
      await tester.pumpWidget(wrap(LastSyncSummaryCard(
        session: session,
        now: () => DateTime(2026, 5, 17, 17, 42),
      )));
      expect(find.text('LAST SYNC'), findsOneWidget);
      expect(find.text('Today · 17:42'), findsOneWidget);
      expect(find.text('50 added · 48 removed'), findsOneWidget);
      expect(
        find.text('84 telemetry events · 3 deduped · 1 clock adjusted'),
        findsOneWidget,
      );
      expect(find.text('Duration: 2m 14s'), findsOneWidget);
    });

    testWidgets('failed session shows granular failure narration',
        (tester) async {
      final session = SyncSession(
        sessionId: 's1',
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
        startedAt: DateTime(2026, 5, 17, 17, 40).millisecondsSinceEpoch,
        currentState: SyncState.transferFailed,
        completedAt: DateTime(2026, 5, 17, 17, 41).millisecondsSinceEpoch,
        failureState: 'transfer_failed',
        failureReason: '3 tracks unreachable',
      );
      await tester.pumpWidget(wrap(LastSyncSummaryCard(
        session: session,
        now: () => DateTime(2026, 5, 17, 17, 42),
      )));
      expect(find.text('Transfer interrupted'), findsOneWidget);
      expect(find.text('3 tracks unreachable'), findsOneWidget);
      // Success counters don't show on failure.
      expect(find.textContaining('added'), findsNothing);
    });

    testWidgets('renders nothing for an active (incomplete) session',
        (tester) async {
      const session = SyncSession(
        sessionId: 's1',
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
        startedAt: 0,
        currentState: SyncState.transferring,
        // completedAt intentionally null — active sessions belong
        // to the SyncProgressWindow, not this archival card.
      );
      await tester.pumpWidget(wrap(LastSyncSummaryCard(session: session)));
      expect(find.text('LAST SYNC'), findsNothing);
    });

    testWidgets('yesterday timestamp formats as "Yesterday · HH:mm"',
        (tester) async {
      final yesterday = DateTime(2026, 5, 16, 9, 15);
      final session = SyncSession(
        sessionId: 's1',
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
        startedAt: yesterday.subtract(const Duration(seconds: 30))
            .millisecondsSinceEpoch,
        currentState: SyncState.rotationComplete,
        completedAt: yesterday.millisecondsSinceEpoch,
        tracksAdded: 1,
      );
      await tester.pumpWidget(wrap(LastSyncSummaryCard(
        session: session,
        now: () => DateTime(2026, 5, 17, 12, 0),
      )));
      expect(find.text('Yesterday · 09:15'), findsOneWidget);
    });
  });
}

class _NoopPlaybackEngine implements PlaybackEngine {
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<bool> get playingStream => const Stream.empty();
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Stream<ProcessingState> get processingStateStream =>
      const Stream.empty();
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

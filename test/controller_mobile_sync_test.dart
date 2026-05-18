// LibraryController mobile-sync surface tests (PR2.6.B).
//
// Pins the controller-level contracts the desktop UI binds to:
//
//   1. pinTracksToDevice — writes residency=pinned inventory
//      rows, idempotent on repeat-pin, skips rows without a
//      content_hash (manifest-builder would reject those anyway).
//   2. pairedDevicesListenable — pre-computes
//      DeviceOperationalState via the pure derivation; UI never
//      recomputes on rebuild.
//   3. Active syncing session overrides a stale heartbeat so the
//      sidebar shows "Syncing…" even when the last-seen counter
//      drifted.

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' show ProcessingState;
import 'package:music_tracker/services/database.dart';
import 'package:music_tracker/services/library_repository.dart';
import 'package:music_tracker/services/mobile_sync/mobile_device.dart';
import 'package:music_tracker/services/mobile_sync/mobile_sync_repository.dart';
import 'package:music_tracker/services/mobile_sync/sync_orchestrator.dart';
import 'package:music_tracker/services/mobile_sync/sync_session_store.dart';
import 'package:music_tracker/services/playback_engine.dart';
import 'package:music_tracker/state/library_controller.dart';
import 'package:shared_core/shared_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late AppDatabase appDb;
  late LibraryRepository libRepo;
  late MobileSyncRepository syncRepo;
  late SyncSessionStore sessions;
  late LibraryController controller;

  setUpAll(() {
    // LibraryController wires MediaKeysBridge in its ctor, which
    // hits a method channel. Tests need the binding before the
    // controller is constructed.
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

    // Seed the source FK + a track row + intelligence so
    // controller.pinTracksToDevice can resolve content_hash.
    await appDb.db.insert('sources', {
      'id': 'src1',
      'display_name': 'test',
      'folder_path': '/test',
      'created_at': 0,
    });
    await appDb.db.insert('indexed_files', {
      'path': '/test/song-a.mp3',
      'source_id': 'src1',
      'filename': 'song-a.mp3',
      'filesize': 1_000_000,
      'modified_at': 0,
      'duration_ms': 240000,
      'fingerprint': 'fp-a',
      'content_hash': 'hash-a',
      'uid': 'variant-a',
      'intel_uid': 'intel-a',
      'is_available': 1,
      'availability_state': 'available',
      'last_seen_at': 0,
      'title': 'Song A',
      'artist': 'Artist',
    });
    await appDb.db.insert('indexed_files', {
      'path': '/test/song-b.mp3',
      'source_id': 'src1',
      'filename': 'song-b.mp3',
      'filesize': 1_000_000,
      'modified_at': 0,
      'duration_ms': 240000,
      'fingerprint': 'fp-b',
      'content_hash': null, // no content hash → can't pin
      'uid': 'variant-b',
      'intel_uid': 'intel-b',
      'is_available': 1,
      'availability_state': 'available',
      'last_seen_at': 0,
      'title': 'Song B',
      'artist': 'Artist',
    });

    // Load tracks into the controller's in-memory list via the
    // canonical hydrate path so pinTracksToDevice can resolve
    // intel_uids back to (variant_id, content_hash) pairs.
    await controller.hydrate();

    await syncRepo.insertDevice(MobileDevice(
      deviceId: 'iphone-zico',
      friendlyName: 'Zico iPhone',
      pairedAt: DateTime.now(),
      capacity: const CapacityPolicy.songs(100),
      tokenHash: 'stub',
    ));
  });

  tearDown(() async {
    controller.dispose();
    await appDb.close();
  });

  group('pinTracksToDevice', () {
    test('writes pinned residency row for a single intel_uid', () async {
      final written = await controller.pinTracksToDevice(
        deviceId: 'iphone-zico',
        intelUids: ['intel-a'],
      );
      expect(written, 1);

      final inventory = await syncRepo.listInventory('iphone-zico');
      expect(inventory, hasLength(1));
      expect(inventory.first.intelUid, 'intel-a');
      expect(inventory.first.residency, ResidencyClass.pinned);
      expect(inventory.first.syncOrigin, 'manual');
      expect(inventory.first.variantId, 'variant-a');
      expect(inventory.first.contentHash, 'hash-a');
      expect(inventory.first.pinnedAt, isNotNull);
    });

    test('is idempotent on repeat-pin (no duplicate inventory rows)',
        () async {
      await controller.pinTracksToDevice(
        deviceId: 'iphone-zico',
        intelUids: ['intel-a'],
      );
      await controller.pinTracksToDevice(
        deviceId: 'iphone-zico',
        intelUids: ['intel-a'],
      );
      final inventory = await syncRepo.listInventory('iphone-zico');
      expect(inventory, hasLength(1),
          reason:
              'Repeat-pin must REPLACE, not duplicate — the residency '
              'PK is (device_id, intel_uid)');
    });

    test('skips intel_uids without a content_hash', () async {
      // intel-b has content_hash = null in the seed; the manifest
      // builder would reject it at eligibility-filter time, so
      // the controller must not create a stub inventory row.
      final written = await controller.pinTracksToDevice(
        deviceId: 'iphone-zico',
        intelUids: ['intel-a', 'intel-b'],
      );
      expect(written, 1);
      final inventory = await syncRepo.listInventory('iphone-zico');
      expect(inventory.map((e) => e.intelUid), ['intel-a']);
    });

    test('no-op when controller has no mobileSync wired', () async {
      final standalone = LibraryController(
        engine: _NoopPlaybackEngine(),
        repo: libRepo,
        // mobileSync intentionally omitted
      );
      addTearDown(standalone.dispose);
      final written = await standalone.pinTracksToDevice(
        deviceId: 'whatever',
        intelUids: ['intel-a'],
      );
      expect(written, 0);
    });
  });

  group('unpinTrackFromDevice', () {
    test('removes the pinned inventory row', () async {
      await controller.pinTracksToDevice(
        deviceId: 'iphone-zico',
        intelUids: ['intel-a'],
      );
      await controller.unpinTrackFromDevice(
        deviceId: 'iphone-zico',
        intelUid: 'intel-a',
      );
      final inventory = await syncRepo.listInventory('iphone-zico');
      expect(inventory, isEmpty);
    });

    test('is idempotent on already-removed', () async {
      // Removing a row that doesn't exist is a no-op (the
      // underlying DELETE just matches zero rows). The listenable
      // refresh still fires so the UI re-evaluates state.
      await controller.unpinTrackFromDevice(
        deviceId: 'iphone-zico',
        intelUid: 'never-pinned',
      );
      // No throw.
    });
  });

  group('pairedDevicesListenable', () {
    test('refreshPairedDevices populates the listenable with derived state',
        () async {
      await controller.refreshPairedDevices();
      final devices = controller.pairedDevicesListenable.value;
      expect(devices, hasLength(1));
      final entry = devices.first;
      expect(entry.device.deviceId, 'iphone-zico');
      // No heartbeat yet → offline.
      expect(entry.state, DeviceOperationalState.offline);
    });

    test('online state surfaces after a heartbeat', () async {
      await syncRepo.touchLastSeen('iphone-zico');
      await controller.refreshPairedDevices();
      final state = controller.pairedDevicesListenable.value.first.state;
      // touchLastSeen stamped now() — derivation should call it online.
      expect(state, DeviceOperationalState.online);
    });

    test('active sync session overrides stale heartbeat', () async {
      // No heartbeat at all (last_seen NULL → offline), but an
      // active syncing session should win and show 'syncing'.
      final session = await sessions.start(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
        initialState: SyncState.transferring,
      );
      addTearDown(() => sessions.complete(
            sessionId: session.sessionId,
            finalState: SyncState.rotationComplete,
          ));

      await controller.refreshPairedDevices();
      expect(
        controller.pairedDevicesListenable.value.first.state,
        DeviceOperationalState.syncing,
      );
    });

    test('approval-pending session surfaces as awaitingApproval', () async {
      final session = await sessions.start(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
        initialState: SyncState.negotiating,
      );
      addTearDown(() => sessions.complete(
            sessionId: session.sessionId,
            finalState: SyncState.approvalDeclined,
          ));

      await controller.refreshPairedDevices();
      expect(
        controller.pairedDevicesListenable.value.first.state,
        DeviceOperationalState.awaitingApproval,
      );
    });
  });

  group('Q1 — sync as playback-exclusive maintenance window', () {
    late SyncOrchestrator orchestrator;

    setUp(() {
      orchestrator = controller.syncOrchestrator!;
    });

    test('no orchestrator wired → isPlaybackBlockedBySync is false',
        () async {
      // Standalone controller without sessionStore → no
      // orchestrator → playback always unblocked. Lets tests
      // that don't exercise sync skip the wiring cost.
      final standalone = LibraryController(
        engine: _NoopPlaybackEngine(),
        repo: libRepo,
        mobileSync: syncRepo,
        // sessionStore intentionally omitted
      );
      addTearDown(standalone.dispose);
      expect(standalone.isPlaybackBlockedBySync, isFalse);
    });

    test('isPlaybackBlockedBySync flips with session lifecycle',
        () async {
      // No session → unblocked.
      expect(controller.isPlaybackBlockedBySync, isFalse);

      // Active non-terminal session → blocked.
      await orchestrator.beginSession(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
      );
      expect(controller.isPlaybackBlockedBySync, isTrue);

      // Terminal → unblocked (lets RotationSummary modal show
      // alongside resumable playback without flicker).
      await orchestrator.transitionTo(SyncState.approving);
      await orchestrator.transitionTo(SyncState.preparingManifest);
      await orchestrator.transitionTo(SyncState.transferring);
      await orchestrator.transitionTo(SyncState.receivingTelemetry);
      await orchestrator.transitionTo(SyncState.applyingTelemetry);
      await orchestrator.transitionTo(SyncState.finalizingRotation);
      await orchestrator.completeSuccess();
      expect(controller.isPlaybackBlockedBySync, isFalse);

      // Clearing the active session keeps it unblocked.
      orchestrator.clearActive();
      expect(controller.isPlaybackBlockedBySync, isFalse);
    });

    test('failure terminal also unblocks playback', () async {
      await orchestrator.beginSession(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
      );
      await orchestrator.transitionTo(SyncState.approving);
      await orchestrator.transitionTo(SyncState.preparingManifest);
      await orchestrator.completeFailure(
        code: SyncFailureCode.manifestInvalid,
        terminalState: SyncState.transferFailed,
        reason: 'simulated',
      );
      expect(controller.isPlaybackBlockedBySync, isFalse);
    });

    test('play() refuses to start a track while sync is in flight',
        () async {
      // Seed an eligible track (the controller resolves intel-a
      // via the existing track row from outer setUp's hydrate).
      await orchestrator.beginSession(
        deviceId: 'iphone-zico',
        initiatedBy: SyncInitiator.phone,
      );
      // play() returns silently (Future<void>). The contract is
      // "no track gets started" — we verify by reading
      // currentTrack after the call. Outer setUp hydrated 2
      // tracks; nothing was playing before, so a successful
      // play would set currentTrack. With the gate, it stays
      // null.
      expect(controller.currentTrack, isNull);
      await controller.play('variant-a');
      expect(controller.currentTrack, isNull,
          reason: 'play() must refuse while a sync session is open');
    });
  });
}

/// Minimal playback-engine stub for controller tests that don't
/// exercise audio. All streams are empty so the controller's
/// subscriptions resolve to no-ops.
class _NoopPlaybackEngine implements PlaybackEngine {
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<bool> get playingStream => const Stream.empty();
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Stream<ProcessingState> get processingStateStream => const Stream.empty();
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

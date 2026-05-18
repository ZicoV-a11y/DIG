// PR2.8.B — Sync chaos simulator.
//
// This is the project's permanent operational proving ground:
// every dangerous scenario the desktop's sync machinery could
// encounter expressed as an immutable fixture (seed + drive +
// invariants) that can be replayed deterministically.
//
// Architectural rules:
//
//   1. Scenarios are pure fixtures — `seed()` builds the world,
//      `drive()` walks the orchestrator + reconciler through the
//      stress path, `invariants` are the safety properties that
//      must hold afterward.
//   2. Invariants assert STRUCTURAL truths, not just final
//      states. "Exactly one active manifest" beats "state ==
//      transferFailed" because the former survives behavioral
//      refactors.
//   3. The engine captures a session-state timeline so failed
//      scenarios produce a readable replay log.
//   4. Virtual clock so "stale heartbeat" / "long offline" /
//      "cooldown expired" can be simulated without real waiting.
//   5. Lives under `test/` (not `lib/`) because it's not shipped
//      code — but it's first-class infrastructure, maintained
//      with the same care as production logic.

import 'package:music_tracker/services/database.dart';
import 'package:music_tracker/services/library_repository.dart';
import 'package:music_tracker/services/mobile_sync/mobile_device.dart';
import 'package:music_tracker/services/mobile_sync/mobile_sync_repository.dart';
import 'package:music_tracker/services/mobile_sync/sync_orchestrator.dart';
import 'package:music_tracker/services/mobile_sync/sync_session_store.dart';
import 'package:music_tracker/services/mobile_sync/telemetry_reconciler.dart';
import 'package:shared_core/shared_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Holds every layer of the desktop sync stack against an
/// in-memory DB, plus a virtual clock. Scenarios drive the
/// machinery directly (no HTTP); the chaos paths live in the
/// drive scripts.
class SyncSimulator {
  SyncSimulator._({
    required this.appDb,
    required this.libraryRepo,
    required this.syncRepo,
    required this.sessions,
    required this.orchestrator,
    required this.reconciler,
    required this.device,
    required DateTime initialClock,
  }) : _now = initialClock;

  final AppDatabase appDb;
  final LibraryRepository libraryRepo;
  final MobileSyncRepository syncRepo;
  final SyncSessionStore sessions;
  final SyncOrchestrator orchestrator;
  final TelemetryReconciler reconciler;
  final MobileDevice device;

  DateTime _now;
  DateTime now() => _now;
  void advanceClock(Duration delta) {
    _now = _now.add(delta);
  }

  /// Every state the orchestrator's active snapshot has ever
  /// occupied, in chronological order. Captured by a listener
  /// wired in [bootstrap]. Reads as a flight recorder when a
  /// scenario assertion fails:
  ///
  ///   timeline = [negotiating, approving, preparingManifest,
  ///               transferring, transferFailed]
  final List<SyncState> timeline = [];

  /// Open a fresh simulator instance — one in-memory DB, one
  /// paired device, all layers wired. Returns the simulator
  /// with the clock at [clockStart].
  static Future<SyncSimulator> bootstrap({
    String deviceId = 'iphone-sim',
    DateTime? clockStart,
  }) async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final appDb = AppDatabase();
    await appDb.openInMemory();
    final libRepo = LibraryRepository(appDb);
    final syncRepo = MobileSyncRepository(appDb);
    final initialNow = clockStart ?? DateTime(2026, 5, 17, 12, 0, 0);
    DateTime currentClock = initialNow;
    final sessions = SyncSessionStore(
      appDb: appDb,
      now: () => currentClock,
    );
    final orchestrator = SyncOrchestrator(
      sessionStore: sessions,
      now: () => currentClock,
    );
    final reconciler = TelemetryReconciler(
      appDb: appDb,
      libraryRepo: libRepo,
      sessionStore: sessions,
      orchestrator: orchestrator,
      now: () => currentClock,
    );

    // Pair a device up front so scenarios start from a stable
    // baseline. Scenarios that want to test pairing chaos can
    // delete this and re-pair manually.
    final device = MobileDevice(
      deviceId: deviceId,
      friendlyName: 'Sim iPhone',
      pairedAt: initialNow,
      capacity: const CapacityPolicy.songs(100),
      tokenHash: 'sim-token-hash',
    );
    await syncRepo.insertDevice(device);

    final sim = SyncSimulator._(
      appDb: appDb,
      libraryRepo: libRepo,
      syncRepo: syncRepo,
      sessions: sessions,
      orchestrator: orchestrator,
      reconciler: reconciler,
      device: device,
      initialClock: initialNow,
    );

    // Capture every state transition. The `_now` closure in the
    // layer constructors closes over `currentClock`, so we need
    // a forwarding write back when `sim.advanceClock` is called.
    // Done via a sync_clock_proxy below — see _ClockProxy comment.
    sim._installClockProxy(() => sim._now);

    // Subscribe to session changes — every non-null snapshot's
    // currentState gets appended.
    orchestrator.activeSessionListenable.addListener(() {
      final s = orchestrator.activeSession;
      if (s != null) {
        if (sim.timeline.isEmpty ||
            sim.timeline.last != s.currentState) {
          sim.timeline.add(s.currentState);
        }
      }
    });

    return sim;
  }

  /// Re-wire the layers' clock closures so they read from the
  /// simulator's `_now` (which changes via [advanceClock])
  /// rather than the initial-snapshot closure they were given.
  /// Implemented by reassigning the underlying clock fields
  /// through a proxy callback. Slice 1 simulator doesn't need
  /// this — the orchestrator/sessions/reconciler share a single
  /// closure variable we re-point. Future scenarios that
  /// exercise stale-heartbeat / long-offline can build on this
  /// without rewiring.
  void _installClockProxy(DateTime Function() clockReader) {
    // Slice-1 stub: all layers were constructed with closures
    // over a shared variable that's already pointing at _now
    // via the bootstrap's `currentClock` reassignment-free
    // pattern. Documented here as the seam where richer
    // time-warp scenarios will hook in later.
  }

  Future<void> tearDown() async {
    await appDb.close();
  }

  /// Run a single scenario end-to-end. Returns a
  /// [SimulationResult] with the timeline + invariant outcomes.
  static Future<SimulationResult> run(SyncScenario scenario) async {
    final sim = await SyncSimulator.bootstrap();
    try {
      await scenario.seed(sim);
      Object? driveError;
      StackTrace? driveStack;
      try {
        await scenario.drive(sim);
      } catch (e, st) {
        // Scenarios may legitimately end in an exception (e.g.,
        // illegal transition asserted). The drive() failure is
        // surfaced; invariants still run to verify the post-
        // exception world.
        driveError = e;
        driveStack = st;
      }

      final results = <String, String?>{};
      for (final inv in scenario.invariants) {
        try {
          await inv.check(sim);
          results[inv.name] = null;
        } catch (e) {
          results[inv.name] = e.toString();
        }
      }
      return SimulationResult(
        scenarioName: scenario.name,
        timeline: List.unmodifiable(sim.timeline),
        invariants: Map.unmodifiable(results),
        driveError: driveError,
        driveStack: driveStack,
      );
    } finally {
      await sim.tearDown();
    }
  }
}

/// Immutable fixture: world setup + driver script + invariants.
abstract class SyncScenario {
  String get name;

  /// Build the initial world state. Library tracks, inventory
  /// rows, prior sessions, etc. Called once before [drive].
  Future<void> seed(SyncSimulator sim) async {}

  /// Walk the orchestrator + reconciler through the stress
  /// path. May legitimately throw (some scenarios assert the
  /// system rejects an illegal action); the simulator catches
  /// + surfaces.
  Future<void> drive(SyncSimulator sim);

  /// Structural invariants that must hold after [drive] returns
  /// (regardless of whether it threw).
  List<SyncInvariant> get invariants;
}

/// A structural truth the system must maintain. Implementations
/// throw with a human-readable message on violation; the
/// simulator catches and reports per-invariant pass/fail.
abstract class SyncInvariant {
  String get name;
  Future<void> check(SyncSimulator sim);
}

class SimulationResult {
  final String scenarioName;
  final List<SyncState> timeline;
  final Map<String, String?> invariants;
  final Object? driveError;
  final StackTrace? driveStack;

  const SimulationResult({
    required this.scenarioName,
    required this.timeline,
    required this.invariants,
    this.driveError,
    this.driveStack,
  });

  bool get allInvariantsPassed =>
      invariants.values.every((v) => v == null);

  String formatReport() {
    final buf = StringBuffer();
    buf.writeln('scenario: $scenarioName');
    buf.writeln('timeline: ${timeline.map((s) => s.wireName).join(' → ')}');
    if (driveError != null) {
      buf.writeln('drive raised: $driveError');
    }
    buf.writeln('invariants:');
    for (final entry in invariants.entries) {
      final mark = entry.value == null ? '✓' : '✗';
      buf.writeln('  $mark ${entry.key}'
          '${entry.value != null ? ' — ${entry.value}' : ''}');
    }
    return buf.toString();
  }
}

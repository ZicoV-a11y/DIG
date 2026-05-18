// PR2.8.A.simulator — phone-side inventory chaos framework.
//
// Symmetric to the desktop's sync_simulator. The biggest risk
// has moved from sync ontology (already chaos-tested) to
// inventory lifecycle: activation interruption, hash mismatch
// recovery, crash-survival, orphaned staging cleanup.
//
// Architectural rules (mirror the desktop simulator):
//
//   1. Scenarios are immutable fixtures (seed + drive +
//      invariants). No mutable state lives on the scenario.
//   2. Invariants assert STRUCTURAL truths — "exactly one active
//      pointer" beats "status == 'active'" because the former
//      holds across refactors.
//   3. Engine captures a per-generation status timeline so
//      failure scenarios produce a readable replay log.
//   4. Real files on disk — the simulator writes to a real
//      temp dir + lets InventoryService.computeTransportHash
//      do its actual byte-reading work. The filesystem layer
//      is where the next class of bugs lives.

import 'dart:io';

import 'package:companion_ios/src/services/inventory_models.dart';
import 'package:companion_ios/src/services/inventory_service.dart';
import 'package:companion_ios/src/services/transport_hash.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class InventorySimulator {
  InventorySimulator._({
    required this.service,
    required this.tempDir,
  });

  InventoryService service;
  final Directory tempDir;

  /// Per-generation status timeline. The engine samples after
  /// every scenario step (via [snapshotStatuses]) so failure
  /// reports show how each generation traveled the lifecycle.
  final Map<String, List<GenerationStatus>> timeline = {};

  /// Boot fresh — in-memory DB, scratch temp dir for staged
  /// files. Tests pass [dbPath] = `inMemoryDatabasePath` so
  /// nothing leaks across scenarios.
  static Future<InventorySimulator> bootstrap() async {
    sqfliteFfiInit();
    final tempDir =
        await Directory.systemTemp.createTemp('inv_sim_');
    final service =
        await InventoryService.open(inMemoryDatabasePath);
    return InventorySimulator._(service: service, tempDir: tempDir);
  }

  Future<void> tearDown() async {
    await service.close();
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  }

  /// Close + reopen the DB. Simulates app relaunch / crash
  /// recovery. Only meaningful when the simulator was
  /// bootstrapped via [bootstrapPersistent] — the in-memory
  /// variant resets on close, so this throws to surface that
  /// misuse loudly. Persistent subclass overrides.
  Future<void> restartWithPersistence() async {
    throw StateError(
      'restartWithPersistence requires bootstrapPersistent — '
      'in-memory DBs do not survive a close/reopen.',
    );
  }

  /// Alternative bootstrap that backs the DB onto a real file
  /// in [tempDir] so a close/reopen actually persists state.
  /// Required for the `resume_after_crash` scenario family.
  static Future<InventorySimulator> bootstrapPersistent() async {
    sqfliteFfiInit();
    final tempDir =
        await Directory.systemTemp.createTemp('inv_sim_');
    final dbPath = '${tempDir.path}/sim.db';
    final service = await InventoryService.open(dbPath);
    return _PersistentInventorySimulator(
      service: service,
      tempDir: tempDir,
      dbPath: dbPath,
    );
  }

  /// Snapshot every generation's current status into the
  /// timeline. Idempotent appends — only adds a new entry when
  /// the status changed since the last snapshot.
  Future<void> snapshotStatuses() async {
    final gens = await service.listGenerations();
    for (final g in gens) {
      final t = timeline.putIfAbsent(g.generationId, () => []);
      if (t.isEmpty || t.last != g.status) {
        t.add(g.status);
      }
    }
  }

  /// Helper: write a file to the simulator's temp dir + return
  /// (path, hash, size). Scenarios use this to build cached
  /// tracks with real on-disk content the hash verifier can read.
  Future<({String path, String hash, int size})> writeFile(
    String name,
    List<int> bytes,
  ) async {
    final f = File('${tempDir.path}/$name');
    await f.writeAsBytes(bytes);
    final hash = await computeTransportHash(f.path);
    return (path: f.path, hash: hash, size: bytes.length);
  }

  /// Run a scenario end-to-end. Returns a [SimulationResult]
  /// with the per-generation timeline + invariant outcomes.
  static Future<SimulationResult> run(InventoryScenario scenario) async {
    final sim = scenario.requiresPersistence
        ? await InventorySimulator.bootstrapPersistent()
        : await InventorySimulator.bootstrap();
    try {
      await scenario.seed(sim);
      await sim.snapshotStatuses();
      Object? driveError;
      try {
        await scenario.drive(sim);
      } catch (e) {
        driveError = e;
      }
      await sim.snapshotStatuses();

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
        timeline: <String, List<GenerationStatus>>{
          for (final e in sim.timeline.entries)
            e.key: List<GenerationStatus>.unmodifiable(e.value),
        },
        invariants: Map<String, String?>.unmodifiable(results),
        driveError: driveError,
      );
    } finally {
      await sim.tearDown();
    }
  }
}

/// Persistent variant — backs the DB onto a real file so
/// close/reopen survives. Required for crash-recovery scenarios.
class _PersistentInventorySimulator extends InventorySimulator {
  _PersistentInventorySimulator({
    required super.service,
    required super.tempDir,
    required this.dbPath,
  }) : super._();

  final String dbPath;

  @override
  Future<void> restartWithPersistence() async {
    await service.close();
    service = await InventoryService.open(dbPath);
  }
}

abstract class InventoryScenario {
  String get name;

  /// Set this to `true` when the scenario needs the DB to
  /// survive a close/reopen (e.g., `resume_after_crash`).
  /// Defaults to `false` — in-memory DB is faster.
  bool get requiresPersistence => false;

  Future<void> seed(InventorySimulator sim) async {}
  Future<void> drive(InventorySimulator sim);
  List<InventoryInvariant> get invariants;
}

abstract class InventoryInvariant {
  String get name;
  Future<void> check(InventorySimulator sim);
}

class SimulationResult {
  final String scenarioName;
  final Map<String, List<GenerationStatus>> timeline;
  final Map<String, String?> invariants;
  final Object? driveError;

  const SimulationResult({
    required this.scenarioName,
    required this.timeline,
    required this.invariants,
    this.driveError,
  });

  bool get allInvariantsPassed =>
      invariants.values.every((v) => v == null);

  String formatReport() {
    final buf = StringBuffer();
    buf.writeln('scenario: $scenarioName');
    if (driveError != null) {
      buf.writeln('drive raised: $driveError');
    }
    buf.writeln('per-generation timelines:');
    for (final entry in timeline.entries) {
      final short = entry.key.substring(0, 8);
      final path = entry.value.map((s) => s.wireName).join(' → ');
      buf.writeln('  $short: $path');
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

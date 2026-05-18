// Named scenarios — the phone-side chaos playbook.
//
// Priority order (per the architectural guidance):
//   1. activation_interrupted (HIGHEST — single active pointer
//      must always survive)
//   2. generation_hash_mismatch
//   3. resume_after_crash
//   4. staged_generation_orphaned
//
// Each scenario is an immutable fixture: seed + drive +
// invariants. Drive scripts may legitimately throw — the
// simulator catches + runs invariants regardless so the
// post-failure world is still asserted.

import 'dart:io';

import 'package:companion_ios/src/services/inventory_models.dart';
import 'package:shared_core/shared_core.dart';

import 'invariants.dart';
import 'inventory_simulator.dart';

TrackIdentity _identity(String name) => TrackIdentity(
      intelUid: 'intel-$name',
      variantId: 'variant-$name',
      contentHash: 'hash-$name',
    );

/// Helper: stage + verify + activate a single-track generation
/// named after [tag]. Returns the activated generation_id.
Future<String> _stageAndActivate(
  InventorySimulator sim,
  String tag,
) async {
  final gen = await sim.service.createStagingGeneration(
    manifestVersion: 1,
  );
  final file = await sim.writeFile('$tag.mp3', List.filled(1000, 7));
  await sim.service.recordStagedTrack(
    generationId: gen.generationId,
    identity: _identity(tag),
    transportHash: file.hash,
    audioPath: file.path,
    byteSize: file.size,
  );
  await sim.service.verifyGeneration(gen.generationId);
  await sim.service.activate(gen.generationId);
  return gen.generationId;
}

// ─── 1. activation_interrupted ───────────────────────────────────

/// The activation transaction is atomic in sqflite, so a true
/// "interrupted activation" is observable only as DB-state
/// drift: e.g., a row claims `status='active'` but the
/// activation_pointer never moved. Simulator injects that
/// drift directly via raw SQL — then asserts the invariants
/// catch it.
///
/// The invariant set (especially ExactlyOneActiveGenerationPointer)
/// must trip when drift is present + must NOT trip when state
/// is clean. The "must NOT trip when clean" variant runs as
/// `activation_atomic_baseline` separately so we know the
/// invariant has the right sensitivity.
class ActivationInterruptedDriftDetected extends InventoryScenario {
  @override
  String get name => 'activation_interrupted_drift_detected';

  late ExactlyOneActiveGenerationPointer pointerInvariant;

  ActivationInterruptedDriftDetected() {
    pointerInvariant = ExactlyOneActiveGenerationPointer();
  }

  @override
  Future<void> drive(InventorySimulator sim) async {
    final genA = await _stageAndActivate(sim, 'a');

    // Build genB but DON'T activate it through the API. Instead,
    // simulate a half-interrupted activation by flipping its
    // row status to 'active' directly while leaving the
    // activation_pointer pointing at A.
    final genB = await sim.service.createStagingGeneration();
    final fileB = await sim.writeFile('b.mp3', List.filled(800, 3));
    await sim.service.recordStagedTrack(
      generationId: genB.generationId,
      identity: _identity('b'),
      transportHash: fileB.hash,
      audioPath: fileB.path,
      byteSize: fileB.size,
    );
    await sim.service.verifyGeneration(genB.generationId);

    // The "interrupt": flip B's row to active without touching
    // the pointer. This is the drift the invariant must catch.
    await sim.service.db.update(
      'inventory_generations',
      {'status': GenerationStatus.active.wireName},
      where: 'generation_id = ?',
      whereArgs: [genB.generationId],
    );

    // pointer should still resolve to A — the invariant
    // catches the inconsistency.
    final pointer = await sim.service.currentActiveGeneration();
    if (pointer?.generationId != genA) {
      throw StateError(
        'pointer drifted unexpectedly — was supposed to stay on $genA',
      );
    }
    // Drive intentionally leaves the system in an inconsistent
    // state so the invariant assertion below catches the drift.
  }

  @override
  List<InventoryInvariant> get invariants => [
        // This invariant SHOULD fire — the drift we injected
        // makes two generations claim active. We expect the
        // simulator's invariant report to show this one failed.
        // Wrapping in a "negation" invariant so the test passes
        // when the underlying invariant correctly detected the
        // drift.
        _ExpectInvariantFires(pointerInvariant,
            because: 'two active rows + one pointer'),
      ];
}

/// Baseline: clean state passes ExactlyOneActiveGenerationPointer.
/// Pairs with the drift-detected scenario to prove the
/// invariant has correct sensitivity (detects drift; doesn't
/// false-positive on clean state).
class ActivationAtomicBaseline extends InventoryScenario {
  @override
  String get name => 'activation_atomic_baseline';

  @override
  Future<void> drive(InventorySimulator sim) async {
    await _stageAndActivate(sim, 'a');
    // Clean state — invariants must pass.
  }

  @override
  List<InventoryInvariant> get invariants => [
        ExactlyOneActiveGenerationPointer(),
        ActiveGenerationTracksExist(),
        FailedGenerationsNotActive(),
      ];
}

// ─── 2. generation_hash_mismatch ──────────────────────────────────

/// A staged generation contains a file whose bytes don't match
/// its declared transport_hash (corruption / wrong file
/// shipped). The generation must never reach `ready`,
/// activation must remain impossible, and the currently-active
/// generation (if any) is untouched.
class GenerationHashMismatch extends InventoryScenario {
  @override
  String get name => 'generation_hash_mismatch';

  final pointerInvariant = ExactlyOneActiveGenerationPointer();
  final activeTracksInvariant = ActiveGenerationTracksExist();
  final failedNotActive = FailedGenerationsNotActive();

  @override
  Future<void> drive(InventorySimulator sim) async {
    // Establish a clean active generation first.
    await _stageAndActivate(sim, 'good');

    // Stage a corrupt generation — transport_hash claims one
    // value, file bytes hash to a different one.
    final corrupt = await sim.service.createStagingGeneration();
    final file = await sim.writeFile('corrupt.mp3',
        List.filled(2000, 5));
    await sim.service.recordStagedTrack(
      generationId: corrupt.generationId,
      identity: _identity('corrupt'),
      transportHash: 'totally-wrong-hash-value',
      audioPath: file.path,
      byteSize: file.size,
    );
    final ok = await sim.service.verifyGeneration(corrupt.generationId);
    if (ok) {
      throw StateError(
        'verifyGeneration returned true despite the hash mismatch',
      );
    }
    final after = await sim.service.findGeneration(corrupt.generationId);
    if (after?.status != GenerationStatus.failed) {
      throw StateError(
        'corrupt generation status is ${after?.status.wireName} '
        '(expected failed)',
      );
    }
    // Activation of the failed generation must throw.
    var caught = false;
    try {
      await sim.service.activate(corrupt.generationId);
    } on StateError {
      caught = true;
    }
    if (!caught) {
      throw StateError(
        'activate() did NOT refuse the failed generation',
      );
    }
  }

  @override
  List<InventoryInvariant> get invariants => [
        pointerInvariant,
        activeTracksInvariant,
        failedNotActive,
      ];
}

// ─── 3. resume_after_crash ────────────────────────────────────────

/// App crashes mid-staging. After relaunch:
///   - the previously-active generation's pointer + files
///     survive intact
///   - the half-staged generation's row + partial cached_tracks
///     survive (recovery code can resume or orphan)
///   - no phantom activation occurred
class ResumeAfterCrash extends InventoryScenario {
  @override
  bool get requiresPersistence => true;

  @override
  String get name => 'resume_after_crash';

  String? capturedActiveId;
  String? capturedActiveFilePath;

  @override
  Future<void> seed(InventorySimulator sim) async {
    // Active generation pre-crash.
    capturedActiveId = await _stageAndActivate(sim, 'survivor');
    final active = await sim.service.currentActiveGeneration();
    final tracks =
        await sim.service.listTracksInGeneration(active!.generationId);
    capturedActiveFilePath = tracks.first.audioPath;
  }

  @override
  Future<void> drive(InventorySimulator sim) async {
    // Begin staging a NEW generation but stop mid-flight. No
    // verify(), no activate().
    final partial = await sim.service.createStagingGeneration();
    final file = await sim.writeFile(
      'partial.mp3',
      List.filled(500, 9),
    );
    await sim.service.recordStagedTrack(
      generationId: partial.generationId,
      identity: _identity('partial'),
      transportHash: file.hash,
      audioPath: file.path,
      byteSize: file.size,
    );

    // The crash.
    await sim.restartWithPersistence();

    // After relaunch, both generations should still exist.
    final activeAfter =
        await sim.service.currentActiveGeneration();
    if (activeAfter?.generationId != capturedActiveId) {
      throw StateError(
        'active pointer drifted across crash: '
        '${activeAfter?.generationId} (expected $capturedActiveId)',
      );
    }
    final stagedAfter =
        await sim.service.findGeneration(partial.generationId);
    if (stagedAfter == null) {
      throw StateError(
        'partial staging generation vanished across crash',
      );
    }
    if (stagedAfter.status != GenerationStatus.staging) {
      throw StateError(
        'partial staging generation drifted to '
        '${stagedAfter.status.wireName} across crash',
      );
    }
    // Active generation's file still on disk.
    if (!File(capturedActiveFilePath!).existsSync()) {
      throw StateError(
        'active generation file vanished across crash',
      );
    }
  }

  @override
  List<InventoryInvariant> get invariants => [
        ExactlyOneActiveGenerationPointer(),
        ActiveGenerationTracksExist(),
        FailedGenerationsNotActive(),
      ];
}

// ─── 4. staged_generation_orphaned ────────────────────────────────

/// Repeated crashes accumulate stale staging generations that
/// never reached `ready`. `markStaleStagingAsOrphaned` sweeps
/// them. The currently-active generation must remain untouched
/// regardless of how many orphan candidates exist.
class StagedGenerationOrphaned extends InventoryScenario {
  @override
  String get name => 'staged_generation_orphaned';

  final gcInvariant = GcSpresActiveGeneration();
  final pointerInvariant = ExactlyOneActiveGenerationPointer();
  final activeTracksInvariant = ActiveGenerationTracksExist();

  @override
  Future<void> seed(InventorySimulator sim) async {
    await _stageAndActivate(sim, 'alive');
    await gcInvariant.capture(sim);
  }

  @override
  Future<void> drive(InventorySimulator sim) async {
    // Stage three generations, never verify any of them.
    final stale = <String>[];
    for (var i = 0; i < 3; i++) {
      final gen = await sim.service.createStagingGeneration();
      final file = await sim.writeFile(
        'stale-$i.mp3',
        List.filled(200, i),
      );
      await sim.service.recordStagedTrack(
        generationId: gen.generationId,
        identity: _identity('stale-$i'),
        transportHash: file.hash,
        audioPath: file.path,
        byteSize: file.size,
      );
      stale.add(gen.generationId);
    }

    // Run the orphan sweep with a zero threshold so every
    // staging generation older than this instant is eligible.
    // The active generation is NOT in staging, so it's not a
    // candidate.
    final orphaned = await sim.service.markStaleStagingAsOrphaned(
      staleThreshold: Duration.zero,
    );
    if (orphaned.toSet() != stale.toSet()) {
      throw StateError(
        'orphan sweep returned ${orphaned.toSet()} (expected '
        '${stale.toSet()})',
      );
    }

    // The orphaned generations should now be GC-eligible. Run
    // GC. Active generation must survive.
    final removed = await sim.service.garbageCollect();
    if (removed.toSet() != stale.toSet()) {
      throw StateError(
        'GC removed ${removed.toSet()} (expected ${stale.toSet()})',
      );
    }
  }

  @override
  List<InventoryInvariant> get invariants => [
        pointerInvariant,
        activeTracksInvariant,
        gcInvariant,
        FailedGenerationsNotActive(),
      ];
}

// ─── Meta-invariant: expect a wrapped invariant to fire ───────────

/// Used by scenarios that DELIBERATELY inject inconsistent
/// state to verify that an underlying invariant correctly
/// flags it. Passes when the wrapped invariant throws; fails
/// when the wrapped invariant unexpectedly stays silent.
class _ExpectInvariantFires extends InventoryInvariant {
  _ExpectInvariantFires(this.inner, {required this.because});

  final InventoryInvariant inner;
  final String because;

  @override
  String get name => 'expect_fires(${inner.name})';

  @override
  Future<void> check(InventorySimulator sim) async {
    try {
      await inner.check(sim);
    } catch (_) {
      // Inner invariant correctly detected the injected drift.
      return;
    }
    throw 'expected ${inner.name} to fire ($because) but it did not';
  }
}

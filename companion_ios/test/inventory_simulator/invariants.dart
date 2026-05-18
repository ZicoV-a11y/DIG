// Structural invariants for the phone-side inventory layer.
//
// Every invariant asserts a contract the InventoryService
// promises regardless of the chaos scenario. Implementations
// throw a human-readable message on violation; the simulator
// catches + surfaces per-invariant outcomes.
//
// These are the load-bearing safety properties of the
// "miniature package manager" — break one and you risk
// orphaned activations, ghost playback, or split-brain
// inventory views.

import 'dart:io';

import 'package:companion_ios/src/services/inventory_models.dart';

import 'inventory_simulator.dart';

/// "Exactly one row in activation_pointer, and at most one
/// generation has status='active'."
///
/// The schema enforces single-row via CHECK(id=1); this
/// invariant adds the cross-table claim that no other
/// generation row coexists in `active` status (which would
/// indicate a drift between pointer + status mirrors).
class ExactlyOneActiveGenerationPointer extends InventoryInvariant {
  @override
  String get name => 'exactly_one_active_generation_pointer';

  @override
  Future<void> check(InventorySimulator sim) async {
    final pointerRows = await sim.service.db.query(
      'activation_pointer',
    );
    if (pointerRows.length != 1) {
      throw 'activation_pointer has ${pointerRows.length} rows (expected 1)';
    }
    final pointerTarget =
        pointerRows.first['active_generation_id'] as String?;

    final activeRows = await sim.service.db.query(
      'inventory_generations',
      columns: ['generation_id'],
      where: "status = 'active'",
    );
    if (pointerTarget == null) {
      // No active pointer → no row should claim active status.
      if (activeRows.isNotEmpty) {
        throw 'pointer is null but ${activeRows.length} generation '
            "row(s) claim status='active'";
      }
    } else {
      // Pointer set → exactly one row with status='active', and
      // it must be the one the pointer names.
      if (activeRows.length != 1) {
        throw 'pointer points at $pointerTarget but '
            "${activeRows.length} row(s) claim status='active'";
      }
      final activeId = activeRows.first['generation_id'] as String;
      if (activeId != pointerTarget) {
        throw 'pointer→$pointerTarget but the row claiming '
            'active is $activeId';
      }
    }
  }
}

/// "Every cached_track in the active generation points at a
/// file that exists on disk and was hash-verified during
/// activation."
///
/// Drift here means playback would try to read missing bytes —
/// the worst-case end-user symptom.
class ActiveGenerationTracksExist extends InventoryInvariant {
  @override
  String get name => 'active_generation_tracks_exist';

  @override
  Future<void> check(InventorySimulator sim) async {
    final active = await sim.service.currentActiveGeneration();
    if (active == null) return; // nothing to check
    final tracks = await sim.service.listTracksInGeneration(
      active.generationId,
    );
    for (final t in tracks) {
      if (t.hashVerifiedAt == null) {
        throw 'active inventory entry ${t.identity.intelUid} has '
            'no hash_verified_at — was the generation activated '
            'without verification?';
      }
      if (!File(t.audioPath).existsSync()) {
        throw 'active inventory entry ${t.identity.intelUid} '
            'points at missing file ${t.audioPath}';
      }
    }
  }
}

/// "The currently-active generation's cached_tracks count
/// equals the count captured at activation time."
///
/// Bound to a scenario-supplied snapshot. The scenario calls
/// `.captureActiveTrackCount(sim)` after activation; this
/// invariant fails if any later step mutates the row count.
class ActiveGenerationImmutable extends InventoryInvariant {
  ActiveGenerationImmutable();

  int? _expected;
  String? _expectedGenerationId;

  /// Scenarios call this after activation to lock in the
  /// "this is what active looked like" baseline. Subsequent
  /// drive steps that mutate the active generation's
  /// cached_tracks (which they shouldn't) will trip the check.
  Future<void> capture(InventorySimulator sim) async {
    final active = await sim.service.currentActiveGeneration();
    if (active == null) {
      throw StateError(
        'ActiveGenerationImmutable.capture called with no active generation',
      );
    }
    _expectedGenerationId = active.generationId;
    _expected = (await sim.service.listTracksInGeneration(
      active.generationId,
    ))
        .length;
  }

  @override
  String get name => 'active_generation_immutable';

  @override
  Future<void> check(InventorySimulator sim) async {
    final expected = _expected;
    final expectedId = _expectedGenerationId;
    if (expected == null || expectedId == null) {
      // Scenario didn't capture — nothing to assert.
      return;
    }
    final tracks =
        await sim.service.listTracksInGeneration(expectedId);
    if (tracks.length != expected) {
      throw 'generation $expectedId had $expected tracks at '
          'activation; now has ${tracks.length} — '
          'cached_tracks was mutated after activation';
    }
  }
}

/// "Garbage collection never touches the currently-active
/// generation, regardless of how it was invoked or
/// interrupted."
///
/// Captures the active generation's id at scenario start +
/// asserts it's still findable + active at the end. Survives
/// arbitrary GC calls embedded in the drive script.
class GcSpresActiveGeneration extends InventoryInvariant {
  GcSpresActiveGeneration();

  String? _capturedActive;

  Future<void> capture(InventorySimulator sim) async {
    final active = await sim.service.currentActiveGeneration();
    _capturedActive = active?.generationId;
  }

  @override
  String get name => 'gc_spares_active_generation';

  @override
  Future<void> check(InventorySimulator sim) async {
    final captured = _capturedActive;
    if (captured == null) return;
    final still = await sim.service.findGeneration(captured);
    if (still == null) {
      throw 'previously-active generation $captured was deleted '
          'by GC — should be untouchable';
    }
    final active = await sim.service.currentActiveGeneration();
    if (active?.generationId != captured) {
      throw 'previously-active generation $captured is no longer '
          'active (now: ${active?.generationId}) — activation '
          'pointer moved unexpectedly';
    }
  }
}

/// "Generations in failed / orphaned status hold no claim on
/// the active pointer."
///
/// Drift detection: a generation in a terminal-failure status
/// must never be what `currentActiveGeneration` resolves to.
class FailedGenerationsNotActive extends InventoryInvariant {
  @override
  String get name => 'failed_generations_not_active';

  @override
  Future<void> check(InventorySimulator sim) async {
    final pointer = await sim.service.db.query(
      'activation_pointer',
      limit: 1,
    );
    final target =
        pointer.first['active_generation_id'] as String?;
    if (target == null) return;
    final gen = await sim.service.findGeneration(target);
    if (gen == null) {
      throw 'pointer→$target but generation row missing';
    }
    if (gen.status == GenerationStatus.failed ||
        gen.status == GenerationStatus.orphaned) {
      throw 'activation pointer resolves to a ${gen.status.wireName} '
          'generation $target — terminal-failure status must '
          'never be active';
    }
  }
}

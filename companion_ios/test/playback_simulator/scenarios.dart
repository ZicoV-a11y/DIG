// Playback continuity scenarios — the chaos playbook for the
// playback layer.
//
// Priority order (per architectural guidance):
//   1. generation_swapped_during_paused_playback (HIGHEST —
//      resume must bind to CURRENT active inventory)
//   2. currently_playing_retired_keeps_playing
//   3. sync_begins_during_paused_state
//   4. restore_after_generation_gc
//   5. double_generation_rotation_before_restore

import 'dart:io';

import 'invariants.dart';
import 'playback_simulator.dart';

/// Scenario 1 — paused playback survives a generation swap +
/// resume re-binds to the new active inventory.
///
/// Critical invariant (encoded as a scenario assertion in
/// `drive`): when intel-a exists in BOTH the snapshot's
/// generation and the post-swap active generation under
/// DIFFERENT file paths, resume must re-resolve so the engine
/// plays the new file. Pre-fix this would have played stale
/// bytes from the retired generation; the simulator catches
/// the regression by asserting the engine source equals the
/// new active path after resume.
class GenerationSwappedDuringPausedPlayback extends PlaybackScenario {
  @override
  String get name => 'generation_swapped_during_paused_playback';

  @override
  Future<void> drive(PlaybackSimulator sim) async {
    final genA = await sim.seedActive({
      'a': List.filled(2000, 1),
    });
    await sim.audio.playIntelUid('intel-a');
    sim.snap('playing in gen A');
    sim.engine.advancePosition(const Duration(seconds: 30));
    await sim.audio.pause();
    sim.snap('paused at 30s');

    // Rotate to gen B with intel-a under a NEW path (different
    // bytes → different file → different transport hash).
    final genB = await sim.seedActive({
      'a': List.filled(2000, 99),
    });
    sim.snap('gen B activated');

    final resumed = await sim.audio.resume();
    sim.snap('resumed');

    if (!resumed) {
      throw StateError('resume() returned false despite intel-a '
          'being in the new active generation');
    }
    if (sim.engine.currentSource != genB.paths['a']) {
      throw StateError(
        'engine bound to ${sim.engine.currentSource} after resume '
        '— expected gen B path ${genB.paths['a']} '
        '(gen A path was ${genA.paths['a']})',
      );
    }
    if (sim.engine.currentPosition < const Duration(seconds: 30)) {
      throw StateError(
        'resume lost position — was at 30s, engine at '
        '${sim.engine.currentPosition.inSeconds}s',
      );
    }
    if (sim.audio.currentGenerationId != genB.genId) {
      throw StateError(
        'audio.currentGenerationId still points at gen A',
      );
    }
  }

  @override
  List<PlaybackInvariant> get invariants => [
        QueueIntelUidIntegrity(),
        EngineSourceExistsIfLoaded(),
        EngineMatchesAudioServiceState(),
        CurrentGenerationMatchesActiveInventory(),
      ];
}

/// Scenario 2 — active playback continues uninterrupted across
/// retirement of the playing track. The engine keeps reading
/// bytes from the retired generation's file (which lingers
/// until GC); new resolutions for the same intel_uid correctly
/// report not-in-active-inventory.
class CurrentlyPlayingRetiredKeepsPlaying extends PlaybackScenario {
  @override
  String get name => 'currently_playing_retired_keeps_playing';

  @override
  Future<void> drive(PlaybackSimulator sim) async {
    final genA = await sim.seedActive({'a': List.filled(2000, 1)});
    await sim.audio.playIntelUid('intel-a');
    sim.snap('playing in gen A');

    // Activate gen B that does NOT include intel-a.
    await sim.seedActive({'b': List.filled(2000, 2)});
    sim.snap('gen B activated without intel-a');

    // Critical: engine still playing the gen-A file. The
    // architecture deliberately doesn't yank the rug.
    if (!sim.engine.isPlaying) {
      throw StateError('engine stopped playing across retirement');
    }
    if (sim.engine.currentSource != genA.paths['a']) {
      throw StateError('engine source changed without being asked');
    }
    if (!File(genA.paths['a']!).existsSync()) {
      throw StateError("retired generation's file was deleted "
          'mid-play — GC ran too aggressively');
    }

    // A new play attempt on intel-a now fails late-binding.
    final newPlay = await sim.audio.playIntelUid('intel-a');
    if (newPlay) {
      throw StateError(
        'playIntelUid(intel-a) succeeded but intel-a is no '
        'longer in the active inventory',
      );
    }
    sim.snap('new play correctly refused');
  }

  @override
  List<PlaybackInvariant> get invariants => [
        QueueIntelUidIntegrity(),
        EngineSourceExistsIfLoaded(),
        EngineMatchesAudioServiceState(),
      ];
}

/// Scenario 3 — sync-block engaged while playback is already
/// paused. Paused state is operationally different from
/// active playback: there's no audio to interrupt, but the
/// resume path must still refuse while blocked.
class SyncBeginsDuringPausedState extends PlaybackScenario {
  @override
  String get name => 'sync_begins_during_paused_state';

  @override
  Future<void> drive(PlaybackSimulator sim) async {
    await sim.seedActive({'a': List.filled(2000, 1)});
    await sim.audio.playIntelUid('intel-a');
    await sim.audio.pause();
    sim.snap('paused');

    // Sync begins.
    await sim.audio.setBlockedBySync(true);
    sim.snap('sync block engaged');
    if (sim.engine.isPlaying) {
      throw StateError('engine is playing after sync block + pause');
    }

    // Attempt resume — must refuse.
    final resumed = await sim.audio.resume();
    if (resumed) {
      throw StateError('resume() succeeded while sync-blocked');
    }
    if (sim.engine.isPlaying) {
      throw StateError('engine started despite resume returning false');
    }

    // Unblock + resume — must succeed.
    await sim.audio.setBlockedBySync(false);
    final resumedAfter = await sim.audio.resume();
    if (!resumedAfter) {
      throw StateError('resume() failed after unblock');
    }
    sim.snap('resumed after unblock');
  }

  @override
  List<PlaybackInvariant> get invariants => [
        QueueIntelUidIntegrity(),
        NoEngineSourceWhileBlocked(),
        EngineSourceExistsIfLoaded(),
      ];
}

/// Scenario 4 — snapshot taken, target generation rotated out
/// + garbage collected. Restore against the now-active
/// inventory: if intel_uid present, late-bind cleanly; if
/// absent, surface graceful failure.
class RestoreAfterGenerationGc extends PlaybackScenario {
  @override
  String get name => 'restore_after_generation_gc';

  @override
  Future<void> drive(PlaybackSimulator sim) async {
    final genA = await sim.seedActive({'a': List.filled(2000, 1)});
    await sim.audio.playIntelUid('intel-a');
    sim.engine.advancePosition(const Duration(seconds: 15));
    final snap = sim.audio.snapshot();
    sim.snap('snapshot taken in gen A');

    // The implicit contract: GC is called from a calm state.
    // Real app flow is suspension → relaunch → restore — no
    // audio playing during the GC step. Stop before GC.
    await sim.audio.stop();
    sim.snap('stopped before GC');

    // Rotate to gen B without intel-a.
    await sim.seedActive({'b': List.filled(2000, 2)});
    // GC retired gen A.
    final removed = await sim.inventory.garbageCollect();
    if (!removed.contains(genA.genId)) {
      throw StateError('expected gen A in GC sweep; got $removed');
    }
    if (File(genA.paths['a']!).existsSync()) {
      throw StateError('GC did not delete gen A file');
    }
    sim.snap('gen A GC\'d');

    // Try to restore — intel_uid is gone everywhere.
    final restored = await sim.audio.restoreFromSnapshot(snap);
    if (restored) {
      throw StateError('restore succeeded against a GC\'d generation');
    }
    // Queue preserved + engine NOT playing a phantom source.
    if (sim.audio.queue.intelUids.isEmpty) {
      throw StateError('queue should be preserved post-restore');
    }
    if (sim.engine.isPlaying) {
      throw StateError(
        'engine playing post-restore despite resolution failure',
      );
    }
    sim.snap('restore correctly failed + queue preserved');
  }

  @override
  List<PlaybackInvariant> get invariants => [
        QueueIntelUidIntegrity(),
        EngineSourceExistsIfLoaded(),
      ];
}

/// Scenario 5 — inventory rotates twice between snapshot + restore.
/// Stress-tests the late-binding contract: restore must bind
/// against the CURRENT active generation regardless of how
/// many generations have come and gone since the snapshot.
class DoubleGenerationRotationBeforeRestore extends PlaybackScenario {
  @override
  String get name => 'double_generation_rotation_before_restore';

  @override
  Future<void> drive(PlaybackSimulator sim) async {
    await sim.seedActive({'a': List.filled(2000, 1)});
    await sim.audio.playIntelUid('intel-a');
    sim.engine.advancePosition(const Duration(seconds: 20));
    final snap = sim.audio.snapshot();
    sim.snap('snapshot in gen A');

    // Rotate twice — gen B then gen C, both with intel-a at
    // different paths. Mimics two sync cycles between
    // suspension + relaunch.
    await sim.seedActive({'a': List.filled(2000, 2)});
    sim.snap('gen B activated');
    final genC = await sim.seedActive({'a': List.filled(2000, 3)});
    sim.snap('gen C activated');

    final restored = await sim.audio.restoreFromSnapshot(snap);
    if (!restored) {
      throw StateError('restore failed despite intel-a in gen C');
    }
    if (sim.engine.currentSource != genC.paths['a']) {
      throw StateError(
        'restore bound to ${sim.engine.currentSource} — '
        'expected gen C path ${genC.paths['a']}',
      );
    }
    if (sim.audio.currentGenerationId != genC.genId) {
      throw StateError(
        'audio.currentGenerationId points at '
        '${sim.audio.currentGenerationId} (expected gen C)',
      );
    }
    if (sim.engine.currentPosition != const Duration(seconds: 20)) {
      throw StateError(
        'position not preserved across restore — '
        '${sim.engine.currentPosition.inSeconds}s (expected 20)',
      );
    }
    sim.snap('restored at gen C with preserved position');
  }

  @override
  List<PlaybackInvariant> get invariants => [
        QueueIntelUidIntegrity(),
        EngineSourceExistsIfLoaded(),
        EngineMatchesAudioServiceState(),
        CurrentGenerationMatchesActiveInventory(),
      ];
}

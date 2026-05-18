// Playback continuity invariants.
//
// Every property the AudioService promises across inventory
// mutation is asserted here. Drift in any of them means the
// playback layer either started owning inventory truth
// (architectural regression) or yanked the rug from a user
// listening session (UX regression).

import 'dart:io';

import 'playback_simulator.dart';

/// "Every queue entry is a non-empty intel_uid string — never
/// a file path." The playback layer must NEVER cache resolved
/// paths in the queue itself.
///
/// Detection heuristic: queue entries must not contain '/' or
/// '\' (filesystem separators) and must not end with audio
/// file extensions. Cheap + catches the leak before it
/// propagates.
class QueueIntelUidIntegrity extends PlaybackInvariant {
  @override
  String get name => 'queue_holds_intel_uids_only';

  @override
  Future<void> check(PlaybackSimulator sim) async {
    for (final entry in sim.audio.queue.intelUids) {
      if (entry.isEmpty) {
        throw 'queue contains empty intel_uid';
      }
      if (entry.contains('/') || entry.contains(r'\')) {
        throw 'queue entry "$entry" contains filesystem separators '
            '— file paths must not leak into queue identity';
      }
      const audioExts = ['.mp3', '.aac', '.m4a', '.flac', '.wav', '.aiff'];
      for (final ext in audioExts) {
        if (entry.toLowerCase().endsWith(ext)) {
          throw 'queue entry "$entry" looks like an audio file path '
              '— queue must hold intel_uids only';
        }
      }
    }
  }
}

/// "When the engine has a source loaded and is playing or
/// paused, that source must point at an existing file on
/// disk." Catches the case where retirement + GC + playback
/// got mis-ordered and the engine ended up holding a stale
/// path.
class EngineSourceExistsIfLoaded extends PlaybackInvariant {
  @override
  String get name => 'engine_source_exists_if_loaded';

  @override
  Future<void> check(PlaybackSimulator sim) async {
    final src = sim.engine.currentSource;
    if (src == null) return;
    if (!File(src).existsSync()) {
      throw 'engine source $src points at a non-existent file';
    }
  }
}

/// "If the engine is playing, the audioService believes a
/// playback context exists." Catches the case where the engine
/// is running but the queue / generation reference were
/// cleared (split-brain between layers).
class EngineMatchesAudioServiceState extends PlaybackInvariant {
  @override
  String get name => 'engine_matches_audio_service_state';

  @override
  Future<void> check(PlaybackSimulator sim) async {
    if (!sim.engine.isPlaying) return;
    if (sim.audio.queue.currentIntelUid == null) {
      throw 'engine is playing but audio service has no '
          'currentIntelUid — playback layers drifted apart';
    }
    if (sim.audio.currentGenerationId == null) {
      throw 'engine is playing but audio service has no '
          'currentGenerationId — generation attribution lost';
    }
  }
}

/// "When sync-block is on, the engine must not be playing."
/// Q1 contract: sync is a playback-exclusive maintenance
/// window. This is the runtime guarantee — checked via the
/// engine, not just the service's intent flag.
class NoEngineSourceWhileBlocked extends PlaybackInvariant {
  @override
  String get name => 'no_engine_playback_while_blocked';

  @override
  Future<void> check(PlaybackSimulator sim) async {
    if (sim.audio.blockedBySync && sim.engine.isPlaying) {
      throw 'engine is playing while audio.blockedBySync=true — '
          'Q1 contract violated';
    }
  }
}

/// "When the engine's source matches the active-inventory
/// resolution of the current queue intel_uid, the audio
/// service's currentGenerationId equals the active generation."
///
/// In other words: if a NEW play / resume / next happened
/// recently against the current active inventory, the service's
/// generation attribution must point at that active generation.
/// The historical exception (currently-playing track survives
/// retirement) is allowed — its source may still match a
/// retired generation's path. This invariant only fires when
/// the engine's source IS in the active inventory + the
/// service's generation_id disagrees.
class CurrentGenerationMatchesActiveInventory
    extends PlaybackInvariant {
  @override
  String get name => 'current_generation_matches_active_when_resolved';

  @override
  Future<void> check(PlaybackSimulator sim) async {
    final intelUid = sim.audio.queue.currentIntelUid;
    if (intelUid == null) return;
    final active = await sim.inventory.findInActive(intelUid);
    if (active == null) return; // retired — historical case, fine
    if (sim.engine.currentSource != active.audioPath) return;
    // Engine source matches active resolution — the service's
    // generation attribution must agree.
    if (sim.audio.currentGenerationId != active.generationId) {
      throw 'engine source matches active resolution but '
          'audio.currentGenerationId=${sim.audio.currentGenerationId} '
          'disagrees with active generation '
          '${active.generationId}';
    }
  }
}

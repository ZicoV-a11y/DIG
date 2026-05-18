import 'package:flutter/foundation.dart';

import 'inventory_service.dart';
import 'operational_log.dart';
import 'playback_engine.dart';
import 'playback_models.dart';

void _log(String msg) => OperationalLog.emit('playback', msg);

String _short(String id) => id.length <= 8 ? id : id.substring(0, 8);

/// **Inventory consumer**, never inventory authority.
///
/// PR2.8.C contract — the four rules that make this slice
/// matter:
///
///   1. The audio service NEVER scans the filesystem,
///      discovers tracks, mutates inventory, or infers the
///      active generation. All resolution flows through
///      [InventoryService.findInActive].
///   2. The queue stores **intel_uid** strings — never file
///      paths. File paths belong to generation state.
///   3. Resolution is **late-bound** — `intel_uid → CachedTrack
///      → audio_path` happens just before [PlaybackEngine.setSource],
///      not at queue-build time.
///   4. Once playback starts, the **currently-playing track
///      survives generation retirement**. The user keeps
///      listening until they stop or the track ends; only then
///      does the next track re-resolve against the new active
///      generation.
///
/// Sync blocking (Q1 contract) gates new playback at the
/// inventory level, not at the engine level. Setting
/// [blockedBySync] = true pauses any current playback and
/// refuses new plays.
class AudioService {
  AudioService({
    required this.inventory,
    required this.engine,
  });

  final InventoryService inventory;
  final PlaybackEngine engine;

  /// Current queue snapshot. UI binds via [queueListenable].
  PlaybackQueue _queue = PlaybackQueue.empty;
  final ValueNotifier<PlaybackQueue> _queueNotifier =
      ValueNotifier<PlaybackQueue>(PlaybackQueue.empty);
  ValueListenable<PlaybackQueue> get queueListenable => _queueNotifier;
  PlaybackQueue get queue => _queue;

  /// Generation_id the currently-playing track was resolved
  /// in. Captured at setSource time; lets the snapshot record
  /// "this playback originated in generation X" so a relaunch
  /// can detect retirement.
  String? _currentGenerationId;
  String? get currentGenerationId => _currentGenerationId;

  /// The audio_path AudioService last handed to the engine.
  /// Kept here (not queried from the engine) so the service
  /// owns its own truth — the engine stays a pure executor.
  /// Used by [resume] to skip a redundant setSource when the
  /// active inventory hasn't rotated since the pause.
  String? _currentAudioPath;
  String? get currentAudioPath => _currentAudioPath;

  /// Sync-block gate. When `true`, [playIntelUid] /
  /// [playQueue] / [resume] refuse, and any current playback
  /// pauses. The host (companion app's controller layer)
  /// flips this in response to SyncSession state changes.
  bool _blockedBySync = false;
  bool get blockedBySync => _blockedBySync;
  Future<void> setBlockedBySync(bool blocked) async {
    if (_blockedBySync == blocked) return;
    _blockedBySync = blocked;
    _log('sync-block ${blocked ? "engaged" : "released"}');
    if (blocked && engine.isPlaying) {
      // Q1 contract: sync is a playback-exclusive maintenance
      // window. Pause whatever's playing.
      await engine.pause();
    }
  }

  // ─── Playback control ───────────────────────────────────────────

  /// Start playback at [intelUid]. Builds a single-track
  /// queue if none exists, or repositions the current queue's
  /// cursor if the intel_uid is already in it.
  Future<bool> playIntelUid(String intelUid) async {
    if (_blockedBySync) {
      _log('playIntelUid refused (sync-blocked) intel=${_short(intelUid)}');
      return false;
    }
    final existingIdx = _queue.intelUids.indexOf(intelUid);
    _log('playIntelUid intel=${_short(intelUid)} '
        '${existingIdx >= 0 ? "reposition@$existingIdx" : "new-queue"}');
    final next = existingIdx >= 0
        ? _queue.withCurrentIndex(existingIdx)
        : PlaybackQueue(intelUids: [intelUid], currentIndex: 0);
    return _enterQueueState(next);
  }

  /// Replace the queue + start playback at [startIndex].
  Future<bool> playQueue({
    required List<String> intelUids,
    int startIndex = 0,
  }) async {
    if (_blockedBySync) {
      _log('playQueue refused (sync-blocked) size=${intelUids.length}');
      return false;
    }
    if (intelUids.isEmpty) {
      _log('playQueue refused (empty)');
      return false;
    }
    final clamped = startIndex.clamp(0, intelUids.length - 1);
    _log('playQueue size=${intelUids.length} start=$clamped');
    final next = PlaybackQueue(
      intelUids: List.unmodifiable(intelUids),
      currentIndex: clamped,
    );
    return _enterQueueState(next);
  }

  Future<void> pause() async {
    _log('pause');
    await engine.pause();
  }

  /// Resume playback of the current track.
  ///
  /// **Late-binds against the CURRENT active inventory** —
  /// paused playback is operationally different from active
  /// playback (the retirement-survival rule applies only to
  /// the latter). If the inventory rotated while paused,
  /// resume re-binds the engine to whatever the active
  /// generation now resolves intel_uid to, preserving the
  /// pre-pause position.
  ///
  /// Returns `false` when sync-blocked, queue empty, or the
  /// current intel_uid is no longer in active inventory
  /// (track rotated out + gone from every generation the
  /// user holds).
  Future<bool> resume() async {
    if (_blockedBySync) {
      _log('resume refused (sync-blocked)');
      return false;
    }
    final intelUid = _queue.currentIntelUid;
    if (intelUid == null) {
      _log('resume refused (empty queue)');
      return false;
    }
    final resolved = await inventory.findInActive(intelUid);
    if (resolved == null) {
      _log('resume refused (intel=${_short(intelUid)} not in active inventory)');
      return false;
    }
    if (resolved.generationId == _currentGenerationId &&
        resolved.audioPath == _currentAudioPath) {
      // Same generation, same source — just play.
      _log('resume intel=${_short(intelUid)} '
          'gen=${_short(resolved.generationId)} same-source');
      await engine.play();
      return true;
    }
    // Generation rotated while paused. Re-bind + preserve
    // position (engine.setSource resets to 0).
    final position = engine.currentPosition;
    _log('resume intel=${_short(intelUid)} '
        'rebind gen=${_short(_currentGenerationId ?? "?")}→${_short(resolved.generationId)} '
        'preserve=${position.inMilliseconds}ms');
    _currentGenerationId = resolved.generationId;
    _currentAudioPath = resolved.audioPath;
    await engine.setSource(resolved.audioPath);
    if (position > Duration.zero) {
      await engine.seek(position);
    }
    await engine.play();
    return true;
  }

  /// Stop playback + clear the engine source. Queue and
  /// snapshot are preserved so the UI can show "stopped at
  /// track X, position Y."
  Future<void> stop() async {
    _log('stop');
    await engine.stop();
  }

  /// Advance to the next intel_uid in the queue + start
  /// playback. Re-resolves against the CURRENT active
  /// generation (the new track might point at a different
  /// generation's file than the previous one).
  Future<bool> next() async {
    if (_blockedBySync) {
      _log('next refused (sync-blocked)');
      return false;
    }
    if (!_queue.hasNext) {
      _log('next refused (end of queue idx=${_queue.currentIndex})');
      return false;
    }
    final cur = _queue.currentIndex!;
    _log('next idx=$cur→${cur + 1}');
    return _enterQueueState(_queue.advanceNext());
  }

  Future<bool> previous() async {
    if (_blockedBySync) {
      _log('previous refused (sync-blocked)');
      return false;
    }
    if (!_queue.hasPrevious) {
      _log('previous refused (start of queue idx=${_queue.currentIndex})');
      return false;
    }
    final cur = _queue.currentIndex!;
    _log('previous idx=$cur→${cur - 1}');
    return _enterQueueState(_queue.advancePrevious());
  }

  /// Heart of the late-binding contract — resolves the
  /// current intel_uid against [InventoryService.findInActive]
  /// and hands the resulting file path to the engine.
  ///
  /// Returns `false` when the intel_uid isn't in the active
  /// generation; the engine stays at whatever it was on.
  /// (Existing playback of a now-retired track keeps running
  /// because we never called [PlaybackEngine.setSource] for the
  /// missing entry.)
  Future<bool> _enterQueueState(PlaybackQueue next) async {
    final intelUid = next.currentIntelUid;
    if (intelUid == null) {
      _log('enter-queue empty-cursor size=${next.intelUids.length}');
      _queue = next;
      _queueNotifier.value = next;
      return false;
    }
    final resolved = await inventory.findInActive(intelUid);
    if (resolved == null) {
      // Late-binding failure: intel_uid isn't in the active
      // generation. Don't disturb whatever's currently
      // playing. The user keeps listening; the queue is
      // updated but engine source unchanged.
      _log('enter-queue resolve-miss intel=${_short(intelUid)} '
          '— engine undisturbed');
      _queue = next;
      _queueNotifier.value = next;
      return false;
    }
    _log('enter-queue intel=${_short(intelUid)} '
        'gen=${_short(resolved.generationId)} → setSource+play');
    _currentGenerationId = resolved.generationId;
    _currentAudioPath = resolved.audioPath;
    _queue = next;
    _queueNotifier.value = next;
    await engine.setSource(resolved.audioPath);
    await engine.play();
    return true;
  }

  // ─── Snapshot ───────────────────────────────────────────────────

  /// Build a serializable snapshot of current playback state.
  /// Persisted by the host on app-suspend; restored on launch.
  PlaybackSnapshot snapshot() {
    return PlaybackSnapshot(
      queueIntelUids: _queue.intelUids,
      currentIndex: _queue.currentIndex,
      currentIntelUid: _queue.currentIntelUid,
      currentGenerationId: _currentGenerationId,
      currentPosition: engine.currentPosition,
      wasPlaying: engine.isPlaying,
    );
  }

  /// Restore from a [snapshot]. Late-binds via the inventory
  /// so a track retired since the snapshot was taken won't
  /// resume — the host's UI can surface the change.
  ///
  /// Returns `true` when the snapshot's current_intel_uid
  /// resolved against the active inventory + playback was
  /// restored; `false` when the track is gone (e.g., rotated
  /// out during the suspension).
  Future<bool> restoreFromSnapshot(PlaybackSnapshot snap) async {
    final intelUid = snap.currentIntelUid;
    if (intelUid == null || snap.currentIndex == null) {
      _log('restore empty-snapshot — queue cleared');
      _queue = PlaybackQueue.empty;
      _queueNotifier.value = _queue;
      return false;
    }
    final restored = PlaybackQueue(
      intelUids: List.unmodifiable(snap.queueIntelUids),
      currentIndex: snap.currentIndex,
    );
    final resolved = await inventory.findInActive(intelUid);
    if (resolved == null) {
      // Snapshot's current track was retired. Surface the
      // queue but don't auto-play a substitute — the user
      // explicitly stopped on this track, they may want to
      // see the change.
      _log('restore intel=${_short(intelUid)} retired — queue surfaced, no playback');
      _queue = restored;
      _queueNotifier.value = restored;
      _currentGenerationId = null;
      _currentAudioPath = null;
      return false;
    }
    _log('restore intel=${_short(intelUid)} '
        'gen=${_short(resolved.generationId)} '
        'pos=${snap.currentPosition.inMilliseconds}ms '
        'wasPlaying=${snap.wasPlaying}');
    _currentGenerationId = resolved.generationId;
    _currentAudioPath = resolved.audioPath;
    _queue = restored;
    _queueNotifier.value = restored;
    await engine.setSource(resolved.audioPath);
    if (snap.currentPosition > Duration.zero) {
      await engine.seek(snap.currentPosition);
    }
    if (snap.wasPlaying && !_blockedBySync) {
      await engine.play();
    }
    return true;
  }

  Future<void> dispose() async {
    _queueNotifier.dispose();
    await engine.dispose();
  }
}

/// Immutable playback queue. Holds **intel_uids only** — never
/// file paths.
///
/// File paths belong to the inventory layer (generation state).
/// Storing them in the queue would couple playback identity to
/// transport bytes, which breaks across generation swaps. With
/// intel_uid-keyed queues, a generation rotation that
/// preserves `intel-a` keeps the queue intact even if the
/// underlying file path changed.
///
/// All mutations return new instances. The AudioService swaps
/// references via its ValueNotifier; nothing mutates in-place.
class PlaybackQueue {
  /// Ordered list of intel_uids. Empty queue = no playback context.
  final List<String> intelUids;

  /// Index into [intelUids] that's currently playing / paused.
  /// `null` when the queue is empty or stopped without a
  /// current pointer.
  final int? currentIndex;

  const PlaybackQueue({
    required this.intelUids,
    this.currentIndex,
  });

  static const empty = PlaybackQueue(intelUids: []);

  bool get isEmpty => intelUids.isEmpty;
  bool get isNotEmpty => intelUids.isNotEmpty;

  String? get currentIntelUid {
    final idx = currentIndex;
    if (idx == null || idx < 0 || idx >= intelUids.length) return null;
    return intelUids[idx];
  }

  bool get hasNext =>
      currentIndex != null && currentIndex! < intelUids.length - 1;
  bool get hasPrevious => currentIndex != null && currentIndex! > 0;

  PlaybackQueue withCurrentIndex(int? index) =>
      PlaybackQueue(intelUids: intelUids, currentIndex: index);

  PlaybackQueue advanceNext() {
    if (!hasNext) return this;
    return withCurrentIndex(currentIndex! + 1);
  }

  PlaybackQueue advancePrevious() {
    if (!hasPrevious) return this;
    return withCurrentIndex(currentIndex! - 1);
  }

  @override
  bool operator ==(Object other) {
    if (other is! PlaybackQueue) return false;
    if (other.currentIndex != currentIndex) return false;
    if (other.intelUids.length != intelUids.length) return false;
    for (var i = 0; i < intelUids.length; i++) {
      if (other.intelUids[i] != intelUids[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(currentIndex, Object.hashAll(intelUids));
}

/// Persistable snapshot of playback state. Used for relaunch
/// restore, CarPlay reconnect, interruption recovery.
///
/// Carries **intel_uid + position + the generation_id the
/// resolution happened in** so the consumer can detect
/// "playing track was retired since this snapshot was taken"
/// on restore.
class PlaybackSnapshot {
  final List<String> queueIntelUids;
  final int? currentIndex;
  final String? currentIntelUid;
  final String? currentGenerationId;
  final Duration currentPosition;
  final bool wasPlaying;

  const PlaybackSnapshot({
    required this.queueIntelUids,
    required this.currentIndex,
    required this.currentIntelUid,
    required this.currentGenerationId,
    required this.currentPosition,
    required this.wasPlaying,
  });

  static const empty = PlaybackSnapshot(
    queueIntelUids: [],
    currentIndex: null,
    currentIntelUid: null,
    currentGenerationId: null,
    currentPosition: Duration.zero,
    wasPlaying: false,
  );

  Map<String, Object?> toJson() => {
        'queue_intel_uids': queueIntelUids,
        'current_index': currentIndex,
        'current_intel_uid': currentIntelUid,
        'current_generation_id': currentGenerationId,
        'current_position_ms': currentPosition.inMilliseconds,
        'was_playing': wasPlaying,
      };

  static PlaybackSnapshot fromJson(Map<String, Object?> j) {
    final queue = j['queue_intel_uids'];
    return PlaybackSnapshot(
      queueIntelUids:
          queue is List ? [for (final s in queue) s as String] : const [],
      currentIndex: j['current_index'] as int?,
      currentIntelUid: j['current_intel_uid'] as String?,
      currentGenerationId: j['current_generation_id'] as String?,
      currentPosition: Duration(
        milliseconds: (j['current_position_ms'] as int?) ?? 0,
      ),
      wasPlaying: (j['was_playing'] as bool?) ?? false,
    );
  }
}

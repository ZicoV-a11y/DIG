/// Wire shape for the "Rotation Summary" modal the desktop shows
/// (and the iPhone optionally mirrors) AFTER a successful sync.
///
/// The mockup's macOS variant lists:
///   `Added to Device  +50  4.97 GB   [Tycho — Awake, ...]`
///   `Removed from Device  -48  4.83 GB   [Massive Attack, ...]`
///   `Device After Sync  100 songs  4.97 GB`
///   `Last Sync  Today 9:41 AM   Total Play Count  123`
///
/// Kept separate from [ManifestDiff] because diff is pre-sync
/// (what will change) and summary is post-sync (what did change +
/// the resulting steady state). They're related but not the same
/// shape — summary carries display titles for the added/removed
/// tracks so the modal can render them without re-fetching.
class RotationSummary {
  final List<RotationTrackEntry> added;
  final List<RotationTrackEntry> removed;

  final int afterSyncTrackCount;
  final int afterSyncBytes;

  /// Wall-clock ms of the sync completion.
  final int completedAt;

  /// Aggregate `play_count` across the surviving inventory.
  /// Surfaces in the modal as "Total Play Count 123" so the user
  /// sees cumulative listening at a glance.
  final int aggregatePlayCount;

  const RotationSummary({
    required this.added,
    required this.removed,
    required this.afterSyncTrackCount,
    required this.afterSyncBytes,
    required this.completedAt,
    required this.aggregatePlayCount,
  });

  int get addedBytes =>
      added.fold(0, (sum, t) => sum + t.byteSize);
  int get removedBytes =>
      removed.fold(0, (sum, t) => sum + t.byteSize);

  Map<String, Object?> toJson() => {
        'added': [for (final t in added) t.toJson()],
        'removed': [for (final t in removed) t.toJson()],
        'after_sync_track_count': afterSyncTrackCount,
        'after_sync_bytes': afterSyncBytes,
        'completed_at': completedAt,
        'aggregate_play_count': aggregatePlayCount,
      };

  static RotationSummary fromJson(Map<String, Object?> j) {
    final add = j['added'];
    final rem = j['removed'];
    if (add is! List) {
      throw const FormatException('RotationSummary.added required (list)');
    }
    if (rem is! List) {
      throw const FormatException('RotationSummary.removed required (list)');
    }
    return RotationSummary(
      added: [
        for (final t in add)
          RotationTrackEntry.fromJson(t as Map<String, Object?>),
      ],
      removed: [
        for (final t in rem)
          RotationTrackEntry.fromJson(t as Map<String, Object?>),
      ],
      afterSyncTrackCount: _asInt(j['after_sync_track_count']) ?? 0,
      afterSyncBytes: _asInt(j['after_sync_bytes']) ?? 0,
      completedAt: _asInt(j['completed_at']) ?? 0,
      aggregatePlayCount: _asInt(j['aggregate_play_count']) ?? 0,
    );
  }
}

/// One row in [RotationSummary.added] / [RotationSummary.removed].
/// Carries display title/artist + byte size — enough for the modal
/// to render a compact list without a separate metadata fetch.
class RotationTrackEntry {
  final String intelUid;
  final String title;
  final String artist;
  final int byteSize;

  const RotationTrackEntry({
    required this.intelUid,
    required this.title,
    required this.artist,
    required this.byteSize,
  });

  Map<String, Object?> toJson() => {
        'intel_uid': intelUid,
        'title': title,
        'artist': artist,
        'byte_size': byteSize,
      };

  static RotationTrackEntry fromJson(Map<String, Object?> j) {
    final intel = j['intel_uid'];
    if (intel is! String) {
      throw const FormatException('RotationTrackEntry.intel_uid required');
    }
    return RotationTrackEntry(
      intelUid: intel,
      title: (j['title'] as String?) ?? '',
      artist: (j['artist'] as String?) ?? '',
      byteSize: _asInt(j['byte_size']) ?? 0,
    );
  }
}

int? _asInt(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

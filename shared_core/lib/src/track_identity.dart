/// Stable identity triple for a synced track. Every payload (manifest
/// entry, telemetry event, eviction record) keys off this so the
/// phone-side state reconnects cleanly to desktop intelligence rows
/// no matter how the underlying files have moved or been renamed.
///
/// Three identifiers, three jobs:
/// - [intelUid]: primary reconciliation key. Points at the canonical
///   `tracks` row on desktop. Survives rename, move, variant
///   promotion. Telemetry routes through this. Favorite/playCount
///   cascade across variants.
/// - [variantId]: which specific file (the desktop's `Track.uid`)
///   was actually shipped to the phone. Lets the desktop narrate
///   "Zico played the MP3 variant" and the phone distinguish replays
///   of the same song-identity across different shipped variants.
/// - [contentHash]: byte-identity verification on download. SHA256
///   of first+last 256KB. Survives rename / Cmd+D / folder move.
///   Used to detect corruption / wrong-file-shipped and to short-
///   circuit re-downloads of unchanged content across desktop
///   reorganizations.
///
/// Never put `path` or `filename` on this object — those aren't
/// identity, they're display.
class TrackIdentity {
  final String intelUid;
  final String variantId;
  final String contentHash;

  const TrackIdentity({
    required this.intelUid,
    required this.variantId,
    required this.contentHash,
  });

  Map<String, Object?> toJson() => {
        'intel_uid': intelUid,
        'variant_id': variantId,
        'content_hash': contentHash,
      };

  static TrackIdentity fromJson(Map<String, Object?> j) {
    final intel = j['intel_uid'];
    final variant = j['variant_id'];
    final hash = j['content_hash'];
    if (intel is! String || intel.isEmpty) {
      throw const FormatException('TrackIdentity.intel_uid required');
    }
    if (variant is! String || variant.isEmpty) {
      throw const FormatException('TrackIdentity.variant_id required');
    }
    if (hash is! String || hash.isEmpty) {
      throw const FormatException('TrackIdentity.content_hash required');
    }
    return TrackIdentity(
      intelUid: intel,
      variantId: variant,
      contentHash: hash,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TrackIdentity &&
      other.intelUid == intelUid &&
      other.variantId == variantId &&
      other.contentHash == contentHash;

  @override
  int get hashCode => Object.hash(intelUid, variantId, contentHash);

  @override
  String toString() =>
      'TrackIdentity(intel: $intelUid, variant: $variantId, '
      'hash: ${contentHash.substring(0, contentHash.length.clamp(0, 8))}…)';
}

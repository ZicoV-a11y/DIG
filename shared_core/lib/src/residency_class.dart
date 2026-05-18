/// Governs whether a track in a phone's `mobile_sync_inventory`
/// rotates out automatically or sticks until the user removes it.
///
/// See the architecture plan (section "Track residency classes")
/// for the full eviction priority table and pin lifecycle rules.
enum ResidencyClass {
  /// Manually pinned by the user via right-click "Pin on iPhone".
  /// Never auto-rotates. Survives review. Manual unpin only.
  pinned,

  /// Auto-fill from the unreviewed-random recipe. Eligible for
  /// eviction once the phone reports threshold-crossed / completed.
  rotating,

  /// Sent via right-click "Send to iPhone". Stays until reviewed,
  /// then becomes eligible for eviction.
  manual,

  /// Auto-included because the track is favorite=true on desktop.
  /// Auto-removed if user unfavorites. Review state irrelevant.
  favoriteCache,

  /// Auto-fill portion of a hybrid recipe (pinned + random fill).
  /// Same eviction rules as `rotating`.
  hybridFill;

  String get wireName {
    switch (this) {
      case ResidencyClass.pinned:
        return 'pinned';
      case ResidencyClass.rotating:
        return 'rotating';
      case ResidencyClass.manual:
        return 'manual';
      case ResidencyClass.favoriteCache:
        return 'favorite_cache';
      case ResidencyClass.hybridFill:
        return 'hybrid_fill';
    }
  }

  /// Inverse of [wireName]. Unknown values throw — the wire format
  /// is the contract, and a typo in either app should fail loudly
  /// in tests rather than silently degrade to a default class.
  static ResidencyClass fromWire(String s) {
    switch (s) {
      case 'pinned':
        return ResidencyClass.pinned;
      case 'rotating':
        return ResidencyClass.rotating;
      case 'manual':
        return ResidencyClass.manual;
      case 'favorite_cache':
        return ResidencyClass.favoriteCache;
      case 'hybrid_fill':
        return ResidencyClass.hybridFill;
      default:
        throw FormatException('Unknown ResidencyClass wire value: $s');
    }
  }
}

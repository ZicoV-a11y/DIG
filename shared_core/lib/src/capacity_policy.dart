/// The two ways a phone caps its inventory.
enum CapacityMode {
  /// Cap by song count, e.g., "100 tracks." Predictable for review-
  /// flow planning.
  songCount,

  /// Cap by storage bytes, e.g., "5 GB." Predictable for storage
  /// management; song count varies with track length.
  storageBudget;

  String get wireName => switch (this) {
        CapacityMode.songCount => 'song_count',
        CapacityMode.storageBudget => 'storage_budget',
      };

  static CapacityMode fromWire(String s) => switch (s) {
        'song_count' => CapacityMode.songCount,
        'storage_budget' => CapacityMode.storageBudget,
        _ => throw FormatException('Unknown CapacityMode: $s'),
      };
}

/// A per-device capacity target. `value` is interpreted via [mode]:
/// song-count → number of tracks; storage-budget → bytes.
class CapacityPolicy {
  final CapacityMode mode;
  final int value;

  const CapacityPolicy({required this.mode, required this.value});

  /// Convenience: count-mode capacity, e.g., `CapacityPolicy.songs(100)`.
  const CapacityPolicy.songs(int count)
      : mode = CapacityMode.songCount,
        value = count;

  /// Convenience: bytes-mode capacity, e.g.,
  /// `CapacityPolicy.bytes(5 * 1024 * 1024 * 1024)`.
  const CapacityPolicy.bytes(int bytes)
      : mode = CapacityMode.storageBudget,
        value = bytes;

  Map<String, Object?> toJson() => {
        'mode': mode.wireName,
        'value': value,
      };

  static CapacityPolicy fromJson(Map<String, Object?> j) {
    final mode = j['mode'];
    final value = j['value'];
    if (mode is! String) {
      throw const FormatException('CapacityPolicy.mode missing or not String');
    }
    if (value is! int) {
      throw const FormatException('CapacityPolicy.value missing or not int');
    }
    return CapacityPolicy(mode: CapacityMode.fromWire(mode), value: value);
  }

  @override
  bool operator ==(Object other) =>
      other is CapacityPolicy && other.mode == mode && other.value == value;

  @override
  int get hashCode => Object.hash(mode, value);
}

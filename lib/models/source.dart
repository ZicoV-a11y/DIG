/// How a watched source enumerates its folder contents during scan.
///
/// `recursive` walks all subdirectories (matches the legacy behaviour).
/// `topLevelOnly` indexes files only at the top level — useful for
/// review/promo folders where the user explicitly does not want to
/// crawl deeper.
enum ScanMode { recursive, topLevelOnly }

extension ScanModeCodec on ScanMode {
  String get wire => name; // 'recursive' / 'topLevelOnly'
  static ScanMode fromWire(String s) {
    for (final m in ScanMode.values) {
      if (m.name == s) return m;
    }
    return ScanMode.recursive;
  }
}

/// A user-configured library source.
///
/// Two flavours, distinguished by [isSubView]:
///
/// - **Top-level scanning source** ([parentSourceId] is `null`): owns
///   `indexed_files` rows, scans disk, manages availability. The
///   classic "watched folder".
/// - **Sub-view** ([parentSourceId] and [pathPrefix] are both set):
///   purely virtual — references a parent scanning source and filters
///   its tracks by exact path-prefix. Sub-views never scan, never own
///   `indexed_files`, never write to `tracks`. They are filtered
///   lenses over the parent's data.
///
/// The folder path may change between sessions (drive remount, folder
/// move on disk); the source identity is the UUID, not the path.
class Source {
  final String id;
  final String displayName;
  final String folderPath;
  final ScanMode scanMode;
  final bool enabled;
  final int? lastScanAt;
  final int trackCount;
  final int createdAt;
  // Sub-view fields. Both null for top-level sources; both set for
  // sub-views. Mixing is invalid.
  final String? parentSourceId;
  final String? pathPrefix;

  const Source({
    required this.id,
    required this.displayName,
    required this.folderPath,
    required this.scanMode,
    this.enabled = true,
    this.lastScanAt,
    this.trackCount = 0,
    required this.createdAt,
    this.parentSourceId,
    this.pathPrefix,
  });

  bool get isSubView => parentSourceId != null && pathPrefix != null;

  Source copyWith({
    String? displayName,
    String? folderPath,
    ScanMode? scanMode,
    bool? enabled,
    int? lastScanAt,
    int? trackCount,
  }) {
    return Source(
      id: id,
      displayName: displayName ?? this.displayName,
      folderPath: folderPath ?? this.folderPath,
      scanMode: scanMode ?? this.scanMode,
      enabled: enabled ?? this.enabled,
      lastScanAt: lastScanAt ?? this.lastScanAt,
      trackCount: trackCount ?? this.trackCount,
      createdAt: createdAt,
      parentSourceId: parentSourceId,
      pathPrefix: pathPrefix,
    );
  }
}

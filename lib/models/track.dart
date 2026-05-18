import '../services/filename_parser.dart';
import '../utils/key_normalizer.dart';

/// Persistent operational state for the metadata-enrichment
/// pipeline. Stored in `indexed_files.enrichment_state` (v14).
///
/// Lifecycle:
///   `discovered` → `enriching` → `ready`  (happy path)
///   `discovered` → `enriching` → `failed` (read error, missing tags)
///   `ready`      → `discovered`           (stat change wipes the
///                                          cached enrichment; the
///                                          upsert path re-flags the
///                                          row for a fresh pass)
///
/// Transient render-time states (`waitingCloud`, "interactive",
/// "deferred") are layered on top by the UI; they do NOT live in
/// this enum. Keeping the persistent vocabulary tight makes the
/// row-state ontology easier to reason about.
///
/// Crash recovery: rows stuck in `enriching` after an unexpected
/// exit are swept back to `discovered` on the next app boot so
/// the regular enrichment pipeline picks them up cleanly.
enum EnrichmentState {
  /// Row exists in the index but its ID3 / Vorbis tags have not
  /// been read. Title / artist / duration come from filename
  /// heuristics. Default state for new rows + for stat-changed
  /// rows whose previously-cached metadata is now stale.
  discovered,

  /// The metadata-enrichment pipeline has picked this path up
  /// and is currently reading its tags (in-isolate compute).
  enriching,

  /// Tags + duration + artwork read successfully. The row is
  /// fully populated and renders at normal opacity.
  ready,

  /// The enrichment pipeline tried this path and the read failed
  /// (file gone, permission denied, corrupt tag block). Surfaces
  /// as a warning treatment in the UI; the controller's in-memory
  /// `_failedEnrichmentPaths` set prevents retry within a session.
  failed;

  /// String form used for the DB column. Single source of truth so
  /// renames here propagate to schema + migrations cleanly.
  String get wireName => name;

  /// Parse the DB-column string back into the enum. Unknown values
  /// fall back to `discovered` so a forward-compat row (written by
  /// a newer build, opened in an older one) doesn't blow up — it
  /// just falls back to the "we haven't seen this yet" state.
  static EnrichmentState fromWire(String? s) {
    switch (s) {
      case 'discovered':
        return EnrichmentState.discovered;
      case 'enriching':
        return EnrichmentState.enriching;
      case 'ready':
        return EnrichmentState.ready;
      case 'failed':
        return EnrichmentState.failed;
      default:
        return EnrichmentState.discovered;
    }
  }
}

/// A unified view over `indexed_files` (location + metadata) and
/// `tracks` (intelligence). The split is a database concern; consumers
/// (controller, widgets) treat a Track as one object.
///
/// Two identifiers matter:
/// - [uid]: this file revision's content hash (basename + filesize +
///   duration + mtime). Used as the `tracks.uid` PK once intelligence
///   is materialised. Stable across path moves but changes if the file
///   is re-tagged (mtime changes).
/// - [intelUid]: which `tracks` row this file is linked to. Most often
///   equal to [uid], but for duplicates it points at a sibling whose
///   uid was promoted first. `null` until the first meaningful
///   interaction.
///
/// [path] is filesystem location, never identity. Hand it to the audio
/// engine; never use it for equality.
class Track {
  // From indexed_files (file identity + location):
  final String uid;

  /// **Heuristic** similarity hash — sha256 of basename + filesize
  /// + duration. Stable across path moves IFF the basename is
  /// unchanged. Breaks on rename / Cmd+D's `… copy.mp3` suffix /
  /// extension change. Originally named "fingerprint" because it
  /// was the only identity primitive; kept under the old name for
  /// migration continuity even though [contentHash] is the
  /// authoritative byte-identity now (Slice 5 swaps relocation
  /// matching over). For cross-format song identity, use
  /// `sameSongIdentity` / `groupBySongIdentity` in
  /// `lib/utils/song_identity.dart`. See
  /// `project_track_identity_vs_file_variants.md` and
  /// `project_content_hash_separation.md` in project memory.
  final String fingerprint;

  /// True physical-file identity — sha256 of the first 256KB plus
  /// the last 256KB of audio bytes. Survives rename, folder move,
  /// Cmd+D copy. Distinguishes re-encodes / transcodes / different
  /// masters. Populated lazily: scan-time write path fills it for
  /// new + changed files, the background backfill worker walks
  /// the rest. May be `null` on legacy rows that haven't been
  /// re-scanned and haven't been visited by the worker yet.
  ///
  /// Not consumed by any state-mutation path in Slice 2/3 — only
  /// in Slice 5 does cross-source relocation matching switch over.
  final String? contentHash;

  String? intelUid;

  /// User-set manual override for song identity. When non-null,
  /// `songIdentityKey` short-circuits and returns this value instead
  /// of the computed 4-field key. Lets two files the strict matcher
  /// missed (e.g., renamed-between-encodes or tag drift) be paired
  /// manually via the right-click "Link with another song" action.
  String? identityOverride;

  final String path;
  final String filename;
  int filesize;
  int modifiedAt;

  final String sourceId;
  /// Legacy boolean kept for backward compatibility — derived from
  /// [availability]. Most call-sites check `isAvailable`; the
  /// state field carries the finer distinction.
  bool isAvailable;
  /// Finer-grained availability state. `'available'` files are on
  /// disk and play. `'missing'` files vanished from a scan with no
  /// known replacement. `'superseded'` files were auto-detected as
  /// moved — another row in the same source has the same
  /// fingerprint and is available, so the intel transfers and the
  /// old row is hidden from the main table but kept for the
  /// "Review missing files" UI.
  String availability;
  int lastSeenAt;

  // Displayable metadata (lightweight index — populated by extractor):
  String title;
  String artist;
  String album;
  String genre;
  String musicalKey;
  double? bpm;
  Duration duration;
  bool hasArtwork;
  DateTime? metadataReadAt;

  /// Formal lifecycle state of this file's metadata enrichment.
  /// Backs the operational ontology so the UI can render explicit
  /// state (dim for discovered, pulse for enriching, warning for
  /// failed) instead of inferring from `metadataReadAt`. Persisted
  /// in `indexed_files.enrichment_state` (schema v14).
  ///
  /// Transient states (`waitingCloud`, "interactive") are NOT
  /// stored here — those live on the controller and are layered
  /// over this base state at render time.
  EnrichmentState enrichmentState;

  // Intelligence fields (default values when no `tracks` row exists):
  bool favorite;
  int playCount;
  Duration cumulativeListened;
  DateTime? lastPlayedAt;

  /// Wall-clock moment review state was first asserted. Stamped by
  /// the threshold-crossing path atomically with `playCount` and
  /// `lastPlayedAt` (one trigger, three side effects). Null = not
  /// yet reviewed. Once stamped, stays stamped across replays — the
  /// timestamp records WHEN review happened, not the most recent
  /// listen.
  ///
  /// Schema column: `tracks.reviewed_at` (v15). The `reviewed`
  /// getter reads from this; older code that derived it from
  /// `cumulative_ms >= 3` is gone.
  DateTime? reviewedAt;

  /// Wall-clock moment `favorite` last changed. Powers LWW
  /// reconciliation for the iPhone-sync subsystem: when desktop
  /// and phone disagree, the side with the larger timestamp wins.
  ///
  /// Schema column: `tracks.favorite_toggled_at` (v15).
  DateTime? favoriteToggledAt;

  Track({
    required this.uid,
    required this.fingerprint,
    this.contentHash,
    this.intelUid,
    this.identityOverride,
    required this.path,
    required this.filename,
    required this.sourceId,
    this.filesize = 0,
    this.modifiedAt = 0,
    this.isAvailable = true,
    this.availability = 'available',
    this.lastSeenAt = 0,
    required this.title,
    this.artist = '',
    this.album = '',
    this.genre = '',
    this.musicalKey = '',
    this.bpm,
    this.duration = Duration.zero,
    this.hasArtwork = false,
    this.metadataReadAt,
    this.enrichmentState = EnrichmentState.discovered,
    this.favorite = false,
    this.playCount = 0,
    this.cumulativeListened = Duration.zero,
    this.lastPlayedAt,
    this.reviewedAt,
    this.favoriteToggledAt,
  });

  /// `true` once the user has meaningfully interacted with this track
  /// (a `tracks` row exists). Useful for diagnostics; the rest of the
  /// app treats default intelligence values as identical to "no row".
  bool get hasIntelligence => intelUid != null;

  bool get reviewed => reviewedAt != null;

  /// `true` when the metadata enrichment pipeline has successfully
  /// read this file's tags + duration. Reads from the formal
  /// [enrichmentState] enum (schema v14) rather than inferring from
  /// [metadataReadAt] — the enum carries explicit "failed" and
  /// "enriching" states the timestamp alone can't express.
  ///
  /// The row can still be played in any non-ready state — the
  /// audio engine doesn't need metadata — but the displayed
  /// title / artist / duration come from filename heuristics, and
  /// the UI should signal "we're still working on this one."
  bool get isReady => enrichmentState == EnrichmentState.ready;

  // ─── Display-layer metadata fallback ────────────────────────────
  //
  // When canonical [artist] is empty (ID3/Vorbis tags missing or not
  // yet extracted), parse the filename heuristically so the UI can
  // sort and render a meaningful artist/title pair immediately.
  //
  // Strict rules — see [parseDjFilename]:
  //   1. Embedded metadata always wins. If [artist] is non-empty,
  //      both display values come from canonical fields verbatim.
  //   2. Filename parsing is **only** for display + sorting. It is
  //      never persisted into `tracks`/`indexed_files`, never written
  //      back, never treated as authoritative. When metadata
  //      extraction later succeeds, these getters silently switch
  //      back to canonical values.
  //   3. If the filename can't be parsed, fall through to the raw
  //      basename / canonical title.
  //
  // Cached because `visibleTracks` sorts on these values per build.

  ParsedFilename? _parsedFilenameCache;
  String? _parsedFilenameCacheKey;
  ParsedFilename get _parsedFilename {
    if (_parsedFilenameCacheKey != filename) {
      _parsedFilenameCacheKey = filename;
      _parsedFilenameCache = parseDjFilename(filename);
    }
    return _parsedFilenameCache ?? ParsedFilename.empty;
  }

  /// Best-effort artist for UI display.
  /// Canonical [artist] when present; otherwise the filename-parsed
  /// artist; otherwise empty.
  String get displayArtist {
    if (artist.isNotEmpty) return artist;
    return _parsedFilename.artist ?? '';
  }

  /// Best-effort title for UI display.
  /// Canonical [title] when canonical [artist] is also present
  /// (= "we have real metadata"); otherwise the filename-parsed
  /// title; otherwise the canonical title (which may itself be the
  /// raw basename if no metadata was ever set).
  String get displayTitle {
    if (artist.isNotEmpty) return title;
    return _parsedFilename.title ?? title;
  }

  // Cached filename-key parse — same justification as
  // [_parsedFilename]: avoid running the regex per sort comparison
  // or per row build at 60fps.
  String? _parsedKeyCache;
  String? _parsedKeyCacheKey;
  String? get _parsedKey {
    if (_parsedKeyCacheKey != filename) {
      _parsedKeyCacheKey = filename;
      _parsedKeyCache = parseDjKey(filename);
    }
    return _parsedKeyCache;
  }

  /// Raw key as resolved from metadata or filename, before notation
  /// normalization. Priority:
  ///   1. canonical [musicalKey] (from ID3 / Vorbis tags)
  ///   2. trailing-bracket / trailing-token key in the filename
  ///   3. empty string
  ///
  /// Used for searching against the original tag (so a user typing
  /// "Dm" still finds a track tagged "Dm", even though the column
  /// renders "7A").
  String get rawKey {
    if (musicalKey.isNotEmpty) return musicalKey;
    return _parsedKey ?? '';
  }

  /// Canonical Camelot form ("1A".."12B") of [rawKey] for display
  /// and harmonic-wheel sorting. Empty string if the raw value is
  /// missing or in an unrecognised notation.
  ///
  /// Like [displayArtist] / [displayTitle], purely a read-side
  /// transform — never written to the DB, never overrides ID3.
  String get displayKey => normalizeKeyToCamelot(rawKey) ?? '';
}

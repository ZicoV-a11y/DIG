import '../models/track.dart';
import 'file_format.dart';
import 'key_normalizer.dart';
import 'song_identity.dart' show basenameForIdentity;

/// How a multi-variant song-identity bucket got paired. Drives the
/// duplicates audit's "trust" sectioning — the user expects to focus
/// on the questionable pairs, not the obviously-correct ones.
enum BucketMatchReason {
  /// Every variant agrees on every matching field (basename minus
  /// extension and minus macOS Cmd+D " copy" suffix, title, artist,
  /// duration in seconds) AND every variant shares the same file
  /// format. Truly same-file class: literal duplicates, macOS
  /// Cmd+D copies. Highest confidence — system trusted.
  exactMatch,

  /// Every variant agrees on the metadata fields but the bucket
  /// spans multiple file formats (e.g., MP3 + AIFF, MP3 + WAV).
  /// Almost certainly intentional alternates of the same song, but
  /// worth browsing because different containers could legitimately
  /// hold different masters with matching tags.
  crossFormat,

  /// Two or more variants share a non-empty `identityOverride` set
  /// by the right-click "Link with another song" action. User-vetted
  /// pairing that bypasses the auto-matcher. High confidence from
  /// the user's perspective (they did it on purpose) but worth
  /// surfacing in audit so they can review their own decisions.
  manualLink,

  /// Variants pair because their file-content fingerprint matches
  /// (byte-equivalent audio) BUT they disagree on at least one of
  /// the 4 matching fields (title, artist, duration, basename).
  /// The most questionable category: the file content is the same,
  /// the metadata isn't — usually tag drift, sometimes a sign two
  /// genuinely different songs collided on filename+size+duration.
  /// Surface these first for review.
  fingerprintWithTagDrift,
}

/// Pure value object that derives the display values for a single
/// collapsed row in the table when grouping by song identity is on.
///
/// Given a bucket of variants (1+) that all share the same song
/// identity, this exposes the cells the row should render. The rules
/// follow `project_track_identity_vs_file_variants.md` in project
/// memory:
///
///   - **playCount, cumulativeListened** → sum across variants
///   - **lastPlayedAt** → most-recent (max) across variants
///   - **favorite, reviewed-derived (from cumulativeListened)** → OR
///   - **BPM, key (display Camelot)** → agreement passes through;
///     one-present-one-blank passes the present value; disagreement
///     blanks. (Title / artist / duration / filename-base can't
///     disagree at the row level because they're matching criteria.)
///   - **FORMAT** → " · "-joined unique formats in stable preference
///     order, e.g. `MP3 · AIFF`.
///
/// Per-file fields (path, filesize, codec, modified date, waveform
/// cache) are *not* aggregated — they only make sense per variant
/// and surface when the user expands the row to inspect siblings.
class AggregatedTrackView {
  /// Variants in this bucket. Always non-empty. The first entry is
  /// the *primary* — the one shown when the row is collapsed and
  /// played by default for indirect playback. Order is set by
  /// `pickPrimary` (lowest-quality first for prep-speed reasons).
  final List<Track> variants;

  AggregatedTrackView(this.variants) : assert(variants.isNotEmpty);

  Track get primary => variants.first;

  bool get hasSiblings => variants.length > 1;

  int get variantCount => variants.length;

  /// Classify why this bucket's variants ended up paired. Mirrors
  /// the rule priority in `sameSongIdentity` but inspects each
  /// variant directly to detect when the auto-matcher's 4-field
  /// rule held cleanly vs when fingerprint-fallback / manual
  /// override had to step in.
  ///
  /// Priority (least to most questionable):
  ///   1. `exactMatch` — every variant agrees on every field AND
  ///      shares the same file format.
  ///   2. `crossFormat` — every variant agrees on every field but
  ///      the bucket spans multiple file formats.
  ///   3. `manualLink` — at least two variants share a non-empty
  ///      override (and the bucket isn't a metadata match without it).
  ///   4. `fingerprintWithTagDrift` — otherwise. Variants paired
  ///      because of fingerprint equivalence despite drifted tags.
  BucketMatchReason get matchReason {
    if (variants.length < 2) return BucketMatchReason.exactMatch;
    if (_allFieldsAgree) {
      // Metadata agrees. Single format → confident; multi-format →
      // worth a glance to confirm both encodes are the same source.
      final formats = <String>{
        for (final t in variants) fileFormatLabel(t.filename),
      };
      // Treat empty / unrecognised formats as a single bucket among
      // themselves so a single weird file doesn't bump the whole
      // bucket into crossFormat. The "do we span formats?" decision
      // only fires when there are 2+ known formats.
      formats.removeWhere((f) => f.isEmpty);
      if (formats.length <= 1) return BucketMatchReason.exactMatch;
      return BucketMatchReason.crossFormat;
    }
    // Not a metadata match. Check for a shared manual override.
    final overrideCounts = <String, int>{};
    for (final t in variants) {
      final ov = t.identityOverride;
      if (ov == null || ov.isEmpty) continue;
      overrideCounts[ov] = (overrideCounts[ov] ?? 0) + 1;
    }
    for (final n in overrideCounts.values) {
      if (n >= 2) return BucketMatchReason.manualLink;
    }
    return BucketMatchReason.fingerprintWithTagDrift;
  }

  bool get _allFieldsAgree {
    final first = variants.first;
    final firstBase = basenameForIdentity(first.filename);
    final firstDurSec = first.duration.inSeconds;
    for (final t in variants) {
      if (t.title != first.title) return false;
      if (t.artist != first.artist) return false;
      if (t.duration.inSeconds != firstDurSec) return false;
      if (basenameForIdentity(t.filename) != firstBase) return false;
    }
    return true;
  }

  /// Sum of plays across all variants. Until per-song stats land in
  /// slice 3, this is a display-only aggregation — the underlying
  /// `Track.playCount` values on each variant are unchanged.
  int get playCount {
    var sum = 0;
    for (final t in variants) {
      sum += t.playCount;
    }
    return sum;
  }

  Duration get cumulativeListened {
    var total = Duration.zero;
    for (final t in variants) {
      total += t.cumulativeListened;
    }
    return total;
  }

  /// Mirrors `Track.reviewed` (cumulativeListened ≥ 3s) but on the
  /// aggregate, so the bucket counts as reviewed if *any* variant
  /// crossed the threshold.
  bool get reviewed => cumulativeListened.inSeconds >= 3;

  bool get favorite {
    for (final t in variants) {
      if (t.favorite) return true;
    }
    return false;
  }

  DateTime? get lastPlayedAt {
    DateTime? best;
    for (final t in variants) {
      final at = t.lastPlayedAt;
      if (at == null) continue;
      if (best == null || at.isAfter(best)) best = at;
    }
    return best;
  }

  // ── Divergence + provenance ─────────────────────────────────
  //
  // Per project memory (variant divergence model, set 2026-05-11
  // in conversation):
  //
  //   - title and artist participate in a "share-aware" model:
  //     when variants disagree, the table cell renders a small
  //     divergence indicator + the click-reveal panel surfaces
  //     each variant's value. The cell itself shows the primary's
  //     value so the row stays scannable.
  //
  //   - every OTHER displayable field (album, genre, BPM, key,
  //     has_artwork) follows "last-change-wins": pick the value
  //     from the variant whose `metadataReadAt` is freshest. The
  //     bucket converges on whichever variant the user (or an
  //     external tag editor) most recently edited.
  //
  //   - behavioural state (favorite, plays, last_played) is
  //     already singular at the song-identity layer because the
  //     bucket shares `intel_uid` — no divergence possible.

  /// True when at least two variants disagree on `displayTitle`.
  /// Drives the small divergence marker rendered in the title
  /// cell + tells the right-click handler whether to offer
  /// "Show variant metadata."
  bool get titleDivergent {
    String? first;
    for (final t in variants) {
      final title = t.displayTitle;
      if (title.isEmpty) continue;
      first ??= title;
      if (title != first) return true;
    }
    return false;
  }

  /// True when at least two variants disagree on `displayArtist`.
  /// Same UX treatment as [titleDivergent] — marker + reveal.
  bool get artistDivergent {
    String? first;
    for (final t in variants) {
      final artist = t.displayArtist;
      if (artist.isEmpty) continue;
      first ??= artist;
      if (artist != first) return true;
    }
    return false;
  }

  /// Variant the bucket consults for last-change-wins fields
  /// (album / genre / BPM / key / has_artwork). Picks the variant
  /// with the freshest `metadataReadAt`. Falls back to [primary]
  /// when no variant has been enriched yet, so the row still has
  /// something to render during the cold-start backfill.
  Track get operationalMetadataSource {
    Track? best;
    DateTime? bestAt;
    for (final t in variants) {
      final at = t.metadataReadAt;
      if (at == null) continue;
      if (bestAt == null || at.isAfter(bestAt)) {
        bestAt = at;
        best = t;
      }
    }
    return best ?? primary;
  }

  /// Last-change-wins: BPM from the variant with the freshest
  /// `metadataReadAt` AND a non-zero BPM. If the operational-
  /// metadata source has no BPM (the most-recently-enriched
  /// variant happens to have a blank field), fall back to any
  /// other variant that does — better to show a value than `—`
  /// when the data exists somewhere in the bucket.
  double? get bpm {
    final ops = operationalMetadataSource.bpm;
    if (ops != null && ops > 0) return ops;
    for (final t in variants) {
      final b = t.bpm;
      if (b != null && b > 0) return b;
    }
    return null;
  }

  /// Normalized Camelot key, last-change-wins with the same
  /// fallback rule as [bpm].
  String get displayKey {
    final opsKey =
        normalizeKeyToCamelot(operationalMetadataSource.rawKey);
    if (opsKey != null && opsKey.isNotEmpty) return opsKey;
    for (final t in variants) {
      final k = normalizeKeyToCamelot(t.rawKey);
      if (k != null && k.isNotEmpty) return k;
    }
    return '';
  }

  /// `MP3 · AIFF` style label of the formats present in the bucket,
  /// in `_formatPreferenceOrder` (lowest-quality first, so the
  /// bucket leader's format reads first). When a format appears
  /// more than once (e.g., two MP3 copies — typically the macOS
  /// Cmd+D " copy" duplicate), the count is appended as ` ×N`:
  ///
  ///   1 MP3                → `MP3`
  ///   1 MP3 + 1 AIFF       → `MP3 · AIFF`
  ///   2 MP3                → `MP3 ×2`
  ///   2 MP3 + 1 AIFF       → `MP3 ×2 · AIFF`
  ///   3 MP3 + 2 AIFF       → `MP3 ×3 · AIFF ×2`
  ///
  /// Unrecognised extensions sort to the end, alphabetised.
  String get formatLabel {
    final counts = <String, int>{};
    for (final t in variants) {
      final f = fileFormatLabel(t.filename);
      if (f.isEmpty) continue;
      counts[f] = (counts[f] ?? 0) + 1;
    }
    if (counts.isEmpty) return '';
    final ordered = <String>[];
    for (final f in _formatPreferenceOrder) {
      if (counts.containsKey(f)) ordered.add(f);
    }
    // Anything not in the canonical order goes at the end,
    // alphabetised so the display is deterministic.
    final remaining = counts.keys.toSet()..removeAll(ordered);
    final tail = remaining.toList()..sort();
    ordered.addAll(tail);
    return ordered
        .map((f) => counts[f]! > 1 ? '$f ×${counts[f]}' : f)
        .join(' · ');
  }
}

/// Lowest-quality-first order. Drives the default for indirect
/// playback (prep speed, CDJ compatibility, memory pressure — see
/// project memory) and the visual order of formats in the FORMAT
/// cell so the primary's encode reads leftmost.
const List<String> _formatPreferenceOrder = ['MP3', 'M4A', 'OGG', 'FLAC', 'WAV', 'AIFF'];

/// Rank a bucket against the active FORMAT-column sort lead.
///
/// Family-clustering, not strict set matching. See
/// `feedback_format_sort_family_clustering.md` in project memory
/// for the why-not-set-equality.
///
/// **Single lead** (e.g. `['MP3']`):
///   0 — exact: bucket has ONLY this format (`{MP3}`)
///   1 — contains: bucket has this format among others
///       (`{MP3, AIFF}`, `{MP3, WAV, AIFF}`)
///   2 — none: bucket lacks this format
///
/// **Pair lead** (e.g. `['MP3', 'WAV']`):
///   0 — contains both: bucket has both formats with or without
///       extras (`{MP3, WAV}` and `{MP3, WAV, AIFF}` cluster
///       together — same family from the user's POV)
///   1 — contains one: bucket has exactly one of the pair
///       (`{MP3}`, `{WAV}`, `{MP3, AIFF}`, `{WAV, FLAC}`)
///   2 — none: bucket has neither
///
/// Pure function over the view's variants and the lead — extracted
/// from `LibraryController` so it can be tested directly.
int computeFormatBucketRank(
  AggregatedTrackView view,
  List<String> lead,
) {
  final leadSet = lead.toSet();
  final formats = <String>{};
  for (final t in view.variants) {
    final f = fileFormatLabel(t.filename);
    if (f.isNotEmpty) formats.add(f);
  }
  if (formats.isEmpty) return 2;
  final intersection = formats.intersection(leadSet);
  if (intersection.isEmpty) return 2;
  if (leadSet.length == 1) {
    return formats.length == 1 ? 0 : 1;
  }
  return intersection.length == leadSet.length ? 0 : 1;
}

/// Compare two buckets under the active FORMAT-column sort lead.
///
/// Three-level ordering (extracted from the controller's
/// comparator so the same logic is testable directly):
///
///   1. Tier from [computeFormatBucketRank] — `0` exact / `1`
///      contains / `2` lacks. Primary clustering.
///   2. `view.formatLabel` ascending — secondary clustering so
///      same-combo rows form adjacent blocks. Without this,
///      tier 1 mixes `MP3 · AIFF` and `MP3 · WAV` by title alone.
///   3. Primary track's title ascending — tertiary.
int compareFormatBuckets(
  AggregatedTrackView a,
  AggregatedTrackView b,
  List<String> lead,
) {
  final ar = computeFormatBucketRank(a, lead);
  final br = computeFormatBucketRank(b, lead);
  if (ar != br) return ar.compareTo(br);
  final aLabel = a.formatLabel;
  final bLabel = b.formatLabel;
  if (aLabel != bLabel) return aLabel.compareTo(bLabel);
  return a.primary.displayTitle
      .toLowerCase()
      .compareTo(b.primary.displayTitle.toLowerCase());
}

/// Choose the primary variant for a bucket of same-song tracks.
/// Lowest-quality format wins (MP3 > FLAC > WAV > AIFF). When two
/// variants share a format, falls back to insertion order from
/// [bucket] so the choice is stable across calls.
///
/// Returns [bucket] reordered so the primary is at index 0. The
/// original list is not mutated.
List<Track> orderBucketByPlaybackPreference(List<Track> bucket) {
  if (bucket.length < 2) return List.of(bucket);
  final indexed = <(int, Track)>[
    for (var i = 0; i < bucket.length; i++) (i, bucket[i]),
  ];
  indexed.sort((a, b) {
    final fa = _formatRank(fileFormatLabel(a.$2.filename));
    final fb = _formatRank(fileFormatLabel(b.$2.filename));
    if (fa != fb) return fa.compareTo(fb);
    return a.$1.compareTo(b.$1); // stable
  });
  return [for (final e in indexed) e.$2];
}

int _formatRank(String label) {
  final idx = _formatPreferenceOrder.indexOf(label);
  return idx >= 0 ? idx : _formatPreferenceOrder.length; // unknown last
}

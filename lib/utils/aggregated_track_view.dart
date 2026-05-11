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

  /// Agreement → that value; one-present-one-blank → present value;
  /// any disagreement → null (renders as `—`).
  double? get bpm {
    double? value;
    var sawValue = false;
    for (final t in variants) {
      final b = t.bpm;
      if (b == null || b <= 0) continue;
      if (!sawValue) {
        value = b;
        sawValue = true;
      } else if (value != b) {
        return null; // disagreement
      }
    }
    return value;
  }

  /// Normalized Camelot key with the same agreement / disagreement
  /// rule as [bpm]. Returns empty string when variants disagree or
  /// when no variant has a parseable key.
  String get displayKey {
    String? value;
    var sawValue = false;
    for (final t in variants) {
      final k = normalizeKeyToCamelot(t.rawKey);
      if (k == null || k.isEmpty) continue;
      if (!sawValue) {
        value = k;
        sawValue = true;
      } else if (value != k) {
        return ''; // disagreement
      }
    }
    return value ?? '';
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

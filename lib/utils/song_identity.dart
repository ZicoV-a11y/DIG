// Song-identity matching.
//
// **Song identity** is a different concept from **file identity** in this
// codebase — see `project_track_identity_vs_file_variants.md` in the
// project memory for the full rationale. A user's library can hold
// multiple file variants (MP3 + AIFF, etc.) of the same song; this
// matcher decides when two file rows represent the same song so the
// table can collapse them into one row downstream.
//
// The rule is intentionally strict: a 4-field exact AND. Tightness is
// the safety property — false-positive merges silently hide files.
// Manual link / unlink (UI work, not yet implemented) is the escape
// hatch for the cases the rule misses.
//
// Do NOT confuse this with `Track.fingerprint` or `TrackUid.fingerprint`,
// which is a file-content-equivalence hash (basename WITH extension +
// filesize + duration). That hash detects "same file at a different
// path"; this matcher detects "same song across encodes."

import '../models/track.dart';

/// Returns `true` when [a] and [b] represent the same song under the
/// strict 4-field rule.
///
/// All four conditions must hold (case-sensitive, no whitespace
/// normalization, no unicode folding):
///
///   - basename without extension
///   - canonical title (from ID3 / Vorbis, via `Track.title`)
///   - canonical artist (from ID3 / Vorbis, via `Track.artist`)
///   - duration truncated to whole seconds (`Duration.inSeconds`)
///
/// Title / artist / filename are matched character-for-character.
/// Duration uses whole-second equality because MP3 and AIFF of the
/// same master routinely report durations that differ by tens or
/// hundreds of ms (different frame / sample alignments); strict
/// millisecond equality refuses almost every cross-format pair in
/// practice, even when they're audibly the same content. Whole-
/// second equality absorbs codec rounding while still failing the
/// radio-edit / extended-mix case (those differ by many seconds).
///
/// Tracks with empty canonical title or artist never match anything,
/// even each other — without metadata there's no song identity to
/// match on.
bool sameSongIdentity(Track a, Track b) {
  if (identical(a, b)) return true;
  // Manual override wins over everything else. Two tracks with the
  // same non-empty override pair regardless of fields; if only one
  // has an override they're intentionally distinct (no fallthrough
  // to fingerprint or 4-field).
  final ao = a.identityOverride;
  final bo = b.identityOverride;
  final aHasOverride = ao != null && ao.isNotEmpty;
  final bHasOverride = bo != null && bo.isNotEmpty;
  if (aHasOverride && bHasOverride) return ao == bo;
  if (aHasOverride != bHasOverride) return false;
  // Fingerprint fallback: two files with the same `(basename +
  // filesize + durationMs)` hash are byte-equivalent at the file
  // level. Always pair them, even when their ID3 tags drifted
  // (different tagger, edited tags, etc).
  if (a.fingerprint.isNotEmpty && a.fingerprint == b.fingerprint) {
    return true;
  }
  // Asymmetric-tagging fallback. When exactly ONE side lacks tags
  // — typically a freshly-added file whose metadata enrichment
  // hasn't completed yet — pair via basename + duration. Common
  // real-world case: user adds an MP3 to a folder that already
  // has an enriched AIFF sibling of the same song. The MP3 sits
  // with empty title/artist for the few seconds (or minutes, on
  // slow Dropbox) it takes for the enrichment pipeline to reach
  // it; during that window the strict 4-field match silently
  // splits the bucket and the user can't see the MP3 next to the
  // AIFFs in the variant picker / move dialog / etc.
  //
  // The asymmetric guard ("exactly one untagged") prevents two
  // unrelated, both-untagged files with coincidentally similar
  // names from merging. Two untagged tracks STILL fail to pair —
  // identity is not asserted until at least one side carries real
  // tags. Once the pipeline catches up, the match upgrades to the
  // strict path and stays.
  final aTagged = a.title.isNotEmpty && a.artist.isNotEmpty;
  final bTagged = b.title.isNotEmpty && b.artist.isNotEmpty;
  if (aTagged != bTagged) {
    final aSecs = a.duration.inSeconds;
    final bSecs = b.duration.inSeconds;
    if (aSecs == 0 || bSecs == 0) return false;
    if (aSecs != bSecs) return false;
    return _basenameNoExt(a.filename) == _basenameNoExt(b.filename);
  }
  if (!aTagged) return false; // both untagged → cannot pair
  if (a.duration.inSeconds != b.duration.inSeconds) return false;
  if (a.title != b.title) return false;
  if (a.artist != b.artist) return false;
  return _basenameNoExt(a.filename) == _basenameNoExt(b.filename);
}

/// Groups [tracks] into buckets of same-song-identity siblings.
///
/// Each returned list is one song identity; lists of length 1 are
/// included so callers can iterate uniformly. Order of input tracks is
/// preserved within each bucket, and bucket order matches the first
/// occurrence of each identity in [tracks].
///
/// Tracks that fail [sameSongIdentity]'s basic precondition (empty
/// title or artist) are each placed in their own singleton bucket so
/// they round-trip through the table without being silently dropped.
List<List<Track>> groupBySongIdentity(Iterable<Track> tracks) {
  final buckets = <List<Track>>[];
  // Three parallel indices, mirroring the match rules in
  // `sameSongIdentity`:
  //   - byKey: primary key (manual override or 4-field) → bucket
  //   - byFingerprint: file-content equivalence hash → bucket
  //   - byNameSec: basename-noext + duration in seconds → bucket
  //     (the asymmetric-tagging fallback; only consulted when the
  //     other two signals miss)
  // A track joins an existing bucket if any of those indexes points
  // to one; otherwise it creates a new bucket. When a track joins
  // (or creates) a bucket, all three of its signals get registered
  // so future tracks matching by any of them follow it in.
  final byKey = <String, int>{};
  final byFingerprint = <String, int>{};
  final byNameSec = <String, int>{};

  String? nameSecKey(Track t) {
    final secs = t.duration.inSeconds;
    if (secs == 0) return null;
    return '${_basenameNoExt(t.filename)}|$secs';
  }

  for (final t in tracks) {
    final key = songIdentityKey(t);
    final ns = nameSecKey(t);
    final tagged = t.title.isNotEmpty && t.artist.isNotEmpty;
    int? bucketIdx;
    if (key != null) bucketIdx = byKey[key];
    if (bucketIdx == null && t.fingerprint.isNotEmpty) {
      bucketIdx = byFingerprint[t.fingerprint];
    }
    if (bucketIdx == null && ns != null) {
      bucketIdx = byNameSec[ns];
    }
    if (bucketIdx == null) {
      bucketIdx = buckets.length;
      buckets.add([]);
    }
    buckets[bucketIdx].add(t);
    if (key != null) byKey[key] = bucketIdx;
    if (t.fingerprint.isNotEmpty) byFingerprint[t.fingerprint] = bucketIdx;
    // Only TAGGED tracks register their own basename+seconds key.
    // Untagged tracks can JOIN a name+secs bucket (when a tagged
    // sibling registered it earlier), but they don't seed one
    // themselves — otherwise two unrelated untagged files with
    // coincidentally identical names + durations would silently
    // merge, violating the "at least one side must be tagged"
    // rule the matcher enforces. Once enrichment lands a tagged
    // sibling, it registers the key and future untagged
    // discoveries pair correctly.
    if (tagged && ns != null) byNameSec[ns] = bucketIdx;
  }
  return buckets;
}

/// Stable string key that two tracks share iff [sameSongIdentity]
/// returns `true` for them. Returns `null` when the track is missing
/// canonical title or artist — those rows never group with anything.
///
/// Exposed so callers can drive collapse / expansion state (which
/// song-identities are "expanded" in the table) by string key rather
/// than by holding Track references.
///
/// **Manual override**: when [Track.identityOverride] is set, it
/// short-circuits the computed key. Two files with the same override
/// value bucket together regardless of whether the strict 4-field
/// rule would have paired them. Set by the right-click
/// "Link with another song" action; cleared via repository write.
String? songIdentityKey(Track t) {
  final override = t.identityOverride;
  if (override != null && override.isNotEmpty) return override;
  if (t.title.isEmpty || t.artist.isEmpty) return null;
  // U+001F (Unit Separator) — never appears in filesystem basenames
  // or ID3 strings on any platform we target, so it can't collide
  // across field boundaries (`"a", "bc"` vs `"ab", "c"`).
  const sep = '';
  return '${_basenameNoExt(t.filename)}$sep'
      '${t.title}$sep'
      '${t.artist}$sep'
      '${t.duration.inSeconds}';
}

/// Public mirror of the basename normalization the matcher applies
/// (extension strip + macOS Cmd+D suffix strip). Exposed so other
/// modules — e.g. the duplicates-audit classifier — can ask "would
/// the matcher see these two filenames as the same?" without
/// re-implementing the rule. Keep this in sync with `_basenameNoExt`
/// below; right now it's just a wrapper so the matcher is the
/// single source of truth.
String basenameForIdentity(String filename) => _basenameNoExt(filename);

String _basenameNoExt(String filename) {
  // Strip the last extension only. `track.tar.gz` → `track.tar`,
  // which matches how Dart's `path.withoutExtension` behaves and is
  // the right call for audio files (`.mp3`, `.aiff`, `.flac`, etc.).
  // Caller passes a basename, not a full path — we don't need to
  // hunt for separators.
  final dot = filename.lastIndexOf('.');
  final base = (dot <= 0) ? filename : filename.substring(0, dot);
  return _stripMacOsDuplicateSuffix(base);
}

// macOS Finder appends " copy" (and " copy 2", " copy 3", etc) when
// the user duplicates a file via Cmd+D. Strip those suffixes during
// identity matching so the duplicate pairs with the original. The
// user reported "ONE OF THEM IS NAMED COPY, THE MAC MADE A DUP AND
// ADDED COPY TO THE FILE NAME" — this rule unifies that specific
// flow. Case-insensitive on "copy" (Finder lowercases but a user
// rename might not). The optional trailing " N" handles further
// duplicates of duplicates.
final RegExp _macOsCopySuffix =
    RegExp(r'\s+copy(?:\s+\d+)?$', caseSensitive: false);

String _stripMacOsDuplicateSuffix(String baseNoExt) {
  final stripped = baseNoExt.replaceFirst(_macOsCopySuffix, '');
  // Never strip the whole name — if the input WAS just "copy" or
  // "copy 2", leave it alone so the comparison still distinguishes
  // it from other tracks.
  if (stripped.isEmpty) return baseNoExt;
  return stripped;
}

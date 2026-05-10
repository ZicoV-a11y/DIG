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
  if (a.title.isEmpty || a.artist.isEmpty) return false;
  if (b.title.isEmpty || b.artist.isEmpty) return false;
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
  // Two parallel indices, mirroring the two-tier match rule in
  // `sameSongIdentity`:
  //   - byKey: primary key (manual override or 4-field) → bucket
  //   - byFingerprint: file-content equivalence hash → bucket
  // A track joins an existing bucket if its key matches, else if
  // its fingerprint matches, else creates a new bucket. When a
  // track joins (or creates) a bucket, both its key and its
  // fingerprint are registered to that bucket so future tracks
  // matching by either signal follow it in.
  final byKey = <String, int>{};
  final byFingerprint = <String, int>{};

  for (final t in tracks) {
    final key = songIdentityKey(t);
    int? bucketIdx;
    if (key != null) bucketIdx = byKey[key];
    if (bucketIdx == null && t.fingerprint.isNotEmpty) {
      bucketIdx = byFingerprint[t.fingerprint];
    }
    if (bucketIdx == null) {
      bucketIdx = buckets.length;
      buckets.add([]);
    }
    buckets[bucketIdx].add(t);
    if (key != null) byKey[key] = bucketIdx;
    if (t.fingerprint.isNotEmpty) byFingerprint[t.fingerprint] = bucketIdx;
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

String _basenameNoExt(String filename) {
  // Strip the last extension only. `track.tar.gz` → `track.tar`,
  // which matches how Dart's `path.withoutExtension` behaves and is
  // the right call for audio files (`.mp3`, `.aiff`, `.flac`, etc.).
  // Caller passes a basename, not a full path — we don't need to
  // hunt for separators.
  final dot = filename.lastIndexOf('.');
  if (dot <= 0) return filename;
  return filename.substring(0, dot);
}

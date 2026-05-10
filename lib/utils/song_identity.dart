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
/// normalization, no unicode folding, exact text and exact duration):
///
///   - basename without extension
///   - canonical title (from ID3 / Vorbis, via `Track.title`)
///   - canonical artist (from ID3 / Vorbis, via `Track.artist`)
///   - duration in milliseconds
///
/// Tracks with empty canonical title or artist never match anything,
/// even each other — without metadata there's no song identity to
/// match on.
bool sameSongIdentity(Track a, Track b) {
  if (identical(a, b)) return true;
  if (a.title.isEmpty || a.artist.isEmpty) return false;
  if (b.title.isEmpty || b.artist.isEmpty) return false;
  if (a.duration != b.duration) return false;
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
  // Hash table over the same key shape as `sameSongIdentity` for
  // O(n) grouping. Tracks with empty title/artist short-circuit to a
  // null key and never group with anything.
  final byKey = <String, int>{};

  for (final t in tracks) {
    final key = _identityKey(t);
    if (key == null) {
      buckets.add([t]);
      continue;
    }
    final existing = byKey[key];
    if (existing == null) {
      byKey[key] = buckets.length;
      buckets.add([t]);
    } else {
      buckets[existing].add(t);
    }
  }
  return buckets;
}

String? _identityKey(Track t) {
  if (t.title.isEmpty || t.artist.isEmpty) return null;
  // U+001F (Unit Separator) — never appears in filesystem basenames
  // or ID3 strings on any platform we target, so it can't collide
  // across field boundaries (`"a", "bc"` vs `"ab", "c"`).
  const sep = '';
  return '${_basenameNoExt(t.filename)}$sep'
      '${t.title}$sep'
      '${t.artist}$sep'
      '${t.duration.inMilliseconds}';
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

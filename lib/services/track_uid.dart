import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Result of computing identity hashes for a single audio file.
///
/// Two distinct hashes serve different purposes (per architectural
/// guardrail 3 — "track identity ≠ file identity"):
///
/// - [fingerprint] = file-content equivalence. Same physical content at
///   any path/mtime collapses to the same fingerprint. Used to recognise
///   duplicates and reconnect intelligence after a folder move.
/// - [uid] = file revision identity. Unique per concrete file revision
///   (changes if mtime changes). Used as the `tracks.uid` PK.
///
/// **Naming caveat:** [fingerprint] here is a file-equivalence hash, not
/// a song-identity hash. Re-encodes of the same song (MP3 vs AIFF) hash
/// to *different* fingerprints because the extension and filesize change.
/// For cross-format "same song" matching, see `sameSongIdentity` in
/// `lib/utils/song_identity.dart` and the project memory entry
/// `project_track_identity_vs_file_variants.md`.
class TrackUid {
  final String fingerprint;
  final String uid;

  const TrackUid({required this.fingerprint, required this.uid});
}

/// Compute identity hashes for a single audio file.
///
/// All inputs are expected from the caller (already-stat'd file fields)
/// so this stays pure and isolate-safe. SHA-256 truncated to 16 hex
/// chars on each side; collisions for that namespace are practically
/// impossible at any realistic library size.
TrackUid computeTrackUid({
  required String basename,
  required int filesize,
  required int durationMs,
  required int mtimeMs,
}) {
  final normBase = _normalizeBasename(basename);
  final fp = _hash16('$normBase|$filesize|$durationMs');
  final uid = _hash16('$normBase|$filesize|$durationMs|$mtimeMs');
  return TrackUid(fingerprint: fp, uid: uid);
}

/// Convenience wrapper: stat the file at [path] and compute hashes.
/// If the file is missing, returns hashes computed against `filesize=0`
/// and `mtime=0` so the row is still uniquely keyed by basename + a
/// known-degenerate value (callers should mark `is_available = 0`).
TrackUid computeTrackUidFromFile(String path, {required int durationMs}) {
  int filesize = 0;
  int mtimeMs = 0;
  try {
    final stat = File(path).statSync();
    filesize = stat.size;
    mtimeMs = stat.modified.millisecondsSinceEpoch;
  } on FileSystemException {
    // best-effort; keep zeros
  }
  return computeTrackUid(
    basename: _basenameOf(path),
    filesize: filesize,
    durationMs: durationMs,
    mtimeMs: mtimeMs,
  );
}

String _basenameOf(String path) {
  final sep = path.lastIndexOf(Platform.pathSeparator);
  return sep < 0 ? path : path.substring(sep + 1);
}

String _normalizeBasename(String basename) {
  // Trim, then lowercase. Includes extension (so `Track.mp3` and
  // `track.flac` differ — different physical content). Unicode
  // normalisation isn't applied here because Dart strings are already
  // UTF-16, and macOS HFS+/APFS normalise filenames to NFD; for the
  // purposes of identity we treat the bytes as-given.
  return basename.trim().toLowerCase();
}

String _hash16(String input) {
  final digest = sha256.convert(utf8.encode(input));
  return digest.toString().substring(0, 16);
}

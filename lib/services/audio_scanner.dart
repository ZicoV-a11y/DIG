import 'dart:io';

import 'package:flutter/foundation.dart';

/// One file found during a scan. Both the directory walk AND the
/// per-file `stat` happen inside the scanner isolate so the UI thread
/// stays responsive on large libraries on slow / cloud-backed paths.
class ScannedEntry {
  final String path;
  final String filename;
  final int filesize;
  final int modifiedAtMs;

  const ScannedEntry({
    required this.path,
    required this.filename,
    required this.filesize,
    required this.modifiedAtMs,
  });
}

class AudioScanner {
  static const audioExtensions = <String>{
    'mp3',
    'wav',
    'flac',
    'm4a',
    'aiff',
    'aif',
  };

  /// Walk [rootPath] and return one [ScannedEntry] per audio file
  /// (path + stat result). All disk I/O happens in a worker isolate
  /// via `compute()`.
  ///
  /// [recursive] controls whether subdirectories are descended into.
  /// `false` indexes only files directly inside [rootPath] — useful
  /// for review/promo folders where deeper crawling is undesired.
  static Future<List<ScannedEntry>> scan(
    String rootPath, {
    required bool recursive,
  }) {
    return compute(_scanInIsolate, _ScanRequest(rootPath, recursive));
  }
}

class _ScanRequest {
  final String rootPath;
  final bool recursive;
  const _ScanRequest(this.rootPath, this.recursive);
}

@pragma('vm:entry-point')
List<ScannedEntry> _scanInIsolate(_ScanRequest req) {
  final root = Directory(req.rootPath);
  if (!root.existsSync()) return const [];
  final out = <ScannedEntry>[];

  // We deliberately do NOT use `Directory.listSync(recursive: true)`.
  // That call returns a single iterator backed by a depth-first walk;
  // if any subdirectory raises a FileSystemException mid-iteration
  // (a Dropbox/iCloud cloud-only file going through sync, a permission
  // hiccup, a stale handle), the WHOLE iteration aborts and the rest
  // of the tree is silently dropped. On a 9k-file library that means
  // most files appear "missing" on the next scan.
  //
  // Manual per-directory walk: errors on one subtree don't stop the
  // others.
  final stack = <Directory>[root];
  while (stack.isNotEmpty) {
    final dir = stack.removeLast();
    final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } on FileSystemException {
      continue; // best-effort: skip this subtree, keep going
    } catch (_) {
      continue;
    }
    for (final entity in entries) {
      if (entity is Directory) {
        if (!req.recursive) continue;
        // Skip hidden directories. The big one is macOS `.Trashes/`
        // (per-volume Trash on external drives) — if the source
        // folder lives at the root of an external drive, recursing
        // into `.Trashes/` makes deleted files come back as "still
        // present" at the new in-Trash path, so the scan can never
        // mark them gone. Also skips `.Spotlight-V100`,
        // `.fseventsd`, `.DS_Store` directories, etc. — none of
        // which a user organises music into.
        final p = entity.path;
        final sepIdx = p.lastIndexOf(Platform.pathSeparator);
        final dirName = sepIdx < 0 ? p : p.substring(sepIdx + 1);
        if (dirName.startsWith('.')) continue;
        stack.add(entity);
        continue;
      }
      if (entity is! File) continue;
      final p = entity.path;
      final sepIdx = p.lastIndexOf(Platform.pathSeparator);
      final name = sepIdx < 0 ? p : p.substring(sepIdx + 1);
      if (name.startsWith('.')) continue;
      final dotIdx = name.lastIndexOf('.');
      if (dotIdx <= 0 || dotIdx == name.length - 1) continue;
      final ext = name.substring(dotIdx + 1).toLowerCase();
      if (!AudioScanner.audioExtensions.contains(ext)) continue;

      // Stat each file here, in the isolate. Per-file stat on
      // Dropbox paths can be slow; running it on the main isolate
      // would freeze the UI for 9k+ files.
      //
      // Stat failures (Dropbox/iCloud sync races, the file being
      // moved or deleted between the listSync and statSync, perm
      // hiccups) used to emit the entry with size=0 / mtime=0,
      // which then got persisted as an indexed_files row with a
      // junk fingerprint computed from degenerate inputs. Those
      // ghost rows then stuck around forever as "missing" with
      // unmatchable fingerprints. Treat a stat failure as a
      // transient I/O error: skip the entry entirely, let the
      // next scan retry. Better to be temporarily blind to a file
      // than to persist corrupted identity for it.
      int size = 0;
      int mtimeMs = 0;
      try {
        final st = entity.statSync();
        size = st.size;
        mtimeMs = st.modified.millisecondsSinceEpoch;
      } catch (_) {
        // best-effort
      }
      if (size <= 0 || mtimeMs == 0) continue;
      out.add(ScannedEntry(
        path: p,
        filename: name,
        filesize: size,
        modifiedAtMs: mtimeMs,
      ));
    }
  }
  return out;
}

String filenameWithoutExtension(String path) {
  final sep = path.lastIndexOf(Platform.pathSeparator);
  final base = sep < 0 ? path : path.substring(sep + 1);
  final dot = base.lastIndexOf('.');
  return dot > 0 ? base.substring(0, dot) : base;
}

String basenameOfPath(String path) {
  final sep = path.lastIndexOf(Platform.pathSeparator);
  return sep < 0 ? path : path.substring(sep + 1);
}

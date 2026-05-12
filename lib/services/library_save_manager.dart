import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/save_snapshot.dart';

/// Filesystem layout for one library. Single owner of where saves
/// live, what the canonical DB filename is, and how to create the
/// subdirs. Pure paths — no I/O happens just from constructing
/// this. Call [ensureLayout] to materialise the directory tree on
/// disk.
class LibraryRoot {
  /// Absolute path to the library root directory.
  final String path;

  const LibraryRoot(this.path);

  /// Live working DB lives here. The app reads/writes from this
  /// file. Snapshots are immutable copies of it.
  String get currentDbPath => '$path/Current/db.sqlite';

  String get currentDir => '$path/Current';
  String get savesDir => '$path/Saves';
  String get cacheDir => '$path/Cache';
  String get logsDir => '$path/Logs';

  /// Create the directory skeleton if it doesn't exist. Idempotent.
  /// Cache/ and Logs/ are created up front even though this slice
  /// doesn't use them yet — keeps the on-disk shape stable so the
  /// user sees the same layout every time they open the library
  /// folder in Finder.
  Future<void> ensureLayout() async {
    await Directory(currentDir).create(recursive: true);
    await Directory(savesDir).create(recursive: true);
    await Directory(cacheDir).create(recursive: true);
    await Directory(logsDir).create(recursive: true);
  }
}

/// Manages immutable `.library` snapshots inside [LibraryRoot]'s
/// `Saves/` directory.
///
/// Each snapshot is a direct SQLite file copy — plain enough that
/// `sqlite3 file.library .tables` works from the terminal. This is
/// the "transparent / recoverable" UX from the spec; no archive
/// wrapper to learn, no custom format to maintain.
///
/// The manager guarantees:
///   - filenames follow [SaveSnapshot.formatFilename]
///   - the latest [maxSnapshots] are kept; older ones are pruned
///   - a snapshot is NEVER overwritten in place — every save
///     produces a new file. Filename collisions (same minute) get
///     suffixed with a `-N` counter so even two saves in the same
///     minute can coexist.
///   - foreign files in `Saves/` (anything not matching the format)
///     are left alone — never deleted, never miscounted.
class LibrarySaveManager {
  final LibraryRoot root;
  final int maxSnapshots;

  LibrarySaveManager({required this.root, this.maxSnapshots = 20});

  /// Capture the current DB to a new `.library` file. Returns the
  /// snapshot's path. Prunes older snapshots beyond [maxSnapshots]
  /// after a successful write. If the DB doesn't exist yet (fresh
  /// install before any data) the call is a no-op and returns null.
  Future<File?> snapshot({
    required String libraryName,
    required String machineId,
    DateTime? at,
  }) async {
    final dbFile = File(root.currentDbPath);
    if (!dbFile.existsSync()) {
      debugPrint(
        '[save] no Current/db.sqlite yet — snapshot skipped',
      );
      return null;
    }
    final capturedAt = at ?? DateTime.now();
    await Directory(root.savesDir).create(recursive: true);
    final path = await _allocateUniquePath(
      libraryName: libraryName,
      machineId: machineId,
      capturedAt: capturedAt,
    );
    // Copy through a temp file in the same directory then rename
    // so a partial write never leaves a half-baked `.library` file
    // that startup would try to restore from.
    final tmp = File('$path.partial');
    try {
      await dbFile.copy(tmp.path);
      await tmp.rename(path);
    } catch (e) {
      if (tmp.existsSync()) {
        try {
          await tmp.delete();
        } catch (_) {/* best-effort */}
      }
      rethrow;
    }
    final created = File(path);
    debugPrint('[save] wrote ${created.path}');
    await _prune();
    return created;
  }

  /// List every recognised snapshot in `Saves/`, sorted newest
  /// first. Foreign files are silently ignored.
  Future<List<SaveSnapshot>> listSnapshots() async {
    final dir = Directory(root.savesDir);
    if (!dir.existsSync()) return const [];
    final entries = await dir.list(followLinks: false).toList();
    final out = <SaveSnapshot>[];
    for (final e in entries) {
      if (e is! File) continue;
      final name = e.uri.pathSegments.last;
      final parsed = SaveSnapshot.tryParse(name);
      if (parsed != null) out.add(parsed);
    }
    out.sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
    return out;
  }

  /// Most-recent snapshot, or null if none exist. Used by the
  /// startup restore path when `Current/db.sqlite` is missing.
  Future<SaveSnapshot?> newestSnapshot() async {
    final all = await listSnapshots();
    return all.isEmpty ? null : all.first;
  }

  /// Restore the newest snapshot into `Current/db.sqlite`. Only
  /// fires when `Current/db.sqlite` is missing — caller's
  /// responsibility to check. Returns the snapshot that was used,
  /// or null if `Saves/` was empty.
  Future<SaveSnapshot?> restoreFromNewest() async {
    final newest = await newestSnapshot();
    if (newest == null) return null;
    final src = File('${root.savesDir}/${newest.filename}');
    if (!src.existsSync()) return null;
    await Directory(root.currentDir).create(recursive: true);
    await src.copy(root.currentDbPath);
    debugPrint(
      '[save] restored ${newest.filename} → Current/db.sqlite',
    );
    return newest;
  }

  /// Build a path that doesn't collide with an existing file. Same
  /// minute → append `-2`, `-3`, etc. Bounded at 99 attempts so a
  /// runaway loop can't lock the app on a misconfigured filesystem.
  Future<String> _allocateUniquePath({
    required String libraryName,
    required String machineId,
    required DateTime capturedAt,
  }) async {
    final base = SaveSnapshot.formatFilename(
      libraryName: libraryName,
      machineId: machineId,
      capturedAt: capturedAt,
    );
    final basePath = '${root.savesDir}/$base';
    if (!File(basePath).existsSync()) return basePath;
    for (var n = 2; n < 100; n++) {
      final stem = base.substring(0, base.length - '.library'.length);
      final candidate = '${root.savesDir}/$stem-$n.library';
      if (!File(candidate).existsSync()) return candidate;
    }
    // Extremely unlikely. Fall back to a millisecond-suffixed name
    // so we still produce a unique file instead of throwing.
    final fallback =
        '${root.savesDir}/${base.substring(0, base.length - '.library'.length)}'
        '-${DateTime.now().millisecondsSinceEpoch}.library';
    return fallback;
  }

  /// Keep newest [maxSnapshots], delete the rest. Pure cleanup —
  /// runs after every successful snapshot. Foreign files (anything
  /// that doesn't parse) are never touched.
  Future<void> _prune() async {
    final all = await listSnapshots();
    if (all.length <= maxSnapshots) return;
    final stale = all.sublist(maxSnapshots);
    for (final s in stale) {
      try {
        await File('${root.savesDir}/${s.filename}').delete();
      } catch (e) {
        debugPrint('[save] prune failed on ${s.filename}: $e');
      }
    }
  }
}

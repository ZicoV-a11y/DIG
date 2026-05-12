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
  /// file. Snapshots in `Saves/` are immutable copies of it.
  /// Filename intentionally matches the `.library` extension used
  /// by snapshots — one canonical live identity per library, same
  /// container format, so the user opening the folder in Finder
  /// sees one consistent naming convention.
  String get currentDbPath => '$path/Current/CURRENT.library';

  String get currentDir => '$path/Current';
  String get savesDir => '$path/Saves';
  String get cacheDir => '$path/Cache';
  String get logsDir => '$path/Logs';

  /// Per-device state channel files (`{MACHINE_ID}.library`).
  /// Each device writes ONE always-overwritten file here per
  /// autosave — the operational truth for that device. Saves/
  /// holds the rolling lineage; Systems/ holds latest-only state.
  String get systemsDir => '$path/Systems';

  /// Reserved for cross-device library exchange — timestamped
  /// per-device files from multiple machines so the eventual
  /// resolver can do "newest per device" load on startup.
  /// Scaffolded empty this slice; the resolver + cross-device
  /// merge semantics are explicitly deferred. Folder name contains
  /// a space intentionally — matches the user-facing label so
  /// Finder browsing reads naturally.
  String get sharedLibrariesDir => '$path/Shared Libraries';

  /// Create the directory skeleton if it doesn't exist. Idempotent.
  /// Cache/ / Logs/ / Shared Libraries/ are created up front even
  /// though this slice doesn't write to them yet — keeps the on-disk
  /// shape stable so the user sees the same layout every time they
  /// open the library folder in Finder.
  Future<void> ensureLayout() async {
    await Directory(currentDir).create(recursive: true);
    await Directory(savesDir).create(recursive: true);
    await Directory(cacheDir).create(recursive: true);
    await Directory(logsDir).create(recursive: true);
    await Directory(systemsDir).create(recursive: true);
    await Directory(sharedLibrariesDir).create(recursive: true);
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
        '[save] no Current/CURRENT.library yet — snapshot skipped',
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

  /// Overwrite this device's operational state file at
  /// `Systems/{sanitised(machineId)}.library` with the current
  /// DB bytes. Returns the resulting File, or `null` when
  /// `Current/CURRENT.library` doesn't exist yet (same no-op
  /// semantics as [snapshot]).
  ///
  /// Unlike [snapshot] there is no rolling history at this layer —
  /// one file per device, latest only. The Saves/ snapshot taken
  /// in the same tick is the rollback / recovery surface; this
  /// file is the operational truth, eventually authoritative for
  /// startup once the resolver lands.
  ///
  /// [libraryName] is accepted for API symmetry with [snapshot]
  /// even though it isn't part of the filename — keeps both write
  /// paths interchangeable from the caller's POV and leaves room
  /// to embed library identity into a future file header if
  /// needed.
  Future<File?> writeDeviceChannel({
    required String libraryName,
    required String machineId,
  }) async {
    final dbFile = File(root.currentDbPath);
    if (!dbFile.existsSync()) {
      debugPrint(
        '[save] no Current/CURRENT.library yet — '
        'device channel write skipped',
      );
      return null;
    }
    final sanitised = SaveSnapshot.sanitiseFilesystemLabel(
      machineId,
      emptyFallback: 'MACHINE',
    );
    final destPath = '${root.systemsDir}/$sanitised.library';
    await Directory(root.systemsDir).create(recursive: true);
    // Copy through `.partial` then rename for atomicity. A
    // half-baked write must never leave a corrupt
    // Systems/{device}.library that a future startup resolver
    // could read as authoritative state.
    final tmp = File('$destPath.partial');
    try {
      await dbFile.copy(tmp.path);
      // Dart's File.rename on macOS atomically replaces an
      // existing destination — same semantics as POSIX rename(2)
      // — so the prior device-channel file goes away in the same
      // syscall, not in a separate delete step that could race.
      await tmp.rename(destPath);
    } catch (e) {
      if (tmp.existsSync()) {
        try {
          await tmp.delete();
        } catch (_) {/* best-effort */}
      }
      rethrow;
    }
    final created = File(destPath);
    debugPrint('[save] wrote device channel ${created.path}');
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
  /// startup restore path when `Current/CURRENT.library` is
  /// missing.
  Future<SaveSnapshot?> newestSnapshot() async {
    final all = await listSnapshots();
    return all.isEmpty ? null : all.first;
  }

  /// Restore the newest snapshot into `Current/CURRENT.library`.
  /// Only fires when `Current/CURRENT.library` is missing —
  /// caller's responsibility to check. Returns the snapshot that
  /// was used, or null if `Saves/` was empty.
  Future<SaveSnapshot?> restoreFromNewest() async {
    final newest = await newestSnapshot();
    if (newest == null) return null;
    final src = File('${root.savesDir}/${newest.filename}');
    if (!src.existsSync()) return null;
    await Directory(root.currentDir).create(recursive: true);
    await src.copy(root.currentDbPath);
    debugPrint(
      '[save] restored ${newest.filename} → Current/CURRENT.library',
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

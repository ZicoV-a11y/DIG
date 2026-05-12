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

  /// Compatibility-mirror DB path. After the 2026-05-12 boot
  /// transition, the live working DB lives at [deviceLiveDbPath]
  /// (Systems/{MACHINE}.library); `Current/CURRENT.library` is
  /// kept as a transitional mirror so manual rollback / external
  /// inspection / paranoia recovery still have a stable
  /// filename. Long-term fate (keep / cache / remove) is
  /// deliberately deferred — see `feedback_save_trust_cycle.md`.
  String get currentDbPath => '$path/Current/CURRENT.library';

  String get currentDir => '$path/Current';
  String get savesDir => '$path/Saves';
  String get cacheDir => '$path/Cache';
  String get logsDir => '$path/Logs';

  /// Per-device contribution channel files
  /// (`{MACHINE_ID}.library`). As of the 2026-05-12 boot transition
  /// this IS the live DB the running app opens — sqflite writes
  /// here directly. One file per device, always overwritten, no
  /// rolling history at this layer (Saves/ holds the lineage).
  ///
  /// Critical framing: each `{MACHINE_ID}.library` is a CONTRIBUTION
  /// SOURCE — this device's perspective on the user's library — NOT
  /// the ultimate library authority. Single-device today means
  /// contribution ≈ global, but the conceptual distinction is
  /// preserved so future resolver / composed-graph work
  /// (§1a + §1b of `project_library_knowledge_graph_direction.md`)
  /// can compose authority from multiple contributions without
  /// re-litigating the model.
  String get systemsDir => '$path/Systems';

  /// Per-device live DB path. Resolves to
  /// `Systems/{sanitised(machineId)}.library`. Sanitisation shared
  /// with the Saves/ filename builder via
  /// [SaveSnapshot.sanitiseFilesystemLabel] so a single source of
  /// truth governs both filenames.
  String deviceLiveDbPath(String machineId) {
    final mach = SaveSnapshot.sanitiseFilesystemLabel(
      machineId,
      emptyFallback: 'MACHINE',
    );
    return '$systemsDir/$mach.library';
  }

  /// Filesystem-level device identity. Read BEFORE any SQLite
  /// open so the bootstrap doesn't need to open a DB to decide
  /// which DB to open (the chicken-and-egg that would keep
  /// `Current/` secretly authoritative). Plain text file, one
  /// line, sanitised on write — inspectable, editable, manually
  /// operable in Finder. The DB still mirrors `machine_id` in
  /// `app_settings` for UI / metadata / save naming, but the
  /// filesystem file is the source of truth for boot routing.
  String get machineIdFilePath => '$path/machine_id.txt';

  /// Read the device's filesystem-level machine identity. Reads
  /// `machine_id.txt` if present; otherwise falls back to
  /// `Platform.localHostname` sanitised. Returns a non-empty
  /// filesystem-safe string suitable for direct interpolation
  /// into [deviceLiveDbPath].
  Future<String> readMachineId() async {
    final file = File(machineIdFilePath);
    if (file.existsSync()) {
      try {
        final raw = (await file.readAsString()).trim();
        if (raw.isNotEmpty) {
          return SaveSnapshot.sanitiseFilesystemLabel(
            raw,
            emptyFallback: 'MACHINE',
          );
        }
      } catch (e) {
        debugPrint('[libroot] failed to read $machineIdFilePath: $e');
      }
    }
    String host = '';
    try {
      host = Platform.localHostname;
    } catch (_) {/* keep empty, falls through to MACHINE */}
    return SaveSnapshot.sanitiseFilesystemLabel(
      host,
      emptyFallback: 'MACHINE',
    );
  }

  /// Write the device's filesystem-level machine identity to
  /// `machine_id.txt`. Sanitises the value before persisting so
  /// the on-disk filename matches what [readMachineId] will
  /// return later. Idempotent — re-writing the same value is a
  /// no-op effect on the boot path.
  Future<void> writeMachineId(String machineId) async {
    final sanitised = SaveSnapshot.sanitiseFilesystemLabel(
      machineId,
      emptyFallback: 'MACHINE',
    );
    await Directory(path).create(recursive: true);
    await File(machineIdFilePath).writeAsString('$sanitised\n');
  }

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

  /// Capture the live DB to a new `.library` file in `Saves/`.
  /// Returns the snapshot's path. Prunes older snapshots beyond
  /// [maxSnapshots] after a successful write. If the live DB
  /// doesn't exist yet (fresh install before any data) the call is
  /// a no-op and returns null.
  ///
  /// [sourceDbPath] is the path to the running app's live SQLite
  /// file. After the 2026-05-12 boot transition this is
  /// `root.deviceLiveDbPath(machineId)` (Systems/{MACHINE}.library);
  /// the parameter is explicit so the snapshot method has zero
  /// hardcoded assumption about where "live" lives.
  Future<File?> snapshot({
    required String libraryName,
    required String machineId,
    required String sourceDbPath,
    DateTime? at,
  }) async {
    final dbFile = File(sourceDbPath);
    if (!dbFile.existsSync()) {
      debugPrint(
        '[save] no live DB at $sourceDbPath yet — snapshot skipped',
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

  /// Mirror the live `Systems/{MACHINE}.library` file to
  /// `Current/CURRENT.library` for backward-compatible rollback.
  /// Returns the destination File, or `null` when the live device
  /// file doesn't exist yet (same no-op semantics as [snapshot]).
  ///
  /// Reversed direction from the original `writeDeviceChannel` —
  /// after the 2026-05-12 boot transition, `Systems/` is the live
  /// DB that sqflite opens and writes to directly, and `Current/`
  /// is a compatibility mirror so manual Finder-swap rollback and
  /// external inspection still have a stable filename. Long-term
  /// fate of `Current/` (keep / cache / remove) is deferred.
  ///
  /// [libraryName] is accepted for API symmetry with [snapshot]
  /// even though it isn't part of the filename — leaves room for
  /// future library-identity metadata.
  Future<File?> mirrorToCurrent({
    required String libraryName,
    required String machineId,
  }) async {
    final sourcePath = root.deviceLiveDbPath(machineId);
    final sourceFile = File(sourcePath);
    if (!sourceFile.existsSync()) {
      debugPrint(
        '[save] no live device file at $sourcePath yet — '
        'mirror skipped',
      );
      return null;
    }
    final destPath = root.currentDbPath;
    await Directory(root.currentDir).create(recursive: true);
    // Copy through `.partial` then rename for atomicity. A
    // half-baked write must never leave a corrupt
    // Current/CURRENT.library that a manual rollback would
    // restore from.
    final tmp = File('$destPath.partial');
    try {
      await sourceFile.copy(tmp.path);
      // Dart's File.rename on macOS atomically replaces an
      // existing destination — same semantics as POSIX rename(2)
      // — so the prior mirror file goes away in the same syscall,
      // not in a separate delete step that could race.
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
    debugPrint('[save] mirrored to ${created.path}');
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

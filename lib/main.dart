import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'screens/home_screen.dart';
import 'services/database.dart';
import 'services/library_repository.dart';
import 'services/library_save_manager.dart';
import 'services/playback_engine.dart';
import 'state/library_controller.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final root = await _resolveLibraryRoot();
  await root.ensureLayout();
  final saveManager = LibrarySaveManager(root: root);

  // Filesystem-level device identity. Resolved BEFORE any SQLite
  // open so the bootstrap doesn't depend on reading the DB to
  // decide which DB to open — otherwise Current/ remains secretly
  // authoritative (see §1c Core Architectural Principles in
  // `project_library_knowledge_graph_direction.md`).
  final machineId = await root.readMachineId();
  final liveDbPath = root.deviceLiveDbPath(machineId);

  // Locate / migrate / bootstrap the live device DB at
  // `Systems/{machine_id}.library`. After this returns, the live
  // file is in place ready for sqflite to open.
  await _bootstrapLiveDb(
    root: root,
    saveManager: saveManager,
    liveDbPath: liveDbPath,
  );

  final db = AppDatabase();
  await db.open(dbPath: liveDbPath);
  final repo = LibraryRepository(db);
  final engine = PlaybackEngine();
  final controller = LibraryController(
    engine: engine,
    repo: repo,
    saveManager: saveManager,
    libraryRoot: root,
  );
  await controller.hydrate();

  runApp(MusicTrackerApp(engine: engine, controller: controller, db: db));
}

Future<LibraryRoot> _resolveLibraryRoot() async {
  final docs = await getApplicationDocumentsDirectory();
  return LibraryRoot('${docs.path}/Music Tracker');
}

Future<void> _bootstrapLiveDb({
  required LibraryRoot root,
  required LibrarySaveManager saveManager,
  required String liveDbPath,
}) async {
  final liveDb = File(liveDbPath);

  // Priority 0: live DB already exists — most common case once
  // the boot transition has taken effect. Operational continuity
  // outranks any other consideration; Systems/ wins.
  if (liveDb.existsSync()) {
    debugPrint('[bootstrap] live DB present at $liveDbPath — opening directly');
    return;
  }

  // Priority 1: one-shot migration from `Current/CURRENT.library`.
  // First launch after the boot-transition slice — the existing
  // live DB is at Current/CURRENT.library (where it lived before
  // this slice flipped authority to Systems/). Copy (NOT move)
  // into Systems/ so Current/ stays as the compatibility mirror
  // per the transition safety contract.
  final currentDb = File(root.currentDbPath);
  if (currentDb.existsSync()) {
    try {
      await Directory(root.systemsDir).create(recursive: true);
      await currentDb.copy(liveDbPath);
      debugPrint(
        '[bootstrap] migrated Current/CURRENT.library → $liveDbPath '
        '(Current/ preserved as compatibility mirror)',
      );
      return;
    } catch (e) {
      debugPrint(
        '[bootstrap] Current/ → Systems/ migration failed: $e '
        '— falling through',
      );
    }
  }

  // Priority 2: in-place rename of prior `Current/db.sqlite`
  // (legacy filename from before the CURRENT.library naming
  // unification). Same SQLite bytes are valid under any name;
  // rename + copy to Systems/.
  final priorCurrent = File('${root.currentDir}/db.sqlite');
  if (priorCurrent.existsSync()) {
    try {
      await Directory(root.systemsDir).create(recursive: true);
      await priorCurrent.copy(liveDbPath);
      // Also rename to CURRENT.library so the compatibility
      // mirror has the right filename for future swaps.
      try {
        await priorCurrent.rename(root.currentDbPath);
      } catch (_) {/* best-effort */}
      debugPrint(
        '[bootstrap] migrated legacy Current/db.sqlite → $liveDbPath',
      );
      return;
    } catch (e) {
      debugPrint('[bootstrap] db.sqlite migration failed: $e — falling through');
    }
  }

  // Priority 3: copy-first migration from the legacy macOS
  // Application Support DB. First launch on a machine that had
  // the app before LibraryRoot existed at all. Legacy file stays
  // as emergency fallback until the user deletes it manually.
  final legacyDb = await _legacyDbFile();
  if (legacyDb != null && legacyDb.existsSync()) {
    try {
      await Directory(root.systemsDir).create(recursive: true);
      await legacyDb.copy(liveDbPath);
      debugPrint(
        '[bootstrap] copied legacy DB → $liveDbPath '
        '(legacy file preserved at ${legacyDb.path})',
      );
      return;
    } catch (e) {
      debugPrint('[bootstrap] legacy copy failed: $e — falling through');
    }
  }

  // Priority 4: restore from the newest snapshot in Saves/.
  // Clean install on a machine where the user dropped saves into
  // the library root manually, or deleted both the live + mirror
  // files to roll back.
  final newest = await saveManager.newestSnapshot();
  if (newest != null) {
    try {
      final src = File('${root.savesDir}/${newest.filename}');
      await Directory(root.systemsDir).create(recursive: true);
      await src.copy(liveDbPath);
      debugPrint(
        '[bootstrap] restored newest snapshot ${newest.filename} → $liveDbPath',
      );
      return;
    } catch (e) {
      debugPrint('[bootstrap] snapshot restore failed: $e — falling through');
    }
  }

  // Otherwise leave the Systems/ path empty — AppDatabase.open
  // will create a fresh DB at that path with the latest schema.
  debugPrint('[bootstrap] fresh DB will be created at $liveDbPath');
}

/// Path to the macOS Application Support DB used before the
/// LibraryRoot model existed. May not exist on fresh installs or
/// non-macOS platforms — caller checks `existsSync` before using.
Future<File?> _legacyDbFile() async {
  try {
    final supportDir = await getApplicationSupportDirectory();
    return File('${supportDir.path}/music_tracker.db');
  } catch (_) {
    return null;
  }
}

class MusicTrackerApp extends StatefulWidget {
  final PlaybackEngine engine;
  final LibraryController controller;
  final AppDatabase db;

  const MusicTrackerApp({
    super.key,
    required this.engine,
    required this.controller,
    required this.db,
  });

  @override
  State<MusicTrackerApp> createState() => _MusicTrackerAppState();
}

class _MusicTrackerAppState extends State<MusicTrackerApp> {
  @override
  void dispose() {
    widget.controller.dispose();
    widget.engine.dispose();
    widget.db.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Music Tracker',
      theme: buildAppTheme(),
      home: HomeScreen(controller: widget.controller),
    );
  }
}

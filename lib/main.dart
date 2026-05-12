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

  // Copy-first migration from the legacy Application Support DB.
  // Runs only when Current/db.sqlite doesn't exist yet, never
  // mutates the legacy file in place (per project decision —
  // legacy file stays as an emergency fallback until the user
  // deletes it manually). If Current/ is missing but Saves/ has
  // files, fall through to restore-newest instead.
  await _bootstrapCurrentDb(root: root, saveManager: saveManager);

  final db = AppDatabase();
  await db.open(dbPath: root.currentDbPath);
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

Future<void> _bootstrapCurrentDb({
  required LibraryRoot root,
  required LibrarySaveManager saveManager,
}) async {
  final currentDb = File(root.currentDbPath);
  if (currentDb.existsSync()) return;

  // Priority 1: copy-first migration from the legacy Application
  // Support DB. The user already has 12k+ tracks there; first
  // launch with the new code should land them on the same data
  // inside the new layout without any prompt.
  final legacyDb = await _legacyDbFile();
  if (legacyDb != null && legacyDb.existsSync()) {
    try {
      await Directory(root.currentDir).create(recursive: true);
      await legacyDb.copy(root.currentDbPath);
      debugPrint(
        '[bootstrap] copied legacy DB → ${root.currentDbPath} '
        '(legacy file preserved at ${legacyDb.path})',
      );
      return;
    } catch (e) {
      debugPrint('[bootstrap] legacy copy failed: $e — falling through');
    }
  }

  // Priority 2: restore from the newest snapshot in Saves/.
  // Happens after a clean install on a machine where the user
  // dropped saves into the library root manually (or after the
  // user deleted Current/db.sqlite intentionally to roll back).
  final restored = await saveManager.restoreFromNewest();
  if (restored != null) {
    debugPrint(
      '[bootstrap] restored newest snapshot ${restored.filename}',
    );
    return;
  }

  // Otherwise leave Current/ empty — AppDatabase.open will create
  // a fresh DB at that path with the latest schema.
  debugPrint('[bootstrap] fresh DB will be created at ${root.currentDbPath}');
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

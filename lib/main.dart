import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'services/database.dart';
import 'services/library_repository.dart';
import 'services/playback_engine.dart';
import 'state/library_controller.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final db = AppDatabase();
  await db.open();
  final repo = LibraryRepository(db);
  final engine = PlaybackEngine();
  final controller = LibraryController(engine: engine, repo: repo);
  await controller.hydrate();

  runApp(MusicTrackerApp(engine: engine, controller: controller, db: db));
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

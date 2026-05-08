import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'services/playback_engine.dart';
import 'state/library_controller.dart';
import 'theme/app_theme.dart';

void main() {
  runApp(const MusicTrackerApp());
}

class MusicTrackerApp extends StatefulWidget {
  const MusicTrackerApp({super.key});

  @override
  State<MusicTrackerApp> createState() => _MusicTrackerAppState();
}

class _MusicTrackerAppState extends State<MusicTrackerApp> {
  late final PlaybackEngine _engine;
  late final LibraryController _controller;

  @override
  void initState() {
    super.initState();
    _engine = PlaybackEngine();
    _controller = LibraryController(engine: _engine);
  }

  @override
  void dispose() {
    _controller.dispose();
    _engine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Music Tracker',
      theme: buildAppTheme(),
      home: HomeScreen(controller: _controller),
    );
  }
}

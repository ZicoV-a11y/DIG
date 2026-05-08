import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:music_tracker/main.dart';
import 'package:music_tracker/services/database.dart';
import 'package:music_tracker/services/library_repository.dart';
import 'package:music_tracker/services/playback_engine.dart';
import 'package:music_tracker/state/library_controller.dart';

void main() {
  testWidgets('App renders empty library shell', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final db = AppDatabase();
    await db.openInMemory();
    addTearDown(db.close);

    final repo = LibraryRepository(db);
    final engine = PlaybackEngine();
    final controller = LibraryController(engine: engine, repo: repo);
    await controller.hydrate();

    await tester.pumpWidget(
      MusicTrackerApp(engine: engine, controller: controller, db: db),
    );
    await tester.pump();

    expect(find.text('LIBRARY'), findsOneWidget);
    expect(find.text('All Tracks'), findsOneWidget);
    expect(find.text('Unreviewed only'), findsOneWidget);
    expect(find.text('No folders yet.'), findsOneWidget);
    expect(find.text('Add folder'), findsOneWidget);
  });
}

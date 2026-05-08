import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:music_tracker/main.dart';

void main() {
  testWidgets('App renders empty library shell', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MusicTrackerApp());
    await tester.pump();

    expect(find.text('LIBRARY'), findsOneWidget);
    expect(find.text('All Tracks'), findsOneWidget);
    expect(find.text('Unreviewed only'), findsOneWidget);
    expect(find.text('No folders yet.'), findsOneWidget);
    expect(find.text('Add folder'), findsOneWidget);
  });
}

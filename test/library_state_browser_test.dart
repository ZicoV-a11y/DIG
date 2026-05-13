import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_tracker/models/operational_state.dart';
import 'package:music_tracker/services/library_save_manager.dart';
import 'package:music_tracker/services/library_state_browser.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Tests for the operational-state browser — enumeration only.
/// Preview enrichment uses sqflite over an actual `.library` file
/// (a real SQLite DB with the music_tracker schema) — that's
/// exercised by the live app and the
/// `library_save_manager_test`'s integration flow; here we focus
/// on the listing/categorisation logic that drives the UI groups.
void main() {
  late Directory tmp;
  late LibraryRoot root;
  late LibraryStateBrowser browser;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tmp = await Directory.systemTemp.createTemp('state_browser_test_');
    root = LibraryRoot(tmp.path);
    await root.ensureLayout();
    browser = LibraryStateBrowser(root: root);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// Create a dummy `.library` file with arbitrary bytes (not a
  /// real SQLite DB). Enough for the enumeration path which only
  /// reads filesystem metadata.
  Future<File> placeFile(String dir, String name, [String content = 'x']) async {
    final f = File('$dir/$name');
    await f.writeAsString(content);
    return f;
  }

  test('listOperationalStates returns empty when no files', () async {
    final list = await browser.listOperationalStates(
      currentMachineId: 'MACNEO',
    );
    expect(list, isEmpty);
  });

  test('current-device file in Systems/ tagged correctly', () async {
    await placeFile(root.systemsDir, 'MACNEO.library');
    final list = await browser.listOperationalStates(
      currentMachineId: 'MACNEO',
    );
    expect(list.length, 1);
    expect(list.first.source, OperationalStateSource.currentDevice);
    expect(list.first.machineId, 'MACNEO');
    expect(list.first.snapshot, isNull);
  });

  test('other-device files in Systems/ tagged correctly', () async {
    await placeFile(root.systemsDir, 'MACNEO.library');
    await placeFile(root.systemsDir, 'IPHONE.library');
    await placeFile(root.systemsDir, 'IPAD.library');
    final list = await browser.listOperationalStates(
      currentMachineId: 'MACNEO',
    );
    expect(list.length, 3);
    // Current first, then alphabetised others.
    expect(list[0].machineId, 'MACNEO');
    expect(list[0].source, OperationalStateSource.currentDevice);
    expect(list[1].machineId, 'IPAD');
    expect(list[1].source, OperationalStateSource.otherDevice);
    expect(list[2].machineId, 'IPHONE');
    expect(list[2].source, OperationalStateSource.otherDevice);
  });

  test('historical lineage in Saves/ tagged + sorted newest first',
      () async {
    await placeFile(
      root.savesDir,
      'NEOMAC_LIBRARY__MACNEO__2026-MAY-12__09-15AM.library',
    );
    await placeFile(
      root.savesDir,
      'NEOMAC_LIBRARY__MACNEO__2026-MAY-12__11-33AM.library',
    );
    await placeFile(
      root.savesDir,
      'NEOMAC_LIBRARY__MACNEO__2026-MAY-12__10-02AM.library',
    );
    final list = await browser.listOperationalStates(
      currentMachineId: 'MACNEO',
    );
    expect(list.length, 3);
    for (final s in list) {
      expect(s.source, OperationalStateSource.historicalLineage);
    }
    // Newest first.
    expect(list[0].capturedAt.hour, 11);
    expect(list[1].capturedAt.hour, 10);
    expect(list[2].capturedAt.hour, 9);
  });

  test('shared libraries tagged correctly + sorted newest first',
      () async {
    await placeFile(
      root.sharedLibrariesDir,
      'NEOMAC_LIBRARY__IPHONE__2026-MAY-12__09-15AM.library',
    );
    await placeFile(
      root.sharedLibrariesDir,
      'NEOMAC_LIBRARY__MACMINI__2026-MAY-12__08-02AM.library',
    );
    final list = await browser.listOperationalStates(
      currentMachineId: 'MACNEO',
    );
    expect(list.length, 2);
    for (final s in list) {
      expect(s.source, OperationalStateSource.sharedLibrary);
    }
    expect(list[0].machineId, 'IPHONE');
    expect(list[1].machineId, 'MACMINI');
  });

  test('all four sources together — correct ordering by section',
      () async {
    await placeFile(root.systemsDir, 'MACNEO.library');
    await placeFile(root.systemsDir, 'IPHONE.library');
    await placeFile(
      root.savesDir,
      'NEOMAC_LIBRARY__MACNEO__2026-MAY-12__11-33AM.library',
    );
    await placeFile(
      root.sharedLibrariesDir,
      'NEOMAC_LIBRARY__IPAD__2026-MAY-12__09-15AM.library',
    );
    final list = await browser.listOperationalStates(
      currentMachineId: 'MACNEO',
    );
    expect(list.length, 4);
    // Order: current device → other device → historical → shared.
    expect(list[0].source, OperationalStateSource.currentDevice);
    expect(list[1].source, OperationalStateSource.otherDevice);
    expect(list[2].source, OperationalStateSource.historicalLineage);
    expect(list[3].source, OperationalStateSource.sharedLibrary);
  });

  test('foreign files in Systems/ are silently ignored', () async {
    // `.partial` from an interrupted write, a `.txt` note, and a
    // file whose stem contains __ (looks like a Saves/ entry
    // misplaced into Systems/).
    await placeFile(root.systemsDir, 'MACNEO.library');
    await placeFile(root.systemsDir, 'MACNEO.library.partial');
    await placeFile(root.systemsDir, 'note.txt');
    await placeFile(
      root.systemsDir,
      'WRONG__PLACE__2026-MAY-12__09-15AM.library',
    );
    final list = await browser.listOperationalStates(
      currentMachineId: 'MACNEO',
    );
    expect(list.length, 1);
    expect(list.first.machineId, 'MACNEO');
  });

  test('foreign files in Saves/ are silently ignored', () async {
    await placeFile(
      root.savesDir,
      'NEOMAC_LIBRARY__MACNEO__2026-MAY-12__11-33AM.library',
    );
    await placeFile(root.savesDir, 'random.txt');
    await placeFile(root.savesDir, 'CURRENT.library'); // missing __ separators
    final list = await browser.listOperationalStates(
      currentMachineId: 'MACNEO',
    );
    expect(list.length, 1);
  });

  test('machine ID sanitisation determines current vs other tagging',
      () async {
    // The current_machine_id input contains lowercase + hyphens; it
    // should sanitise to NEOMACS_MACBOOK_LOCAL and match the file.
    await placeFile(root.systemsDir, 'NEOMACS_MACBOOK_LOCAL.library');
    final list = await browser.listOperationalStates(
      currentMachineId: 'neomacs-macbook.local',
    );
    expect(list.length, 1);
    expect(list.first.source, OperationalStateSource.currentDevice);
  });

  test('enrichPreview degrades gracefully on non-SQLite content',
      () async {
    // Plain text file with a `.library` extension. Two valid
    // outcomes depending on platform sqflite behavior:
    //   (a) open succeeds → all per-query stats return null;
    //       errored stays false (UI renders "—" for each stat).
    //   (b) open fails    → errored is true with a SANITISED
    //       message — never a raw SqliteException dump.
    // In both cases the user-facing UI never sees SQL exception
    // text.
    final f = await placeFile(root.systemsDir, 'MACNEO.library');
    final list = await browser.listOperationalStates(
      currentMachineId: 'MACNEO',
    );
    final state = list.first;
    expect(state.filePath, f.path);
    final preview = await browser.enrichPreview(state);
    if (preview.errored) {
      // (b) — when open failed, the message must NOT leak SQL
      // exception internals.
      expect(preview.errorMessage, isNotNull);
      expect(preview.errorMessage!.toLowerCase(),
          isNot(contains('sqfliteffiexception')));
      expect(preview.errorMessage!.toLowerCase(),
          isNot(contains('sqliteexception')));
    } else {
      // (a) — open succeeded; individual queries failed silently.
      // All stats null, recentEvents null, no error surfaced.
      expect(preview.trackCount, isNull);
      expect(preview.favoriteCount, isNull);
      expect(preview.recentEvents, isNull);
    }
  });
}

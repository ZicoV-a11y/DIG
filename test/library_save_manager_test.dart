import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_tracker/services/library_save_manager.dart';

/// Behavioral tests for the save manager — exercises real
/// filesystem I/O in a temp directory so we cover the cases that
/// matter (race-free rolling retention, foreign-file safety,
/// missing-DB no-op, startup restore).
void main() {
  late Directory tmp;
  late LibraryRoot root;
  late LibrarySaveManager manager;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('save_manager_test_');
    root = LibraryRoot(tmp.path);
    await root.ensureLayout();
    manager = LibrarySaveManager(root: root, maxSnapshots: 3);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<void> writeCurrentDb(String contents) async {
    await File(root.currentDbPath).writeAsString(contents);
  }

  test('ensureLayout creates Current / Saves / Cache / Logs / Systems',
      () async {
    expect(Directory(root.currentDir).existsSync(), isTrue);
    expect(Directory(root.savesDir).existsSync(), isTrue);
    expect(Directory(root.cacheDir).existsSync(), isTrue);
    expect(Directory(root.logsDir).existsSync(), isTrue);
    // Systems/ is scaffolded but unused this slice — formalises
    // the per-device state direction in the on-disk layout so the
    // future per-device save logic doesn't trigger a directory
    // migration.
    expect(Directory(root.systemsDir).existsSync(), isTrue);
  });

  test('Systems/ directory has its own dedicated coverage', () async {
    // Explicit standalone check — keeps the per-device state
    // scaffold visible in the test listing so a future regression
    // (someone removing Systems/ from ensureLayout) fails with a
    // self-explanatory name instead of a multi-directory
    // assertion failure.
    expect(Directory(root.systemsDir).path, endsWith('/Systems'));
    expect(Directory(root.systemsDir).existsSync(), isTrue);
  });

  test('snapshot returns null when Current/CURRENT.library is missing',
      () async {
    final file = await manager.snapshot(
      libraryName: 'AFRO',
      machineId: 'DJMAC',
    );
    expect(file, isNull);
    // And no half-written files left behind.
    final entries =
        await Directory(root.savesDir).list().toList();
    expect(entries, isEmpty);
  });

  test('snapshot writes a parseable .library file', () async {
    await writeCurrentDb('hello-db-bytes');
    final file = await manager.snapshot(
      libraryName: 'AFRO_LIBRARY',
      machineId: 'DJMAC',
      at: DateTime(2026, 5, 12, 18, 47),
    );
    expect(file, isNotNull);
    final name = file!.uri.pathSegments.last;
    expect(
      name,
      'AFRO_LIBRARY__DJMAC__2026-MAY-12__06-47PM.library',
    );
    expect(file.readAsStringSync(), 'hello-db-bytes');
  });

  test('same-minute snapshots get -N suffix instead of overwriting',
      () async {
    await writeCurrentDb('v1');
    final at = DateTime(2026, 5, 12, 18, 47);
    await manager.snapshot(
      libraryName: 'AFRO',
      machineId: 'DJMAC',
      at: at,
    );
    await writeCurrentDb('v2');
    final second = await manager.snapshot(
      libraryName: 'AFRO',
      machineId: 'DJMAC',
      at: at,
    );
    expect(second!.uri.pathSegments.last,
        'AFRO__DJMAC__2026-MAY-12__06-47PM-2.library');
    expect(second.readAsStringSync(), 'v2');
  });

  test('rolling retention keeps newest maxSnapshots, deletes older',
      () async {
    // maxSnapshots = 3 from setUp. Write 5 with monotonically
    // increasing timestamps; expect only the newest 3 to survive.
    for (var i = 0; i < 5; i++) {
      await writeCurrentDb('v$i');
      await manager.snapshot(
        libraryName: 'AFRO',
        machineId: 'DJMAC',
        at: DateTime(2026, 5, 12, 1 + i, 0),
      );
    }
    final remaining = await manager.listSnapshots();
    expect(remaining.length, 3);
    // Newest first ordering.
    expect(remaining[0].capturedAt, DateTime(2026, 5, 12, 5, 0));
    expect(remaining[1].capturedAt, DateTime(2026, 5, 12, 4, 0));
    expect(remaining[2].capturedAt, DateTime(2026, 5, 12, 3, 0));
  });

  test('listSnapshots ignores foreign files', () async {
    await writeCurrentDb('v1');
    await manager.snapshot(
      libraryName: 'AFRO',
      machineId: 'DJMAC',
      at: DateTime(2026, 5, 12, 18, 47),
    );
    // Drop two foreign files into Saves/: a half-baked .partial
    // and an unrelated user file. Both must be ignored — never
    // counted, never deleted by prune.
    await File('${root.savesDir}/note.txt').writeAsString('user note');
    await File(
            '${root.savesDir}/AFRO__DJMAC__2026-MAY-12__06-47PM.library.partial')
        .writeAsString('half-baked');
    final all = await manager.listSnapshots();
    expect(all.length, 1);
    // Foreign files still on disk after listing.
    expect(File('${root.savesDir}/note.txt').existsSync(), isTrue);
  });

  test('restoreFromNewest copies into Current/CURRENT.library when missing',
      () async {
    await writeCurrentDb('original');
    await manager.snapshot(
      libraryName: 'AFRO',
      machineId: 'DJMAC',
      at: DateTime(2026, 5, 12, 18, 47),
    );
    // Simulate startup with Current/ deleted (e.g., the user
    // wiped it to roll back).
    await File(root.currentDbPath).delete();
    expect(File(root.currentDbPath).existsSync(), isFalse);

    final restored = await manager.restoreFromNewest();
    expect(restored, isNotNull);
    expect(File(root.currentDbPath).readAsStringSync(), 'original');
  });

  test('restoreFromNewest returns null when Saves/ is empty', () async {
    final restored = await manager.restoreFromNewest();
    expect(restored, isNull);
    expect(File(root.currentDbPath).existsSync(), isFalse);
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_tracker/services/library_save_manager.dart';

/// Behavioral tests for the save manager — exercises real
/// filesystem I/O in a temp directory so we cover the cases that
/// matter (race-free rolling retention, foreign-file safety,
/// missing-DB no-op, startup restore, boot-transition migration).
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

  /// Write to the live device DB (post boot-transition: this is
  /// `Systems/{MACHINE}.library`, the file sqflite opens directly).
  Future<void> writeLiveDb(String machineId, String contents) async {
    await File(root.deviceLiveDbPath(machineId)).writeAsString(contents);
  }

  /// Write to the legacy `Current/CURRENT.library` location —
  /// used only by tests that exercise the boot-transition
  /// migration path or the compatibility-mirror behavior.
  Future<void> writeCurrentDb(String contents) async {
    await File(root.currentDbPath).writeAsString(contents);
  }

  test('ensureLayout creates Current / Saves / Cache / Logs / Systems',
      () async {
    expect(Directory(root.currentDir).existsSync(), isTrue);
    expect(Directory(root.savesDir).existsSync(), isTrue);
    expect(Directory(root.cacheDir).existsSync(), isTrue);
    expect(Directory(root.logsDir).existsSync(), isTrue);
    // Systems/ is the live device-channel directory after the
    // 2026-05-12 boot transition. Post-transition every device
    // writes one `.library` file here as its operational truth.
    expect(Directory(root.systemsDir).existsSync(), isTrue);
  });

  test('Systems/ directory has its own dedicated coverage', () async {
    expect(Directory(root.systemsDir).path, endsWith('/Systems'));
    expect(Directory(root.systemsDir).existsSync(), isTrue);
  });

  test('Shared Libraries/ directory scaffolded by ensureLayout', () async {
    expect(
      Directory(root.sharedLibrariesDir).path,
      endsWith('/Shared Libraries'),
    );
    expect(Directory(root.sharedLibrariesDir).existsSync(), isTrue);
  });

  group('Device identity — filesystem-level (machine_id.txt)', () {
    test('machineIdFilePath resolves to LibraryRoot/machine_id.txt',
        () async {
      expect(root.machineIdFilePath, endsWith('/machine_id.txt'));
      expect(
        root.machineIdFilePath,
        '${root.path}/machine_id.txt',
      );
    });

    test('readMachineId falls back to hostname when file absent',
        () async {
      // No machine_id.txt → fall through to Platform.localHostname.
      // Just verify the result is a non-empty sanitised string —
      // exact hostname value varies per test machine.
      expect(File(root.machineIdFilePath).existsSync(), isFalse);
      final id = await root.readMachineId();
      expect(id, isNotEmpty);
      expect(id, matches(RegExp(r'^[A-Z0-9_]+$')),
          reason: 'hostname must be sanitised to filesystem-safe form');
    });

    test('readMachineId reads file when present, sanitises', () async {
      // Write a label with lowercase + special chars; expect
      // sanitised uppercase + underscore output, matching the
      // Saves/ filename builder.
      await File(root.machineIdFilePath).writeAsString('mac-neo.local\n');
      final id = await root.readMachineId();
      expect(id, 'MAC_NEO_LOCAL');
    });

    test('writeMachineId persists sanitised value to machine_id.txt',
        () async {
      await root.writeMachineId('Some Device-Name');
      final raw = await File(root.machineIdFilePath).readAsString();
      // Sanitised content + trailing newline.
      expect(raw.trim(), 'SOME_DEVICE_NAME');
      // Read-back uses the persisted value.
      expect(await root.readMachineId(), 'SOME_DEVICE_NAME');
    });

    test('deviceLiveDbPath sanitises machine ID into Systems/ path',
        () async {
      final path = root.deviceLiveDbPath('mac-neo.local');
      expect(path, '${root.systemsDir}/MAC_NEO_LOCAL.library');
    });
  });

  group('mirrorToCurrent — compatibility mirror (Systems/ → Current/)', () {
    test('returns null when Systems/{MACHINE}.library is missing',
        () async {
      final file = await manager.mirrorToCurrent(
        libraryName: 'AFRO',
        machineId: 'DJMAC',
      );
      expect(file, isNull);
      // No half-written `.partial` left behind.
      expect(File('${root.currentDbPath}.partial').existsSync(), isFalse);
    });

    test('mirrors Systems/{MACHINE}.library → Current/CURRENT.library',
        () async {
      await writeLiveDb('DJMAC', 'live-bytes');
      final file = await manager.mirrorToCurrent(
        libraryName: 'AFRO',
        machineId: 'DJMAC',
      );
      expect(file, isNotNull);
      expect(file!.uri.pathSegments.last, 'CURRENT.library');
      expect(file.parent.path, endsWith('/Current'));
      expect(file.readAsStringSync(), 'live-bytes');
    });

    test('overwrites existing Current/CURRENT.library atomically',
        () async {
      await writeLiveDb('DJMAC', 'v1');
      await manager.mirrorToCurrent(libraryName: 'AFRO', machineId: 'DJMAC');
      await writeLiveDb('DJMAC', 'v2');
      final second = await manager.mirrorToCurrent(
        libraryName: 'AFRO',
        machineId: 'DJMAC',
      );
      expect(second!.readAsStringSync(), 'v2');
      // No `.partial` straggler.
      expect(File('${root.currentDbPath}.partial').existsSync(), isFalse);
    });

    test('sanitises machine ID for filesystem safety', () async {
      await writeLiveDb('neomacs-macbook.local', 'payload');
      // The Systems/ filename uses the sanitised form; mirror
      // should still find and copy it.
      final file = await manager.mirrorToCurrent(
        libraryName: 'AFRO',
        machineId: 'neomacs-macbook.local',
      );
      expect(file, isNotNull);
      expect(file!.readAsStringSync(), 'payload');
    });
  });

  test('snapshot returns null when sourceDbPath is missing', () async {
    final file = await manager.snapshot(
      libraryName: 'AFRO',
      machineId: 'DJMAC',
      sourceDbPath: root.deviceLiveDbPath('DJMAC'),
    );
    expect(file, isNull);
    // And no half-written files left behind.
    final entries =
        await Directory(root.savesDir).list().toList();
    expect(entries, isEmpty);
  });

  test('snapshot writes a parseable .library file', () async {
    await writeLiveDb('DJMAC', 'hello-db-bytes');
    final file = await manager.snapshot(
      libraryName: 'AFRO_LIBRARY',
      machineId: 'DJMAC',
      sourceDbPath: root.deviceLiveDbPath('DJMAC'),
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
    await writeLiveDb('DJMAC', 'v1');
    final at = DateTime(2026, 5, 12, 18, 47);
    await manager.snapshot(
      libraryName: 'AFRO',
      machineId: 'DJMAC',
      sourceDbPath: root.deviceLiveDbPath('DJMAC'),
      at: at,
    );
    await writeLiveDb('DJMAC', 'v2');
    final second = await manager.snapshot(
      libraryName: 'AFRO',
      machineId: 'DJMAC',
      sourceDbPath: root.deviceLiveDbPath('DJMAC'),
      at: at,
    );
    expect(second!.uri.pathSegments.last,
        'AFRO__DJMAC__2026-MAY-12__06-47PM-2.library');
    expect(second.readAsStringSync(), 'v2');
  });

  test('rolling retention keeps newest maxSnapshots, deletes older',
      () async {
    for (var i = 0; i < 5; i++) {
      await writeLiveDb('DJMAC', 'v$i');
      await manager.snapshot(
        libraryName: 'AFRO',
        machineId: 'DJMAC',
        sourceDbPath: root.deviceLiveDbPath('DJMAC'),
        at: DateTime(2026, 5, 12, 1 + i, 0),
      );
    }
    final remaining = await manager.listSnapshots();
    expect(remaining.length, 3);
    expect(remaining[0].capturedAt, DateTime(2026, 5, 12, 5, 0));
    expect(remaining[1].capturedAt, DateTime(2026, 5, 12, 4, 0));
    expect(remaining[2].capturedAt, DateTime(2026, 5, 12, 3, 0));
  });

  test('listSnapshots ignores foreign files', () async {
    await writeLiveDb('DJMAC', 'v1');
    await manager.snapshot(
      libraryName: 'AFRO',
      machineId: 'DJMAC',
      sourceDbPath: root.deviceLiveDbPath('DJMAC'),
      at: DateTime(2026, 5, 12, 18, 47),
    );
    await File('${root.savesDir}/note.txt').writeAsString('user note');
    await File(
            '${root.savesDir}/AFRO__DJMAC__2026-MAY-12__06-47PM.library.partial')
        .writeAsString('half-baked');
    final all = await manager.listSnapshots();
    expect(all.length, 1);
    expect(File('${root.savesDir}/note.txt').existsSync(), isTrue);
  });

  test('restoreFromNewest copies into Current/CURRENT.library when missing',
      () async {
    // restoreFromNewest still targets Current/CURRENT.library —
    // it's the legacy bootstrap fallback path. Boot-transition
    // logic in main.dart calls newestSnapshot() directly and
    // copies into Systems/ instead; this old method stays for
    // any external/manual rollback use.
    await writeCurrentDb('original');
    await manager.snapshot(
      libraryName: 'AFRO',
      machineId: 'DJMAC',
      sourceDbPath: root.currentDbPath,
      at: DateTime(2026, 5, 12, 18, 47),
    );
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

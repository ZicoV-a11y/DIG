// PR2.8.A — InventoryService contract tests.
//
// These pin the load-bearing architectural rules:
//
//   1. Generations are immutable once they leave `staging`.
//   2. Activation is pointer-swap-only — no file mutation, no
//      cached_tracks edits.
//   3. The activation pointer is the source of truth; row
//      status fields are ergonomic mirrors.
//   4. Hash verification is generation-scoped — a file proven
//      in generation A doesn't carry over to generation B.
//   5. Retired generations survive activation; cleanup is
//      explicitly deferred to garbageCollect().
//   6. Failed generations leave reason text behind for the
//      activity log.
//   7. Files on disk are real — verifyGeneration reads them via
//      the same first+last-256KB convention the desktop uses
//      to compute contentHash, so the wire contract is checked
//      end-to-end.

import 'dart:io';

import 'package:companion_ios/src/services/inventory_models.dart';
import 'package:companion_ios/src/services/inventory_service.dart';
import 'package:companion_ios/src/services/transport_hash.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_core/shared_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late InventoryService inv;
  late Directory tempDir;

  setUp(() async {
    sqfliteFfiInit();
    inv = await InventoryService.open(inMemoryDatabasePath);
    tempDir = await Directory.systemTemp.createTemp('inv_test_');
  });

  tearDown(() async {
    await inv.close();
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  /// Write a file to disk and return (path, transportHash).
  Future<({String path, String hash, int size})> writeFile(
    String name,
    List<int> bytes,
  ) async {
    final f = File('${tempDir.path}/$name');
    await f.writeAsBytes(bytes);
    final hash = await computeTransportHash(f.path);
    return (path: f.path, hash: hash, size: bytes.length);
  }

  TrackIdentity identity(String name) => TrackIdentity(
        intelUid: 'intel-$name',
        variantId: 'variant-$name',
        contentHash: 'hash-$name',
      );

  group('createStagingGeneration', () {
    test('opens a generation in staging status', () async {
      final gen = await inv.createStagingGeneration(
        manifestVersion: 42,
        sourceSessionId: 'sess-abc',
      );
      expect(gen.status, GenerationStatus.staging);
      expect(gen.manifestVersion, 42);
      expect(gen.sourceSessionId, 'sess-abc');
      expect(gen.generationId, hasLength(36)); // UUID
    });

    test('no active generation right after creating one', () async {
      await inv.createStagingGeneration();
      expect(await inv.currentActiveGeneration(), isNull);
      expect(await inv.currentInventory(), isEmpty);
    });
  });

  group('recordStagedTrack', () {
    test('appends a track to the staging generation', () async {
      final gen = await inv.createStagingGeneration();
      final file = await writeFile('a.mp3', List.filled(2048, 42));
      await inv.recordStagedTrack(
        generationId: gen.generationId,
        identity: identity('a'),
        transportHash: file.hash,
        audioPath: file.path,
        byteSize: file.size,
      );
      final tracks = await inv.listTracksInGeneration(gen.generationId);
      expect(tracks, hasLength(1));
      expect(tracks.first.identity.intelUid, 'intel-a');
      expect(tracks.first.transportHash, file.hash);
      expect(tracks.first.byteSize, 2048);
    });

    test('refuses writes to non-staging generations (immutability)',
        () async {
      // Once a generation moves past `staging`, it must never
      // accept new track rows. The PR2.8.A contract says
      // generations are immutable after they leave staging.
      final gen = await inv.createStagingGeneration();
      // Empty generation; verify passes trivially → status = ready.
      await inv.verifyGeneration(gen.generationId);

      final file = await writeFile('late.mp3', List.filled(100, 1));
      expect(
        () => inv.recordStagedTrack(
          generationId: gen.generationId,
          identity: identity('late'),
          transportHash: file.hash,
          audioPath: file.path,
          byteSize: file.size,
        ),
        throwsStateError,
      );
    });

    test('re-recording (generation_id, intel_uid) replaces in-place',
        () async {
      // Idempotency for retries within a single staging session.
      final gen = await inv.createStagingGeneration();
      final firstFile =
          await writeFile('a-first.mp3', List.filled(100, 1));
      await inv.recordStagedTrack(
        generationId: gen.generationId,
        identity: identity('a'),
        transportHash: firstFile.hash,
        audioPath: firstFile.path,
        byteSize: firstFile.size,
      );
      final secondFile =
          await writeFile('a-second.mp3', List.filled(200, 2));
      await inv.recordStagedTrack(
        generationId: gen.generationId,
        identity: identity('a'),
        transportHash: secondFile.hash,
        audioPath: secondFile.path,
        byteSize: secondFile.size,
      );
      final tracks = await inv.listTracksInGeneration(gen.generationId);
      expect(tracks, hasLength(1));
      expect(tracks.first.audioPath, secondFile.path);
      expect(tracks.first.byteSize, 200);
    });
  });

  group('verifyGeneration', () {
    test('passes when every file matches its transport hash', () async {
      final gen = await inv.createStagingGeneration();
      final file = await writeFile('ok.mp3', List.filled(1000, 7));
      await inv.recordStagedTrack(
        generationId: gen.generationId,
        identity: identity('ok'),
        transportHash: file.hash,
        audioPath: file.path,
        byteSize: file.size,
      );
      final ok = await inv.verifyGeneration(gen.generationId);
      expect(ok, isTrue);
      final after = await inv.findGeneration(gen.generationId);
      expect(after!.status, GenerationStatus.ready);
      final tracks = await inv.listTracksInGeneration(gen.generationId);
      expect(tracks.first.hashVerifiedAt, isNotNull,
          reason: 'verified tracks must carry the verification stamp');
    });

    test('fails with reason text on hash mismatch', () async {
      final gen = await inv.createStagingGeneration();
      final file = await writeFile('a.mp3', List.filled(1000, 9));
      await inv.recordStagedTrack(
        generationId: gen.generationId,
        identity: identity('a'),
        transportHash: 'WRONG-HASH-DOES-NOT-MATCH',
        audioPath: file.path,
        byteSize: file.size,
      );
      final ok = await inv.verifyGeneration(gen.generationId);
      expect(ok, isFalse);
      final after = await inv.findGeneration(gen.generationId);
      expect(after!.status, GenerationStatus.failed);
      expect(after.failedReason, contains('transport_hash mismatch'));
    });

    test('fails when a referenced file is missing', () async {
      final gen = await inv.createStagingGeneration();
      final file = await writeFile('vanished.mp3', List.filled(500, 3));
      await inv.recordStagedTrack(
        generationId: gen.generationId,
        identity: identity('vanished'),
        transportHash: file.hash,
        audioPath: file.path,
        byteSize: file.size,
      );
      await File(file.path).delete();
      final ok = await inv.verifyGeneration(gen.generationId);
      expect(ok, isFalse);
      final after = await inv.findGeneration(gen.generationId);
      expect(after!.status, GenerationStatus.failed);
      expect(after.failedReason, contains('missing file'));
    });

    test('refuses to verify non-staging generations', () async {
      // Already-verified generations must not be re-verified
      // (immutability). The check is at the API boundary, not
      // a silent no-op.
      final gen = await inv.createStagingGeneration();
      await inv.verifyGeneration(gen.generationId); // → ready
      expect(
        () => inv.verifyGeneration(gen.generationId),
        throwsStateError,
      );
    });
  });

  group('activate (pointer-swap only)', () {
    test('moves the activation pointer + flips status fields',
        () async {
      final genA = await inv.createStagingGeneration(manifestVersion: 1);
      final file = await writeFile('a.mp3', List.filled(1000, 1));
      await inv.recordStagedTrack(
        generationId: genA.generationId,
        identity: identity('a'),
        transportHash: file.hash,
        audioPath: file.path,
        byteSize: file.size,
      );
      await inv.verifyGeneration(genA.generationId);
      await inv.activate(genA.generationId);

      final active = await inv.currentActiveGeneration();
      expect(active?.generationId, genA.generationId);
      expect(active?.status, GenerationStatus.active);
      // currentInventory binds via the pointer.
      final inventory = await inv.currentInventory();
      expect(inventory, hasLength(1));
      expect(inventory.first.identity.intelUid, 'intel-a');
    });

    test('previous generation transitions to retired, NOT deleted',
        () async {
      // Activation is deferred-cleanup. The previous
      // generation's row + files survive; only the pointer
      // moves. garbageCollect() decides when to clean up later.
      final genA = await inv.createStagingGeneration();
      final fileA = await writeFile('a.mp3', List.filled(800, 1));
      await inv.recordStagedTrack(
        generationId: genA.generationId,
        identity: identity('a'),
        transportHash: fileA.hash,
        audioPath: fileA.path,
        byteSize: fileA.size,
      );
      await inv.verifyGeneration(genA.generationId);
      await inv.activate(genA.generationId);

      final genB = await inv.createStagingGeneration();
      final fileB = await writeFile('b.mp3', List.filled(600, 2));
      await inv.recordStagedTrack(
        generationId: genB.generationId,
        identity: identity('b'),
        transportHash: fileB.hash,
        audioPath: fileB.path,
        byteSize: fileB.size,
      );
      await inv.verifyGeneration(genB.generationId);
      await inv.activate(genB.generationId);

      // Pointer moved to B; A retired but row + file present.
      final active = await inv.currentActiveGeneration();
      expect(active?.generationId, genB.generationId);
      final prior = await inv.findGeneration(genA.generationId);
      expect(prior?.status, GenerationStatus.retired);
      expect(File(fileA.path).existsSync(), isTrue,
          reason: "retired generation's files MUST survive activation");

      // cached_tracks rows of the retired generation also
      // intact — activation doesn't touch them.
      final retiredTracks =
          await inv.listTracksInGeneration(genA.generationId);
      expect(retiredTracks, hasLength(1),
          reason: "retired generation's cached_tracks must survive");
    });

    test('refuses to activate non-ready generations', () async {
      final gen = await inv.createStagingGeneration();
      // Still staging — activation must reject.
      expect(
        () => inv.activate(gen.generationId),
        throwsStateError,
      );
    });

    test('cached_tracks rows of active generation are NOT mutated',
        () async {
      // The cached_tracks rows of the active generation are
      // read-only from activation onwards. The PR2.8.A
      // contract: generations are immutable. There's no API
      // path to write into a non-staging generation; this test
      // asserts that the surface really is closed.
      final gen = await inv.createStagingGeneration();
      final file = await writeFile('a.mp3', List.filled(500, 5));
      await inv.recordStagedTrack(
        generationId: gen.generationId,
        identity: identity('a'),
        transportHash: file.hash,
        audioPath: file.path,
        byteSize: file.size,
      );
      await inv.verifyGeneration(gen.generationId);
      await inv.activate(gen.generationId);

      // recordStagedTrack on the now-active generation must
      // throw. No back-door write path.
      final file2 = await writeFile('a2.mp3', List.filled(400, 6));
      expect(
        () => inv.recordStagedTrack(
          generationId: gen.generationId,
          identity: identity('a'),
          transportHash: file2.hash,
          audioPath: file2.path,
          byteSize: file2.size,
        ),
        throwsStateError,
      );
    });
  });

  group('findInActive', () {
    test('resolves intel_uid in the active generation', () async {
      final gen = await inv.createStagingGeneration();
      final file = await writeFile('a.mp3', List.filled(500, 5));
      await inv.recordStagedTrack(
        generationId: gen.generationId,
        identity: identity('a'),
        transportHash: file.hash,
        audioPath: file.path,
        byteSize: file.size,
      );
      await inv.verifyGeneration(gen.generationId);
      await inv.activate(gen.generationId);

      final got = await inv.findInActive('intel-a');
      expect(got?.audioPath, file.path);
    });

    test('returns null for intel_uids in retired generations',
        () async {
      // The playback engine binds to findInActive; it must
      // never resolve a track from a retired generation, even
      // if the file still exists on disk.
      final genA = await inv.createStagingGeneration();
      final fileA = await writeFile('a.mp3', List.filled(500, 5));
      await inv.recordStagedTrack(
        generationId: genA.generationId,
        identity: identity('a'),
        transportHash: fileA.hash,
        audioPath: fileA.path,
        byteSize: fileA.size,
      );
      await inv.verifyGeneration(genA.generationId);
      await inv.activate(genA.generationId);

      // A new generation that does NOT include intel-a.
      final genB = await inv.createStagingGeneration();
      final fileB = await writeFile('b.mp3', List.filled(300, 7));
      await inv.recordStagedTrack(
        generationId: genB.generationId,
        identity: identity('b'),
        transportHash: fileB.hash,
        audioPath: fileB.path,
        byteSize: fileB.size,
      );
      await inv.verifyGeneration(genB.generationId);
      await inv.activate(genB.generationId);

      // intel-a's file is still on disk (retired generation
      // wasn't GC'd yet), but it's NOT in the active inventory.
      expect(File(fileA.path).existsSync(), isTrue);
      expect(await inv.findInActive('intel-a'), isNull,
          reason:
              'retired generation entries must NOT resolve through findInActive');
      expect(await inv.findInActive('intel-b'), isNotNull);
    });

    test('null when no generation is active yet', () async {
      // Fresh inventory — no sync ever ran.
      expect(await inv.findInActive('intel-a'), isNull);
    });
  });

  group('garbageCollect (deferred cleanup)', () {
    test('deletes retired generations and their files', () async {
      final genA = await inv.createStagingGeneration();
      final fileA = await writeFile('a.mp3', List.filled(500, 5));
      await inv.recordStagedTrack(
        generationId: genA.generationId,
        identity: identity('a'),
        transportHash: fileA.hash,
        audioPath: fileA.path,
        byteSize: fileA.size,
      );
      await inv.verifyGeneration(genA.generationId);
      await inv.activate(genA.generationId);

      final genB = await inv.createStagingGeneration();
      final fileB = await writeFile('b.mp3', List.filled(300, 7));
      await inv.recordStagedTrack(
        generationId: genB.generationId,
        identity: identity('b'),
        transportHash: fileB.hash,
        audioPath: fileB.path,
        byteSize: fileB.size,
      );
      await inv.verifyGeneration(genB.generationId);
      await inv.activate(genB.generationId);

      // Now retire genA → GC.
      final removed = await inv.garbageCollect();
      expect(removed, [genA.generationId]);
      expect(await inv.findGeneration(genA.generationId), isNull);
      expect(File(fileA.path).existsSync(), isFalse,
          reason: 'GC must delete the retired generation\'s files');
      // Active generation untouched.
      expect(await inv.findGeneration(genB.generationId), isNotNull);
      expect(File(fileB.path).existsSync(), isTrue);
    });

    test('also deletes failed generations + their files', () async {
      // Failed generations are GC-eligible from the moment
      // verification rejects them.
      final gen = await inv.createStagingGeneration();
      final file = await writeFile('bad.mp3', List.filled(500, 5));
      await inv.recordStagedTrack(
        generationId: gen.generationId,
        identity: identity('bad'),
        transportHash: 'mismatch-hash',
        audioPath: file.path,
        byteSize: file.size,
      );
      await inv.verifyGeneration(gen.generationId); // fails
      expect((await inv.findGeneration(gen.generationId))!.status,
          GenerationStatus.failed);
      await inv.garbageCollect();
      expect(await inv.findGeneration(gen.generationId), isNull);
      expect(File(file.path).existsSync(), isFalse);
    });

    test('never touches the currently-active generation', () async {
      final gen = await inv.createStagingGeneration();
      final file = await writeFile('live.mp3', List.filled(500, 5));
      await inv.recordStagedTrack(
        generationId: gen.generationId,
        identity: identity('live'),
        transportHash: file.hash,
        audioPath: file.path,
        byteSize: file.size,
      );
      await inv.verifyGeneration(gen.generationId);
      await inv.activate(gen.generationId);
      final removed = await inv.garbageCollect();
      expect(removed, isEmpty);
      expect(await inv.findGeneration(gen.generationId), isNotNull);
      expect(File(file.path).existsSync(), isTrue);
    });
  });

  group('GenerationStatus wireName round-trip', () {
    test('every status round-trips', () {
      for (final s in GenerationStatus.values) {
        expect(GenerationStatus.fromWire(s.wireName), s);
      }
    });

    test('fromWire throws on unknown', () {
      expect(() => GenerationStatus.fromWire('what'),
          throwsFormatException);
    });
  });
}

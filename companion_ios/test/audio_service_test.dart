// PR2.8.C — AudioService contract tests.
//
// Every property the architecture leans on is asserted here:
//
//   1. Queue stores intel_uids only — never file paths.
//   2. Resolution is late-bound — the audio engine receives the
//      file path that findInActive() yields at the moment of
//      playback, not at queue-build time.
//   3. The currently-playing track survives generation
//      retirement. Until stop or end, the engine keeps reading
//      bytes from the retired generation's file (which lingers
//      until GC).
//   4. Q1 sync-blocking gates new playback + pauses current
//      playback when set, regardless of just_audio state.
//   5. PlaybackSnapshot round-trips through JSON + restores
//      against the current inventory, late-binding the queue
//      against the now-active generation.

import 'dart:io';

import 'package:companion_ios/src/services/audio_service.dart';
import 'package:companion_ios/src/services/inventory_service.dart';
import 'package:companion_ios/src/services/playback_engine.dart';
import 'package:companion_ios/src/services/playback_models.dart';
import 'package:companion_ios/src/services/transport_hash.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_core/shared_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late InventoryService inv;
  late FakePlaybackEngine engine;
  late AudioService audio;
  late Directory tempDir;

  setUp(() async {
    sqfliteFfiInit();
    inv = await InventoryService.open(inMemoryDatabasePath);
    engine = FakePlaybackEngine();
    audio = AudioService(inventory: inv, engine: engine);
    tempDir = await Directory.systemTemp.createTemp('audio_test_');
  });

  tearDown(() async {
    await audio.dispose();
    await inv.close();
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  Future<({String path, String hash, int size})> writeFile(
    String name,
    List<int> bytes,
  ) async {
    final f = File('${tempDir.path}/$name');
    await f.writeAsBytes(bytes);
    return (
      path: f.path,
      hash: await computeTransportHash(f.path),
      size: bytes.length,
    );
  }

  TrackIdentity identity(String name) => TrackIdentity(
        intelUid: 'intel-$name',
        variantId: 'variant-$name',
        contentHash: 'hash-$name',
      );

  /// Stage + verify + activate a generation containing [names]
  /// as eligible tracks. Returns (generationId, paths-by-name).
  Future<({String genId, Map<String, String> paths})> seedActive(
    Iterable<String> names,
  ) async {
    final gen = await inv.createStagingGeneration(manifestVersion: 1);
    final paths = <String, String>{};
    for (final name in names) {
      final file = await writeFile('$name.mp3', List.filled(1000, 7));
      await inv.recordStagedTrack(
        generationId: gen.generationId,
        identity: identity(name),
        transportHash: file.hash,
        audioPath: file.path,
        byteSize: file.size,
      );
      paths[name] = file.path;
    }
    await inv.verifyGeneration(gen.generationId);
    await inv.activate(gen.generationId);
    return (genId: gen.generationId, paths: paths);
  }

  group('queue identity (intel_uid-only)', () {
    test('queue holds intel_uids, not file paths', () async {
      await seedActive(['a', 'b', 'c']);
      await audio.playQueue(intelUids: const [
        'intel-a',
        'intel-b',
        'intel-c',
      ]);
      // The queue strictly contains intel_uid strings — no file
      // paths leaked in from inventory resolution.
      expect(audio.queue.intelUids,
          equals(['intel-a', 'intel-b', 'intel-c']));
      expect(audio.queue.currentIntelUid, 'intel-a');
    });

    test('repeat-play repositions cursor instead of duplicating',
        () async {
      await seedActive(['a', 'b']);
      await audio.playQueue(intelUids: const ['intel-a', 'intel-b']);
      await audio.playIntelUid('intel-b');
      expect(audio.queue.intelUids,
          equals(['intel-a', 'intel-b'])); // queue unchanged
      expect(audio.queue.currentIntelUid, 'intel-b');
    });
  });

  group('late-bound resolution', () {
    test('engine receives the file path from findInActive at play time',
        () async {
      final seed = await seedActive(['a']);
      final ok = await audio.playIntelUid('intel-a');
      expect(ok, isTrue);
      expect(engine.currentSource, seed.paths['a'],
          reason: 'engine source must match findInActive output');
      expect(engine.isPlaying, isTrue);
    });

    test('playIntelUid for an intel_uid NOT in active inventory '
        'leaves the engine alone', () async {
      await seedActive(['a']);
      await audio.playIntelUid('intel-a'); // currently playing a
      expect(engine.isPlaying, isTrue);
      final aPath = engine.currentSource;

      // Try to play something the active generation doesn't hold.
      // Late-binding returns null; engine source MUST NOT change.
      final ok = await audio.playIntelUid('intel-nonexistent');
      expect(ok, isFalse);
      expect(engine.currentSource, aPath,
          reason:
              'engine must not lose its source when late-binding fails');
    });
  });

  group('survives generation retirement (the critical property)', () {
    test('currently-playing track keeps playing after retirement',
        () async {
      // Setup: gen A with intel-a active, playing.
      final seedA = await seedActive(['a']);
      await audio.playIntelUid('intel-a');
      expect(engine.isPlaying, isTrue);
      final originalPath = engine.currentSource;

      // Build + activate a new generation that does NOT include
      // intel-a. Gen A is now retired but its file is still on
      // disk (GC hasn't run).
      await seedActive(['b']);
      expect(File(seedA.paths['a']!).existsSync(), isTrue,
          reason: "retired generation's files must linger until GC");

      // The engine is still playing the original path. The
      // architecture deliberately does NOT yank the rug out
      // from under the current track. User keeps listening.
      expect(engine.isPlaying, isTrue);
      expect(engine.currentSource, originalPath);

      // But next() / playIntelUid('intel-a') would now refuse
      // late-binding for intel-a — it's not in the active
      // generation any more.
      final ok = await audio.playIntelUid('intel-a');
      expect(ok, isFalse,
          reason:
              'NEW play attempts on retired intel_uids must fail '
              'late-binding (the active inventory no longer holds it)');
      // The current track keeps playing despite the refused
      // new play — late-binding for the NEW request failed,
      // and we don't disturb the engine on failure.
      expect(engine.isPlaying, isTrue);
    });
  });

  group('sync-block gate (Q1)', () {
    test('refuses new playback when blocked', () async {
      await seedActive(['a']);
      await audio.setBlockedBySync(true);
      final ok = await audio.playIntelUid('intel-a');
      expect(ok, isFalse);
      expect(engine.isPlaying, isFalse);
      expect(engine.currentSource, isNull,
          reason: 'engine never even loaded the source');
    });

    test('pauses any current playback when set true', () async {
      await seedActive(['a']);
      await audio.playIntelUid('intel-a');
      expect(engine.isPlaying, isTrue);
      await audio.setBlockedBySync(true);
      expect(engine.isPlaying, isFalse,
          reason: 'sync-block must pause active playback');
    });

    test('clears + resume works after unblock', () async {
      await seedActive(['a']);
      await audio.playIntelUid('intel-a');
      await audio.setBlockedBySync(true);
      expect(engine.isPlaying, isFalse);
      await audio.setBlockedBySync(false);
      final ok = await audio.resume();
      expect(ok, isTrue);
      expect(engine.isPlaying, isTrue);
    });

    test('next() / previous() refused while blocked', () async {
      await seedActive(['a', 'b']);
      await audio.playQueue(intelUids: const ['intel-a', 'intel-b']);
      await audio.setBlockedBySync(true);
      final n = await audio.next();
      expect(n, isFalse);
      expect(audio.queue.currentIntelUid, 'intel-a',
          reason: 'queue cursor must not advance while blocked');
    });
  });

  group('next / previous + queue traversal', () {
    test('next advances cursor + late-binds against active', () async {
      final seed = await seedActive(['a', 'b']);
      await audio.playQueue(intelUids: const ['intel-a', 'intel-b']);
      expect(engine.currentSource, seed.paths['a']);
      final advanced = await audio.next();
      expect(advanced, isTrue);
      expect(audio.queue.currentIntelUid, 'intel-b');
      expect(engine.currentSource, seed.paths['b']);
    });

    test('previous moves backward', () async {
      final seed = await seedActive(['a', 'b']);
      await audio.playQueue(
        intelUids: const ['intel-a', 'intel-b'],
        startIndex: 1,
      );
      expect(engine.currentSource, seed.paths['b']);
      final back = await audio.previous();
      expect(back, isTrue);
      expect(audio.queue.currentIntelUid, 'intel-a');
      expect(engine.currentSource, seed.paths['a']);
    });

    test('next at end of queue is a no-op', () async {
      await seedActive(['a']);
      await audio.playQueue(intelUids: const ['intel-a']);
      final advanced = await audio.next();
      expect(advanced, isFalse);
    });
  });

  group('snapshot round-trip', () {
    test('captures intel_uid + generation_id + position', () async {
      final seed = await seedActive(['a', 'b']);
      await audio.playQueue(intelUids: const ['intel-a', 'intel-b']);
      engine.advancePosition(const Duration(seconds: 30));
      final snap = audio.snapshot();
      expect(snap.queueIntelUids, ['intel-a', 'intel-b']);
      expect(snap.currentIntelUid, 'intel-a');
      expect(snap.currentGenerationId, seed.genId);
      expect(snap.currentPosition, const Duration(seconds: 30));
      expect(snap.wasPlaying, isTrue);
    });

    test('toJson + fromJson preserves all fields', () async {
      await seedActive(['a']);
      await audio.playIntelUid('intel-a');
      engine.advancePosition(const Duration(seconds: 12));
      final snap = audio.snapshot();
      final decoded = PlaybackSnapshot.fromJson(snap.toJson());
      expect(decoded.currentIntelUid, snap.currentIntelUid);
      expect(decoded.currentGenerationId, snap.currentGenerationId);
      expect(decoded.currentPosition, snap.currentPosition);
      expect(decoded.wasPlaying, snap.wasPlaying);
      expect(decoded.queueIntelUids, snap.queueIntelUids);
    });

    test('restoreFromSnapshot late-binds against current inventory',
        () async {
      // Take snapshot in gen A.
      final seedA = await seedActive(['a']);
      await audio.playIntelUid('intel-a');
      engine.advancePosition(const Duration(seconds: 45));
      final snap = audio.snapshot();

      // Simulate app death: dispose engine + service, rebuild.
      await audio.dispose();
      // (engine is closed by dispose; build a fresh one)
      engine = FakePlaybackEngine();
      audio = AudioService(inventory: inv, engine: engine);

      // Rotate to gen B that still includes intel-a (under a
      // new file path — different generation).
      final newFile = await writeFile('a-new.mp3', List.filled(1000, 9));
      final genB = await inv.createStagingGeneration();
      await inv.recordStagedTrack(
        generationId: genB.generationId,
        identity: identity('a'),
        transportHash: newFile.hash,
        audioPath: newFile.path,
        byteSize: newFile.size,
      );
      await inv.verifyGeneration(genB.generationId);
      await inv.activate(genB.generationId);

      final restored = await audio.restoreFromSnapshot(snap);
      expect(restored, isTrue);
      expect(engine.currentSource, newFile.path,
          reason: 'restore must late-bind against the NEW active '
              'generation, not the snapshot\'s recorded generation');
      expect(engine.currentPosition, const Duration(seconds: 45));
      expect(audio.currentGenerationId, genB.generationId,
          reason: 'audio service must track the resolved generation, '
              'not the snapshot\'s prior one');
      // sanity: the old path is also still on disk (gen A
      // retired but not GC'd).
      expect(File(seedA.paths['a']!).existsSync(), isTrue);
    });

    test('restoreFromSnapshot returns false when intel_uid retired',
        () async {
      await seedActive(['a']);
      await audio.playIntelUid('intel-a');
      final snap = audio.snapshot();
      // Rotate to a generation that DOESN'T include intel-a.
      await seedActive(['b']);

      // Fresh audio service to mimic post-relaunch.
      await audio.dispose();
      engine = FakePlaybackEngine();
      audio = AudioService(inventory: inv, engine: engine);

      final restored = await audio.restoreFromSnapshot(snap);
      expect(restored, isFalse,
          reason: 'cannot restore a track that was rotated out');
      // Queue is preserved so UI can show "previously playing X — gone now".
      expect(audio.queue.intelUids, ['intel-a']);
      expect(engine.isPlaying, isFalse);
      expect(engine.currentSource, isNull);
    });
  });
}

// PR2.8.C.simulator — playback continuity chaos framework.
//
// Bridges the InventoryService + AudioService layers under
// scenarios that stress the layering boundary. The most
// dangerous unresolved frontier in the companion app is now
// playback behavior across inventory mutation — generation
// swaps mid-pause, retired tracks mid-play, GC during snapshot,
// double rotations between snapshot + restore.
//
// Mirrors the inventory chaos shape: scenarios are immutable
// (seed + drive + invariants), invariants throw on violation
// with operationally-specific reason text, the framework
// captures a snapshot trajectory so failures produce a
// readable replay log.

import 'dart:io';

import 'package:companion_ios/src/services/audio_service.dart';
import 'package:companion_ios/src/services/inventory_service.dart';
import 'package:companion_ios/src/services/playback_engine.dart';
import 'package:companion_ios/src/services/transport_hash.dart';
import 'package:shared_core/shared_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class PlaybackSimulator {
  PlaybackSimulator._({
    required this.inventory,
    required this.engine,
    required this.audio,
    required this.tempDir,
  });

  InventoryService inventory;
  FakePlaybackEngine engine;
  AudioService audio;
  final Directory tempDir;

  /// Per-step engine state captures. Each entry is a string the
  /// formatter can read directly — keeps the timeline cheap to
  /// produce and grep-friendly in failure output.
  final List<String> timeline = [];

  /// Capture a one-line snapshot of the current engine + audio
  /// state. Idempotent — only appends when the string changes.
  void snap(String label) {
    final source = engine.currentSource ?? '<none>';
    final playing = engine.isPlaying ? 'play' : 'pause';
    final intel = audio.queue.currentIntelUid ?? '<none>';
    final entry = '$label: intel=$intel src=${_short(source)} '
        '$playing pos=${engine.currentPosition.inMilliseconds}ms '
        'gen=${_short(audio.currentGenerationId ?? "<none>")}';
    if (timeline.isEmpty || timeline.last != entry) {
      timeline.add(entry);
    }
  }

  static String _short(String s) {
    if (s.length <= 12) return s;
    return '${s.substring(0, 6)}…${s.substring(s.length - 4)}';
  }

  static Future<PlaybackSimulator> bootstrap() async {
    sqfliteFfiInit();
    final tempDir =
        await Directory.systemTemp.createTemp('playback_sim_');
    final inventory =
        await InventoryService.open(inMemoryDatabasePath);
    final engine = FakePlaybackEngine();
    final audio = AudioService(inventory: inventory, engine: engine);
    return PlaybackSimulator._(
      inventory: inventory,
      engine: engine,
      audio: audio,
      tempDir: tempDir,
    );
  }

  Future<void> tearDown() async {
    await audio.dispose();
    await inventory.close();
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  }

  /// Stage + verify + activate a generation containing every
  /// (name → file payload) entry. Returns the generation_id
  /// and a name→path map. Calling this for the same `name`
  /// twice produces a NEW file on disk + a NEW generation
  /// (so scenarios can exercise generation swaps with the same
  /// intel_uid pointing at different bytes).
  Future<({String genId, Map<String, String> paths})> seedActive(
    Map<String, List<int>> tracks,
  ) async {
    final gen = await inventory.createStagingGeneration();
    final paths = <String, String>{};
    for (final entry in tracks.entries) {
      final name = entry.key;
      // Unique filename per generation so multiple staging
      // sessions don't collide on disk.
      final filename = '${gen.generationId.substring(0, 8)}_$name.mp3';
      final f = File('${tempDir.path}/$filename');
      await f.writeAsBytes(entry.value);
      final hash = await computeTransportHash(f.path);
      await inventory.recordStagedTrack(
        generationId: gen.generationId,
        identity: TrackIdentity(
          intelUid: 'intel-$name',
          variantId: 'variant-$name-${gen.generationId.substring(0, 4)}',
          contentHash: 'hash-$name',
        ),
        transportHash: hash,
        audioPath: f.path,
        byteSize: entry.value.length,
      );
      paths[name] = f.path;
    }
    await inventory.verifyGeneration(gen.generationId);
    await inventory.activate(gen.generationId);
    return (genId: gen.generationId, paths: paths);
  }

  /// Run a scenario end-to-end. Catches drive-time exceptions
  /// so the invariants still run + report on the post-failure
  /// world.
  static Future<SimulationResult> run(PlaybackScenario scenario) async {
    final sim = await PlaybackSimulator.bootstrap();
    try {
      await scenario.seed(sim);
      sim.snap('seeded');
      Object? driveError;
      try {
        await scenario.drive(sim);
      } catch (e) {
        driveError = e;
      }
      sim.snap('after-drive');
      final results = <String, String?>{};
      for (final inv in scenario.invariants) {
        try {
          await inv.check(sim);
          results[inv.name] = null;
        } catch (e) {
          results[inv.name] = e.toString();
        }
      }
      return SimulationResult(
        scenarioName: scenario.name,
        timeline: List.unmodifiable(sim.timeline),
        invariants: Map<String, String?>.unmodifiable(results),
        driveError: driveError,
      );
    } finally {
      await sim.tearDown();
    }
  }
}

abstract class PlaybackScenario {
  String get name;
  Future<void> seed(PlaybackSimulator sim) async {}
  Future<void> drive(PlaybackSimulator sim);
  List<PlaybackInvariant> get invariants;
}

abstract class PlaybackInvariant {
  String get name;
  Future<void> check(PlaybackSimulator sim);
}

class SimulationResult {
  final String scenarioName;
  final List<String> timeline;
  final Map<String, String?> invariants;
  final Object? driveError;

  const SimulationResult({
    required this.scenarioName,
    required this.timeline,
    required this.invariants,
    this.driveError,
  });

  bool get allInvariantsPassed =>
      invariants.values.every((v) => v == null);

  String formatReport() {
    final buf = StringBuffer();
    buf.writeln('scenario: $scenarioName');
    if (driveError != null) {
      buf.writeln('drive raised: $driveError');
    }
    buf.writeln('timeline:');
    for (final t in timeline) {
      buf.writeln('  $t');
    }
    buf.writeln('invariants:');
    for (final entry in invariants.entries) {
      final mark = entry.value == null ? '✓' : '✗';
      buf.writeln('  $mark ${entry.key}'
          '${entry.value != null ? ' — ${entry.value}' : ''}');
    }
    return buf.toString();
  }
}

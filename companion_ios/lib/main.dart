import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'src/services/audio_service.dart';
import 'src/services/inventory_service.dart';
import 'src/services/just_audio_playback_engine.dart';
import 'src/services/operational_log.dart';
import 'src/services/playback_engine.dart';
import 'src/widgets/debug_surface.dart';
import 'src/widgets/dev_panel.dart';
import 'src/widgets/timeline_view.dart';

/// MusicTracker iPhone companion — entry point.
///
/// PR2.8.D.1 status: runtime-attached scaffold. The three
/// services are wired together in [_bootstrap]:
///
///   InventoryService (sqflite generations + activation pointer)
///        │
///        ▼ findInActive(intel_uid) → CachedTrack.audioPath
///   AudioService (queue + late-bound resolution + Q1 gate)
///        │
///        ▼ setSource(audioPath) / play / pause
///   JustAudioPlaybackEngine (just_audio + AudioSession.music())
///
/// The bootstrap is intentionally narrow. No pairing UI yet, no
/// sync orchestration, no telemetry queue surface — those layer
/// on top once we've watched the runtime stack survive a real
/// device boot, AudioSession interruption, and a real playback
/// cycle.
///
/// The home screen renders only [DebugSurface] — operational
/// state in a single glance for runtime archaeology while the
/// iOS-specific edges shake out.
void main() {
  runApp(const CompanionApp());
}

class CompanionApp extends StatefulWidget {
  const CompanionApp({super.key});

  @override
  State<CompanionApp> createState() => _CompanionAppState();
}

class _CompanionAppState extends State<CompanionApp>
    with WidgetsBindingObserver {
  late final Future<_Stack> _stackFuture;
  String? _timelinePath;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _stackFuture = _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Flush the operational timeline whenever the app is
  /// leaving the foreground. iOS routinely terminates suspended
  /// apps to reclaim memory; persisting here is what makes
  /// post-crash forensics possible. Hard kills bypass this — a
  /// periodic/critical-event flush is known future work.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.inactive) {
      final path = _timelinePath;
      if (path != null) {
        unawaited(_safeFlush(path, state));
      }
    }
  }

  Future<void> _safeFlush(String path, AppLifecycleState state) async {
    try {
      await OperationalLog.persistTo(path);
      OperationalLog.emit('boot',
          'timeline flushed (lifecycle=${state.name})');
    } catch (e) {
      OperationalLog.emit('boot', 'timeline flush FAILED: $e');
    }
  }

  Future<_Stack> _bootstrap() async {
    WidgetsFlutterBinding.ensureInitialized();
    final docs = await getApplicationDocumentsDirectory();
    final dbPath = '${docs.path}${Platform.pathSeparator}companion_inventory.db';
    final toneFilesDir =
        '${docs.path}${Platform.pathSeparator}inventory_files';
    final timelinePath =
        '${docs.path}${Platform.pathSeparator}timeline.jsonl';
    await Directory(toneFilesDir).create(recursive: true);

    // Restore prior-session timeline FIRST so the boot rows
    // narrate alongside whatever survived the last run.
    await OperationalLog.restoreFrom(timelinePath);
    _timelinePath = timelinePath;

    OperationalLog.boundary('app launch');
    OperationalLog.emit('boot', 'inventory db → $dbPath');
    OperationalLog.emit('boot', 'tone-files dir → $toneFilesDir');
    OperationalLog.emit('boot', 'timeline jsonl → $timelinePath');

    // Orphan-sweep on boot: any staging generation older than
    // five minutes is collateral damage from a previous crash or
    // OS-termination. Mark it for GC before the runtime starts
    // accepting work.
    final inventory = await InventoryService.open(dbPath);
    final orphaned = await inventory.markStaleStagingAsOrphaned();
    if (orphaned.isNotEmpty) {
      OperationalLog.emit('boot',
          'orphaned ${orphaned.length} stale staging gen(s)');
    }

    final engine = JustAudioPlaybackEngine();
    final audio = AudioService(inventory: inventory, engine: engine);
    OperationalLog.emit('boot',
        'stack ready '
        '(${Platform.operatingSystem}/${Platform.operatingSystemVersion})');

    return _Stack(
      inventory: inventory,
      engine: engine,
      audio: audio,
      toneFilesDir: toneFilesDir,
      timelinePath: timelinePath,
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MusicTracker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0A0A0D),
      ),
      home: FutureBuilder<_Stack>(
        future: _stackFuture,
        builder: (_, snap) {
          if (snap.hasError) {
            return _BootError(error: snap.error!);
          }
          final stack = snap.data;
          if (stack == null) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          return _DebugHome(stack: stack);
        },
      ),
    );
  }
}

class _Stack {
  _Stack({
    required this.inventory,
    required this.engine,
    required this.audio,
    required this.toneFilesDir,
    required this.timelinePath,
  });

  final InventoryService inventory;
  final PlaybackEngine engine;
  final AudioService audio;
  final String toneFilesDir;
  final String timelinePath;
}

class _DebugHome extends StatefulWidget {
  const _DebugHome({required this.stack});

  final _Stack stack;

  @override
  State<_DebugHome> createState() => _DebugHomeState();
}

class _DebugHomeState extends State<_DebugHome> {
  /// Bumped after dev-panel mutations to nudge DebugSurface +
  /// any other polled views to refresh earlier than the next
  /// tick. Cheap because every key listenable in the stack is
  /// push-driven; this is for the inventory-poll row only.
  Key _surfaceKey = UniqueKey();

  void _onDevMutation() {
    if (!mounted) return;
    setState(() => _surfaceKey = UniqueKey());
  }

  @override
  Widget build(BuildContext context) {
    final stack = widget.stack;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0D),
        elevation: 0,
        title: const Text(
          'MusicTracker',
          style: TextStyle(
            color: Color(0xFFF2F2F7),
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DebugSurface(
                key: _surfaceKey,
                audio: stack.audio,
                inventory: stack.inventory,
                engine: stack.engine,
              ),
              const SizedBox(height: 12),
              DevPanel(
                audio: stack.audio,
                inventory: stack.inventory,
                toneFilesDir: stack.toneFilesDir,
                onMutated: _onDevMutation,
              ),
              const SizedBox(height: 12),
              const TimelineView(),
            ],
          ),
        ),
      ),
    );
  }
}

class _BootError extends StatelessWidget {
  const _BootError({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(
            'Boot failed:\n$error',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFFFF5250),
              fontFamily: 'Menlo',
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }
}

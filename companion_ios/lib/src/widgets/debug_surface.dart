import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/audio_service.dart';
import '../services/inventory_models.dart';
import '../services/inventory_service.dart';
import '../services/playback_engine.dart';
import '../services/playback_models.dart';

/// Operational visibility surface — ugly on purpose, dense on
/// purpose. PR2.8.D.1 brings the runtime up against a real iOS
/// device for the first time; the moment something behaves
/// surprisingly, the answer needs to be one glance away rather
/// than scattered across log lines.
///
/// Renders the five things that explain most of what's happening:
///   • paired status (do we even have a token?)
///   • active generation_id + manifest_version
///   • queue size + current intel_uid + cursor index
///   • engine playing/paused state
///   • last sync state (caller-driven [ValueListenable<String>])
///
/// Polls [InventoryService.currentActiveGeneration] every 2s
/// (cheap; sqlite single-row read). Everything else is push.
class DebugSurface extends StatefulWidget {
  const DebugSurface({
    super.key,
    required this.audio,
    required this.inventory,
    required this.engine,
    this.paired,
    this.lastSyncState,
    this.pollInterval = const Duration(seconds: 2),
  });

  final AudioService audio;
  final InventoryService inventory;
  final PlaybackEngine engine;

  /// Optional. `true` after pairing has produced a token.
  /// Callers that don't track pairing yet can omit — the surface
  /// renders "(unwired)".
  final ValueListenable<bool>? paired;

  /// Optional. Most recent sync-state label ("idle", "negotiating
  /// 192.168.1.42", "rotation complete", "transfer failed: …").
  final ValueListenable<String>? lastSyncState;

  final Duration pollInterval;

  @override
  State<DebugSurface> createState() => _DebugSurfaceState();
}

class _DebugSurfaceState extends State<DebugSurface> {
  Generation? _activeGen;
  Object? _genError;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _refreshActiveGeneration();
    _poll = Timer.periodic(
      widget.pollInterval,
      (_) => _refreshActiveGeneration(),
    );
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refreshActiveGeneration() async {
    try {
      final gen = await widget.inventory.currentActiveGeneration();
      if (!mounted) return;
      setState(() {
        _activeGen = gen;
        _genError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _genError = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF14161A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2A2D36)),
      ),
      child: DefaultTextStyle(
        style: const TextStyle(
          color: Color(0xFFF2F2F7),
          fontFamily: 'Menlo',
          fontSize: 12,
          height: 1.5,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'DEBUG / OPERATIONAL',
              style: TextStyle(
                color: Color(0xFFA1A1AA),
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 8),
            _pairedRow(),
            _activeGenRow(),
            _resolvedGenRow(),
            _queueRow(),
            _engineRow(),
            _enginePathRow(),
            _syncStateRow(),
          ],
        ),
      ),
    );
  }

  Widget _pairedRow() {
    final paired = widget.paired;
    if (paired == null) {
      return const _Line(label: 'paired', value: '(unwired)');
    }
    return ValueListenableBuilder<bool>(
      valueListenable: paired,
      builder: (_, v, _) => _Line(
        label: 'paired',
        value: v ? 'yes' : 'no',
        tone: v ? _Tone.ok : _Tone.warn,
      ),
    );
  }

  Widget _activeGenRow() {
    if (_genError != null) {
      return _Line(
        label: 'active gen',
        value: 'ERR: $_genError',
        tone: _Tone.err,
      );
    }
    final gen = _activeGen;
    if (gen == null) {
      return const _Line(label: 'active gen', value: '<none>');
    }
    return _Line(
      label: 'active gen',
      value: '${_short(gen.generationId)} '
          'mv=${gen.manifestVersion ?? "-"} '
          'st=${gen.status.wireName}',
      tone: _Tone.ok,
    );
  }

  /// Cross-layer continuity row: the generation_id AudioService
  /// resolved against at last setSource. Differs from
  /// [_activeGenRow] (inventory truth) the moment a rotation
  /// happens mid-playback — that gap IS the retirement-survival
  /// rule in action.
  Widget _resolvedGenRow() {
    return ValueListenableBuilder<PlaybackQueue>(
      valueListenable: widget.audio.queueListenable,
      builder: (_, _, _) {
        final resolved = widget.audio.currentGenerationId;
        return _Line(
          label: 'resolved gen',
          value: resolved == null ? '<none>' : _short(resolved),
          tone: resolved == null ? _Tone.muted : _Tone.ok,
        );
      },
    );
  }

  /// Executor truth: the audio_path the engine is bound to.
  /// Differs from `resolved gen` only across a setSource call.
  Widget _enginePathRow() {
    return ValueListenableBuilder<PlaybackQueue>(
      valueListenable: widget.audio.queueListenable,
      builder: (_, _, _) {
        final path = widget.audio.currentAudioPath;
        if (path == null) {
          return const _Line(label: 'engine src', value: '<none>');
        }
        final name = path.split(Platform.pathSeparator).last;
        return _Line(
          label: 'engine src',
          value: name,
          tone: _Tone.ok,
        );
      },
    );
  }

  Widget _queueRow() {
    return ValueListenableBuilder<PlaybackQueue>(
      valueListenable: widget.audio.queueListenable,
      builder: (_, q, _) {
        final cur = q.currentIntelUid;
        final idx = q.currentIndex;
        final size = q.intelUids.length;
        return _Line(
          label: 'queue',
          value: size == 0
              ? '<empty>'
              : 'size=$size idx=${idx ?? "-"} '
                  'cur=${cur == null ? "-" : _short(cur)}',
          tone: size == 0 ? _Tone.muted : _Tone.ok,
        );
      },
    );
  }

  Widget _engineRow() {
    return StreamBuilder<bool>(
      stream: widget.engine.playingStream,
      initialData: widget.engine.isPlaying,
      builder: (_, snap) {
        final playing = snap.data ?? false;
        final pos = widget.engine.currentPosition;
        final blocked = widget.audio.blockedBySync;
        return _Line(
          label: 'engine',
          value: '${playing ? "playing" : "paused"} '
              '${_fmtPos(pos)}'
              '${blocked ? " (sync-blocked)" : ""}',
          tone: blocked
              ? _Tone.warn
              : playing
                  ? _Tone.ok
                  : _Tone.muted,
        );
      },
    );
  }

  Widget _syncStateRow() {
    final s = widget.lastSyncState;
    if (s == null) {
      return const _Line(label: 'sync', value: '(unwired)');
    }
    return ValueListenableBuilder<String>(
      valueListenable: s,
      builder: (_, v, _) => _Line(label: 'sync', value: v),
    );
  }

  static String _short(String id) =>
      id.length <= 8 ? id : id.substring(0, 8);

  static String _fmtPos(Duration d) {
    final mm = d.inMinutes.toString().padLeft(2, '0');
    final ss = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }
}

enum _Tone { ok, warn, err, muted }

class _Line extends StatelessWidget {
  const _Line({
    required this.label,
    required this.value,
    this.tone = _Tone.muted,
  });

  final String label;
  final String value;
  final _Tone tone;

  @override
  Widget build(BuildContext context) {
    Color color;
    switch (tone) {
      case _Tone.ok:
        color = const Color(0xFF4CAF50);
        break;
      case _Tone.warn:
        color = const Color(0xFFFFB300);
        break;
      case _Tone.err:
        color = const Color(0xFFFF5250);
        break;
      case _Tone.muted:
        color = const Color(0xFFA1A1AA);
        break;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: const TextStyle(color: Color(0xFF7D7D85)),
            ),
          ),
          Expanded(
            child: Text(value, style: TextStyle(color: color)),
          ),
        ],
      ),
    );
  }
}

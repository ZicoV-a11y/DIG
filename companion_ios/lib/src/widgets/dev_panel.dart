import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:shared_core/shared_core.dart';

import '../services/audio_service.dart';
import '../services/dev_sample_audio.dart';
import '../services/inventory_service.dart';
import '../services/operational_log.dart';
import '../services/transport_hash.dart';

/// PR2.8.D.2 developer command surface — drives the runtime
/// stack from on-device taps without networking, pairing, or
/// telemetry plumbing.
///
/// Every button routes through the same public API a future UI
/// would use:
///
///   - "Load tone gen" stages a generation via
///     [InventoryService.createStagingGeneration] /
///     [recordStagedTrack] / [verifyGeneration] / [activate].
///   - "Play first" routes through [AudioService.playIntelUid]
///     against the **first** intel_uid in the current active
///     inventory. NEVER reaches into the engine directly.
///   - "Pause / Resume / Next / Stop" route through
///     [AudioService] semantic methods.
///   - "Sync-block toggle" flips [AudioService.setBlockedBySync]
///     so the Q1 contract can be exercised without a real
///     sync session.
///
/// The retirement-survival + late-bind-on-resume contracts are
/// observable by tapping in this order:
///
///   1. Load tone A   (intel-a + intel-b → 440Hz files)
///   2. Play first    (engine plays 440Hz from intel-a)
///   3. Load tone B   (same intel_uids → 880Hz files, gen-a retires)
///   4. Engine STILL plays 440Hz — retirement-survival.
///   5. Pause; Resume → late-binds; now 880Hz at preserved position.
///   6. Stop; Play first → fresh resolve, 880Hz from intel-a.
class DevPanel extends StatefulWidget {
  const DevPanel({
    super.key,
    required this.audio,
    required this.inventory,
    required this.toneFilesDir,
    this.onMutated,
  });

  final AudioService audio;
  final InventoryService inventory;

  /// Directory where synthesized tone WAVs land. Caller
  /// creates this; the panel writes files inside it.
  final String toneFilesDir;

  /// Optional. Called after any inventory mutation completes so
  /// the DebugSurface can refresh its polled-state row early
  /// instead of waiting for the next 2s tick.
  final VoidCallback? onMutated;

  @override
  State<DevPanel> createState() => _DevPanelState();
}

class _DevPanelState extends State<DevPanel> {
  bool _busy = false;

  Future<void> _run(String label, Future<void> Function() work) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await work();
    } catch (e, st) {
      OperationalLog.emit('dev', '$label FAILED: $e');
      debugPrintStack(stackTrace: st, label: 'DevPanel');
    } finally {
      if (mounted) setState(() => _busy = false);
      widget.onMutated?.call();
    }
  }

  Future<void> _loadToneGen(TonePreset preset) async {
    await _run('load gen ${preset.label}', () async {
      // Two tracks per generation so next/prev work end-to-end.
      const intelUids = ['dev-track-a', 'dev-track-b'];

      final gen = await widget.inventory.createStagingGeneration();
      final genDir = Directory(
        '${widget.toneFilesDir}${Platform.pathSeparator}${gen.generationId}',
      );
      await genDir.create(recursive: true);

      for (final uid in intelUids) {
        final filePath =
            '${genDir.path}${Platform.pathSeparator}$uid.wav';
        await DevSampleAudio.writeSineWav(
          path: filePath,
          frequencyHz: preset.frequencyHz,
        );
        final hash = await computeTransportHash(filePath);
        final bytes = await File(filePath).length();
        final identity = TrackIdentity(
          intelUid: uid,
          variantId: '$uid-wav',
          contentHash:
              sha256.convert(uid.codeUnits).toString().substring(0, 32),
        );
        await widget.inventory.recordStagedTrack(
          generationId: gen.generationId,
          identity: identity,
          transportHash: hash,
          audioPath: filePath,
          byteSize: bytes,
        );
      }

      final ok = await widget.inventory.verifyGeneration(gen.generationId);
      if (!ok) {
        OperationalLog.emit('dev',
            'gen ${gen.generationId} verify failed — not activating');
        return;
      }
      await widget.inventory.activate(gen.generationId);
      OperationalLog.emit('dev',
          'activated gen with preset ${preset.label}');
    });
  }

  Future<void> _playFirst() async {
    await _run('play first', () async {
      final inv = await widget.inventory.currentInventory();
      if (inv.isEmpty) {
        OperationalLog.emit('dev', 'play first refused — no active inventory');
        return;
      }
      await widget.audio.playIntelUid(inv.first.identity.intelUid);
    });
  }

  Future<void> _toggleSyncBlock() async {
    await _run('sync-block toggle', () async {
      await widget.audio.setBlockedBySync(!widget.audio.blockedBySync);
    });
  }

  @override
  Widget build(BuildContext context) {
    final blocked = widget.audio.blockedBySync;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF14161A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2A2D36)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'DEV PANEL',
            style: TextStyle(
              color: Color(0xFFA1A1AA),
              fontWeight: FontWeight.bold,
              fontSize: 11,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 8),
          _SectionLabel('Inventory'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final preset in DevSampleAudio.presets)
                _DevButton(
                  label: 'Load gen ${preset.label}',
                  busy: _busy,
                  onTap: () => _loadToneGen(preset),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _SectionLabel('Playback'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _DevButton(
                label: 'Play first',
                busy: _busy,
                onTap: _playFirst,
              ),
              _DevButton(
                label: 'Pause',
                busy: _busy,
                onTap: () => _run('pause', widget.audio.pause),
              ),
              _DevButton(
                label: 'Resume',
                busy: _busy,
                onTap: () => _run('resume', () async {
                  await widget.audio.resume();
                }),
              ),
              _DevButton(
                label: 'Next',
                busy: _busy,
                onTap: () => _run('next', () async {
                  await widget.audio.next();
                }),
              ),
              _DevButton(
                label: 'Prev',
                busy: _busy,
                onTap: () => _run('previous', () async {
                  await widget.audio.previous();
                }),
              ),
              _DevButton(
                label: 'Stop',
                busy: _busy,
                onTap: () => _run('stop', widget.audio.stop),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _SectionLabel('Q1 sync-block gate'),
          _DevButton(
            label: blocked ? 'Release sync-block' : 'Engage sync-block',
            busy: _busy,
            tone: blocked ? _ButtonTone.warn : _ButtonTone.normal,
            onTap: _toggleSyncBlock,
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFF7D7D85),
          fontFamily: 'Menlo',
          fontSize: 11,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

enum _ButtonTone { normal, warn }

class _DevButton extends StatelessWidget {
  const _DevButton({
    required this.label,
    required this.busy,
    required this.onTap,
    this.tone = _ButtonTone.normal,
  });

  final String label;
  final bool busy;
  final VoidCallback onTap;
  final _ButtonTone tone;

  @override
  Widget build(BuildContext context) {
    Color bg;
    switch (tone) {
      case _ButtonTone.warn:
        bg = const Color(0xFFFFB300);
        break;
      case _ButtonTone.normal:
        bg = const Color(0xFF1C1F26);
        break;
    }
    return Opacity(
      opacity: busy ? 0.5 : 1.0,
      child: GestureDetector(
        onTap: busy ? null : onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF2A2D36)),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: tone == _ButtonTone.warn
                  ? Colors.black
                  : const Color(0xFFF2F2F7),
              fontFamily: 'Menlo',
              fontSize: 12,
            ),
          ),
        ),
      ),
    );
  }
}

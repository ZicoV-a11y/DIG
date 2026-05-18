import 'package:flutter/material.dart';
import 'package:shared_core/shared_core.dart';

import '../state/library_controller.dart';
import '../theme/app_theme.dart';

/// **Observational** floating sync window — the live reflection
/// of the conductor's active SyncSession. Per PR2.6.D guidance:
///
///   - NEVER modal or blocking. The user can keep browsing while
///     a sync runs.
///   - Deterministic progress only. Exact counts + exact bytes.
///     No fake percentages, no fake time estimates, no spinner-
///     driven optimism.
///   - Three operational sections (Transfer / Telemetry /
///     Rotation) stay visually separated. The user already
///     mentally separates "data moved" from "library reconciled."
///   - Failures narrate phase-specific reasons. "Transfer
///     interrupted: 3 tracks unavailable" — not "Sync failed."
///   - Hidden when the orchestrator has no active session. No
///     idle placeholder.
///
/// Binds to `controller.syncOrchestrator?.activeSessionListenable`.
/// When the orchestrator clears the session (terminal-state
/// dismiss timer fires elsewhere), this widget renders nothing.
class SyncProgressWindow extends StatelessWidget {
  final LibraryController controller;

  /// Called when the user taps Cancel during a cancellable
  /// phase. Optional — when null, the cancel button is hidden
  /// even on cancellable states. Wired from the host (typically
  /// a controller method that talks to the orchestrator + phone
  /// to abort cleanly).
  final ValueChanged<SyncSession>? onCancel;

  const SyncProgressWindow({
    super.key,
    required this.controller,
    this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final orchestrator = controller.syncOrchestrator;
    if (orchestrator == null) return const SizedBox.shrink();
    return ValueListenableBuilder<SyncSession?>(
      valueListenable: orchestrator.activeSessionListenable,
      builder: (context, session, _) {
        if (session == null) return const SizedBox.shrink();
        return _SyncWindowCard(
          session: session,
          deviceName: _deviceNameFor(session.deviceId),
          onCancel: onCancel,
        );
      },
    );
  }

  String _deviceNameFor(String deviceId) {
    final paired = controller.pairedDevicesListenable.value;
    for (final d in paired) {
      if (d.device.deviceId == deviceId) return d.device.friendlyName;
    }
    return deviceId;
  }
}

class _SyncWindowCard extends StatelessWidget {
  final SyncSession session;
  final String deviceName;
  final ValueChanged<SyncSession>? onCancel;

  const _SyncWindowCard({
    required this.session,
    required this.deviceName,
    this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final canCancel = onCancel != null &&
        isCancellableSyncState(session.currentState);
    final isFailure = session.completedAt != null && !session.isSuccessful;

    return Container(
      width: 320,
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _Header(
            deviceName: deviceName,
            canCancel: canCancel,
            onCancel:
                canCancel ? () => onCancel?.call(session) : null,
          ),
          const Divider(height: 1, color: AppColors.border),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                _PhaseNarration(session: session),
                if (isFailure) ...[
                  const SizedBox(height: 10),
                  _FailureNarration(session: session),
                ],
                const SizedBox(height: 14),
                _Section(
                  title: 'TRANSFER',
                  children: _transferLines(session),
                ),
                const SizedBox(height: 12),
                _Section(
                  title: 'TELEMETRY',
                  children: _telemetryLines(session),
                ),
                const SizedBox(height: 12),
                _Section(
                  title: 'ROTATION',
                  children: _rotationLines(session),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<String> _transferLines(SyncSession s) {
    return [
      '${_formatBytes(s.bytesTransferred)} transferred',
      '${s.tracksAdded} added · ${s.tracksRemoved} removed',
    ];
  }

  List<String> _telemetryLines(SyncSession s) {
    final lines = <String>[
      '${s.telemetryApplied} applied',
    ];
    if (s.telemetryDeduped > 0) {
      lines.add('${s.telemetryDeduped} deduped');
    }
    if (s.telemetrySkipped > 0) {
      lines.add('${s.telemetrySkipped} skipped');
    }
    if (s.telemetryClockClamped > 0) {
      lines.add('${s.telemetryClockClamped} clock adjusted');
    }
    return lines;
  }

  List<String> _rotationLines(SyncSession s) {
    // Mirrors the manifest diff numerics so the user sees the
    // same shape on both sides of the sync.
    return [
      '${s.tracksAdded} added',
      '${s.tracksRemoved} removed',
    ];
  }

  static String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '$bytes B';
  }
}

class _Header extends StatelessWidget {
  final String deviceName;
  final bool canCancel;
  final VoidCallback? onCancel;
  const _Header({
    required this.deviceName,
    required this.canCancel,
    this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Review Sync — $deviceName',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (canCancel)
            Tooltip(
              message: 'Cancel sync',
              waitDuration: const Duration(milliseconds: 400),
              child: InkWell(
                onTap: onCancel,
                hoverColor: AppColors.hoverRow,
                child: const SizedBox(
                  width: 24,
                  height: 24,
                  child: Icon(
                    Icons.close_rounded,
                    size: 14,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PhaseNarration extends StatelessWidget {
  final SyncSession session;
  const _PhaseNarration({required this.session});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _phaseLabel(session.currentState),
          style: const TextStyle(
            fontSize: 13,
            color: AppColors.textPrimary,
            height: 1.3,
          ),
        ),
        // Deterministic progress bar — only when there's a real
        // numerator the user can verify against. Transferring is
        // the only phase with track-level granularity in Slice 1;
        // other phases get a calm indeterminate bar (still
        // honest: a single light tone, no fake animation).
        if (session.currentState == SyncState.transferring &&
            session.tracksAdded + session.tracksRemoved > 0) ...[
          const SizedBox(height: 8),
          _DeterministicProgressBar(
            value: session.tracksAdded /
                (session.tracksAdded + session.tracksRemoved).clamp(1, 1 << 30),
          ),
        ],
      ],
    );
  }

  static String _phaseLabel(SyncState s) {
    switch (s) {
      case SyncState.idle:
        return 'Idle';
      case SyncState.negotiating:
        return 'Connecting…';
      case SyncState.approving:
        return 'Waiting for approval…';
      case SyncState.preparingManifest:
        return 'Preparing review crate…';
      case SyncState.preparingTransports:
        return 'Generating mobile copies…';
      case SyncState.transferring:
        return 'Uploading tracks…';
      case SyncState.receivingTelemetry:
        return 'Receiving playback history…';
      case SyncState.applyingTelemetry:
        return 'Applying to library…';
      case SyncState.finalizingRotation:
        return 'Finalizing rotation…';
      case SyncState.rotationComplete:
        return 'Rotation complete.';
      case SyncState.approvalDeclined:
        return 'Sync declined.';
      case SyncState.transferFailed:
        return 'Transfer interrupted.';
      case SyncState.networkLost:
        return 'Connection lost.';
    }
  }
}

class _DeterministicProgressBar extends StatelessWidget {
  final double value; // 0.0–1.0
  const _DeterministicProgressBar({required this.value});

  @override
  Widget build(BuildContext context) {
    final clamped = value.clamp(0.0, 1.0).toDouble();
    return SizedBox(
      height: 4,
      child: LinearProgressIndicator(
        value: clamped,
        backgroundColor: AppColors.surfaceAlt,
        valueColor: const AlwaysStoppedAnimation(AppColors.accent),
      ),
    );
  }
}

class _FailureNarration extends StatelessWidget {
  final SyncSession session;
  const _FailureNarration({required this.session});

  @override
  Widget build(BuildContext context) {
    final reason = session.failureReason;
    // Phase-specific narration: prefer the granular failure
    // code's wire name, fall back to the SyncState label. Reason
    // text (if present) gets a second line — operational
    // specificity matters more than brevity here.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _humanFailure(session),
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.favorite,
            ),
          ),
          if (reason != null && reason.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              reason,
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.textSecondary,
                height: 1.3,
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _humanFailure(SyncSession s) {
    final code = s.failureState;
    if (code == null) return 'Sync interrupted';
    switch (code) {
      case 'transfer_failed':
        return 'Transfer interrupted';
      case 'telemetry_failed':
        return 'Playback history reconciliation failed';
      case 'manifest_invalid':
        return 'Manifest version mismatch';
      case 'authorization_failed':
        return 'Device authorization rejected';
      case 'device_unreachable':
        return 'Device left the network';
      case 'inventory_conflict':
        return 'Inventory conflict — manual review needed';
      case 'approval_declined':
        return 'Sync declined';
      case 'network_lost':
        return 'Connection lost';
      default:
        return code.replaceAll('_', ' ');
    }
  }
}

class _Section extends StatelessWidget {
  final String title;
  final List<String> children;
  const _Section({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
            color: AppColors.textTertiary,
          ),
        ),
        const SizedBox(height: 4),
        for (final line in children)
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Text(
              '• $line',
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
                height: 1.35,
              ),
            ),
          ),
      ],
    );
  }
}

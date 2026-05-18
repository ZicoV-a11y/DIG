import 'package:shared_core/shared_core.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// **Archival**, not ephemeral. The operational memory layer
/// per PR2.6.D guidance — the user-facing record of the last
/// completed sync, suitable for the sidebar Devices panel's
/// expanded view or a dedicated history surface.
///
/// Takes a [SyncSession] directly (not a controller) so it can
/// render any historical session, not just the most recent.
/// The caller is responsible for fetching the row (e.g., via
/// `SyncSessionStore.lastCompletedForDevice`).
///
/// Failure sessions render a different headline + the granular
/// failure code's narration instead of the success counters.
/// Either way, the card stays compact + scannable.
class LastSyncSummaryCard extends StatelessWidget {
  final SyncSession session;
  final DateTime Function()? now;

  const LastSyncSummaryCard({
    super.key,
    required this.session,
    this.now,
  });

  @override
  Widget build(BuildContext context) {
    final completedAt = session.completedAt;
    if (completedAt == null) {
      // Active sessions don't belong here; the floating
      // SyncProgressWindow owns live state.
      return const SizedBox.shrink();
    }
    final completed = DateTime.fromMillisecondsSinceEpoch(completedAt);
    final clock = now ?? DateTime.now;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Text(
                'LAST SYNC',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2,
                  color: AppColors.textTertiary,
                ),
              ),
              const Spacer(),
              Text(
                _humanTimestamp(completed, clock()),
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textTertiary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (session.isSuccessful)
            _SuccessBody(session: session)
          else
            _FailureBody(session: session),
        ],
      ),
    );
  }

  static String _humanTimestamp(DateTime when, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final whenDay = DateTime(when.year, when.month, when.day);
    final isSameDay = today == whenDay;
    final hour = when.hour.toString().padLeft(2, '0');
    final minute = when.minute.toString().padLeft(2, '0');
    if (isSameDay) return 'Today · $hour:$minute';
    final yesterday = today.subtract(const Duration(days: 1));
    if (whenDay == yesterday) return 'Yesterday · $hour:$minute';
    return '${when.year}-${when.month.toString().padLeft(2, '0')}-'
        '${when.day.toString().padLeft(2, '0')} · $hour:$minute';
  }
}

class _SuccessBody extends StatelessWidget {
  final SyncSession session;
  const _SuccessBody({required this.session});

  @override
  Widget build(BuildContext context) {
    final lines = <String>[
      '${session.tracksAdded} added · ${session.tracksRemoved} removed',
      if (session.telemetryApplied > 0 ||
          session.telemetryDeduped > 0 ||
          session.telemetryClockClamped > 0)
        _telemetryLine(session),
      'Duration: ${_durationLabel(session)}',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              line,
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

  static String _telemetryLine(SyncSession s) {
    final parts = <String>[];
    if (s.telemetryApplied > 0) {
      parts.add('${s.telemetryApplied} telemetry events');
    }
    if (s.telemetryDeduped > 0) {
      parts.add('${s.telemetryDeduped} deduped');
    }
    if (s.telemetryClockClamped > 0) {
      parts.add('${s.telemetryClockClamped} clock adjusted');
    }
    return parts.join(' · ');
  }

  static String _durationLabel(SyncSession s) {
    final completed = s.completedAt;
    if (completed == null) return '—';
    final delta =
        Duration(milliseconds: completed - s.startedAt);
    if (delta.inMinutes >= 1) {
      final m = delta.inMinutes;
      final sec = delta.inSeconds.remainder(60);
      return '${m}m ${sec}s';
    }
    return '${delta.inSeconds}s';
  }
}

class _FailureBody extends StatelessWidget {
  final SyncSession session;
  const _FailureBody({required this.session});

  @override
  Widget build(BuildContext context) {
    final code = session.failureState ?? 'unknown';
    final reason = session.failureReason;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _humanFailure(code),
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppColors.favorite,
          ),
        ),
        if (reason != null && reason.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              reason,
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.textSecondary,
                height: 1.35,
              ),
            ),
          ),
      ],
    );
  }

  static String _humanFailure(String code) {
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
        return 'Inventory conflict';
      case 'approval_declined':
        return 'Sync declined';
      case 'network_lost':
        return 'Connection lost';
      default:
        return code.replaceAll('_', ' ');
    }
  }
}

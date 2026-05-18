import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_core/shared_core.dart';

import '../state/library_controller.dart';
import '../theme/app_theme.dart';

/// **Operational dock** for the desktop sidebar — NOT an account
/// or device browser. Renders paired companion phones as a
/// compact list keyed off the canonical
/// [DeviceOperationalState] from `shared_core`:
///
///     DEVICES
///     ● Zico iPhone
///       Available for sync
///       87 tracks · 4.8 GB
///       Last sync: 12m ago
///
/// Bound to [LibraryController.pairedDevicesListenable]; the
/// controller pre-computes derived state so this widget never
/// has to. Refreshes on a 5-second timer to keep the heartbeat-
/// derived `online → stale` transition fresh without burning
/// CPU on tighter polling.
///
/// Color philosophy (operational neutrality):
///   - online                → calm accent dot
///   - syncing               → bright accent ring (active)
///   - availableForSync      → calm accent dot
///   - awaitingApproval      → favorite (amber, muted warning)
///   - stale                 → text-tertiary dot (dimmed)
///   - offline               → text-tertiary (further dimmed)
///   - failure (deferred PR2.6.C — sync-summary card)
///
/// "No paired devices" state renders as a single line of muted
/// guidance pointing at the (future) pairing flow.
class MobileDevicesPanel extends StatefulWidget {
  final LibraryController controller;
  final Duration refreshInterval;
  const MobileDevicesPanel({
    super.key,
    required this.controller,
    this.refreshInterval = const Duration(seconds: 5),
  });

  @override
  State<MobileDevicesPanel> createState() => _MobileDevicesPanelState();
}

class _MobileDevicesPanelState extends State<MobileDevicesPanel> {
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    // Fire-and-forget initial load; the controller's listenable
    // will rebuild this widget when results land.
    unawaited(widget.controller.refreshPairedDevices());
    _refreshTimer = Timer.periodic(
      widget.refreshInterval,
      (_) => widget.controller.refreshPairedDevices(),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<DeviceWithState>>(
      valueListenable: widget.controller.pairedDevicesListenable,
      builder: (context, devices, _) {
        return Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: 12, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const _SectionHeader(label: 'DEVICES'),
              const SizedBox(height: 6),
              if (devices.isEmpty)
                const _EmptyState()
              else
                for (final d in devices) ...[
                  _DeviceRow(entry: d),
                  const SizedBox(height: 6),
                ],
            ],
          ),
        );
      },
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.2,
        color: AppColors.textTertiary,
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 4),
      child: Text(
        'No paired devices.',
        style: TextStyle(
          fontSize: 12,
          color: AppColors.textTertiary,
        ),
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  final DeviceWithState entry;
  const _DeviceRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    final state = entry.state;
    final isMuted = state == DeviceOperationalState.stale ||
        state == DeviceOperationalState.offline;
    final nameColor =
        isMuted ? AppColors.textSecondary : AppColors.textPrimary;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StatusGlyph(state: state),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                entry.device.friendlyName,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: nameColor,
                  height: 1.2,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 1),
              Text(
                _stateLabel(state),
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textSecondary,
                  height: 1.2,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 1),
              Text(
                _capacityLine(entry.device.capacity),
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textTertiary,
                  height: 1.2,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              if (entry.device.lastSyncAt != null)
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text(
                    'Last sync: ${_relativeTime(entry.device.lastSyncAt!)}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textTertiary,
                      height: 1.2,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  static String _stateLabel(DeviceOperationalState s) {
    switch (s) {
      case DeviceOperationalState.online:
        return 'Online';
      case DeviceOperationalState.availableForSync:
        return 'Available for sync';
      case DeviceOperationalState.awaitingApproval:
        return 'Awaiting approval';
      case DeviceOperationalState.syncing:
        return 'Syncing…';
      case DeviceOperationalState.stale:
        return 'Idle';
      case DeviceOperationalState.offline:
        return 'Offline';
    }
  }

  static String _capacityLine(CapacityPolicy capacity) {
    switch (capacity.mode) {
      case CapacityMode.songCount:
        return '${capacity.value} song target';
      case CapacityMode.storageBudget:
        return '${_formatBytes(capacity.value)} target';
    }
  }

  static String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '$bytes B';
  }

  static String _relativeTime(DateTime ts) {
    final delta = DateTime.now().difference(ts);
    if (delta.inSeconds < 60) return 'just now';
    if (delta.inMinutes < 60) return '${delta.inMinutes}m ago';
    if (delta.inHours < 24) return '${delta.inHours}h ago';
    if (delta.inDays < 7) return '${delta.inDays}d ago';
    return '${ts.year}-${ts.month.toString().padLeft(2, '0')}-'
        '${ts.day.toString().padLeft(2, '0')}';
  }
}

/// 8×8 status glyph. Tone matches the operational-neutrality
/// palette laid out in the plan: calm accent for healthy states,
/// favorite/amber for "needs attention," tertiary for dimmed.
class _StatusGlyph extends StatelessWidget {
  final DeviceOperationalState state;
  const _StatusGlyph({required this.state});

  @override
  Widget build(BuildContext context) {
    final color = _colorFor(state);
    final isActive = state == DeviceOperationalState.syncing;
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: isActive ? color : color.withValues(alpha: 0.85),
          shape: BoxShape.circle,
          border: isActive
              ? Border.all(color: color.withValues(alpha: 0.30), width: 2)
              : null,
        ),
      ),
    );
  }

  static Color _colorFor(DeviceOperationalState s) {
    switch (s) {
      case DeviceOperationalState.syncing:
      case DeviceOperationalState.online:
      case DeviceOperationalState.availableForSync:
        return AppColors.accent;
      case DeviceOperationalState.awaitingApproval:
        return AppColors.favorite;
      case DeviceOperationalState.stale:
      case DeviceOperationalState.offline:
        return AppColors.textTertiary;
    }
  }
}

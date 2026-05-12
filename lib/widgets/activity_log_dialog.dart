import 'dart:io';

import 'package:flutter/material.dart';

import '../models/activity_event.dart';
import '../state/library_controller.dart';
import '../theme/app_theme.dart';

/// Activity log dialog — a chronological feed of the lifecycle
/// decisions the system has made (rows going missing, auto-
/// detected moves, purges, etc). Acts as the explanation surface
/// over the file-lifecycle layer: every state change has a row.
///
/// Read-only for now. Future enhancements (per project memory):
///   - Filter by event type
///   - Tap a row to jump to the corresponding file in Finder
///   - Surface in-app move/copy events when those ship
Future<void> showActivityLogDialog({
  required BuildContext context,
  required LibraryController controller,
}) {
  return showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close history',
    barrierColor: Colors.black.withValues(alpha: 0.55),
    transitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (_, _, _) {
      return _ActivityLogDialog(controller: controller);
    },
  );
}

class _ActivityLogDialog extends StatefulWidget {
  final LibraryController controller;
  const _ActivityLogDialog({required this.controller});

  @override
  State<_ActivityLogDialog> createState() => _ActivityLogDialogState();
}

class _ActivityLogDialogState extends State<_ActivityLogDialog> {
  static const int _pageLimit = 250;

  Future<_FeedSnapshot>? _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_FeedSnapshot> _load() async {
    final events = await widget.controller.loadActivityFeed(
      limit: _pageLimit,
    );
    final total = await widget.controller.activityEventCount();
    return _FeedSnapshot(events: events, total: total);
  }

  void _refresh() {
    setState(() {
      _future = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Material(
        color: AppColors.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: BorderSide(color: AppColors.border),
        ),
        elevation: 10,
        child: SizedBox(
          width: 820,
          height: 640,
          child: FutureBuilder<_FeedSnapshot>(
            future: _future,
            builder: (ctx, snapshot) {
              final snap = snapshot.data;
              final loading = snapshot.connectionState != ConnectionState.done;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Header(
                    total: snap?.total ?? 0,
                    showing: snap?.events.length ?? 0,
                    onRefresh: _refresh,
                    onClose: () => Navigator.of(context).pop(),
                  ),
                  const Divider(height: 1, color: AppColors.border),
                  Expanded(
                    child: loading
                        ? const Center(
                            child: CircularProgressIndicator(strokeWidth: 1.5),
                          )
                        : (snap == null || snap.events.isEmpty)
                            ? const _EmptyState()
                            : ListView.builder(
                                itemCount: snap.events.length,
                                itemBuilder: (_, i) =>
                                    _EventRow(event: snap.events[i]),
                              ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _FeedSnapshot {
  final List<ActivityEvent> events;
  final int total;
  const _FeedSnapshot({required this.events, required this.total});
}

class _Header extends StatelessWidget {
  final int total;
  final int showing;
  final VoidCallback onRefresh;
  final VoidCallback onClose;

  const _Header({
    required this.total,
    required this.showing,
    required this.onRefresh,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final cap = showing < total;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 12, 12),
      child: Row(
        children: [
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'History',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.4,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Lifecycle events the system has recorded — what disappeared, '
                  'what auto-resolved as a move, what was purged.',
                  style: TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          Text(
            cap
                ? 'showing $showing of $total'
                : '$total ${total == 1 ? "event" : "events"}',
            style: const TextStyle(
              color: AppColors.textTertiary,
              fontSize: 11,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Reload',
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh_rounded,
                size: 16, color: AppColors.textSecondary),
            splashRadius: 14,
          ),
          IconButton(
            tooltip: 'Close',
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded,
                size: 16, color: AppColors.textSecondary),
            splashRadius: 14,
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.history_rounded,
              size: 32,
              color: AppColors.textTertiary,
            ),
            SizedBox(height: 12),
            Text(
              'No events yet.',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 4),
            Text(
              'Events appear here as the system removes files, '
              'detects moves, or purges rows.',
              style: TextStyle(
                color: AppColors.textTertiary,
                fontSize: 11,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _EventRow extends StatelessWidget {
  final ActivityEvent event;
  const _EventRow({required this.event});

  @override
  Widget build(BuildContext context) {
    final desc = _eventDescriptorFor(event.eventType);
    final basename = event.path?.split(Platform.pathSeparator).last;
    final detail = _detailLineFor(event);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 70,
            child: Text(
              _formatTime(event.recordedAt),
              style: const TextStyle(
                color: AppColors.textTertiary,
                fontSize: 11,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          Icon(desc.icon, size: 14, color: desc.iconColor),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  desc.label,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (basename != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    basename,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 11,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                if (detail != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    style: const TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: 10,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Per-event-type display metadata. New types are added here; an
/// unknown type renders with a generic label + icon so the panel
/// keeps working when the DB carries event types that the current
/// build doesn't recognise (forward-compat after a downgrade).
class _EventDescriptor {
  final String label;
  final IconData icon;
  final Color iconColor;
  const _EventDescriptor({
    required this.label,
    required this.icon,
    required this.iconColor,
  });
}

_EventDescriptor _eventDescriptorFor(String type) {
  switch (type) {
    case EventType.removedExternal:
      return const _EventDescriptor(
        label: 'Removed (file no longer on disk)',
        icon: Icons.link_off_rounded,
        iconColor: AppColors.favorite,
      );
    case EventType.autoMoveSameSource:
      return const _EventDescriptor(
        label: 'Auto-resolved as move (same source)',
        icon: Icons.drive_file_move_rounded,
        iconColor: AppColors.reviewed,
      );
    case EventType.autoMoveCrossSource:
      return const _EventDescriptor(
        label: 'Auto-resolved as move (across sources)',
        icon: Icons.swap_horiz_rounded,
        iconColor: AppColors.reviewed,
      );
    case EventType.foundElsewhere:
      return const _EventDescriptor(
        label: 'Found elsewhere (coexisting copy detected)',
        icon: Icons.content_copy_rounded,
        iconColor: AppColors.reviewed,
      );
    case EventType.purged:
      return const _EventDescriptor(
        label: 'Purged from library',
        icon: Icons.delete_sweep_rounded,
        iconColor: AppColors.textSecondary,
      );
    case EventType.manualRelink:
      return const _EventDescriptor(
        label: 'Manually linked',
        icon: Icons.link_rounded,
        iconColor: AppColors.accent,
      );
    case EventType.contentUpdatedExternal:
      return const _EventDescriptor(
        label: 'Content updated externally',
        icon: Icons.edit_note_rounded,
        iconColor: AppColors.textSecondary,
      );
    default:
      return _EventDescriptor(
        label: type,
        icon: Icons.help_outline_rounded,
        iconColor: AppColors.textTertiary,
      );
  }
}

String? _detailLineFor(ActivityEvent event) {
  switch (event.eventType) {
    case EventType.autoMoveSameSource:
    case EventType.autoMoveCrossSource:
      final successor = event.payload['successor_path'] as String?;
      final matched = event.payload['matched_on'] as String?;
      if (successor == null) return null;
      final successorBase =
          successor.split(Platform.pathSeparator).last;
      if (matched != null) {
        return '→ $successorBase  ·  matched on $matched';
      }
      return '→ $successorBase';
    case EventType.purged:
      final prior = event.payload['prior_state'] as String?;
      if (prior == null) return null;
      return 'prior state: $prior';
    case EventType.manualRelink:
      final linked = event.payload['linked_to'] as String?;
      if (linked == null) return null;
      return 'linked to ${linked.split(Platform.pathSeparator).last}';
    case EventType.contentUpdatedExternal:
      final oldHash = event.payload['old_content_hash_prefix'] as String?;
      final newHash = event.payload['new_content_hash_prefix'] as String?;
      if (oldHash == null || newHash == null) return null;
      return 'sha: $oldHash… → $newHash…';
    default:
      return null;
  }
}

String _formatTime(DateTime t) {
  final now = DateTime.now();
  final isToday = t.year == now.year &&
      t.month == now.month &&
      t.day == now.day;
  String two(int n) => n.toString().padLeft(2, '0');
  if (isToday) {
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
  return '${two(t.month)}/${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

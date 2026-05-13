import 'package:flutter/material.dart';

import '../models/activity_event.dart';
import '../models/track.dart';
import '../state/library_controller.dart';
import '../theme/app_theme.dart';
import 'event_log_format.dart';

/// "View history" popup — the per-row causal-inspection surface.
///
/// Shows the chronological event chain for [track]'s File Instance:
/// every event recorded directly on its path, plus events where its
/// path appears as the destination/successor of a move or copy. The
/// goal is to answer the user's questions:
///
///   * Why is this file at this path?
///   * What was it before?
///   * When did things happen to it?
///   * Was it auto-resolved as a move? Across which sources?
///   * Has it been edited externally?
///   * Was it linked to another song manually?
///
/// Reuses [eventDescriptorFor] and [eventDetailLineFor] from the
/// shared formatter so this surface, the Activity Log dialog, the
/// Load Operational State dialog, and the Review-missing narration
/// all speak the same causal-narration vocabulary.
///
/// Architectural framing: this popup is the *first per-row causal
/// inspection surface* in the app. The vocabulary it stabilises —
/// matched_on, overlap_ms, successor, coexistence — is the same
/// vocabulary the eventual resolver-conflict surfaces, per-track
/// lineage modal, and contribution timeline will inherit. Building
/// it before the resolver lands means resolver work doesn't have to
/// invent new narration; it derives from this one.
Future<void> showTrackHistoryPopup({
  required BuildContext context,
  required LibraryController controller,
  required Track track,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close history',
    barrierColor: Colors.black.withValues(alpha: 0.5),
    transitionDuration: const Duration(milliseconds: 100),
    pageBuilder: (_, _, _) =>
        _TrackHistoryPopup(controller: controller, track: track),
  );
}

class _TrackHistoryPopup extends StatefulWidget {
  final LibraryController controller;
  final Track track;
  const _TrackHistoryPopup({
    required this.controller,
    required this.track,
  });

  @override
  State<_TrackHistoryPopup> createState() => _TrackHistoryPopupState();
}

class _TrackHistoryPopupState extends State<_TrackHistoryPopup> {
  late Future<List<ActivityEvent>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.controller.repo
        .loadHistoryForPath(widget.track.path);
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
          width: 580,
          height: 520,
          child: FutureBuilder<List<ActivityEvent>>(
            future: _future,
            builder: (ctx, snapshot) {
              final loading =
                  snapshot.connectionState != ConnectionState.done;
              final events = snapshot.data ?? const <ActivityEvent>[];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Header(
                    track: widget.track,
                    count: events.length,
                    onClose: () => Navigator.of(context).pop(),
                  ),
                  const Divider(height: 1, color: AppColors.border),
                  Expanded(
                    child: loading
                        ? const Center(
                            child: CircularProgressIndicator(
                                strokeWidth: 1.5),
                          )
                        : events.isEmpty
                            ? const _EmptyState()
                            : ListView.builder(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 4,
                                ),
                                itemCount: events.length,
                                itemBuilder: (_, i) =>
                                    _EventRow(event: events[i]),
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

class _Header extends StatelessWidget {
  final Track track;
  final int count;
  final VoidCallback onClose;
  const _Header({
    required this.track,
    required this.count,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Text(
                      'HISTORY',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.4,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      count == 0
                          ? 'no recorded events'
                          : count == 1
                              ? '1 event'
                              : '$count events',
                      style: const TextStyle(
                        color: AppColors.textTertiary,
                        fontSize: 11,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  track.filename,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  track.path,
                  style: const TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: 10,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Close',
            onPressed: onClose,
            icon: const Icon(
              Icons.close_rounded,
              size: 16,
              color: AppColors.textSecondary,
            ),
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
        padding: EdgeInsets.all(36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.history_toggle_off_rounded,
              size: 28,
              color: AppColors.textTertiary,
            ),
            SizedBox(height: 12),
            Text(
              'No recorded history for this file.',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 6),
            Text(
              'History accumulates as the file is moved, copied, '
              'linked, edited externally, or auto-resolved by the '
              'system. Files that have only been scanned in show '
              'nothing here yet.',
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
    final desc = eventDescriptorFor(event);
    final detail = eventDetailLineFor(event);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(
              _formatTimestamp(event.recordedAt),
              style: const TextStyle(
                color: AppColors.textTertiary,
                fontSize: 10,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          Icon(desc.icon, size: 13, color: desc.color),
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

String _formatTimestamp(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  final now = DateTime.now();
  final isToday = t.year == now.year &&
      t.month == now.month &&
      t.day == now.day;
  if (isToday) {
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
  // Date-only when not today: keep the time column compact. The
  // chronological order is the line above/below; the user reads
  // age from position, not from this timestamp.
  return '${two(t.month)}/${two(t.day)}/${(t.year % 100).toString().padLeft(2, '0')}';
}

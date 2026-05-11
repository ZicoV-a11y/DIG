import 'package:flutter/material.dart';

import '../models/track.dart';
import '../state/library_controller.dart';
import '../theme/app_theme.dart';
import '../utils/file_format.dart';

/// "Review removed & moved files" dialog — surfaces `indexed_files`
/// rows whose `availability_state` is `missing` (UI: "Removed" —
/// file vanished from disk with no byte-identical copy elsewhere)
/// or `superseded` (UI: "Moved" — auto-resolved relocation, or
/// coexisting copy detected). Lets the user permanently purge
/// ghost rows that have served their purpose.
///
/// Vocabulary discipline (see project memory):
///   - "Removed" = file disappeared OUTSIDE the app (Finder delete,
///     drive disconnect, etc). DB state stays `missing`.
///   - "Deleted" = future in-app delete action that trashes the file
///     from disk. Not yet implemented; the term is reserved.
///   - "Moved" = a relocation we can either confirm (unique match
///     by content_hash / fingerprint → state `superseded`) or
///     surface as coexistence (multiple byte-identical copies → DB
///     stays `missing` but UI reclassifies into MOVED section).
///
/// Per project memory: behavioural intel is never destroyed
/// automatically; purge is an explicit user action. Intel rows on
/// `tracks` survive purging — they reconnect by fingerprint if the
/// file ever returns.
Future<void> showReviewMissingDialog({
  required BuildContext context,
  required LibraryController controller,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (_) => _ReviewMissingDialog(controller: controller),
  );
}

class _ReviewMissingDialog extends StatefulWidget {
  final LibraryController controller;
  const _ReviewMissingDialog({required this.controller});

  @override
  State<_ReviewMissingDialog> createState() => _ReviewMissingDialogState();
}

class _ReviewMissingDialogState extends State<_ReviewMissingDialog> {
  final Set<String> _selected = <String>{};

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (ctx, _) {
        final tracks = widget.controller.tracksNeedingReview;
        // A 'missing' row whose content_hash also lives on at
        // least one currently-available row gets pulled out of
        // the alarming MISSING section and folded into MOVED —
        // the bytes survived elsewhere, even if uniqueness on
        // content_hash blocks the system from picking a single
        // successor (typical Cmd+D-coexistence + move case).
        final coexisting = widget.controller.coexistingMissingPaths;
        final missing = tracks
            .where((t) =>
                t.availability == 'missing' &&
                !coexisting.contains(t.path))
            .toList();
        final moved = tracks
            .where((t) =>
                t.availability == 'superseded' ||
                (t.availability == 'missing' &&
                    coexisting.contains(t.path)))
            .toList();
        final selectedAll = _selected.length == tracks.length &&
            tracks.isNotEmpty;
        return Center(
          child: Material(
            color: AppColors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.zero,
              side: const BorderSide(color: AppColors.border),
            ),
            elevation: 10,
            child: SizedBox(
              width: 820,
              height: 640,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Header(
                    missing: missing.length,
                    moved: moved.length,
                    selectedCount: _selected.length,
                    onSelectAll: tracks.isEmpty
                        ? null
                        : () {
                            setState(() {
                              if (selectedAll) {
                                _selected.clear();
                              } else {
                                _selected.addAll(tracks.map((t) => t.path));
                              }
                            });
                          },
                    selectedAll: selectedAll,
                    onClose: () => Navigator.of(context).pop(),
                  ),
                  const Divider(height: 1, color: AppColors.border),
                  Expanded(
                    child: tracks.isEmpty
                        ? const _EmptyState()
                        : ListView(
                            children: [
                              if (missing.isNotEmpty) ...[
                                _SectionHeader(
                                  label: 'REMOVED',
                                  sublabel:
                                      'Was on disk before. Last scan didn\'t '
                                      "find it and no byte-identical copy was "
                                      "detected in any watched folder — so "
                                      'it was removed from the library\'s '
                                      'view (intel preserved). Purge if you '
                                      'intended to lose it; restore the file '
                                      'or add its new folder as a source if '
                                      'not.',
                                  count: missing.length,
                                  accent: AppColors.favorite,
                                ),
                                for (final t in missing)
                                  _TrackRow(
                                    track: t,
                                    selected:
                                        _selected.contains(t.path),
                                    onToggleSelected: () => _toggle(t),
                                    onShowInFinder: () =>
                                        _showInFinder(t),
                                  ),
                              ],
                              if (moved.isNotEmpty) ...[
                                _SectionHeader(
                                  label: 'MOVED',
                                  sublabel:
                                      'File is no longer at the original '
                                      'path, but the same byte-content exists '
                                      'on at least one other watched file. '
                                      "Either auto-detected as the old row's "
                                      'replacement (single match), or one of '
                                      'multiple byte-identical copies the app '
                                      "won't auto-pick between. Either way "
                                      'the data is preserved; verify or purge '
                                      'as you wish.',
                                  count: moved.length,
                                  accent: AppColors.reviewed,
                                ),
                                for (final t in moved)
                                  _TrackRow(
                                    track: t,
                                    selected:
                                        _selected.contains(t.path),
                                    onToggleSelected: () => _toggle(t),
                                    onShowInFinder: () =>
                                        _showInFinder(t),
                                  ),
                              ],
                            ],
                          ),
                  ),
                  const Divider(height: 1, color: AppColors.border),
                  _Footer(
                    selectedCount: _selected.length,
                    onCancel: () => Navigator.of(context).pop(),
                    onPurge: _selected.isEmpty ? null : _confirmPurge,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _toggle(Track t) {
    setState(() {
      if (!_selected.remove(t.path)) _selected.add(t.path);
    });
  }

  Future<void> _showInFinder(Track t) async {
    // Reveal the file's parent folder so the user can verify the
    // missing/moved state for themselves before deciding to purge.
    await widget.controller.revealVariantInFinder(t);
  }

  Future<void> _confirmPurge() async {
    final count = _selected.length;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: const BorderSide(color: AppColors.border),
        ),
        title: const Text(
          'Purge?',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
          ),
        ),
        content: Text(
          'Permanently remove $count row${count == 1 ? "" : "s"} from '
          "the library index. The audio files on disk aren't "
          'touched. Per-song intelligence (favorite, plays, review '
          'state) is preserved on the canonical `tracks` row and '
          'reconnects automatically by fingerprint if any of these '
          'files reappear later.',
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 12,
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.textSecondary,
            ),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.favorite,
            ),
            child: Text('Purge $count'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final paths = _selected.toList();
    await widget.controller.purgeMissingTracks(paths);
    setState(() => _selected.clear());
  }
}

class _Header extends StatelessWidget {
  final int missing;
  final int moved;
  final int selectedCount;
  final VoidCallback? onSelectAll;
  final bool selectedAll;
  final VoidCallback onClose;
  const _Header({
    required this.missing,
    required this.moved,
    required this.selectedCount,
    required this.onSelectAll,
    required this.selectedAll,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Review removed & moved files',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  missing == 0 && moved == 0
                      ? 'Nothing to review. Every indexed file is on disk.'
                      : '$missing removed · $moved moved',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textTertiary,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          if (onSelectAll != null)
            TextButton(
              onPressed: onSelectAll,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.textSecondary,
              ),
              child: Text(
                selectedAll ? 'Deselect all' : 'Select all',
                style: const TextStyle(fontSize: 11),
              ),
            ),
          IconButton(
            tooltip: 'Close',
            onPressed: onClose,
            icon: const Icon(
              Icons.close_rounded,
              size: 18,
              color: AppColors.textSecondary,
            ),
            splashRadius: 14,
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  final int selectedCount;
  final VoidCallback onCancel;
  final VoidCallback? onPurge;
  const _Footer({
    required this.selectedCount,
    required this.onCancel,
    required this.onPurge,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: onCancel,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.textSecondary,
            ),
            child: const Text('Close'),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: onPurge,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.favorite,
              disabledForegroundColor: AppColors.textTertiary,
            ),
            child: Text(
              selectedCount == 0
                  ? 'Purge selected'
                  : 'Purge $selectedCount selected',
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  final String sublabel;
  final int count;
  final Color accent;
  const _SectionHeader({
    required this.label,
    required this.sublabel,
    required this.count,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surfaceAlt,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(width: 3, height: 24, color: accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: accent,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.4,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '· $count',
                      style: const TextStyle(
                        color: AppColors.textTertiary,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  sublabel,
                  style: const TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: 10,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TrackRow extends StatelessWidget {
  final Track track;
  final bool selected;
  final VoidCallback onToggleSelected;
  final VoidCallback onShowInFinder;
  const _TrackRow({
    required this.track,
    required this.selected,
    required this.onToggleSelected,
    required this.onShowInFinder,
  });

  @override
  Widget build(BuildContext context) {
    final fmt = fileFormatLabel(track.filename);
    return Material(
      color: selected ? AppColors.focusOverlay : Colors.transparent,
      child: InkWell(
        onTap: onToggleSelected,
        hoverColor: AppColors.hoverRow,
        focusColor: AppColors.focusOverlay,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: [
              Checkbox(
                value: selected,
                onChanged: (_) => onToggleSelected(),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                side: const BorderSide(
                  color: AppColors.textTertiary,
                  width: 1,
                ),
                activeColor: AppColors.accent,
              ),
              const SizedBox(width: 8),
              _Pill(label: fmt.isEmpty ? '—' : fmt),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      track.filename,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
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
              const SizedBox(width: 6),
              IconButton(
                tooltip: 'Show in Finder',
                onPressed: onShowInFinder,
                icon: const Icon(
                  Icons.folder_open_rounded,
                  size: 14,
                  color: AppColors.textSecondary,
                ),
                splashRadius: 12,
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 28, minHeight: 28),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  const _Pill({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: const BoxDecoration(color: AppColors.surfaceAlt),
      child: Text(
        label,
        style: const TextStyle(
          color: AppColors.textTertiary,
          fontSize: 10,
          fontFeatures: [FontFeature.tabularFigures()],
          letterSpacing: 0.4,
        ),
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
        padding: EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.check_circle_outline_rounded,
              size: 32,
              color: AppColors.textTertiary,
            ),
            SizedBox(height: 12),
            Text(
              'Nothing to review.',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            SizedBox(height: 4),
            Text(
              'Every file in the library index is on disk.',
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

import 'package:flutter/material.dart';

import '../models/track.dart';
import '../state/library_controller.dart';
import '../theme/app_theme.dart';
import '../utils/aggregated_track_view.dart';
import '../utils/file_format.dart';

/// Single screen listing every multi-variant bucket the matcher has
/// assembled across the library — the "trust center" for the
/// song-identity system. Each row collapses into a per-variant
/// listing (format · folder · size) with `Show in Finder` per file
/// and `Unlink variants…` per bucket so the user can audit and
/// correct false-positive merges in batch.
Future<void> showDuplicatesAuditDialog({
  required BuildContext context,
  required LibraryController controller,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (_) => _DuplicatesAuditDialog(controller: controller),
  );
}

class _DuplicatesAuditDialog extends StatefulWidget {
  final LibraryController controller;
  const _DuplicatesAuditDialog({required this.controller});

  @override
  State<_DuplicatesAuditDialog> createState() =>
      _DuplicatesAuditDialogState();
}

class _DuplicatesAuditDialogState extends State<_DuplicatesAuditDialog> {
  final Set<String> _expanded = <String>{};

  // Sections collapse independently. EXACT MATCHES starts collapsed
  // because it's the big noisy pile the user generally doesn't need
  // to read through; the actionable sections start open.
  final Set<BucketMatchReason> _collapsedSections = {
    BucketMatchReason.exactMatch,
  };

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (ctx, _) {
        // Recompute on every controller notification so post-unlink
        // the dialog reflects the new bucket count without needing
        // a manual refresh.
        final buckets = widget.controller.multiVariantBuckets;
        final totalSongs = buckets.length;
        final totalFiles = buckets.fold<int>(
          0,
          (acc, b) => acc + b.variantCount,
        );
        final totalSize = buckets.fold<int>(
          0,
          (acc, b) => acc + b.variants.fold<int>(0, (a, t) => a + t.filesize),
        );

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
                  _DialogHeader(
                    totalSongs: totalSongs,
                    totalFiles: totalFiles,
                    totalSize: totalSize,
                    onClose: () => Navigator.of(context).pop(),
                  ),
                  const Divider(height: 1, color: AppColors.border),
                  Expanded(
                    child: buckets.isEmpty
                        ? const _EmptyState()
                        : _buildSectionedList(buckets),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Render the bucket list grouped by `matchReason`, with the
  /// most-questionable section first. Within each section, buckets
  /// keep the controller's disk-size-descending order. Section
  /// headers separate the categories so the user can scan
  /// `Needs review` cases without wading through the obvious
  /// auto-matches.
  Widget _buildSectionedList(List<AggregatedTrackView> buckets) {
    final byReason = <BucketMatchReason, List<AggregatedTrackView>>{
      BucketMatchReason.fingerprintWithTagDrift: [],
      BucketMatchReason.crossFormat: [],
      BucketMatchReason.manualLink: [],
      BucketMatchReason.exactMatch: [],
    };
    for (final v in buckets) {
      byReason[v.matchReason]!.add(v);
    }
    final entries = <Widget>[];
    void addSection(BucketMatchReason reason, _SectionMeta meta) {
      final list = byReason[reason]!;
      if (list.isEmpty) return;
      final isCollapsed = _collapsedSections.contains(reason);
      entries.add(_SectionHeader(
        meta: meta,
        count: list.length,
        collapsed: isCollapsed,
        onToggle: () {
          setState(() {
            if (!_collapsedSections.remove(reason)) {
              _collapsedSections.add(reason);
            }
          });
        },
      ));
      if (isCollapsed) return; // skip rows when section is collapsed
      for (final view in list) {
        final key = view.primary.uid;
        entries.add(_BucketRow(
          view: view,
          expanded: _expanded.contains(key),
          onToggleExpand: () {
            setState(() {
              if (!_expanded.remove(key)) _expanded.add(key);
            });
          },
          onShowVariantInFinder: (t) {
            widget.controller.revealVariantInFinder(t);
          },
          onUnlinkBucket: () => _confirmUnlink(view),
        ));
      }
    }
    // Order: questionable → worth-a-glance → user-vetted → trust.
    addSection(
      BucketMatchReason.fingerprintWithTagDrift,
      const _SectionMeta(
        label: 'NEEDS REVIEW',
        sublabel:
            'Same audio fingerprint, but title / artist / duration '
            'drifted — confirm these are really the same song.',
        accent: AppColors.favorite,
      ),
    );
    addSection(
      BucketMatchReason.crossFormat,
      const _SectionMeta(
        label: 'CROSS-FORMAT',
        sublabel:
            'Same metadata, different file formats (MP3 + AIFF etc.). '
            'Almost always intentional alternates — browse to confirm.',
        accent: AppColors.reviewed,
      ),
    );
    addSection(
      BucketMatchReason.manualLink,
      const _SectionMeta(
        label: 'MANUAL LINKS',
        sublabel:
            'You paired these explicitly via the right-click menu.',
        accent: AppColors.accent,
      ),
    );
    addSection(
      BucketMatchReason.exactMatch,
      const _SectionMeta(
        label: 'EXACT MATCHES',
        sublabel:
            'Every field agrees, same format. Confident auto-match — '
            'usually macOS Cmd+D copies or literal file duplicates.',
        accent: AppColors.textTertiary,
      ),
    );
    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (_, i) => entries[i],
    );
  }

  Future<void> _confirmUnlink(AggregatedTrackView view) async {
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
          'Unlink variants?',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
          ),
        ),
        content: Text(
          'Break this song-identity bucket of ${view.variantCount} '
          'files into separate songs. Play count, favorite, and '
          'review state will reset for all of them. File analysis '
          '(BPM, key, duration) is kept.',
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
            child: const Text('Unlink'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.controller.unlinkBucket(view.primary);
      _expanded.remove(view.primary.uid);
    }
  }
}

class _DialogHeader extends StatelessWidget {
  final int totalSongs;
  final int totalFiles;
  final int totalSize;
  final VoidCallback onClose;
  const _DialogHeader({
    required this.totalSongs,
    required this.totalFiles,
    required this.totalSize,
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
                  'Duplicates audit',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  totalSongs == 0
                      ? 'No songs currently have multiple variants.'
                      : '$totalSongs songs · $totalFiles files · '
                          '${_formatBytes(totalSize)} on disk',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textTertiary,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
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

/// Compile-time description of one classification section header
/// (label + sublabel + accent color). One per `BucketMatchReason`.
class _SectionMeta {
  final String label;
  final String sublabel;
  final Color accent;
  const _SectionMeta({
    required this.label,
    required this.sublabel,
    required this.accent,
  });
}

class _SectionHeader extends StatelessWidget {
  final _SectionMeta meta;
  final int count;
  final bool collapsed;
  final VoidCallback onToggle;
  const _SectionHeader({
    required this.meta,
    required this.count,
    required this.collapsed,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surfaceAlt,
      child: InkWell(
        onTap: onToggle,
        hoverColor: AppColors.hoverRow,
        focusColor: AppColors.focusOverlay,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(width: 3, height: 24, color: meta.accent),
              const SizedBox(width: 10),
              Icon(
                collapsed
                    ? Icons.keyboard_arrow_right_rounded
                    : Icons.keyboard_arrow_down_rounded,
                size: 18,
                color: meta.accent,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Text(
                          meta.label,
                          style: TextStyle(
                            color: meta.accent,
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
                      meta.sublabel,
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
              'No multi-variant songs.',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            SizedBox(height: 4),
            Text(
              'Every song in the library has exactly one file.',
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

class _BucketRow extends StatelessWidget {
  final AggregatedTrackView view;
  final bool expanded;
  final VoidCallback onToggleExpand;
  final void Function(Track) onShowVariantInFinder;
  final VoidCallback onUnlinkBucket;
  const _BucketRow({
    required this.view,
    required this.expanded,
    required this.onToggleExpand,
    required this.onShowVariantInFinder,
    required this.onUnlinkBucket,
  });

  @override
  Widget build(BuildContext context) {
    final primary = view.primary;
    final title = primary.displayTitle.isEmpty
        ? primary.filename
        : primary.displayTitle;
    final artist =
        primary.displayArtist.isEmpty ? '—' : primary.displayArtist;
    final totalSize = view.variants.fold<int>(0, (a, t) => a + t.filesize);
    final plays = view.playCount;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onToggleExpand,
            hoverColor: AppColors.hoverRow,
            focusColor: AppColors.focusOverlay,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(
                    expanded
                        ? Icons.keyboard_arrow_down_rounded
                        : Icons.keyboard_arrow_right_rounded,
                    size: 18,
                    color: AppColors.textSecondary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          artist,
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 11,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  _Pill(label: view.formatLabel),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 72,
                    child: Text(
                      _formatBytes(totalSize),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        color: AppColors.textTertiary,
                        fontSize: 11,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 56,
                    child: Text(
                      '$plays ${plays == 1 ? "play" : "plays"}',
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        color: AppColors.textTertiary,
                        fontSize: 11,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (expanded)
          _ExpandedVariants(
            view: view,
            onShowVariantInFinder: onShowVariantInFinder,
            onUnlinkBucket: onUnlinkBucket,
          ),
        const Divider(height: 1, color: AppColors.border),
      ],
    );
  }
}

class _ExpandedVariants extends StatelessWidget {
  final AggregatedTrackView view;
  final void Function(Track) onShowVariantInFinder;
  final VoidCallback onUnlinkBucket;
  const _ExpandedVariants({
    required this.view,
    required this.onShowVariantInFinder,
    required this.onUnlinkBucket,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surfaceAlt,
      padding: const EdgeInsets.fromLTRB(36, 8, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final v in view.variants)
            _VariantRow(
              track: v,
              onShowInFinder: () => onShowVariantInFinder(v),
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: onUnlinkBucket,
              icon: const Icon(
                Icons.link_off_rounded,
                size: 14,
              ),
              label: Text(
                'Unlink ${view.variantCount} variants…',
                style: const TextStyle(fontSize: 11),
              ),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.favorite,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _VariantRow extends StatelessWidget {
  final Track track;
  final VoidCallback onShowInFinder;
  const _VariantRow({required this.track, required this.onShowInFinder});

  @override
  Widget build(BuildContext context) {
    final fmt = fileFormatLabel(track.filename);
    final parent = _parentDirNameOf(track.path);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          _Pill(label: fmt.isEmpty ? '—' : fmt, dim: true),
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
                    fontSize: 11,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (parent.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    '$parent/',
                    style: const TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: 10,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 2),
                _ContentHashLabel(track: track),
              ],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 72,
            child: Text(
              _formatBytes(track.filesize),
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: AppColors.textTertiary,
                fontSize: 11,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: 4),
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
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
        ],
      ),
    );
  }
}

/// One-line content_hash hint for an audit variant row.
///
/// Three states (each visually distinct so the user can scan a
/// bucket and immediately see why the matcher paired things):
///   - hash present → first 12 hex chars in monospace + a tooltip
///     with the full 64-char value. Two variants in the same
///     bucket with identical prefixes ARE byte-identical files;
///     differing prefixes mean the song-identity matcher (not
///     content_hash) is what linked them.
///   - hash null    → faint "sha: pending" placeholder. Means
///     the row was created before v10 and the backfill worker
///     hasn't reached it yet. Slice 5's relocation match will
///     skip these.
class _ContentHashLabel extends StatelessWidget {
  final Track track;
  const _ContentHashLabel({required this.track});

  @override
  Widget build(BuildContext context) {
    final hash = track.contentHash;
    if (hash == null || hash.isEmpty) {
      return const Text(
        'sha: pending',
        style: TextStyle(
          color: AppColors.textTertiary,
          fontSize: 9,
          fontStyle: FontStyle.italic,
        ),
      );
    }
    final prefix = hash.length >= 12 ? hash.substring(0, 12) : hash;
    return Tooltip(
      message: 'content_hash: $hash',
      waitDuration: const Duration(milliseconds: 300),
      child: Text(
        'sha: $prefix…',
        style: const TextStyle(
          color: AppColors.textTertiary,
          fontSize: 9,
          fontFeatures: [FontFeature.tabularFigures()],
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final bool dim;
  const _Pill({required this.label, this.dim = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: const BoxDecoration(color: AppColors.surfaceAlt),
      child: Text(
        label,
        style: TextStyle(
          color: dim ? AppColors.textTertiary : AppColors.textSecondary,
          fontSize: 10,
          fontFeatures: const [FontFeature.tabularFigures()],
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var size = bytes.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  if (unit == 0) return '$bytes B';
  return '${size < 10 ? size.toStringAsFixed(1) : size.toStringAsFixed(0)} '
      '${units[unit]}';
}

String _parentDirNameOf(String path) {
  final sep = '/';
  final lastSep = path.lastIndexOf(sep);
  if (lastSep <= 0) return '';
  final parentPath = path.substring(0, lastSep);
  final prevSep = parentPath.lastIndexOf(sep);
  return prevSep < 0 ? parentPath : parentPath.substring(prevSep + 1);
}

import 'package:flutter/material.dart';

import '../models/track.dart';
import '../state/library_controller.dart';
import '../theme/app_theme.dart';
import 'track_artwork.dart';

class TrackTable extends StatefulWidget {
  final LibraryController controller;
  const TrackTable({super.key, required this.controller});

  @override
  State<TrackTable> createState() => _TrackTableState();
}

class _TrackTableState extends State<TrackTable> {
  final ScrollController _scroll = ScrollController();
  String? _lastScrolledSelection;

  @override
  void initState() {
    super.initState();
    widget.controller.revealTick.addListener(_onRevealRequested);
  }

  @override
  void dispose() {
    widget.controller.revealTick.removeListener(_onRevealRequested);
    _scroll.dispose();
    super.dispose();
  }

  void _onRevealRequested() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _centerOnCurrent();
    });
  }

  void _centerOnCurrent() {
    if (!_scroll.hasClients) return;
    final c = widget.controller;
    final id = c.currentTrackId;
    if (id == null) return;
    final tracks = c.visibleTracks;
    final idx = tracks.indexWhere((t) => t.id == id);
    if (idx < 0) return;
    final extent = c.showArtwork ? 48.0 : 32.0;
    final view = _scroll.position.viewportDimension;
    final maxScroll = _scroll.position.maxScrollExtent;
    final target = (idx * extent - view / 2 + extent / 2).clamp(
      0.0,
      maxScroll,
    );
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  void _ensureSelectedVisible() {
    if (!_scroll.hasClients) return;
    final c = widget.controller;
    final id = c.selectedTrackId;
    if (id == null || id == _lastScrolledSelection) return;
    final tracks = c.visibleTracks;
    final idx = tracks.indexWhere((t) => t.id == id);
    if (idx < 0) return;
    final extent = c.showArtwork ? 48.0 : 32.0;
    final target = idx * extent;
    final view = _scroll.position.viewportDimension;
    final current = _scroll.offset;
    final maxScroll = _scroll.position.maxScrollExtent;
    if (target < current) {
      _scroll.jumpTo(target.clamp(0.0, maxScroll));
    } else if (target + extent > current + view) {
      _scroll.jumpTo((target + extent - view).clamp(0.0, maxScroll));
    }
    _lastScrolledSelection = id;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        final tracks = c.visibleTracks;
        final showArtwork = c.showArtwork;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _ensureSelectedVisible();
        });
        return Column(
          children: [
            _TableHeader(controller: c),
            const Divider(height: 1, color: AppColors.border),
            Expanded(
              child: tracks.isEmpty
                  ? _EmptyState(hasFolders: c.folders.isNotEmpty)
                  : Scrollbar(
                      controller: _scroll,
                      child: ListView.builder(
                        controller: _scroll,
                        itemExtent: showArtwork ? 48 : 32,
                        itemCount: tracks.length,
                        itemBuilder: (context, index) {
                          final t = tracks[index];
                          return _TrackRow(
                            key: ValueKey(t.id),
                            track: t,
                            controller: c,
                            showArtwork: showArtwork,
                          );
                        },
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  final bool hasFolders;
  const _EmptyState({required this.hasFolders});

  @override
  Widget build(BuildContext context) {
    final message = hasFolders
        ? 'No tracks match your filters.'
        : 'No watched folders yet.\nClick "Add folder" to scan your music.';
    return Center(
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 13,
          height: 1.4,
        ),
      ),
    );
  }
}

class _TableHeader extends StatelessWidget {
  final LibraryController controller;
  const _TableHeader({required this.controller});

  @override
  Widget build(BuildContext context) {
    final ratio = controller.titleArtistRatio;
    final titleFlex = (ratio * 1000).round().clamp(1, 1000);
    final artistFlex = (1000 - titleFlex).clamp(1, 1000);
    return Container(
      height: 30,
      color: AppColors.surface,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          _HeaderCell(
            width: controller.colFavWidth,
            label: '★',
            column: TrackSortColumn.favorite,
            controller: controller,
            align: TextAlign.center,
          ),
          _ResizeHandle(
            onDelta: (dx) => controller.setColumnWidth(
              'fav',
              controller.colFavWidth + dx,
            ),
          ),
          _HeaderCell(
            width: controller.colRevWidth,
            label: 'REV',
            column: TrackSortColumn.reviewed,
            controller: controller,
            align: TextAlign.center,
          ),
          _ResizeHandle(
            onDelta: (dx) => controller.setColumnWidth(
              'rev',
              controller.colRevWidth + dx,
            ),
          ),
          Expanded(
            flex: titleFlex,
            child: _HeaderCell(
              label: 'TITLE',
              column: TrackSortColumn.title,
              controller: controller,
              align: TextAlign.left,
            ),
          ),
          _TitleArtistSplitter(controller: controller),
          Expanded(
            flex: artistFlex,
            child: _HeaderCell(
              label: 'ARTIST',
              column: TrackSortColumn.artist,
              controller: controller,
              align: TextAlign.left,
            ),
          ),
          _ResizeHandle(
            onDelta: (dx) => controller.setColumnWidth(
              'bpm',
              controller.colBpmWidth - dx,
            ),
          ),
          _HeaderCell(
            width: controller.colBpmWidth,
            label: 'BPM',
            column: TrackSortColumn.bpm,
            controller: controller,
            align: TextAlign.right,
          ),
          _ResizeHandle(
            onDelta: (dx) => controller.setColumnWidth(
              'time',
              controller.colTimeWidth - dx,
            ),
          ),
          _HeaderCell(
            width: controller.colTimeWidth,
            label: 'TIME',
            column: TrackSortColumn.duration,
            controller: controller,
            align: TextAlign.right,
          ),
          _ResizeHandle(
            onDelta: (dx) => controller.setColumnWidth(
              'plays',
              controller.colPlaysWidth - dx,
            ),
          ),
          _HeaderCell(
            width: controller.colPlaysWidth,
            label: 'PLAYS',
            column: TrackSortColumn.plays,
            controller: controller,
            align: TextAlign.right,
          ),
        ],
      ),
    );
  }
}

class _ResizeHandle extends StatelessWidget {
  final ValueChanged<double> onDelta;
  const _ResizeHandle({required this.onDelta});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (d) => onDelta(d.delta.dx),
        child: const SizedBox(width: 6, height: double.infinity),
      ),
    );
  }
}

class _TitleArtistSplitter extends StatelessWidget {
  final LibraryController controller;
  const _TitleArtistSplitter({required this.controller});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (d) {
          // Estimate flex pool from the row width by grabbing this widget's
          // ancestor RenderBox. ~5px nudge is fine for a session-length drag.
          final box = context.findRenderObject() as RenderBox?;
          final parent = box?.parent;
          double flexWidth = 800;
          if (parent is RenderBox) {
            flexWidth = parent.size.width;
          }
          if (flexWidth <= 0) return;
          final newRatio =
              controller.titleArtistRatio + (d.delta.dx / flexWidth);
          controller.setTitleArtistRatio(newRatio);
        },
        child: const SizedBox(width: 6, height: double.infinity),
      ),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  final double? width;
  final String label;
  final TrackSortColumn column;
  final LibraryController controller;
  final TextAlign align;

  const _HeaderCell({
    this.width,
    required this.label,
    required this.column,
    required this.controller,
    required this.align,
  });

  @override
  Widget build(BuildContext context) {
    final isSorted = controller.sortColumn == column;
    final ascending = controller.sortAscending;
    final mainAlign = align == TextAlign.right
        ? MainAxisAlignment.end
        : align == TextAlign.center
            ? MainAxisAlignment.center
            : MainAxisAlignment.start;

    return SizedBox(
      width: width,
      child: InkWell(
        onTap: () => controller.setSort(column),
        hoverColor: AppColors.hoverRow,
        focusColor: AppColors.focusOverlay,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            mainAxisAlignment: mainAlign,
            children: [
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  textAlign: align,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0,
                  ),
                ),
              ),
              if (isSorted) ...[
                const SizedBox(width: 2),
                Icon(
                  ascending
                      ? Icons.arrow_drop_up_rounded
                      : Icons.arrow_drop_down_rounded,
                  size: 14,
                  color: AppColors.textPrimary,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _TrackRow extends StatelessWidget {
  final Track track;
  final LibraryController controller;
  final bool showArtwork;

  const _TrackRow({
    super.key,
    required this.track,
    required this.controller,
    required this.showArtwork,
  });

  Future<void> _showContextMenu(BuildContext context, Offset position) async {
    final overlayState = Overlay.of(context);
    final overlayBox = overlayState.context.findRenderObject() as RenderBox;
    final result = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(position, position),
        Offset.zero & overlayBox.size,
      ),
      color: AppColors.surface,
      elevation: 6,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: const BorderSide(color: AppColors.border),
      ),
      items: const [
        PopupMenuItem<String>(
          value: 'reveal',
          height: 32,
          child: Row(
            children: [
              Icon(
                Icons.folder_open_rounded,
                size: 14,
                color: AppColors.textSecondary,
              ),
              SizedBox(width: 8),
              Text(
                'Show in Finder',
                style: TextStyle(color: AppColors.textPrimary, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
    if (result == 'reveal') {
      await controller.showTrackInFinder(track.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isCurrent = controller.currentTrackId == track.id;
    final isSelected = !isCurrent && controller.selectedTrackId == track.id;
    final titleColor = isCurrent ? AppColors.accent : AppColors.textPrimary;
    final titleWeight = isCurrent ? FontWeight.w600 : FontWeight.w500;
    final trailIndex = isCurrent ? null : controller.trailIndexOf(track.id);
    Color rowColor;
    if (isCurrent) {
      rowColor = AppColors.selectedRow;
    } else if (isSelected) {
      rowColor = AppColors.accent.withValues(alpha: 0.07);
    } else {
      rowColor = AppColors.trailTint(trailIndex) ?? Colors.transparent;
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapDown: (details) =>
          _showContextMenu(context, details.globalPosition),
      child: Material(
      color: rowColor,
      child: InkWell(
        onTap: () => controller.play(track.id),
        hoverColor: AppColors.hoverRow,
        focusColor: AppColors.focusOverlay,
        child: Stack(
          children: [
            if (isCurrent)
              const Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: SizedBox(
                  width: 2,
                  child: ColoredBox(color: AppColors.accent),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  SizedBox(
                    width: controller.colFavWidth,
                    child: _IconAction(
                      tooltip: track.favorite ? 'Unfavorite' : 'Favorite',
                      icon: track.favorite
                          ? Icons.star_rounded
                          : Icons.star_border_rounded,
                      color: track.favorite
                          ? AppColors.favorite
                          : AppColors.textSecondary,
                      onPressed: () => controller.toggleFavorite(track.id),
                    ),
                  ),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: controller.colRevWidth,
                    child: Text(
                      track.reviewed ? '✔' : '○',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 17,
                        height: 1.0,
                        color: track.reviewed
                            ? AppColors.reviewed
                            : AppColors.textSecondary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    flex:
                        (controller.titleArtistRatio * 1000).round().clamp(
                          1,
                          1000,
                        ),
                    child: _TitleCell(
                      track: track,
                      isCurrent: isCurrent,
                      showArtwork: showArtwork,
                      titleColor: titleColor,
                      titleWeight: titleWeight,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    flex:
                        (1000 - (controller.titleArtistRatio * 1000).round())
                            .clamp(1, 1000),
                    child: Text(
                      track.artist.isEmpty ? '—' : track.artist,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: TextStyle(
                        color: track.artist.isEmpty
                            ? AppColors.textSecondary
                            : AppColors.textPrimary,
                        fontSize: 12,
                        height: 1.0,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: controller.colBpmWidth,
                    child: Text(
                      _formatBpm(track.bpm),
                      textAlign: TextAlign.right,
                      style: _numStyle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: controller.colTimeWidth,
                    child: Text(
                      _formatDuration(track.duration),
                      textAlign: TextAlign.right,
                      style: _numStyle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: controller.colPlaysWidth,
                    child: Text(
                      '${track.playCount}',
                      textAlign: TextAlign.right,
                      style: _numStyle,
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

class _TitleCell extends StatelessWidget {
  final Track track;
  final bool isCurrent;
  final bool showArtwork;
  final Color titleColor;
  final FontWeight titleWeight;

  const _TitleCell({
    required this.track,
    required this.isCurrent,
    required this.showArtwork,
    required this.titleColor,
    required this.titleWeight,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (showArtwork) ...[
          TrackArtwork(
            seed: track.title,
            size: 36,
            highlight: isCurrent,
          ),
          const SizedBox(width: 10),
        ] else ...[
          SizedBox(
            width: 14,
            child: isCurrent
                ? const Icon(
                    Icons.graphic_eq,
                    size: 12,
                    color: AppColors.accent,
                  )
                : null,
          ),
          const SizedBox(width: 8),
        ],
        Flexible(
          child: Text(
            track.title,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
            style: TextStyle(
              color: titleColor,
              fontSize: 13,
              fontWeight: titleWeight,
              height: 1.0,
            ),
          ),
        ),
      ],
    );
  }
}

class _IconAction extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final Color color;
  final VoidCallback onPressed;

  const _IconAction({
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: InkResponse(
        onTap: onPressed,
        radius: 18,
        containedInkWell: false,
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Icon(icon, size: 20, color: color),
        ),
      ),
    );
  }
}

const _numStyle = TextStyle(
  color: AppColors.textPrimary,
  fontSize: 12,
  height: 1.0,
  fontFeatures: [FontFeature.tabularFigures()],
);

String _formatDuration(Duration d) {
  if (d == Duration.zero) return '—';
  final m = d.inMinutes;
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$m:$s';
}

String _formatBpm(double? bpm) {
  if (bpm == null || bpm <= 0) return '—';
  return bpm.round().toString();
}

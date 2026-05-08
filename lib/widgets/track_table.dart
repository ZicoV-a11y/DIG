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

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        final tracks = c.visibleTracks;
        final showArtwork = c.showArtwork;
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
    return Container(
      height: 30,
      color: AppColors.surface,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          _HeaderCell(
            width: 38,
            label: '★',
            column: TrackSortColumn.favorite,
            controller: controller,
            align: TextAlign.center,
          ),
          const SizedBox(width: 6),
          _HeaderCell(
            width: 40,
            label: 'REV',
            column: TrackSortColumn.reviewed,
            controller: controller,
            align: TextAlign.center,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _HeaderCell(
              label: 'TITLE',
              column: TrackSortColumn.title,
              controller: controller,
              align: TextAlign.left,
            ),
          ),
          const SizedBox(width: 6),
          _HeaderCell(
            width: 60,
            label: 'TIME',
            column: TrackSortColumn.duration,
            controller: controller,
            align: TextAlign.right,
          ),
          const SizedBox(width: 6),
          _HeaderCell(
            width: 50,
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

  @override
  Widget build(BuildContext context) {
    final isCurrent = controller.currentTrackId == track.id;
    final titleColor = isCurrent ? AppColors.accent : AppColors.textPrimary;
    final titleWeight = isCurrent ? FontWeight.w600 : FontWeight.w500;
    final trailIndex = isCurrent ? null : controller.trailIndexOf(track.id);
    final rowColor = isCurrent
        ? AppColors.selectedRow
        : (AppColors.trailTint(trailIndex) ?? Colors.transparent);

    return Material(
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
                    width: 38,
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
                    width: 40,
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
                    child: _TitleCell(
                      track: track,
                      isCurrent: isCurrent,
                      showArtwork: showArtwork,
                      titleColor: titleColor,
                      titleWeight: titleWeight,
                    ),
                  ),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 60,
                    child: Text(
                      _formatDuration(track.duration),
                      textAlign: TextAlign.right,
                      style: _numStyle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 50,
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
          child: RichText(
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
            text: TextSpan(
              children: [
                TextSpan(
                  text: track.title,
                  style: TextStyle(
                    color: titleColor,
                    fontSize: 13,
                    fontWeight: titleWeight,
                    height: 1.0,
                  ),
                ),
                if (track.artist.isNotEmpty) ...[
                  const TextSpan(text: '   '),
                  TextSpan(
                    text: track.artist,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                      height: 1.0,
                    ),
                  ),
                ],
              ],
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

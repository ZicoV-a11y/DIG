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
  final ScrollController _hScroll = ScrollController();
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
    _hScroll.dispose();
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
        return LayoutBuilder(
          builder: (ctx, constraints) {
            // Suppress the framework's default platform scrollbar for
            // all descendant Scrollables. Both axes use a single styled
            // RawScrollbar instead — no double scrollbar at any time.
            final noDefaultScrollbars =
                ScrollConfiguration.of(ctx).copyWith(scrollbars: false);

            // Natural row width = sum of every column's stored width
            // + 7 dividers (6 inter-column + 1 trailing right edge,
            // 6 px each). No outer padding — the table sits flush
            // against the sidebar divider on the left and uses its
            // trailing _ColumnDivider as the closing right edge.
            // Resizing TITLE / ARTIST grows or shrinks the row's
            // total; horizontal scroll engages when it exceeds the
            // viewport.
            const gapTotal = 7 * 6.0;
            final naturalWidth = c.colFavWidth +
                c.colRevWidth +
                c.colTitleWidth +
                c.colArtistWidth +
                c.colBpmWidth +
                c.colTimeWidth +
                c.colPlaysWidth +
                gapTotal;
            final contentWidth = naturalWidth > constraints.maxWidth
                ? naturalWidth
                : constraints.maxWidth;
            // Both scrollbars share the same styling so vertical and
            // horizontal scroll feel like one consistent system.
            // crossAxisMargin pushes the bar inward from the window
            // edge so it doesn't collide with the macOS resize zone
            // and is easier to grab.
            const scrollbarThickness = 8.0;
            const scrollbarRadius = Radius.circular(4);
            const scrollbarMargin = 4.0;
            final scrollbarColor = const Color(0xFF6E6E78).withValues(
              alpha: 0.7,
            );

            final body = SizedBox(
              width: contentWidth,
              child: Column(
                children: [
                  _TableHeader(controller: c),
                  const Divider(height: 1, color: AppColors.border),
                  Expanded(
                    child: tracks.isEmpty
                        ? _EmptyState(hasFolders: c.folders.isNotEmpty)
                        : RawScrollbar(
                            controller: _scroll,
                            thumbVisibility: true,
                            thickness: scrollbarThickness,
                            radius: scrollbarRadius,
                            thumbColor: scrollbarColor,
                            crossAxisMargin: scrollbarMargin,
                            mainAxisMargin: scrollbarMargin,
                            child: ScrollConfiguration(
                              behavior: noDefaultScrollbars,
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
                  ),
                ],
              ),
            );

            return RawScrollbar(
              controller: _hScroll,
              thumbVisibility: true,
              thickness: scrollbarThickness,
              radius: scrollbarRadius,
              thumbColor: scrollbarColor,
              crossAxisMargin: scrollbarMargin,
              mainAxisMargin: scrollbarMargin,
              child: ScrollConfiguration(
                behavior: noDefaultScrollbars,
                child: SingleChildScrollView(
                  controller: _hScroll,
                  scrollDirection: Axis.horizontal,
                  physics: const ClampingScrollPhysics(),
                  child: body,
                ),
              ),
            );
          },
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
      padding: EdgeInsets.zero,
      child: Builder(
        builder: (context) {
          final order = controller.columnOrder;
          const animDuration = Duration(milliseconds: 220);
          const animCurve = Curves.easeOutCubic;
          const dividerWidth = 6.0;
          const headerHeight = 30.0;

          final children = <Widget>[];
          var x = 0.0;

          for (var i = 0; i < order.length; i++) {
            final col = order[i];
            final w = _columnWidth(col, controller);

            children.add(AnimatedPositioned(
              key: ValueKey('hdr_$col'),
              duration: animDuration,
              curve: animCurve,
              left: x,
              top: 0,
              height: headerHeight,
              width: w,
              child: _DraggableHeaderCell(
                column: col,
                width: w,
                controller: controller,
                child: _buildHeaderInner(col, controller),
              ),
            ));
            x += w;

            if (i < order.length - 1) {
              children.add(AnimatedPositioned(
                key: ValueKey('hdr_gap_after_$col'),
                duration: animDuration,
                curve: animCurve,
                left: x,
                top: 0,
                height: headerHeight,
                width: dividerWidth,
                child: _buildHeaderGap(col, controller),
              ));
              x += dividerWidth;
            }
          }

          // Trailing divider — closing edge of the rightmost column.
          children.add(AnimatedPositioned(
            key: const ValueKey('hdr_trailing'),
            duration: animDuration,
            curve: animCurve,
            left: x,
            top: 0,
            height: headerHeight,
            width: dividerWidth,
            child: const _ColumnDivider(),
          ));

          return Stack(clipBehavior: Clip.none, children: children);
        },
      ),
    );
  }
}

/// Single subtle 1 px line at the center of a 6 px gap — the *only*
/// visible thing between columns. The line uses a brightness slightly
/// above `AppColors.border` so it actually reads against the dark surface
/// (border alone is too close to the background to be visible). `alpha`
/// scales the brightness for rows where the divider should be quieter.
class _ColumnDivider extends StatelessWidget {
  final double alpha;
  const _ColumnDivider({this.alpha = 1.0});

  // Slightly above the dark surface — visible at full alpha, still subtle.
  static const _baseColor = Color(0xFF3F3F46);

  @override
  Widget build(BuildContext context) {
    final color = alpha == 1.0
        ? _baseColor
        : _baseColor.withValues(alpha: alpha);
    return SizedBox(
      width: 6,
      // height: double.infinity so the SizedBox stretches to fill the
      // Row's cross-axis (header is 30 tall, rows match itemExtent). The
      // inner Container then renders a full-height 1 px line.
      height: double.infinity,
      child: Center(
        child: Container(width: 1, color: color),
      ),
    );
  }
}

/// Right-edge resize handle. *Same width as `_ColumnDivider`* (6 px) so
/// it occupies the same horizontal layout space as the row dividers
/// underneath — keeping every column boundary in the header at the same
/// x as the corresponding row boundary. Forgiveness for fast drags
/// comes from Flutter's built-in pointer tracking: once a horizontal
/// drag is recognised, the gesture follows the cursor anywhere until
/// pointer-up (no need to widen the hit zone past the visible line).
///
/// On every drag-update frame `onDelta(dx, commit: false)` fires —
/// keeping per-frame work to a single notify, no SQLite write. On drag
/// end (or cancel) `onDelta(0, commit: true)` flushes the final value
/// once.
class _ResizeHandle extends StatelessWidget {
  final void Function(double dx, {bool commit}) onDelta;
  const _ResizeHandle({required this.onDelta});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) =>
            onDelta(d.delta.dx, commit: false),
        onHorizontalDragEnd: (_) => onDelta(0, commit: true),
        onHorizontalDragCancel: () => onDelta(0, commit: true),
        child: const _ColumnDivider(),
      ),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  final String label;
  final TrackSortColumn column;
  final LibraryController controller;
  final TextAlign align;

  const _HeaderCell({
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

    return InkWell(
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
      );
  }
}

// ---------------------------------------------------------------------------
// Column iteration helpers — used by both _TableHeader and _TrackRow so the
// dynamic column order from the controller drives layout in one place.
// ---------------------------------------------------------------------------

double _columnWidth(String col, LibraryController c) {
  switch (col) {
    case 'fav':
      return c.colFavWidth;
    case 'rev':
      return c.colRevWidth;
    case 'title':
      return c.colTitleWidth;
    case 'artist':
      return c.colArtistWidth;
    case 'bpm':
      return c.colBpmWidth;
    case 'time':
      return c.colTimeWidth;
    case 'plays':
      return c.colPlaysWidth;
  }
  return 0;
}

bool _isResizableColumn(String col) =>
    col == 'title' || col == 'artist';

Widget _buildHeaderInner(String col, LibraryController c) {
  switch (col) {
    case 'fav':
      return _HeaderCell(
        label: '★',
        column: TrackSortColumn.favorite,
        controller: c,
        align: TextAlign.center,
      );
    case 'rev':
      return _HeaderCell(
        label: 'REV',
        column: TrackSortColumn.reviewed,
        controller: c,
        align: TextAlign.center,
      );
    case 'title':
      return _HeaderCell(
        label: 'TITLE',
        column: TrackSortColumn.title,
        controller: c,
        align: TextAlign.left,
      );
    case 'artist':
      return _HeaderCell(
        label: 'ARTIST',
        column: TrackSortColumn.artist,
        controller: c,
        align: TextAlign.left,
      );
    case 'bpm':
      return _HeaderCell(
        label: 'BPM',
        column: TrackSortColumn.bpm,
        controller: c,
        align: TextAlign.center,
      );
    case 'time':
      return _HeaderCell(
        label: 'TIME',
        column: TrackSortColumn.duration,
        controller: c,
        align: TextAlign.center,
      );
    case 'plays':
      return _HeaderCell(
        label: 'PLAYS',
        column: TrackSortColumn.plays,
        controller: c,
        align: TextAlign.center,
      );
  }
  return const SizedBox.shrink();
}

Widget _buildRowInner(
  String col,
  Track t,
  LibraryController c, {
  required bool isCurrent,
  required bool showArtwork,
  required Color titleColor,
  required FontWeight titleWeight,
}) {
  switch (col) {
    case 'fav':
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Center(
          child: _IconAction(
            tooltip: t.favorite ? 'Unfavorite' : 'Favorite',
            icon: t.favorite
                ? Icons.star_rounded
                : Icons.star_border_rounded,
            color: t.favorite
                ? AppColors.favorite
                : AppColors.textSecondary,
            onPressed: () => c.toggleFavorite(t.id),
          ),
        ),
      );
    case 'rev':
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Center(
          child: Text(
            t.reviewed ? '✔' : '○',
            style: TextStyle(
              fontSize: 17,
              height: 1.0,
              color: t.reviewed
                  ? AppColors.reviewed
                  : AppColors.textSecondary,
            ),
          ),
        ),
      );
    case 'title':
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: _TitleCell(
          track: t,
          isCurrent: isCurrent,
          showArtwork: showArtwork,
          titleColor: titleColor,
          titleWeight: titleWeight,
        ),
      );
    case 'artist':
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(
          t.artist.isEmpty ? '—' : t.artist,
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
          style: TextStyle(
            color: t.artist.isEmpty
                ? AppColors.textSecondary
                : AppColors.textPrimary,
            fontSize: 12,
            height: 1.0,
          ),
        ),
      );
    case 'bpm':
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Center(child: Text(_formatBpm(t.bpm), style: _numStyle)),
      );
    case 'time':
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Center(
          child: Text(_formatDuration(t.duration), style: _numStyle),
        ),
      );
    case 'plays':
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Center(child: Text('${t.playCount}', style: _numStyle)),
      );
  }
  return const SizedBox.shrink();
}

Widget _buildHeaderGap(String col, LibraryController c) {
  if (_isResizableColumn(col)) {
    return _ResizeHandle(
      onDelta: (dx, {bool commit = false}) => c.setColumnWidth(
        col,
        _columnWidth(col, c) + dx,
        commit: commit,
      ),
    );
  }
  return const _ColumnDivider();
}

/// Wraps a header cell so it can be picked up via long-press and dropped
/// onto another column to reorder. The DragTarget shows an accent
/// insertion bar on its left edge while a drag hovers, providing a
/// "nudging into a drop position" cue. On drop, `controller.moveColumn`
/// commits the new order — `AnimatedPositioned` then slides every cell
/// to its new x smoothly.
class _DraggableHeaderCell extends StatelessWidget {
  final String column;
  final double width;
  final LibraryController controller;
  final Widget child;

  const _DraggableHeaderCell({
    required this.column,
    required this.width,
    required this.controller,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return DragTarget<String>(
      onWillAcceptWithDetails: (d) => d.data != column,
      onAcceptWithDetails: (d) {
        final order = controller.columnOrder;
        final myIdx = order.indexOf(column);
        if (myIdx < 0) return;
        controller.moveColumn(d.data, myIdx);
      },
      builder: (ctx, candidate, rejected) {
        final dragOver = candidate.isNotEmpty;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              // Draggable with horizontal affinity: a horizontal drag
              // gesture (movement past Flutter's touch slop) immediately
              // starts the column drag — no hold required. A pure click
              // with no movement passes through to the InkWell beneath
              // for sort. Vertical pointer activity (e.g., trackpad
              // scroll) doesn't trigger drag.
              child: Draggable<String>(
                data: column,
                affinity: Axis.horizontal,
                feedback: Material(
                  color: Colors.transparent,
                  child: Container(
                    width: width,
                    height: 30,
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      border: Border.all(
                        color: AppColors.accent,
                        width: 1,
                      ),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: child,
                  ),
                ),
                childWhenDragging: Opacity(opacity: 0.3, child: child),
                child: child,
              ),
            ),
            // Insertion indicator: 3 px accent line nudged just outside
            // the cell's left edge so it visually represents the gap
            // between the dragged column's future neighbours rather
            // than a border on this cell.
            if (dragOver)
              const Positioned(
                left: -3,
                top: -2,
                bottom: -2,
                child: SizedBox(
                  width: 3,
                  child: ColoredBox(color: AppColors.accent),
                ),
              ),
          ],
        );
      },
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
              padding: EdgeInsets.zero,
              child: Builder(
                builder: (context) {
                  final order = controller.columnOrder;
                  const animDuration = Duration(milliseconds: 220);
                  const animCurve = Curves.easeOutCubic;
                  const dividerWidth = 6.0;
                  final rowHeight = showArtwork ? 48.0 : 32.0;

                  final children = <Widget>[];
                  var x = 0.0;

                  for (var i = 0; i < order.length; i++) {
                    final col = order[i];
                    final w = _columnWidth(col, controller);

                    children.add(AnimatedPositioned(
                      key: ValueKey('row_$col'),
                      duration: animDuration,
                      curve: animCurve,
                      left: x,
                      top: 0,
                      height: rowHeight,
                      width: w,
                      child: _buildRowInner(
                        col,
                        track,
                        controller,
                        isCurrent: isCurrent,
                        showArtwork: showArtwork,
                        titleColor: titleColor,
                        titleWeight: titleWeight,
                      ),
                    ));
                    x += w;

                    if (i < order.length - 1) {
                      children.add(AnimatedPositioned(
                        key: ValueKey('row_gap_after_$col'),
                        duration: animDuration,
                        curve: animCurve,
                        left: x,
                        top: 0,
                        height: rowHeight,
                        width: dividerWidth,
                        child: const _ColumnDivider(alpha: 0.35),
                      ));
                      x += dividerWidth;
                    }
                  }

                  // Trailing divider mirrors the header's closing edge.
                  children.add(AnimatedPositioned(
                    key: const ValueKey('row_trailing'),
                    duration: animDuration,
                    curve: animCurve,
                    left: x,
                    top: 0,
                    height: rowHeight,
                    width: dividerWidth,
                    child: const _ColumnDivider(alpha: 0.35),
                  ));

                  return SizedBox(
                    height: rowHeight,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: children,
                    ),
                  );
                },
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
    // Title text starts flush left so it lines up with the "TITLE"
    // header label — no leading EQ-glyph slot or padding inside the
    // cell itself. Album artwork (compact mode toggle) is the only
    // optional leader. Row tinting handles "currently playing"
    // visual indication; the EQ glyph would otherwise push title
    // text out of alignment with the header.
    if (showArtwork) {
      return Row(
        children: [
          TrackArtwork(
            seed: track.title,
            size: 36,
            highlight: isCurrent,
          ),
          const SizedBox(width: 10),
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
    return Text(
      track.title,
      overflow: TextOverflow.ellipsis,
      maxLines: 1,
      style: TextStyle(
        color: titleColor,
        fontSize: 13,
        fontWeight: titleWeight,
        height: 1.0,
      ),
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
        radius: 14,
        containedInkWell: false,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Icon(icon, size: 18, color: color),
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

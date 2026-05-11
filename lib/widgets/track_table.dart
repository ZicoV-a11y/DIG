import 'dart:async';

import 'package:flutter/material.dart';

import '../models/track.dart';
import '../state/library_controller.dart';
import '../theme/app_theme.dart';
import '../utils/file_format.dart';
import 'link_track_dialog.dart';
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
  // Viewport-driven enrichment debounce. We snapshot the visible
  // row range only after scrolling settles for ~250ms, so a fast
  // flick across thousands of rows enqueues only what stays on
  // screen at the end. The 20-row look-ahead each side covers
  // casual scrolling without ever amplifying into mass downloads.
  Timer? _viewportDebounce;
  static const _viewportLookahead = 20;

  @override
  void initState() {
    super.initState();
    widget.controller.revealTick.addListener(_onRevealRequested);
    // Initial viewport snapshot once the table has laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduleViewportReport();
    });
  }

  @override
  void dispose() {
    _viewportDebounce?.cancel();
    widget.controller.revealTick.removeListener(_onRevealRequested);
    _scroll.dispose();
    _hScroll.dispose();
    super.dispose();
  }

  /// Reset the debounce timer. Each scroll notification calls this;
  /// the actual snapshot only fires once movement settles.
  void _scheduleViewportReport() {
    _viewportDebounce?.cancel();
    _viewportDebounce =
        Timer(const Duration(milliseconds: 250), _emitViewport);
  }

  /// Snapshot the currently-visible track range (plus look-ahead)
  /// and report the paths to the controller. The controller filters
  /// out paths already enriched or already in flight.
  void _emitViewport() {
    if (!mounted || !_scroll.hasClients) return;
    final c = widget.controller;
    final tracks = c.visibleTracks;
    if (tracks.isEmpty) return;
    final extent = c.showArtwork ? 56.0 : 44.0;
    final pos = _scroll.position;
    final firstIdx =
        ((pos.pixels / extent).floor() - _viewportLookahead);
    final lastIdx = (((pos.pixels + pos.viewportDimension) / extent)
            .ceil() +
        _viewportLookahead);
    final lo = firstIdx.clamp(0, tracks.length - 1);
    final hi = lastIdx.clamp(0, tracks.length - 1);
    if (hi < lo) return;
    final paths = <String>[
      for (var i = lo; i <= hi; i++) tracks[i].path,
    ];
    c.reportViewportPaths(paths);
  }

  void _onRevealRequested() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _centerOnCurrent();
    });
  }

  void _centerOnCurrent() {
    if (!_scroll.hasClients) return;
    final c = widget.controller;
    final uid = c.currentTrackUid;
    if (uid == null) return;
    final tracks = c.visibleTracks;
    final idx = tracks.indexWhere((t) => t.uid == uid);
    if (idx < 0) return;
    final extent = c.showArtwork ? 56.0 : 44.0;
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
    final uid = c.selectedTrackUid;
    if (uid == null || uid == _lastScrolledSelection) return;
    final tracks = c.visibleTracks;
    final idx = tracks.indexWhere((t) => t.uid == uid);
    if (idx < 0) return;
    final extent = c.showArtwork ? 56.0 : 44.0;
    final target = idx * extent;
    final view = _scroll.position.viewportDimension;
    final current = _scroll.offset;
    final maxScroll = _scroll.position.maxScrollExtent;
    if (target < current) {
      _scroll.jumpTo(target.clamp(0.0, maxScroll));
    } else if (target + extent > current + view) {
      _scroll.jumpTo((target + extent - view).clamp(0.0, maxScroll));
    }
    _lastScrolledSelection = uid;
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
          // Re-snapshot the viewport whenever the visible-tracks
          // identity may have changed (sort / search / source
          // switch). Cheap — just resets the debounce.
          _scheduleViewportReport();
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
                        ? _EmptyState(hasFolders: c.sources.isNotEmpty)
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
                              // NotificationListener intercepts scroll
                              // updates; we only RESET the debounce
                              // here. The actual viewport snapshot
                              // fires when scrolling settles, so a
                              // fast flick across thousands of rows
                              // enqueues only the rows the user
                              // ends up looking at.
                              child: NotificationListener<ScrollNotification>(
                                onNotification: (n) {
                                  _scheduleViewportReport();
                                  return false;
                                },
                                child: ListView.builder(
                                  controller: _scroll,
                                  itemExtent: showArtwork ? 56 : 44,
                                  itemCount: tracks.length,
                                  itemBuilder: (context, index) {
                                    final t = tracks[index];
                                    return _TrackRow(
                                      key: ValueKey(t.uid),
                                      track: t,
                                      controller: c,
                                      showArtwork: showArtwork,
                                    );
                                  },
                                ),
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
    // FORMAT cycles through priority leads instead of asc/desc, so
    // its header shows the leading format (e.g., "FORMAT · MP3")
    // when active so the user can see which lead is current.
    final isFormatColumn = column == TrackSortColumn.format;
    final displayLabel = (isFormatColumn && isSorted)
        ? '$label · ${controller.sortFormatLead}'
        : label;

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
                  displayLabel,
                  overflow: TextOverflow.ellipsis,
                  textAlign: align,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 1.0,
                  ),
                ),
              ),
              if (isSorted && !isFormatColumn) ...[
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
    case 'key':
      return c.colKeyWidth;
    case 'time':
      return c.colTimeWidth;
    case 'format':
      return c.colFormatWidth;
    case 'plays':
      return c.colPlaysWidth;
    case 'lastPlayed':
      return c.colLastPlayedWidth;
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
    case 'key':
      return _HeaderCell(
        label: 'KEY',
        column: TrackSortColumn.key,
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
    case 'format':
      return _HeaderCell(
        label: 'FORMAT',
        column: TrackSortColumn.format,
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
    case 'lastPlayed':
      return _HeaderCell(
        label: 'LAST PLAYED',
        column: TrackSortColumn.lastPlayed,
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
  required bool isLoading,
  required bool showArtwork,
  required Color titleColor,
  required FontWeight titleWeight,
}) {
  // When grouping by song identity is on, primary rows render
  // aggregated values across their bucket. `aggView` is non-null
  // only for primaries — single-variant or ungrouped rows fall
  // through to the underlying Track fields.
  final aggView = c.aggregatedViewForPrimary(t);
  final favorite = aggView?.favorite ?? t.favorite;
  final reviewed = aggView?.reviewed ?? t.reviewed;

  switch (col) {
    case 'fav':
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Center(
          child: _IconAction(
            tooltip: favorite ? 'Unfavorite' : 'Favorite',
            icon: favorite
                ? Icons.star_rounded
                : Icons.star_border_rounded,
            color: favorite
                ? AppColors.favorite
                : AppColors.textSecondary,
            onPressed: () => c.toggleFavorite(t.uid),
          ),
        ),
      );
    case 'rev':
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Center(
          child: Text(
            reviewed ? '✔' : '○',
            style: TextStyle(
              fontSize: 17,
              height: 1.0,
              color: reviewed
                  ? AppColors.reviewed
                  : AppColors.textSecondary,
            ),
          ),
        ),
      );
    case 'title':
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: _TitleCell(
            track: t,
            isCurrent: isCurrent,
            isLoading: isLoading,
            showArtwork: showArtwork,
            titleColor: titleColor,
            titleWeight: titleWeight,
          ),
        ),
      );
    case 'artist':
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            t.displayArtist.isEmpty ? '—' : t.displayArtist,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
            style: TextStyle(
              color: t.displayArtist.isEmpty
                  ? AppColors.textSecondary
                  : AppColors.textPrimary,
              fontSize: 12,
              height: 1.0,
            ),
          ),
        ),
      );
    case 'bpm':
      final bpm = aggView?.bpm ?? t.bpm;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Center(child: Text(_formatBpm(bpm), style: _numStyle)),
      );
    case 'key':
      // displayKey hits a per-Track cache; the underlying parser
      // is regex-on-basename and does no I/O, so this is cheap
      // even at 60fps with ~50 visible rows. When the row is a
      // bucket primary, the aggregated `displayKey` enforces the
      // blank-on-disagreement rule per project memory.
      final key = aggView?.displayKey ?? t.displayKey;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Center(
          child: Text(
            key.isEmpty ? '—' : key,
            style: key.isEmpty ? _numStyleDim : _numStyle,
          ),
        ),
      );
    case 'time':
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Center(
          child: Text(_formatDuration(t.duration), style: _numStyle),
        ),
      );
    case 'format':
      // Plain text in all cases: aggregated `MP3 · AIFF` when the
      // row is a multi-variant primary, single format label
      // otherwise. The user reaches the individual variants via
      // the right-click "Show in Finder" submenu — no inline
      // expand/collapse here.
      final fmt = aggView?.formatLabel ?? fileFormatLabel(t.filename);
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Center(
          child: Text(
            fmt.isEmpty ? '—' : fmt,
            style: fmt.isEmpty ? _numStyleDim : _numStyle,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        ),
      );
    case 'plays':
      final plays = aggView?.playCount ?? t.playCount;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Center(child: Text('$plays', style: _numStyle)),
      );
    case 'lastPlayed':
      // `_formatLastPlayed` returns a short, allocation-light
      // string (one of `Today` / `Yesterday` / `3d ago` / `Apr 28`
      // / `Never`). No DateTime arithmetic per-comparison sort —
      // the sort comparator works on `lastPlayedAt` directly.
      final at = aggView?.lastPlayedAt ?? t.lastPlayedAt;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Center(
          child: Text(
            _formatLastPlayed(at),
            style: at == null ? _numStyleDim : _numStyle,
          ),
        ),
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
                      borderRadius: BorderRadius.zero,
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

    // Multi-variant rows surface a per-format reveal item ("Show MP3
    // in Finder", "Show AIFF in Finder", …) so the user picks
    // exactly which file to open. Single-variant rows keep the old
    // flat "Show in Finder" item with its currently-playing
    // override + fallback semantics.
    final aggView = controller.aggregatedViewForPrimary(track);
    final variants = (aggView != null && aggView.hasSiblings)
        ? aggView.variants
        : const <Track>[];

    final items = <PopupMenuEntry<String>>[];
    if (variants.isEmpty) {
      items.add(_revealMenuItem(value: 'reveal', label: 'Show in Finder'));
    } else {
      for (var i = 0; i < variants.length; i++) {
        final v = variants[i];
        final format = fileFormatLabel(v.filename);
        final label = format.isEmpty
            ? 'Show variant ${i + 1} in Finder'
            : 'Show $format in Finder';
        items.add(_revealMenuItem(value: 'reveal:$i', label: label));
      }
    }
    items.add(const PopupMenuDivider(height: 1));
    items.add(_linkMenuItem());
    // UNLINK only meaningful when the row is the primary of a
    // multi-variant bucket. Hidden on singletons.
    if (aggView != null && aggView.hasSiblings) {
      items.add(_unlinkMenuItem(variantCount: aggView.variantCount));
    }

    final result = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(position, position),
        Offset.zero & overlayBox.size,
      ),
      color: AppColors.surface,
      elevation: 6,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
        side: const BorderSide(color: AppColors.border),
      ),
      items: items,
    );

    if (result == null) return;
    if (result == 'reveal') {
      await controller.showTrackInstanceInFinder(track);
    } else if (result.startsWith('reveal:')) {
      final idx = int.parse(result.substring('reveal:'.length));
      if (idx >= 0 && idx < variants.length) {
        await controller.revealVariantInFinder(variants[idx]);
      }
    } else if (result == 'link' && context.mounted) {
      final target = await showLinkTrackDialog(
        context: context,
        controller: controller,
        origin: track,
      );
      if (target != null) {
        await controller.linkTracks(track, target);
      }
    } else if (result == 'unlink' && context.mounted) {
      final view = controller.aggregatedViewForPrimary(track);
      if (view == null || !view.hasSiblings) return;
      final confirmed = await _confirmUnlink(
        context,
        variantCount: view.variantCount,
      );
      if (confirmed == true) {
        await controller.unlinkBucket(track);
      }
    }
  }

  Future<bool?> _confirmUnlink(
    BuildContext context, {
    required int variantCount,
  }) {
    return showDialog<bool>(
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
          'This breaks the song-identity bucket of $variantCount '
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
  }

  PopupMenuItem<String> _unlinkMenuItem({required int variantCount}) {
    return PopupMenuItem<String>(
      value: 'unlink',
      height: 32,
      child: Row(
        children: [
          const Icon(
            Icons.link_off_rounded,
            size: 14,
            color: AppColors.textSecondary,
          ),
          const SizedBox(width: 8),
          Text(
            'Unlink $variantCount variants…',
            style:
                const TextStyle(color: AppColors.textPrimary, fontSize: 12),
          ),
        ],
      ),
    );
  }

  PopupMenuItem<String> _linkMenuItem() {
    return const PopupMenuItem<String>(
      value: 'link',
      height: 32,
      child: Row(
        children: [
          Icon(
            Icons.link_rounded,
            size: 14,
            color: AppColors.textSecondary,
          ),
          SizedBox(width: 8),
          Text(
            'Link with another song…',
            style: TextStyle(color: AppColors.textPrimary, fontSize: 12),
          ),
        ],
      ),
    );
  }

  PopupMenuItem<String> _revealMenuItem({
    required String value,
    required String label,
  }) {
    return PopupMenuItem<String>(
      value: value,
      height: 32,
      child: Row(
        children: [
          const Icon(
            Icons.folder_open_rounded,
            size: 14,
            color: AppColors.textSecondary,
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style:
                const TextStyle(color: AppColors.textPrimary, fontSize: 12),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Surface "currently playing" on a bucket's primary if any
    // variant in its bucket is the current track — siblings never
    // appear as their own rows, so the primary has to own the
    // highlight on behalf of the whole bucket. When grouping is
    // off, `aggregatedViewForPrimary` returns null and this
    // reduces to a plain uid match.
    final currentUid = controller.currentTrackUid;
    bool isCurrent = currentUid != null && currentUid == track.uid;
    if (!isCurrent && currentUid != null) {
      final aggView = controller.aggregatedViewForPrimary(track);
      if (aggView != null &&
          aggView.hasSiblings &&
          aggView.variants.any((v) => v.uid == currentUid)) {
        isCurrent = true;
      }
    }
    final isLoading = isCurrent && controller.isLoadingTrack;
    final isSelected = !isCurrent && controller.selectedTrackUid == track.uid;
    final titleColor = isCurrent
        ? AppColors.accent
        : (track.isAvailable ? AppColors.textPrimary : AppColors.textTertiary);
    final titleWeight = isCurrent ? FontWeight.w600 : FontWeight.w500;
    final trailIndex = isCurrent ? null : controller.trailIndexOf(track.uid);
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
        onTap: () => controller.play(track.uid),
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
                  const dividerWidth = 6.0;
                  final rowHeight = showArtwork ? 56.0 : 44.0;

                  // Rows use plain Positioned (no animation). The
                  // header keeps `AnimatedPositioned` so the user
                  // sees a smooth reorder during column drag — but
                  // for the body, every visible row × 7 cells of
                  // active AnimationController objects ticking
                  // indefinitely was a sustained per-frame cost
                  // even when nothing was being dragged. Snap
                  // layout for body rows is dramatically cheaper
                  // and visually indistinguishable when columns
                  // aren't moving.
                  final children = <Widget>[];
                  var x = 0.0;

                  for (var i = 0; i < order.length; i++) {
                    final col = order[i];
                    final w = _columnWidth(col, controller);

                    children.add(Positioned(
                      left: x,
                      top: 0,
                      height: rowHeight,
                      width: w,
                      child: _buildRowInner(
                        col,
                        track,
                        controller,
                        isCurrent: isCurrent,
                        isLoading: isLoading,
                        showArtwork: showArtwork,
                        titleColor: titleColor,
                        titleWeight: titleWeight,
                      ),
                    ));
                    x += w;

                    if (i < order.length - 1) {
                      children.add(Positioned(
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
                  children.add(Positioned(
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
  final bool isLoading;
  final bool showArtwork;
  final Color titleColor;
  final FontWeight titleWeight;

  const _TitleCell({
    required this.track,
    required this.isCurrent,
    required this.isLoading,
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
    //
    // Per-row loading indicator: when this is the row whose audio
    // file the engine is currently materialising (e.g. Dropbox
    // download), show a small spinner in the cell so the user can
    // see *which* track triggered the wait — a single spinner on
    // the central play button isn't enough during fast browsing.
    final Widget? missingPrefix = isLoading
        ? const Padding(
            padding: EdgeInsets.only(right: 6),
            child: SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                valueColor:
                    AlwaysStoppedAnimation<Color>(AppColors.accent),
              ),
            ),
          )
        : track.isAvailable
        ? null
        : const Tooltip(
            message: 'File not found at last scan',
            waitDuration: Duration(milliseconds: 600),
            child: Padding(
              padding: EdgeInsets.only(right: 6),
              child: Icon(
                Icons.warning_amber_rounded,
                size: 12,
                color: AppColors.textTertiary,
              ),
            ),
          );

    final shownTitle = track.displayTitle;
    if (showArtwork) {
      return Row(
        children: [
          TrackArtwork(
            seed: shownTitle,
            size: 36,
            highlight: isCurrent,
          ),
          const SizedBox(width: 10),
          ?missingPrefix,
          Flexible(
            child: Text(
              shownTitle,
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
    if (missingPrefix != null) {
      return Row(
        children: [
          missingPrefix,
          Flexible(
            child: Text(
              shownTitle,
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
      shownTitle,
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

const _numStyleDim = TextStyle(
  color: AppColors.textTertiary,
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

const _monthsShort = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// Compact relative-time label for the Last Played column.
/// Pure function over `(at, now)` — no allocations beyond the
/// returned String, no DateTime arithmetic per-frame beyond a few
/// integer subtractions. Cheap enough at 60fps × ~50 visible rows.
String _formatLastPlayed(DateTime? at) {
  if (at == null) return 'Never';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final atDay = DateTime(at.year, at.month, at.day);
  final days = today.difference(atDay).inDays;
  if (days <= 0) return 'Today';
  if (days == 1) return 'Yesterday';
  if (days < 7) return '${days}d ago';
  // Older than a week → drop to "Mon D" / "Mon D, YYYY" if not
  // current calendar year.
  final monthDay = '${_monthsShort[at.month - 1]} ${at.day}';
  if (at.year == now.year) return monthDay;
  return '$monthDay, ${at.year}';
}

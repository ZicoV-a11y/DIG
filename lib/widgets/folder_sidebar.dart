import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/source.dart';
import '../state/library_controller.dart';
import '../theme/app_theme.dart';
import 'add_source_dialog.dart';

class FolderSidebar extends StatelessWidget {
  final LibraryController controller;
  const FolderSidebar({super.key, required this.controller});

  Future<void> _pickFolder(BuildContext context) async {
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: 'Select a music folder',
    );
    if (path == null) return;
    if (!context.mounted) return;

    // Picked folder lives inside an already-watched source → auto
    // sub-view (no scan, no scan-mode dialog). Surface what
    // happened (success OR failure) with a toast.
    final containing = controller.findContainingSource(path);
    if (containing != null) {
      final messenger = ScaffoldMessenger.maybeOf(context);
      try {
        await controller.addSource(path, ScanMode.recursive);
        messenger?.showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 4),
            content: Text(
              "Added a sub-view of '${containing.displayName}' (no rescan needed).",
            ),
          ),
        );
      } catch (e) {
        messenger?.showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 6),
            content: Text('Add sub-view failed: $e'),
          ),
        );
      }
      return;
    }

    final mode = await showAddSourceDialog(context, folderPath: path);
    if (mode == null) return;
    await controller.addSource(path, mode);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.navSurface,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _SectionHeader('LIBRARY'),
              _SourceTile(
                label: 'All Tracks',
                count: controller.totalTrackCount,
                selected: controller.selectedSourceId == null,
                icon: Icons.library_music_outlined,
                onTap: () => controller.selectSource(null),
                // "Enrich all" lives on All Tracks — explicit
                // opt-in to background-fill the entire library's
                // metadata. Not auto-triggered (per the
                // viewport-first contract).
                onEnrichLibrary: controller.enrichAll,
              ),
              const SizedBox(height: 6),
              const _SectionHeader('WATCHED FOLDERS'),
              if (controller.sources.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(14, 4, 14, 8),
                  child: Text(
                    'No folders yet.',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                )
              else
                ..._buildSourceTiles(context),
              const Spacer(),
              if (controller.isScanning)
                const Padding(
                  padding: EdgeInsets.fromLTRB(14, 0, 14, 6),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: AppColors.accent,
                        ),
                      ),
                      SizedBox(width: 8),
                      Text(
                        'Scanning…',
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(10),
                child: OutlinedButton.icon(
                  onPressed: controller.isScanning
                      ? null
                      : () => _pickFolder(context),
                  icon: const Icon(Icons.add, size: 14),
                  label: const Text('Add folder'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textSecondary,
                    side: const BorderSide(color: AppColors.border),
                    minimumSize: const Size.fromHeight(30),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    textStyle: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Build sidebar tiles: each top-level source, then its sub-views
  /// indented immediately beneath. Sub-views are virtual filtered
  /// lenses — they render with a smaller icon and different context
  /// menu (no Rescan).
  ///
  /// Top-level tiles are wrapped in a Draggable + DragTarget pair so
  /// the user can drag-reorder watched folders. Sub-views are not
  /// independently reorderable — they always follow their parent.
  List<Widget> _buildSourceTiles(BuildContext context) {
    final tiles = <Widget>[];
    for (final s in controller.sources) {
      if (s.isSubView) continue; // emitted under their parent below
      tiles.add(_DraggableSourceTile(
        source: s,
        controller: controller,
        child: _SourceTile(
          label: s.displayName,
          count: controller.sourceTrackCount(s.id),
          selected: controller.selectedSourceId == s.id,
          icon: Icons.folder_outlined,
          scanMode: s.scanMode,
          onTap: () => controller.selectSource(s.id),
          onRescan: () => controller.rescanSource(s.id),
          onEnrich: () => controller.enrichSource(s.id),
          onRemove: () => _confirmRemove(context, s),
        ),
      ));
      for (final child in controller.sources) {
        if (child.parentSourceId != s.id) continue;
        tiles.add(_DraggableSourceTile(
          source: child,
          controller: controller,
          child: _SourceTile(
            label: child.displayName,
            count: controller.sourceTrackCount(child.id),
            selected: controller.selectedSourceId == child.id,
            icon: Icons.subdirectory_arrow_right_rounded,
            isSubView: true,
            parentForRescan: s,
            onRescanParent: () => controller.rescanSource(s.id),
            onEnrich: () => controller.enrichSource(child.id),
            onTap: () => controller.selectSource(child.id),
            onRemove: () =>
                _confirmRemoveSubView(context, child, parent: s),
          ),
        ));
      }
    }
    return tiles;
  }

  Future<void> _confirmRemoveSubView(
    BuildContext context,
    Source subView, {
    required Source parent,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: const BorderSide(color: AppColors.border),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Remove sub-view',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  subView.displayName,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  "Removes this sub-view. The underlying files and "
                  "intelligence stay with '${parent.displayName}'.",
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Material(
                      color: AppColors.surface,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.zero,
                        side: const BorderSide(color: AppColors.border),
                      ),
                      child: InkWell(
                        onTap: () => Navigator.of(ctx).pop(false),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 7,
                          ),
                          child: Text(
                            'Cancel',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Material(
                      color: AppColors.accent.withValues(alpha: 0.15),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.zero,
                        side: const BorderSide(color: AppColors.accent),
                      ),
                      child: InkWell(
                        onTap: () => Navigator.of(ctx).pop(true),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 7,
                          ),
                          child: Text(
                            'Remove',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppColors.accent,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (ok == true) {
      await controller.removeSource(subView.id);
    }
  }

  Future<void> _confirmRemove(BuildContext context, Source source) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: const BorderSide(color: AppColors.border),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Remove folder',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  source.displayName,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Workflow history is preserved. Re-adding this folder later will reconnect favorites, plays, and review state.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Material(
                      color: AppColors.surface,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.zero,
                        side: const BorderSide(color: AppColors.border),
                      ),
                      child: InkWell(
                        onTap: () => Navigator.of(ctx).pop(false),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 7,
                          ),
                          child: Text(
                            'Cancel',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Material(
                      color: AppColors.accent.withValues(alpha: 0.15),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.zero,
                        side: const BorderSide(color: AppColors.accent),
                      ),
                      child: InkWell(
                        onTap: () => Navigator.of(ctx).pop(true),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 7,
                          ),
                          child: Text(
                            'Remove',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppColors.accent,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (ok == true) {
      await controller.removeSource(source.id);
    }
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
      child: Text(
        label,
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

class _SourceTile extends StatefulWidget {
  final String label;
  final int count;
  final bool selected;
  final IconData icon;
  final ScanMode? scanMode;
  final VoidCallback onTap;
  final VoidCallback? onRescan;
  final VoidCallback? onRemove;
  // When true, the tile renders indented under its parent and uses a
  // slightly smaller folder icon to communicate "filtered lens, not a
  // peer source". Sub-view tiles never trigger a scan of their own
  // path, but they may surface a "rescan parent" affordance.
  final bool isSubView;
  // Sub-view-only: the parent source this lens filters. When set
  // alongside [onRescanParent], the right-click menu offers a
  // "Rescan {parent}" entry that calls [onRescanParent].
  final Source? parentForRescan;
  final VoidCallback? onRescanParent;
  // Per-source / per-sub-view "Enrich metadata" action. Pushes
  // every un-enriched track in scope onto the priority queue so
  // the user can watch the enriched counter climb without having
  // to scroll. Available on regular sources and sub-views.
  final VoidCallback? onEnrich;
  // "All Tracks" tile only: enrich the entire library scope.
  final VoidCallback? onEnrichLibrary;

  const _SourceTile({
    required this.label,
    required this.count,
    required this.selected,
    required this.icon,
    required this.onTap,
    this.scanMode,
    this.onRescan,
    this.onRemove,
    this.isSubView = false,
    this.parentForRescan,
    this.onRescanParent,
    this.onEnrich,
    this.onEnrichLibrary,
  });

  @override
  State<_SourceTile> createState() => _SourceTileState();
}

class _SourceTileState extends State<_SourceTile> {
  bool _hovering = false;

  Future<void> _showContextMenu(Offset position) async {
    if (widget.onRescan == null &&
        widget.onRemove == null &&
        widget.onRescanParent == null &&
        widget.onEnrich == null &&
        widget.onEnrichLibrary == null) {
      return;
    }
    final overlayState = Overlay.of(context);
    final overlayBox = overlayState.context.findRenderObject() as RenderBox;
    final tooltip = widget.scanMode == ScanMode.topLevelOnly
        ? 'Rescan (top-level only)'
        : 'Rescan (recursive)';
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
      items: [
        if (widget.onRescan != null)
          PopupMenuItem<String>(
            value: 'rescan',
            height: 32,
            child: Row(
              children: [
                const Icon(
                  Icons.refresh_rounded,
                  size: 14,
                  color: AppColors.textSecondary,
                ),
                const SizedBox(width: 8),
                Text(
                  tooltip,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        if (widget.onRescanParent != null && widget.parentForRescan != null)
          PopupMenuItem<String>(
            value: 'rescan_parent',
            height: 32,
            child: Row(
              children: [
                const Icon(
                  Icons.refresh_rounded,
                  size: 14,
                  color: AppColors.textSecondary,
                ),
                const SizedBox(width: 8),
                Text(
                  "Rescan '${widget.parentForRescan!.displayName}'",
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        if (widget.onEnrich != null)
          const PopupMenuItem<String>(
            value: 'enrich',
            height: 32,
            child: Row(
              children: [
                Icon(
                  Icons.auto_awesome_outlined,
                  size: 14,
                  color: AppColors.textSecondary,
                ),
                SizedBox(width: 8),
                Text(
                  'Enrich metadata',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        if (widget.onEnrichLibrary != null)
          const PopupMenuItem<String>(
            value: 'enrich_library',
            height: 32,
            child: Row(
              children: [
                Icon(
                  Icons.auto_awesome_rounded,
                  size: 14,
                  color: AppColors.textSecondary,
                ),
                SizedBox(width: 8),
                Text(
                  'Enrich entire library',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        if (widget.onRemove != null)
          const PopupMenuItem<String>(
            value: 'remove',
            height: 32,
            child: Row(
              children: [
                Icon(
                  Icons.close_rounded,
                  size: 14,
                  color: AppColors.textSecondary,
                ),
                SizedBox(width: 8),
                Text(
                  'Remove from library',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
    switch (result) {
      case 'rescan':
        widget.onRescan?.call();
        break;
      case 'rescan_parent':
        widget.onRescanParent?.call();
        break;
      case 'enrich':
        widget.onEnrich?.call();
        break;
      case 'enrich_library':
        widget.onEnrichLibrary?.call();
        break;
      case 'remove':
        widget.onRemove?.call();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: SizedBox(
        height: 28,
        child: Material(
          color: Colors.transparent,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onSecondaryTapDown: (d) => _showContextMenu(d.globalPosition),
            child: InkWell(
              onTap: widget.onTap,
              hoverColor: AppColors.hoverRow,
              focusColor: AppColors.focusOverlay,
              child: Stack(
                children: [
                  if (widget.selected)
                    Positioned.fill(
                      child: Container(color: AppColors.selectedRow),
                    ),
                  if (widget.selected)
                    const Positioned(
                      left: 0,
                      top: 4,
                      bottom: 4,
                      child: SizedBox(
                        width: 2,
                        child: ColoredBox(color: AppColors.accent),
                      ),
                    ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      widget.isSubView ? 30 : 14,
                      0,
                      14,
                      0,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          widget.icon,
                          size: widget.isSubView ? 12 : 14,
                          color: widget.selected
                              ? AppColors.accent
                              : AppColors.textSecondary,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            widget.label,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 13,
                              fontWeight: widget.selected
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                        if (_hovering && widget.onRemove != null)
                          InkWell(
                            onTap: widget.onRemove,
                            borderRadius: BorderRadius.zero,
                            child: const Padding(
                              padding: EdgeInsets.all(2),
                              child: Icon(
                                Icons.close_rounded,
                                size: 12,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          )
                        else
                          Text(
                            '${widget.count}',
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 11,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Wraps a top-level source tile in a `Draggable` + `DragTarget` so
/// the user can vertically rearrange watched folders.
///
/// Drop semantics: dropping a dragged source ID onto another tile
/// inserts the dragged source **before** that tile in the order.
/// While a drag hovers, an accent insertion line renders at the top
/// of the receiving tile so the user can see exactly where the
/// drop will land.
///
/// Sub-views are not draggable on their own; they always follow
/// their parent in the rendered list (see
/// `LibraryController.sources`). Only top-level sources get this
/// wrapper.
class _DraggableSourceTile extends StatelessWidget {
  final Source source;
  final Widget child;
  final LibraryController controller;

  const _DraggableSourceTile({
    required this.source,
    required this.child,
    required this.controller,
  });

  Source? _findSource(String id) {
    for (final s in controller.sources) {
      if (s.id == id) return s;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return DragTarget<String>(
      // Same-tier rule: a top-level can only land on another
      // top-level; a sub-view can only land on a sibling sub-view
      // of the same parent. This keeps the visual hierarchy
      // intact (no sub-view jumping out of its parent group, no
      // top-level burrowing into a sub-view stack).
      onWillAcceptWithDetails: (d) {
        if (d.data == source.id) return false;
        final dragged = _findSource(d.data);
        if (dragged == null) return false;
        return dragged.parentSourceId == source.parentSourceId;
      },
      onAcceptWithDetails: (d) {
        controller.moveSourceBefore(d.data, source.id);
      },
      builder: (ctx, candidate, rejected) {
        final hovering = candidate.isNotEmpty;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Draggable<String>(
              data: source.id,
              affinity: Axis.vertical,
              feedback: Material(
                color: Colors.transparent,
                child: SizedBox(
                  width: 220,
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      border: Border.all(
                        color: AppColors.accent,
                        width: 1,
                      ),
                    ),
                    child: child,
                  ),
                ),
              ),
              childWhenDragging: Opacity(opacity: 0.3, child: child),
              child: child,
            ),
            if (hovering)
              const Positioned(
                left: 0,
                right: 0,
                top: -1,
                height: 2,
                child: ColoredBox(color: AppColors.accent),
              ),
          ],
        );
      },
    );
  }
}

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/library_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/folder_sidebar.dart';
import '../widgets/library_status_bar.dart';
import '../widgets/library_toolbar.dart';
import '../widgets/playback_bar.dart';
import '../widgets/track_table.dart';
import '../widgets/utility_rail.dart';

class HomeScreen extends StatefulWidget {
  final LibraryController controller;
  const HomeScreen({super.key, required this.controller});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final TextEditingController _searchTextController;
  late final FocusNode _searchFocusNode;
  late final FocusNode _bodyFocusNode;
  final ScrollController _tableScroll = ScrollController();
  final GlobalKey _tableAreaKey = GlobalKey();
  final GlobalKey _railAreaKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _searchTextController = TextEditingController(
      text: widget.controller.searchQuery,
    );
    _searchFocusNode = FocusNode(debugLabel: 'search');
    _bodyFocusNode = FocusNode(debugLabel: 'body');
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
    // Keep the search-field text in sync when the query is set
    // from outside the toolbar (e.g. a Now Playing pivot click).
    widget.controller.addListener(_syncSearchTextWithQuery);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncSearchTextWithQuery);
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    _searchTextController.dispose();
    _searchFocusNode.dispose();
    _bodyFocusNode.dispose();
    _tableScroll.dispose();
    super.dispose();
  }

  /// Mirror `controller.searchQuery` back into the toolbar's
  /// `TextEditingController` whenever the controller changes the
  /// query through a path other than the toolbar's own onChange
  /// (e.g. tapping a Now Playing pivot). One-way sync from
  /// controller → field; the field's onChange still drives the
  /// other direction.
  void _syncSearchTextWithQuery() {
    final q = widget.controller.searchQuery;
    if (_searchTextController.text != q) {
      _searchTextController.value = TextEditingValue(
        text: q,
        selection: TextSelection.collapsed(offset: q.length),
      );
    }
  }

  /// Forward a scroll wheel event to the table's controller when the cursor
  /// sits over a non-scrollable region (toolbar, playback bar, gaps). When
  /// the cursor is already over the table, the table's own Scrollable
  /// handles it natively — we skip forwarding so the user doesn't get
  /// double-speed scroll.
  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (!_tableScroll.hasClients) return;
    // Any pointer scroll over a region that has its own scroll
    // (track table, utility rail) should be handled natively — we
    // don't want to steal the wheel event and forward it to the
    // table.
    if (_pointerInside(event.position, _tableAreaKey)) return;
    if (_pointerInside(event.position, _railAreaKey)) return;
    final pos = _tableScroll.position;
    final next = (pos.pixels + event.scrollDelta.dy)
        .clamp(pos.minScrollExtent, pos.maxScrollExtent);
    _tableScroll.jumpTo(next);
  }

  bool _pointerInside(Offset position, GlobalKey key) {
    final ctx = key.currentContext;
    if (ctx == null) return false;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null) return false;
    final origin = box.localToGlobal(Offset.zero);
    final bounds = origin & box.size;
    return bounds.contains(position);
  }

  void _focusSearch() {
    _searchFocusNode.requestFocus();
  }

  void _escape() {
    if (_searchTextController.text.isNotEmpty) {
      _searchTextController.clear();
      widget.controller.setSearchQuery('');
    }
    if (_searchFocusNode.hasFocus) {
      _searchFocusNode.unfocus();
    }
    _bodyFocusNode.requestFocus();
  }

  void _toggleFavoriteCurrent() {
    final uid = widget.controller.currentTrackUid;
    if (uid != null) widget.controller.toggleFavorite(uid);
  }

  void _toggleReviewedCurrent() {
    final uid = widget.controller.currentTrackUid;
    if (uid != null) widget.controller.toggleReviewed(uid);
  }

  bool _isFocusInTextInput() {
    if (_searchFocusNode.hasFocus) return true;
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null) return false;
    if (primary == _searchFocusNode) return true;
    final ctx = primary.context;
    if (ctx == null) return false;
    var found = false;
    ctx.visitAncestorElements((element) {
      if (element.widget is EditableText) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;

    final c = widget.controller;
    final key = event.logicalKey;
    final isShift = HardwareKeyboard.instance.isShiftPressed;
    final isMeta = HardwareKeyboard.instance.isMetaPressed;
    final isCtrl = HardwareKeyboard.instance.isControlPressed;
    final isAlt = HardwareKeyboard.instance.isAltPressed;

    // Always-on shortcuts (work in or out of text inputs)
    if (key == LogicalKeyboardKey.escape && !isMeta && !isCtrl && !isAlt) {
      _escape();
      return true;
    }
    if (key == LogicalKeyboardKey.keyF &&
        isMeta &&
        !isCtrl &&
        !isAlt &&
        !isShift) {
      _focusSearch();
      return true;
    }
    if (key == LogicalKeyboardKey.backslash &&
        isMeta &&
        !isCtrl &&
        !isAlt &&
        !isShift) {
      widget.controller.toggleSidebarVisible();
      return true;
    }

    // Suppress single-key shortcuts while typing in any text input.
    if (_isFocusInTextInput()) return false;

    // Single-key shortcuts only — skip if Cmd/Ctrl/Alt held (Shift allowed).
    if (isMeta || isCtrl || isAlt) return false;

    switch (key) {
      case LogicalKeyboardKey.space:
        c.togglePlayPause();
        return true;
      case LogicalKeyboardKey.arrowLeft:
        if (isShift) {
          c.goBack();
        } else {
          c.skip(const Duration(seconds: -10));
        }
        return true;
      case LogicalKeyboardKey.arrowRight:
        if (isShift) {
          c.next();
        } else {
          c.skip(const Duration(seconds: 10));
        }
        return true;
      case LogicalKeyboardKey.keyF:
        _toggleFavoriteCurrent();
        return true;
      case LogicalKeyboardKey.keyR:
        _toggleReviewedCurrent();
        return true;
      case LogicalKeyboardKey.keyU:
        c.toggleUnreviewedOnly();
        return true;
      case LogicalKeyboardKey.keyS:
        c.cyclePlaybackMode();
        return true;
      case LogicalKeyboardKey.arrowUp:
        c.selectPreviousVisible();
        return true;
      case LogicalKeyboardKey.arrowDown:
        c.selectNextVisible();
        return true;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        c.playSelected();
        return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.arrowUp):
            DoNothingAndStopPropagationIntent(),
        SingleActivator(LogicalKeyboardKey.arrowDown):
            DoNothingAndStopPropagationIntent(),
        SingleActivator(LogicalKeyboardKey.arrowLeft):
            DoNothingAndStopPropagationIntent(),
        SingleActivator(LogicalKeyboardKey.arrowRight):
            DoNothingAndStopPropagationIntent(),
        SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true):
            DoNothingAndStopPropagationIntent(),
        SingleActivator(LogicalKeyboardKey.arrowRight, shift: true):
            DoNothingAndStopPropagationIntent(),
      },
      child: Focus(
        focusNode: _bodyFocusNode,
        autofocus: true,
        child: Listener(
          onPointerSignal: _handlePointerSignal,
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.zero,
                          child: PlaybackBar(controller: c),
                        ),
                        const SizedBox(height: 4),
                        Expanded(
                          child: ListenableBuilder(
                            listenable: c,
                            builder: (ctx, _) => Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (c.sidebarVisible) ...[
                                  SizedBox(
                                    width: c.sidebarWidth,
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.zero,
                                      child: FolderSidebar(controller: c),
                                    ),
                                  ),
                                  _SidebarResizeHandle(controller: c),
                                ],
                                Expanded(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.zero,
                                  child: Container(
                                    color: AppColors.workspaceSurface,
                                    child: Column(
                                      children: [
                                        LibraryToolbar(
                                          controller: c,
                                          searchTextController:
                                              _searchTextController,
                                          searchFocusNode: _searchFocusNode,
                                        ),
                                        Expanded(
                                          child: KeyedSubtree(
                                            key: _tableAreaKey,
                                            child: TrackTable(controller: c),
                                          ),
                                        ),
                                        LibraryStatusBar(controller: c),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  KeyedSubtree(
                    key: _railAreaKey,
                    child: ClipRRect(
                      borderRadius: BorderRadius.zero,
                      child: UtilityRail(controller: c),
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

/// 4 px vertical drag handle that lives on the right edge of the sidebar.
/// Drags update `controller.setSidebarWidth(...)` live (no SQLite write per
/// frame); the final width is committed on drag end. Dragging past the
/// minimum collapses the sidebar (visibility off) — the toggle button or
/// keyboard shortcut brings it back.
class _SidebarResizeHandle extends StatelessWidget {
  final LibraryController controller;
  const _SidebarResizeHandle({required this.controller});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) => controller.setSidebarWidth(
          controller.sidebarWidth + d.delta.dx,
          commit: false,
        ),
        onHorizontalDragEnd: (_) => controller.setSidebarWidth(
          controller.sidebarWidth,
          commit: true,
        ),
        child: const SizedBox(width: 4, height: double.infinity),
      ),
    );
  }
}

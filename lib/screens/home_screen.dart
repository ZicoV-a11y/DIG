import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/library_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/folder_sidebar.dart';
import '../widgets/library_toolbar.dart';
import '../widgets/playback_bar.dart';
import '../widgets/track_table.dart';

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

  @override
  void initState() {
    super.initState();
    _searchTextController = TextEditingController(
      text: widget.controller.searchQuery,
    );
    _searchFocusNode = FocusNode(debugLabel: 'search');
    _bodyFocusNode = FocusNode(debugLabel: 'body');
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    _searchTextController.dispose();
    _searchFocusNode.dispose();
    _bodyFocusNode.dispose();
    super.dispose();
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
    final id = widget.controller.currentTrackId;
    if (id != null) widget.controller.toggleFavorite(id);
  }

  void _toggleReviewedCurrent() {
    final id = widget.controller.currentTrackId;
    if (id != null) widget.controller.toggleReviewed(id);
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
    return Focus(
      focusNode: _bodyFocusNode,
      autofocus: true,
      child: Scaffold(
        body: Column(
          children: [
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FolderSidebar(controller: c),
                  const VerticalDivider(width: 1, color: AppColors.border),
                  Expanded(
                    child: Column(
                      children: [
                        LibraryToolbar(
                          controller: c,
                          searchTextController: _searchTextController,
                          searchFocusNode: _searchFocusNode,
                        ),
                        const Divider(height: 1, color: AppColors.border),
                        Expanded(child: TrackTable(controller: c)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: AppColors.border),
            PlaybackBar(controller: c),
          ],
        ),
      ),
    );
  }
}

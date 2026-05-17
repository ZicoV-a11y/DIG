import 'package:flutter/material.dart';

import '../models/track.dart';
import '../services/filename_parser.dart';
import '../state/library_controller.dart';
import '../theme/app_theme.dart';
import 'keyboard_shortcuts_help.dart';

class LibraryToolbar extends StatelessWidget {
  final LibraryController controller;
  final TextEditingController searchTextController;
  final FocusNode searchFocusNode;

  const LibraryToolbar({
    super.key,
    required this.controller,
    required this.searchTextController,
    required this.searchFocusNode,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: [
          ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              return _ToolbarIconButton(
                icon: controller.sidebarVisible
                    ? Icons.view_sidebar_outlined
                    : Icons.view_sidebar_rounded,
                tooltip: controller.sidebarVisible
                    ? 'Hide sidebar (⌘\\)'
                    : 'Show sidebar (⌘\\)',
                onTap: controller.toggleSidebarVisible,
              );
            },
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SizedBox(
              height: 32,
              child: ValueListenableBuilder<TextEditingValue>(
                // Listening to the TextEditingController itself (which
                // is a ValueNotifier<TextEditingValue>) keeps the clear
                // button's visibility in lockstep with the field text
                // without needing the parent toolbar to be Stateful or
                // re-rebuilding on every controller notification.
                valueListenable: searchTextController,
                builder: (ctx, value, _) {
                  final hasText = value.text.isNotEmpty;
                  return TextField(
                    controller: searchTextController,
                    focusNode: searchFocusNode,
                    onChanged: controller.setSearchQuery,
                    onTapOutside: (_) => searchFocusNode.unfocus(),
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'Search title or artist…',
                      hintStyle: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                      ),
                      prefixIcon: hasText
                          ? Tooltip(
                              message: 'Clear search (Esc)',
                              waitDuration:
                                  const Duration(milliseconds: 600),
                              child: InkWell(
                                onTap: () {
                                  searchTextController.clear();
                                  controller.setSearchQuery('');
                                },
                                child: const Icon(
                                  Icons.close_rounded,
                                  size: 14,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            )
                          : const Icon(Icons.search, size: 14),
                      prefixIconConstraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                      suffixIconConstraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                      isDense: true,
                      filled: true,
                      fillColor: AppColors.surface,
                      contentPadding:
                          const EdgeInsets.symmetric(vertical: 6),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.zero,
                        borderSide:
                            const BorderSide(color: AppColors.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.zero,
                        borderSide:
                            const BorderSide(color: AppColors.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.zero,
                        borderSide:
                            const BorderSide(color: AppColors.accent),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(width: 10),
          ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              return _TrackPivotStrip(
                track: controller.currentTrack,
                onTap: controller.setSearchQuery,
              );
            },
          ),
          const SizedBox(width: 10),
          ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final recent = controller.recentReviewedTracks;
              return Row(
                children: [
                  if (recent.isNotEmpty) ...[
                    _RecentReviewedButton(
                      tracks: recent,
                      onSelected: (id) =>
                          controller.play(id, reveal: true),
                    ),
                    const SizedBox(width: 8),
                  ],
                  ToolbarToggle(
                    label: 'Unreviewed only',
                    value: controller.unreviewedOnly,
                    onTap: controller.toggleUnreviewedOnly,
                  ),
                  const SizedBox(width: 8),
                  _ToolbarIconButton(
                    icon: Icons.keyboard_outlined,
                    tooltip: 'Keyboard shortcuts',
                    onTap: () => showKeyboardShortcutsDialog(context),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Horizontally-scrollable strip of people-pivot chips for the
/// currently-playing track. Lives in the toolbar (next to search)
/// because the chips ARE a search shortcut: tapping one fires
/// `controller.setSearchQuery(name)` and the table filters down.
/// Hidden when no track is playing or the track yields no pivots —
/// so the toolbar collapses back to its plain layout in idle state.
class _TrackPivotStrip extends StatelessWidget {
  final Track? track;
  final void Function(String) onTap;

  const _TrackPivotStrip({required this.track, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = track;
    if (t == null) return const SizedBox.shrink();
    final pivots = extractPeoplePivots(
      artist: t.displayArtist,
      title: t.displayTitle,
    );
    if (pivots.isEmpty) return const SizedBox.shrink();
    // Cap at ~360 so the chip strip can't squeeze the search field
    // below readable width on a 1180-px-wide window; the strip
    // scrolls horizontally beyond that.
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < pivots.length; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              _PivotChip(label: pivots[i], onTap: () => onTap(pivots[i])),
            ],
          ],
        ),
      ),
    );
  }
}

class _PivotChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _PivotChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surfaceAlt,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
        side: const BorderSide(color: AppColors.border),
      ),
      child: InkWell(
        onTap: onTap,
        hoverColor: AppColors.hoverRow,
        focusColor: AppColors.focusOverlay,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Text(
            label,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolbarIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _ToolbarIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: Material(
        color: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: const BorderSide(color: AppColors.border),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.zero,
          hoverColor: AppColors.hoverRow,
          focusColor: AppColors.focusOverlay,
          child: SizedBox(
            width: 32,
            height: 32,
            child: Center(
              child: Icon(icon, size: 16, color: AppColors.textSecondary),
            ),
          ),
        ),
      ),
    );
  }
}

class _RecentReviewedButton extends StatelessWidget {
  final List<Track> tracks;
  final void Function(String trackId) onSelected;

  const _RecentReviewedButton({
    required this.tracks,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Recently reviewed',
      onSelected: onSelected,
      color: AppColors.surface,
      elevation: 6,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
        side: const BorderSide(color: AppColors.border),
      ),
      itemBuilder: (context) => [
        for (final t in tracks)
          PopupMenuItem<String>(
            value: t.uid,
            height: 32,
            child: Row(
              children: [
                const Icon(
                  Icons.replay_rounded,
                  size: 14,
                  color: AppColors.textSecondary,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    t.displayTitle,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 12,
                    ),
                  ),
                ),
                if (t.displayArtist.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      t.displayArtist,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
      child: Material(
        color: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: const BorderSide(color: AppColors.border),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            children: [
              const Icon(
                Icons.history_rounded,
                size: 14,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: 6),
              Text(
                'Recent (${tracks.length})',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  height: 1.0,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ToolbarToggle extends StatelessWidget {
  final String label;
  final bool value;
  final VoidCallback onTap;

  const ToolbarToggle({
    super.key,
    required this.label,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: value
          ? AppColors.accent.withValues(alpha: 0.15)
          : AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
        side: BorderSide(
          color: value ? AppColors.accent : AppColors.border,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.zero,
        hoverColor: AppColors.hoverRow,
        focusColor: AppColors.focusOverlay,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            children: [
              Icon(
                value
                    ? Icons.check_box_rounded
                    : Icons.check_box_outline_blank_rounded,
                size: 14,
                color: value ? AppColors.accent : AppColors.textSecondary,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  height: 1.0,
                  color: value ? AppColors.accent : AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

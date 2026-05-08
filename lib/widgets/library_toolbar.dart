import 'package:flutter/material.dart';

import '../models/track.dart';
import '../state/library_controller.dart';
import '../theme/app_theme.dart';

class LibraryToolbar extends StatefulWidget {
  final LibraryController controller;
  const LibraryToolbar({super.key, required this.controller});

  @override
  State<LibraryToolbar> createState() => _LibraryToolbarState();
}

class _LibraryToolbarState extends State<LibraryToolbar> {
  late final TextEditingController _searchCtrl;

  @override
  void initState() {
    super.initState();
    _searchCtrl = TextEditingController(text: widget.controller.searchQuery);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      color: AppColors.background,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 32,
              child: TextField(
                controller: _searchCtrl,
                onChanged: widget.controller.setSearchQuery,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Search title or artist…',
                  hintStyle: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                  prefixIcon: const Icon(Icons.search, size: 14),
                  prefixIconConstraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  isDense: true,
                  filled: true,
                  fillColor: AppColors.surface,
                  contentPadding: const EdgeInsets.symmetric(vertical: 6),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: const BorderSide(color: AppColors.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: const BorderSide(color: AppColors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: const BorderSide(color: AppColors.accent),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          ListenableBuilder(
            listenable: widget.controller,
            builder: (context, _) {
              final recent = widget.controller.recentReviewedTracks;
              return Row(
                children: [
                  if (recent.isNotEmpty) ...[
                    _RecentReviewedButton(
                      tracks: recent,
                      onSelected: widget.controller.play,
                    ),
                    const SizedBox(width: 8),
                  ],
                  ToolbarToggle(
                    label: 'Unreviewed only',
                    value: widget.controller.unreviewedOnly,
                    onTap: widget.controller.toggleUnreviewedOnly,
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
        borderRadius: BorderRadius.circular(6),
        side: const BorderSide(color: AppColors.border),
      ),
      itemBuilder: (context) => [
        for (final t in tracks)
          PopupMenuItem<String>(
            value: t.id,
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
                    t.title,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 12,
                    ),
                  ),
                ),
                if (t.artist.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      t.artist,
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
          borderRadius: BorderRadius.circular(6),
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
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(
          color: value ? AppColors.accent : AppColors.border,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
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

import 'package:flutter/material.dart';

import '../state/library_controller.dart';
import '../theme/app_theme.dart';

/// Persistent vertical operational rail on the right edge of the app.
/// Stacked modules (top → bottom): Volume, Play Threshold, Favorite,
/// Play Mode. Subtle horizontal dividers separate them.
class UtilityRail extends StatelessWidget {
  final LibraryController controller;
  const UtilityRail({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 100,
      color: AppColors.surface,
      child: ListenableBuilder(
        listenable: controller,
        builder: (ctx, _) {
          return Column(
            children: [
              const SizedBox(height: 12),
              _VolumeModule(controller: controller),
              const _RailDivider(),
              _ThresholdModule(controller: controller),
              const _RailDivider(),
              _FavoriteModule(controller: controller),
              const _RailDivider(),
              _ModeModule(controller: controller),
              const _RailDivider(),
              _ShowInFinderModule(controller: controller),
              const SizedBox(height: 12),
            ],
          );
        },
      ),
    );
  }
}

class _RailDivider extends StatelessWidget {
  const _RailDivider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: Container(
        height: 1,
        color: AppColors.border.withValues(alpha: 0.5),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel(this.label);

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      textAlign: TextAlign.center,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        letterSpacing: 1.0,
        color: AppColors.textTertiary,
      ),
    );
  }
}

// ---------- VOLUME ----------

class _VolumeModule extends StatelessWidget {
  final LibraryController controller;
  const _VolumeModule({required this.controller});

  IconData _iconFor(double v) {
    if (v <= 0.001) return Icons.volume_off_rounded;
    if (v < 0.33) return Icons.volume_mute_rounded;
    if (v < 0.66) return Icons.volume_down_rounded;
    return Icons.volume_up_rounded;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: controller.volumeListenable,
      builder: (ctx, volume, _) {
        return Column(
          children: [
            const _SectionLabel('VOLUME'),
            const SizedBox(height: 8),
            Icon(
              _iconFor(volume),
              size: 20,
              color: AppColors.textSecondary,
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 120,
              child: RotatedBox(
                quarterTurns: 3,
                child: SliderTheme(
                  data: const SliderThemeData(
                    trackHeight: 4,
                    activeTrackColor: AppColors.accent,
                    inactiveTrackColor: AppColors.border,
                    thumbColor: AppColors.accent,
                    thumbShape: RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                    ),
                    overlayShape: RoundSliderOverlayShape(
                      overlayRadius: 14,
                    ),
                  ),
                  child: Slider(
                    value: volume,
                    onChanged: (v) =>
                        controller.setVolume(v, commit: false),
                    onChangeEnd: (v) =>
                        controller.setVolume(v, commit: true),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${(volume * 100).round()}%',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        );
      },
    );
  }
}

// ---------- THRESHOLD ----------

class _ThresholdModule extends StatelessWidget {
  final LibraryController controller;
  const _ThresholdModule({required this.controller});

  @override
  Widget build(BuildContext context) {
    return _RailButton(
      tooltip: 'Play threshold (click to cycle)',
      onPressed: controller.cyclePlayThreshold,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _SectionLabel('THRESHOLD'),
          const SizedBox(height: 6),
          const Icon(
            Icons.timer_outlined,
            size: 22,
            color: AppColors.textSecondary,
          ),
          const SizedBox(height: 4),
          Text(
            '${controller.playThresholdSeconds}s',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------- FAVORITE ----------

class _FavoriteModule extends StatelessWidget {
  final LibraryController controller;
  const _FavoriteModule({required this.controller});

  @override
  Widget build(BuildContext context) {
    final track = controller.currentTrack;
    final isFav = track?.favorite ?? false;
    return _RailButton(
      tooltip: track == null
          ? 'Favorite (no track)'
          : (isFav ? 'Unfavorite' : 'Favorite'),
      onPressed: track == null
          ? null
          : () => controller.toggleFavorite(track.id),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _SectionLabel('FAVORITE'),
          const SizedBox(height: 6),
          Icon(
            isFav ? Icons.star_rounded : Icons.star_border_rounded,
            size: 26,
            color: isFav ? AppColors.favorite : AppColors.textSecondary,
          ),
        ],
      ),
    );
  }
}

// ---------- MODE ----------

class _ModeModule extends StatelessWidget {
  final LibraryController controller;
  const _ModeModule({required this.controller});

  IconData _iconFor(PlaybackMode m) {
    switch (m) {
      case PlaybackMode.sequential:
        return Icons.arrow_forward_rounded;
      case PlaybackMode.shuffle:
      case PlaybackMode.shuffleUnreviewed:
        return Icons.shuffle_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final mode = controller.playbackMode;
    final isActive = mode != PlaybackMode.sequential;
    return _RailButton(
      tooltip: 'Playback mode (S to cycle)',
      onPressed: controller.cyclePlaybackMode,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _SectionLabel('MODE'),
          const SizedBox(height: 6),
          Icon(
            _iconFor(mode),
            size: 22,
            color: isActive ? AppColors.accent : AppColors.textSecondary,
          ),
          const SizedBox(height: 4),
          Text(
            mode.label,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------- SHOW IN FINDER ----------

class _ShowInFinderModule extends StatelessWidget {
  final LibraryController controller;
  const _ShowInFinderModule({required this.controller});

  @override
  Widget build(BuildContext context) {
    final id = controller.currentTrackId;
    final enabled = id != null;
    return _RailButton(
      tooltip: enabled ? 'Show in Finder' : 'Show in Finder (no track)',
      onPressed: enabled ? () => controller.showTrackInFinder(id) : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _SectionLabel('FINDER'),
          const SizedBox(height: 6),
          Icon(
            Icons.open_in_new_rounded,
            size: 22,
            color: enabled
                ? AppColors.textSecondary
                : AppColors.textTertiary,
          ),
        ],
      ),
    );
  }
}

// ---------- shared button shell ----------

class _RailButton extends StatelessWidget {
  final String tooltip;
  final VoidCallback? onPressed;
  final Widget child;

  const _RailButton({
    required this.tooltip,
    required this.onPressed,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          hoverColor: AppColors.hoverRow,
          focusColor: AppColors.focusOverlay,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: SizedBox(
              width: double.infinity,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

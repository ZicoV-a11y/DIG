import 'package:flutter/material.dart';

import '../state/library_controller.dart';
import '../theme/app_theme.dart';
import 'skip_button.dart';
import 'track_artwork.dart';

class PlaybackBar extends StatelessWidget {
  final LibraryController controller;
  const PlaybackBar({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 116,
      color: AppColors.surface,
      padding: const EdgeInsets.fromLTRB(16, 12, 18, 12),
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final track = controller.currentTrack;
          final dur = track?.duration ?? Duration.zero;
          final hasTrack = track != null;

          return Row(
            children: [
              if (hasTrack) ...[
                TrackArtwork(seed: track.title, size: 76),
                const SizedBox(width: 14),
              ],
              SizedBox(
                width: 200,
                child: hasTrack
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            track.title,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              height: 1.1,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            track.artist,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 11,
                              height: 1.1,
                            ),
                          ),
                        ],
                      )
                    : const Text(
                        'No track selected',
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SkipButton(
                          label: '-1m',
                          onPressed: hasTrack
                              ? () => controller.skip(
                                    const Duration(minutes: -1),
                                  )
                              : null,
                        ),
                        SkipButton(
                          label: '-30',
                          onPressed: hasTrack
                              ? () => controller.skip(
                                    const Duration(seconds: -30),
                                  )
                              : null,
                        ),
                        SkipButton(
                          label: '-10',
                          onPressed: hasTrack
                              ? () => controller.skip(
                                    const Duration(seconds: -10),
                                  )
                              : null,
                        ),
                        SkipButton(
                          label: '-5',
                          onPressed: hasTrack
                              ? () => controller.skip(
                                    const Duration(seconds: -5),
                                  )
                              : null,
                        ),
                        const SizedBox(width: 14),
                        _CircleIconButton(
                          tooltip: 'Previous',
                          icon: Icons.skip_previous_rounded,
                          onPressed: controller.previous,
                        ),
                        const SizedBox(width: 4),
                        _PlayPauseButton(
                          isPlaying: controller.isPlaying,
                          onPressed: controller.togglePlayPause,
                        ),
                        const SizedBox(width: 4),
                        _CircleIconButton(
                          tooltip: 'Next',
                          icon: Icons.skip_next_rounded,
                          onPressed: controller.next,
                        ),
                        const SizedBox(width: 14),
                        SkipButton(
                          label: '+5',
                          onPressed: hasTrack
                              ? () => controller.skip(
                                    const Duration(seconds: 5),
                                  )
                              : null,
                        ),
                        SkipButton(
                          label: '+10',
                          onPressed: hasTrack
                              ? () => controller.skip(
                                    const Duration(seconds: 10),
                                  )
                              : null,
                        ),
                        SkipButton(
                          label: '+30',
                          onPressed: hasTrack
                              ? () => controller.skip(
                                    const Duration(seconds: 30),
                                  )
                              : null,
                        ),
                        SkipButton(
                          label: '+1m',
                          onPressed: hasTrack
                              ? () => controller.skip(
                                    const Duration(minutes: 1),
                                  )
                              : null,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _PositionRow(
                      controller: controller,
                      duration: dur,
                      enabled: hasTrack,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              const SizedBox(width: 40),
            ],
          );
        },
      ),
    );
  }
}

class _PositionRow extends StatelessWidget {
  final LibraryController controller;
  final Duration duration;
  final bool enabled;

  const _PositionRow({
    required this.controller,
    required this.duration,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Duration>(
      valueListenable: controller.positionListenable,
      builder: (context, pos, _) {
        final progress = duration.inMilliseconds == 0
            ? 0.0
            : (pos.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
        return Row(
          children: [
            SizedBox(
              width: 48,
              child: Text(
                _fmt(pos),
                textAlign: TextAlign.right,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: SliderTheme(
                data: const SliderThemeData(
                  trackHeight: 4,
                  activeTrackColor: AppColors.accent,
                  inactiveTrackColor: AppColors.border,
                  thumbColor: AppColors.accent,
                  thumbShape: RoundSliderThumbShape(enabledThumbRadius: 7),
                  overlayShape: RoundSliderOverlayShape(overlayRadius: 18),
                ),
                child: Slider(
                  value: progress,
                  onChanged: enabled ? controller.seekToFraction : null,
                ),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 48,
              child: Text(
                _fmtDuration(duration),
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _CircleIconButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  const _CircleIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          hoverColor: AppColors.hoverRow,
          focusColor: AppColors.focusOverlay,
          child: SizedBox(
            width: 38,
            height: 38,
            child: Icon(icon, size: 24, color: AppColors.textPrimary),
          ),
        ),
      ),
    );
  }
}

class _PlayPauseButton extends StatelessWidget {
  final bool isPlaying;
  final VoidCallback onPressed;
  const _PlayPauseButton({required this.isPlaying, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.accent,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onPressed,
        customBorder: const CircleBorder(),
        hoverColor: Colors.white.withValues(alpha: 0.10),
        focusColor: Colors.white.withValues(alpha: 0.18),
        child: SizedBox(
          width: 46,
          height: 46,
          child: Icon(
            isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
            color: Colors.white,
            size: 26,
          ),
        ),
      ),
    );
  }
}

String _fmt(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$m:$s';
}

String _fmtDuration(Duration d) => d == Duration.zero ? '—' : _fmt(d);

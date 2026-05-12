import 'package:flutter/material.dart';

import '../models/track.dart';
import '../services/filename_parser.dart';
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
      height: 180,
      color: AppColors.surface,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final track = controller.currentTrack;
          final dur = track?.duration ?? Duration.zero;
          final hasTrack = track != null;

          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(width: 16),
              SizedBox(
                width: 280,
                child: _NowPlayingBlock(
                  track: track,
                  onTap: hasTrack ? controller.revealCurrent : null,
                  onPivotTap: (name) => controller.setSearchQuery(name),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _TransportSubZone(
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
                        const SizedBox(width: 10),
                        SkipButton(
                          label: '-30',
                          onPressed: hasTrack
                              ? () => controller.skip(
                                    const Duration(seconds: -30),
                                  )
                              : null,
                        ),
                        const SizedBox(width: 10),
                        SkipButton(
                          label: '-10',
                          onPressed: hasTrack
                              ? () => controller.skip(
                                    const Duration(seconds: -10),
                                  )
                              : null,
                        ),
                        const SizedBox(width: 18),
                        _CircleIconButton(
                          tooltip: 'Previous',
                          icon: Icons.skip_previous_rounded,
                          onPressed: controller.previous,
                        ),
                        const SizedBox(width: 6),
                        _PlayPauseButton(
                          isPlaying: controller.isPlaying,
                          onPressed: controller.togglePlayPause,
                        ),
                        const SizedBox(width: 6),
                        _CircleIconButton(
                          tooltip: 'Next',
                          icon: Icons.skip_next_rounded,
                          onPressed: controller.next,
                        ),
                        const SizedBox(width: 18),
                        SkipButton(
                          label: '+10',
                          onPressed: hasTrack
                              ? () => controller.skip(
                                    const Duration(seconds: 10),
                                  )
                              : null,
                        ),
                        const SizedBox(width: 10),
                        SkipButton(
                          label: '+30',
                          onPressed: hasTrack
                              ? () => controller.skip(
                                    const Duration(seconds: 30),
                                  )
                              : null,
                        ),
                        const SizedBox(width: 10),
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
                    const SizedBox(height: 12),
                    _PositionRow(
                      controller: controller,
                      duration: dur,
                      enabled: hasTrack,
                    ),
                  ],
                ),
                ),
              ),
              const SizedBox(width: 16),
              _DeckArtwork(track: track),
              const SizedBox(width: 16),
            ],
          );
        },
      ),
    );
  }
}

/// Wrapper for the center transport sub-zone. Adds consistent internal
/// padding around the transport row + position row.
class _TransportSubZone extends StatelessWidget {
  final Widget child;

  const _TransportSubZone({required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: child,
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
                  trackHeight: 6,
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

class _NowPlayingBlock extends StatelessWidget {
  final Track? track;
  final VoidCallback? onTap;
  final void Function(String) onPivotTap;

  const _NowPlayingBlock({
    required this.track,
    required this.onTap,
    required this.onPivotTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = track;
    if (t == null) {
      return const Align(
        alignment: Alignment.centerLeft,
        child: Text(
          'No track selected',
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 12,
          ),
        ),
      );
    }

    final split = _splitTitleAndMix(t.displayTitle);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: 'Jump to current track',
          waitDuration: const Duration(milliseconds: 600),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              hoverColor: AppColors.hoverRow,
              focusColor: AppColors.focusOverlay,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: SizedBox(
                  width: double.infinity,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        split.primary,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                          height: 1.15,
                        ),
                      ),
                      if (split.subtitle != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          split.subtitle!,
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 16,
                            height: 1.15,
                          ),
                        ),
                      ],
                      const SizedBox(height: 4),
                      Text(
                        t.displayArtist.isEmpty ? '—' : t.displayArtist,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 14,
                          height: 1.15,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _formatTrackMeta(t),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        style: const TextStyle(
                          color: AppColors.textTertiary,
                          fontSize: 14,
                          height: 1.15,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: _PeoplePivots(track: t, onTap: onPivotTap),
        ),
      ],
    );
  }
}

/// 130 × 130 album artwork tile shown at the far right of the playback
/// header. Renders a placeholder square when no track is current.
/// Horizontal row of clickable pivots derived from people mentioned
/// on the currently-playing track (artist, co-artists, remixer,
/// featured). Tapping a pivot routes through `onTap(name)` —
/// upstream handler sets the library search query, so the table
/// filters down to that name's tracks instantly. Dropping the
/// query restores the prior view; nothing is rebuilt or re-indexed.
///
/// Rendered as a sibling of the "jump to current track" InkWell, not
/// nested inside it, so chip taps and now-playing taps stay distinct
/// hit zones.
class _PeoplePivots extends StatelessWidget {
  final Track track;
  final void Function(String) onTap;

  const _PeoplePivots({required this.track, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final pivots = extractPeoplePivots(
      artist: track.displayArtist,
      title: track.displayTitle,
    );
    if (pivots.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          for (final name in pivots) _PivotChip(label: name, onTap: () => onTap(name)),
        ],
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
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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

class _DeckArtwork extends StatelessWidget {
  final Track? track;
  const _DeckArtwork({required this.track});

  @override
  Widget build(BuildContext context) {
    final t = track;
    if (t == null) {
      return Container(
        width: 130,
        height: 130,
        decoration: BoxDecoration(
          color: AppColors.surfaceAlt,
          borderRadius: BorderRadius.zero,
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.zero,
      child: TrackArtwork(seed: t.displayTitle, size: 130),
    );
  }
}

/// Extracts a trailing parenthetical mix/version label from a track title.
/// Display-only — never mutates the underlying `track.title` string.
({String primary, String? subtitle}) _splitTitleAndMix(String title) {
  final trimmed = title.trim();
  if (!trimmed.endsWith(')')) {
    return (primary: trimmed, subtitle: null);
  }
  // Walk backward to find the matching open paren — depth-aware so
  // nested brackets like "feat. (X)" before the trailing group don't
  // throw off the split.
  var depth = 0;
  int? openIdx;
  for (var i = trimmed.length - 1; i >= 0; i--) {
    final c = trimmed[i];
    if (c == ')') {
      depth++;
    } else if (c == '(') {
      depth--;
      if (depth == 0) {
        openIdx = i;
        break;
      }
    }
  }
  if (openIdx == null || openIdx == 0) {
    return (primary: trimmed, subtitle: null);
  }
  final primary = trimmed.substring(0, openIdx).trim();
  final subtitle = trimmed.substring(openIdx);
  if (primary.isEmpty) return (primary: trimmed, subtitle: null);
  return (primary: primary, subtitle: subtitle);
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
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        child: InkWell(
          onTap: onPressed,
          customBorder: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
          hoverColor: AppColors.hoverRow,
          focusColor: AppColors.focusOverlay,
          child: SizedBox(
            width: 48,
            height: 64,
            child: Icon(icon, size: 28, color: AppColors.textPrimary),
          ),
        ),
      ),
    );
  }
}

class _PlayPauseButton extends StatelessWidget {
  final bool isPlaying;
  final VoidCallback onPressed;
  const _PlayPauseButton({
    required this.isPlaying,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    // Play/pause is sacred — always visible, always tappable. Even
    // mid-load (slow Dropbox materialisation, cold-cache AIFF, etc.)
    // the user can still pause/abort. Replacing the icon with a
    // spinner and disabling taps used to lock the button when a load
    // stalled; now `controller.togglePlayPause` handles the in-flight
    // case (engine.pause() during load aborts cleanly).
    return Material(
      color: AppColors.accent,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      child: InkWell(
        onTap: onPressed,
        customBorder:
            const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        hoverColor: Colors.white.withValues(alpha: 0.10),
        focusColor: Colors.white.withValues(alpha: 0.18),
        child: SizedBox(
          width: 80,
          height: 80,
          child: Icon(
            isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
            color: Colors.white,
            size: 32,
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

String _formatTrackMeta(Track t) {
  final dur = t.duration > Duration.zero ? _fmt(t.duration) : '—';
  final bpm = (t.bpm != null && t.bpm! > 0) ? '${t.bpm!.round()}' : '—';
  final key = t.displayKey.isEmpty ? '—' : t.displayKey;
  return '$dur • $bpm BPM • $key';
}

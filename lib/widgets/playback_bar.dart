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
      child: LayoutBuilder(
        builder: (ctx, deckConstraints) {
          // Two coupled positioning rules:
          //
          // 1. The play button (centre of the transport row) sits at
          //    the app's actual horizontal centre (W/2). Before this
          //    change it centred inside the Expanded zone, which is
          //    offset rightward because Now Playing eats space on
          //    the left — so play landed ~75 px right of the app's
          //    geometric centre. We re-anchor it via Align with a
          //    computed alignment fraction inside the Expanded zone.
          //
          // 2. Now Playing's layout SLOT stays at 280 px so the
          //    transport row's position is unaffected by Now
          //    Playing's content. But Now Playing's CONTENT can
          //    bleed rightward via OverflowBox, growing into the
          //    empty space between the slot and the transport's
          //    left edge. This means longer titles render without
          //    truncating, with no font-size scaling — pure
          //    horizontal expansion.
          final W = deckConstraints.maxWidth;

          // Right-zone now holds artwork only — volume moved back to
          // the utility rail. Right zone width from edge:
          //   artwork 110 + right pad 16 = 126 from right edge
          const transportButtonRowWidth = 552.0;
          final transportLeftScreen =
              W / 2 - transportButtonRowWidth / 2;

          // Now Playing's render width can extend from the slot's
          // left edge (x=16) up to the transport's left edge minus
          // a breathing margin. Capped at 600 — beyond that the
          // text feels stretched.
          const breathingBeforeTransport = 24.0;
          final maxNowPlayingRender =
              (transportLeftScreen - 16 - breathingBeforeTransport)
                  .clamp(280.0, 600.0);

          // Alignment for the button row inside the Expanded zone.
          // Layout: pad16 + NP280 + gap16 + Expanded + gap16 + artwork110 + pad16
          // Expanded spans [312, W-142]. Width = W - 454. Its centre
          // is at W/2 + 85 (85 px right of app centre because of the
          // left-side Now Playing block). We want the button row
          // centred at W/2.
          //   alignment.x ∈ [-1, 1] where -1 = parent-left, 1 = parent-right
          //   shift_distance_from_centre = alignment.x × (parent_width - child_width) / 2
          //   -85 = alignment.x × (W - 454 - 552) / 2
          //   alignment.x = -170 / (W - 1006)
          // Clamp so we never pin past the edges if the window
          // shrinks below the 1180 minimum.
          final buttonAlignmentX =
              (-170.0 / (W - 1006)).clamp(-1.0, 1.0);

          return ListenableBuilder(
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
                    child: OverflowBox(
                      // Slot width stays 280 (transport position is
                      // unaffected) but the content can render up to
                      // maxNowPlayingRender wide, bleeding right.
                      maxWidth: maxNowPlayingRender,
                      minWidth: 280,
                      alignment: Alignment.centerLeft,
                      child: _NowPlayingBlock(
                        track: track,
                        onTap:
                            hasTrack ? controller.revealCurrent : null,
                        onPivotTap: (name) =>
                            controller.setSearchQuery(name),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _TransportSubZone(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Align(
                      // Anchor the button row's centre at the app's
                      // horizontal centre (W/2). See the alignment
                      // math at the top of this builder.
                      alignment: Alignment(buttonAlignmentX, 0),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
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
                        const SizedBox(width: 14),
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
                        const SizedBox(width: 14),
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
                    ),
                    const SizedBox(height: 6),
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
                  _DeckArtwork(
                    track: track,
                    controller: controller,
                  ),
                  const SizedBox(width: 16),
                ],
              );
            },
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

    // Fixed font sizes — the block's text rendering width can grow
    // (OverflowBox in PlaybackBar lets longer titles render without
    // truncating) but the typography itself stays calm. Earlier
    // attempts at LayoutBuilder-driven font scaling here made the
    // text grow with the block; user feedback was that the block
    // should *use* the space, not balloon the text.
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
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
                        t.displayArtist.isEmpty
                            ? '—'
                            : t.displayArtist,
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
  final LibraryController controller;
  const _DeckArtwork({required this.track, required this.controller});

  @override
  Widget build(BuildContext context) {
    final t = track;
    if (t == null) {
      // Placeholder — no track loaded, so no favorite overlay
      // either. Same neutral square as before.
      return Container(
        width: 110,
        height: 110,
        decoration: BoxDecoration(
          color: AppColors.surfaceAlt,
          borderRadius: BorderRadius.zero,
        ),
      );
    }
    final isFav = t.favorite;
    return SizedBox(
      width: 130,
      height: 130,
      // Stack puts the favorite tap target ON the cover art instead
      // of in the utility rail. The tinted backdrop behind the star
      // is load-bearing for legibility — without it the star washes
      // out against pastel artwork colours.
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.zero,
            child: TrackArtwork(seed: t.displayTitle, size: 110),
          ),
          Positioned(
            top: 6,
            right: 6,
            child: _ArtworkFavoriteButton(
              isFav: isFav,
              onPressed: () => controller.toggleFavorite(t.uid),
            ),
          ),
        ],
      ),
    );
  }
}

/// Favorite toggle rendered as an overlay on the deck artwork. Uses
/// a slightly-translucent dark backdrop so the star stays legible
/// against any cover colour. Replaces the utility-rail FAVORITE
/// module: the action is now where the eye already lives (next to
/// the track image) rather than tucked away in the rail.
class _ArtworkFavoriteButton extends StatelessWidget {
  final bool isFav;
  final VoidCallback onPressed;
  const _ArtworkFavoriteButton({
    required this.isFav,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.45),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: Tooltip(
        message: isFav ? 'Unfavorite' : 'Favorite',
        waitDuration: const Duration(milliseconds: 400),
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 30,
            height: 30,
            child: Icon(
              isFav ? Icons.star_rounded : Icons.star_border_rounded,
              size: 18,
              color: isFav ? AppColors.favorite : Colors.white,
            ),
          ),
        ),
      ),
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

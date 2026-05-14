import 'package:flutter/material.dart';

import '../state/library_controller.dart';
import '../theme/app_theme.dart';
import '../utils/file_format.dart';
import 'activity_log_dialog.dart';
import 'duplicates_audit_dialog.dart';
import 'load_state_dialog.dart';
import 'move_copy_dialog.dart';

/// Persistent vertical operational rail on the right edge of the app.
/// Three vertical sections:
///
///   1. **Volume** — pinned at the top. Tallest module. Anchors the
///      rail visually and gives the user a persistent global-feeling
///      control.
///   2. **Reorderable utilities** — Threshold, Mode, Audit, History,
///      Move/Copy, Finder. The user can drag-reorder these via the
///      handle on each card; order persists per-user in
///      `app_settings.utility_rail_order`. Volume is intentionally
///      outside this section so it can never accidentally land
///      mid-stack.
///   3. **Lock-order toggle** — tiny control at the bottom. When
///      locked, drag handles disappear and reorder gestures are
///      refused; users who don't want to risk accidental drags can
///      pin the order they like.
///
/// Layout philosophy ("persistent operational sidecar" rather than
/// "miscellaneous buttons"): every card in the rail should feel
/// intentional, persistent, spatially stable, and operationally
/// important.
///
/// History of moves: Favorite → deck-artwork overlay (2026-05-13);
/// Refresh + Save/Export/Load/Import → removed from rail entirely
/// (Refresh is now a rescan-on-source flow; Save/Export/Load/Import
/// live in dedicated operational-state surfaces, not the persistent
/// rail).
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
          final order = controller.utilityRailOrder;
          final locked = controller.utilityRailLocked;
          return Column(
            children: [
              const SizedBox(height: 12),
              _VolumeModule(controller: controller),
              const _RailDivider(),
              // Middle section: reorderable utility cards. ListView
              // gives it independent scrolling so the Volume anchor
              // and Lock toggle stay pinned to top/bottom of the
              // rail at all window heights.
              Expanded(
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(ctx)
                      .copyWith(scrollbars: false),
                  child: ReorderableListView.builder(
                    physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                    buildDefaultDragHandles: false,
                    proxyDecorator: _railDragProxy,
                    itemCount: order.length,
                    onReorder: locked
                        ? (_, _) {}
                        : (oldIdx, newIdx) {
                            final reordered = [...order];
                            final item = reordered.removeAt(oldIdx);
                            final insertAt =
                                newIdx > oldIdx ? newIdx - 1 : newIdx;
                            reordered.insert(insertAt, item);
                            controller.setUtilityRailOrder(reordered);
                          },
                    itemBuilder: (ctx, i) {
                      final key = order[i];
                      return _RailCardSlot(
                        key: ValueKey(key),
                        index: i,
                        locked: locked,
                        child: _moduleFor(key, controller),
                      );
                    },
                  ),
                ),
              ),
              const _RailDivider(),
              _LockOrderToggle(controller: controller),
              const SizedBox(height: 12),
            ],
          );
        },
      ),
    );
  }
}

/// Resolve a persisted utility-rail key to the corresponding module
/// widget. Unknown keys (e.g. an old persisted key after a module
/// got removed) render as `SizedBox.shrink()` — defensive null
/// rendering so a stale setting never crashes the rail. Defaults
/// + filtering at hydrate prevent this from happening in practice.
Widget _moduleFor(String key, LibraryController controller) {
  switch (key) {
    case 'threshold':
      return _ThresholdModule(controller: controller);
    case 'mode':
      return _ModeModule(controller: controller);
    case 'audit':
      return _AuditModule(controller: controller);
    case 'history':
      return _HistoryModule(controller: controller);
    case 'movecopy':
      return _MoveCopyModule(controller: controller);
    case 'finder':
      return _ShowInFinderModule(controller: controller);
    case 'loadstate':
      return _LoadStateModule(controller: controller);
    default:
      return const SizedBox.shrink();
  }
}

/// Visual treatment applied to the card while it's being dragged
/// (the "ghost" floating under the cursor). Slight elevation + a
/// faintly brighter background reads as "this is being held".
Widget _railDragProxy(
  Widget child,
  int index,
  Animation<double> animation,
) {
  return AnimatedBuilder(
    animation: animation,
    builder: (ctx, _) {
      return Material(
        elevation: 6,
        color: AppColors.surfaceAlt,
        child: child,
      );
    },
    child: child,
  );
}

/// Wraps each reorderable utility card with its drag handle (visible
/// only when the rail isn't locked) and a thin divider beneath. The
/// divider mirrors the previous `_RailDivider` rhythm so the new
/// reorderable layout reads identically to the old static one when
/// the rail is locked.
class _RailCardSlot extends StatelessWidget {
  final int index;
  final bool locked;
  final Widget child;
  const _RailCardSlot({
    super.key,
    required this.index,
    required this.locked,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          children: [
            child,
            // Drag handle in the top-right corner. Subtle by design —
            // the rail is narrow, anything bigger than a small icon
            // would crowd the module's primary content.
            if (!locked)
              Positioned(
                top: 2,
                right: 2,
                child: ReorderableDragStartListener(
                  index: index,
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(
                      Icons.drag_indicator_rounded,
                      size: 12,
                      color: AppColors.textTertiary,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const _RailDivider(),
      ],
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

// ---------- AUDIT ----------

class _AuditModule extends StatelessWidget {
  final LibraryController controller;
  const _AuditModule({required this.controller});

  @override
  Widget build(BuildContext context) {
    // Use the cached count getter, NOT `multiVariantBuckets.length`.
    // The rail rebuilds on every controller notify, so reading the
    // full list here would re-`groupBySongIdentity` the entire
    // library (~12k tracks) per rebuild — that was the main cause
    // of the UI freezing reported during normal browsing.
    final count = controller.multiVariantBucketCount;
    final hasAny = count > 0;
    return _RailButton(
      tooltip: hasAny
          ? 'Audit $count multi-variant songs'
          : 'No multi-variant songs to audit',
      // Always clickable — even with zero variants, the dialog gives
      // a "you're clean" confirmation. Surfaces the count badge
      // either way so the user always sees the system's current
      // matching state at a glance.
      onPressed: () => showDuplicatesAuditDialog(
        context: context,
        controller: controller,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _SectionLabel('AUDIT'),
          const SizedBox(height: 6),
          Icon(
            Icons.layers_rounded,
            size: 22,
            color: hasAny
                ? AppColors.textSecondary
                : AppColors.textTertiary,
          ),
          const SizedBox(height: 4),
          Text(
            '$count',
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
              color: AppColors.textPrimary,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------- HISTORY ----------

class _HistoryModule extends StatelessWidget {
  final LibraryController controller;
  const _HistoryModule({required this.controller});

  @override
  Widget build(BuildContext context) {
    // No live count badge — events accumulate forever, so "N events"
    // would just grow unboundedly without giving the user
    // actionable info. The dialog itself surfaces the total.
    return _RailButton(
      tooltip: 'Activity log — lifecycle events the system has recorded',
      onPressed: () => showActivityLogDialog(
        context: context,
        controller: controller,
      ),
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SectionLabel('HISTORY'),
          SizedBox(height: 6),
          Icon(
            Icons.history_rounded,
            size: 22,
            color: AppColors.textSecondary,
          ),
          SizedBox(height: 4),
          // Spacer matching the height of count badges in adjacent
          // modules (AUDIT, etc.) so the rail items align.
          SizedBox(height: 14),
        ],
      ),
    );
  }
}

// ---------- MOVE / COPY ----------

class _MoveCopyModule extends StatelessWidget {
  final LibraryController controller;
  const _MoveCopyModule({required this.controller});

  @override
  Widget build(BuildContext context) {
    // Operates on the currently-loaded/playing track. Same signal
    // SHOW IN FINDER uses — keeps the per-track action buttons in
    // the rail behaving consistently. Disabled when nothing's
    // loaded so the user doesn't end up opening a dialog with
    // nothing to act on.
    final track = controller.currentTrack;
    final enabled = track != null;
    return _RailButton(
      tooltip: enabled
          ? 'Move or copy the current track to another watched folder'
          : 'Play or load a track first',
      onPressed: enabled
          ? () => showMoveCopyDialog(
                context: context,
                controller: controller,
                track: track,
              )
          : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _SectionLabel('MOVE / COPY'),
          const SizedBox(height: 6),
          Icon(
            Icons.drive_file_move_rounded,
            size: 22,
            color: enabled
                ? AppColors.textSecondary
                : AppColors.textTertiary,
          ),
          // Spacer to match the height of count badges in
          // adjacent modules so rail items stay aligned.
          const SizedBox(height: 18),
        ],
      ),
    );
  }
}

// ---------- SHOW IN FINDER ----------

class _ShowInFinderModule extends StatefulWidget {
  final LibraryController controller;
  const _ShowInFinderModule({required this.controller});

  @override
  State<_ShowInFinderModule> createState() => _ShowInFinderModuleState();
}

class _ShowInFinderModuleState extends State<_ShowInFinderModule> {
  final GlobalKey _buttonKey = GlobalKey();

  /// Picks which Finder reveal path to use: when the current track is
  /// a multi-variant bucket primary, surfaces a per-format menu
  /// anchored to the rail button so the user picks exactly which file
  /// to open (mirrors the row-level right-click submenu). For
  /// single-variant rows the call falls through to the existing
  /// `showCurrentTrackInFinder` which honors playing-instance +
  /// fallback semantics.
  Future<void> _handlePress() async {
    final controller = widget.controller;
    final current = controller.currentTrack;
    if (current == null) return;
    final view = controller.aggregatedViewForPrimary(current);
    if (view == null || !view.hasSiblings) {
      await controller.showCurrentTrackInFinder();
      return;
    }

    final renderBox =
        _buttonKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) {
      // Defensive fallback — should never happen in practice.
      await controller.showCurrentTrackInFinder();
      return;
    }
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final topLeft = renderBox.localToGlobal(Offset.zero);
    final size = renderBox.size;
    // Anchor the menu at the button's top-right corner so it opens
    // alongside the rail, not on top of it.
    final anchor = Rect.fromLTWH(
      topLeft.dx + size.width,
      topLeft.dy,
      0,
      size.height,
    );

    final result = await showMenu<int>(
      context: context,
      position: RelativeRect.fromRect(anchor, Offset.zero & overlayBox.size),
      color: AppColors.surface,
      elevation: 6,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
        side: const BorderSide(color: AppColors.border),
      ),
      items: [
        for (var i = 0; i < view.variants.length; i++)
          PopupMenuItem<int>(
            value: i,
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
                  () {
                    final f = fileFormatLabel(view.variants[i].filename);
                    return f.isEmpty
                        ? 'Show variant ${i + 1} in Finder'
                        : 'Show $f in Finder';
                  }(),
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
      ],
    );

    if (result == null) return;
    if (result < 0 || result >= view.variants.length) return;
    await controller.revealVariantInFinder(view.variants[result]);
  }

  @override
  Widget build(BuildContext context) {
    final hasCurrent = widget.controller.currentTrackPath != null;
    return KeyedSubtree(
      key: _buttonKey,
      child: _RailButton(
        tooltip:
            hasCurrent ? 'Show in Finder' : 'Show in Finder (no track)',
        onPressed: hasCurrent ? _handlePress : null,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _SectionLabel('FINDER'),
            const SizedBox(height: 6),
            Icon(
              Icons.open_in_new_rounded,
              size: 22,
              color: hasCurrent
                  ? AppColors.textSecondary
                  : AppColors.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}


// ---------- LOAD OPERATIONAL STATE ----------

/// Opens the Load Operational State dialog. Was previously part of
/// the deleted `_DataModule` (Save / Export / Load / Import). The
/// other three actions still belong on dedicated operational-state
/// surfaces, but Load earns a rail slot because it's the entry
/// point to the most common operational-state navigation gesture
/// (switching between Systems / Saves / Shared Libraries).
///
/// Per [feedback_operational_state_language] the user-visible
/// vocabulary stays operational — "Load operational state", not
/// "Restore from backup" / "Open snapshot" / etc.
class _LoadStateModule extends StatelessWidget {
  final LibraryController controller;
  const _LoadStateModule({required this.controller});

  @override
  Widget build(BuildContext context) {
    return _RailButton(
      tooltip:
          'Switch the running app to a different library reality '
          '— Systems / Saves / Shared Libraries.',
      onPressed: () => showLoadStateDialog(
        context: context,
        controller: controller,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _SectionLabel('LOAD'),
          const SizedBox(height: 6),
          Icon(
            Icons.swap_horiz_rounded,
            size: 22,
            color: AppColors.textSecondary,
          ),
        ],
      ),
    );
  }
}

// ---------- VOLUME (pinned anchor at the top of the rail) ----------

/// Pinned at the top of the rail. Visually heavier than the
/// reorderable cards beneath it so it reads as the persistent
/// global anchor rather than one of the swappable utilities. The
/// rail's "Lock Order" affordance and reorder gestures never touch
/// this module — it sits outside the ReorderableListView entirely.
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
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _iconFor(volume),
                size: 22,
                color: AppColors.textSecondary,
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 140,
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
              const SizedBox(height: 8),
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
          ),
        );
      },
    );
  }
}

// ---------- LOCK ORDER (bottom-of-rail toggle) ----------

/// Small toggle at the bottom of the rail that disables / enables
/// the drag-reorder behavior. Locked is the safer default for users
/// who don't want to risk an accidental drag rearranging their
/// rail. The state persists across launches.
class _LockOrderToggle extends StatelessWidget {
  final LibraryController controller;
  const _LockOrderToggle({required this.controller});

  @override
  Widget build(BuildContext context) {
    final locked = controller.utilityRailLocked;
    return _RailButton(
      tooltip: locked
          ? 'Order locked — tap to allow reordering'
          : 'Order unlocked — tap to lock the current arrangement',
      onPressed: () => controller.setUtilityRailLocked(!locked),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              locked
                  ? Icons.lock_outline_rounded
                  : Icons.lock_open_rounded,
              size: 16,
              color: locked
                  ? AppColors.textSecondary
                  : AppColors.textTertiary,
            ),
            const SizedBox(height: 4),
            Text(
              locked ? 'LOCKED' : 'UNLOCKED',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.0,
                color: locked
                    ? AppColors.textSecondary
                    : AppColors.textTertiary,
              ),
            ),
          ],
        ),
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

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/intelligence_export.dart';
import '../state/library_controller.dart';
import '../theme/app_theme.dart';
import '../utils/file_format.dart';
import 'import_confirm_dialog.dart';

/// Persistent vertical operational rail on the right edge of the app.
/// Stacked modules (top → bottom): Volume, Play Threshold, Favorite,
/// Play Mode. Subtle horizontal dividers separate them.
class UtilityRail extends StatelessWidget {
  final LibraryController controller;
  const UtilityRail({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    // The rail's stacked modules can overflow vertically when the
    // window is short. Wrap in a SingleChildScrollView so the whole
    // rail scrolls as a unit — never affecting the deck or workspace
    // layout. Hide the platform scrollbar; the rail is narrow and the
    // scroll is by drag/wheel, not by clicking a thumb.
    return Container(
      width: 100,
      color: AppColors.surface,
      child: ListenableBuilder(
        listenable: controller,
        builder: (ctx, _) {
          return ScrollConfiguration(
            behavior: ScrollConfiguration.of(ctx).copyWith(scrollbars: false),
            child: SingleChildScrollView(
              // Bouncing physics gives the macOS-native elastic feel
              // when overscrolling top/bottom. Combined with letting
              // the wheel event reach the rail (HomeScreen excludes
              // this region from its table-forwarding handler), the
              // rail now scrolls smoothly via trackpad/wheel.
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              child: Column(
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
                  const _RailDivider(),
                  _DataModule(controller: controller),
                  const SizedBox(height: 12),
                ],
              ),
            ),
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
          : () => controller.toggleFavorite(track.uid),
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

// ---------- DATA (Export / Import) ----------

class _DataModule extends StatelessWidget {
  final LibraryController controller;
  const _DataModule({required this.controller});

  /// Quick local save: overwrites the canonical snapshot at
  /// `~/Documents/Music Tracker/intelligence.json`. Always the same
  /// filename, so repeated saves don't pile up timestamped clones —
  /// you have exactly one current-state file you can hand off,
  /// version-control, or restore from. The timestamped variant is
  /// still available via the picker-based EXPORT button below.
  Future<void> _runSave(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final dir = await IntelligenceExportFile.defaultExportDirectory();
      final path =
          '${dir.path}/${IntelligenceExportFile.canonicalFilename}';
      final file = await controller.exportIntelligence(toPath: path);
      messenger?.showSnackBar(
        SnackBar(
          content: Text('Saved → ${file.path}'),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: 'Show',
            onPressed: () {
              try {
                Process.run('open', ['-R', file.path]);
              } catch (_) {/* best-effort */}
            },
          ),
        ),
      );
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Save failed: $e')),
      );
    }
  }

  /// Picker-based export — useful when the user wants to write to a
  /// specific drive or folder (e.g. handing the file to another
  /// machine on a USB stick).
  Future<void> _runExport(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final defaultDir =
        await IntelligenceExportFile.defaultExportDirectory();
    final defaultName = IntelligenceExportFile.defaultFilename();
    final chosen = await FilePicker.saveFile(
      dialogTitle: 'Export intelligence',
      fileName: defaultName,
      initialDirectory: defaultDir.path,
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (chosen == null) return;
    final path = chosen.endsWith('.json') ? chosen : '$chosen.json';
    try {
      final file = await controller.exportIntelligence(toPath: path);
      messenger?.showSnackBar(
        SnackBar(
          content: Text('Exported intelligence → ${file.path}'),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    }
  }

  Future<void> _runImport(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Import intelligence',
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    final picked = result?.files.singleOrNull?.path;
    if (picked == null) return;
    final file = File(picked);

    try {
      final preview = await controller.previewIntelligenceImport(file);
      if (!context.mounted) return;
      final confirmed = await ImportConfirmDialog.show(
        context,
        filename: file.uri.pathSegments.isNotEmpty
            ? file.uri.pathSegments.last
            : picked,
        recordCount: preview.records.length,
        parseErrors: preview.parseErrors.length,
      );
      if (confirmed != true) return;
      final summary =
          await controller.applyIntelligenceImport(preview.records);
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            'Imported ${summary.recordsRead} records '
            '(merged ${summary.mergedByUid + summary.mergedByFingerprint}, '
            'new ${summary.insertedAsGhost}'
            '${summary.skippedErrors.isNotEmpty ? ", errors ${summary.skippedErrors.length}" : ""})',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    } on FormatException catch (e) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Import failed: ${e.message}')),
      );
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Import failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const _SectionLabel('DATA'),
        const SizedBox(height: 4),
        _RailButton(
          tooltip:
              'Quick local save → ~/Documents/Music Tracker/',
          onPressed: () => _runSave(context),
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.save_outlined,
                  size: 20,
                  color: AppColors.textSecondary,
                ),
                SizedBox(height: 2),
                Text(
                  'SAVE',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
        _RailButton(
          tooltip: 'Export to a chosen location',
          onPressed: () => _runExport(context),
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.file_upload_outlined,
                  size: 20,
                  color: AppColors.textSecondary,
                ),
                SizedBox(height: 2),
                Text(
                  'EXPORT',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
        _RailButton(
          tooltip: 'Import intelligence from a JSON file',
          onPressed: () => _runImport(context),
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.file_download_outlined,
                  size: 20,
                  color: AppColors.textSecondary,
                ),
                SizedBox(height: 2),
                Text(
                  'IMPORT',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
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

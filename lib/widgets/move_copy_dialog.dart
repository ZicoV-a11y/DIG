import 'package:flutter/material.dart';

import '../models/source.dart';
import '../models/track.dart';
import '../state/library_controller.dart';
import '../theme/app_theme.dart';
import '../utils/file_format.dart';

/// Summary of a Move/Copy batch the dialog completed. Returned to
/// the caller so a SnackBar / log line can narrate the result.
class MoveCopyDialogOutcome {
  final bool wasMove;
  final List<String> succeededDestNames;
  final List<({String destName, String reason})> failures;

  const MoveCopyDialogOutcome({
    required this.wasMove,
    required this.succeededDestNames,
    required this.failures,
  });

  bool get hasAnyResult =>
      succeededDestNames.isNotEmpty || failures.isNotEmpty;
}

/// One-stop dialog for moving or copying a file to one or more
/// watched sources. Replaces the flat per-destination right-click
/// items so the menu doesn't bloat once the user has 5+ sources.
///
/// Action is mutually exclusive: a single dialog session is either
/// a Move (single destination) or a Copy (one or many destinations).
/// User clarification (2026-05-11): "there can't be a copy AND move
/// — it's one or the other, but selected from a window."
Future<MoveCopyDialogOutcome?> showMoveCopyDialog({
  required BuildContext context,
  required LibraryController controller,
  required Track track,
}) {
  return showGeneralDialog<MoveCopyDialogOutcome>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: Colors.black.withValues(alpha: 0.55),
    transitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (_, _, _) {
      return _MoveCopyDialog(controller: controller, track: track);
    },
  );
}

class _MoveCopyDialog extends StatefulWidget {
  final LibraryController controller;
  final Track track;
  const _MoveCopyDialog({required this.controller, required this.track});

  @override
  State<_MoveCopyDialog> createState() => _MoveCopyDialogState();
}

class _MoveCopyDialogState extends State<_MoveCopyDialog> {
  /// `false` = Move, `true` = Copy. Default to Copy because it's
  /// the safer / additive operation — Move is a destructive
  /// relocation, easier to mis-click on.
  bool _isCopy = true;
  final Set<String> _selectedDestIds = {};
  bool _busy = false;
  /// The physical file the user is choosing to act on. When the
  /// underlying bucket has multiple codec variants (e.g. MP3 + AIFF
  /// + WAV), the picker lets the user pick which one to move/copy —
  /// codec choice is operationally meaningful for DJs (lossless for
  /// home listening, MP3 for travel/USB drives). Defaults to the
  /// row the user right-clicked; falls back to that on first frame.
  late Track _selectedVariant = widget.track;

  @override
  void initState() {
    super.initState();
    // Re-render when the controller's track list mutates — file
    // watcher events (external delete / rename), scan completions,
    // and Copy/Move side effects all flow through here. Without
    // this, the dialog freezes its variant snapshot at open time
    // and silently lies about what's on disk.
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {
      // If the selected variant disappeared (file deleted externally
      // while the dialog was open), pick the most-recently-found
      // surviving variant of the same bucket as the new default.
      // Falls back to widget.track as a last resort — the picker
      // still renders even if all variants are gone.
      final fresh = widget.controller.variantsFor(widget.track);
      final stillExists = fresh.any(
        (v) => v.path == _selectedVariant.path,
      );
      if (!stillExists && fresh.isNotEmpty) {
        _selectedVariant = fresh.first;
        _selectedDestIds.remove(_selectedVariant.sourceId);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final destinations = _validDestinations();
    final currentSource = _findSource(_selectedVariant.sourceId);
    final canApply = !_busy && _selectedDestIds.isNotEmpty;
    // Recompute each build — the dialog stays in sync with external
    // file events via the controller listener above.
    final variants = widget.controller.variantsFor(widget.track);
    final hasMultipleVariants = variants.length > 1;

    return Center(
      child: Material(
        color: AppColors.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: BorderSide(color: AppColors.border),
        ),
        elevation: 10,
        child: SizedBox(
          width: 620,
          height: hasMultipleVariants ? 640 : 560,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(
                track: _selectedVariant,
                currentSource: currentSource,
                onClose: () => Navigator.of(context).pop(),
              ),
              const Divider(height: 1, color: AppColors.border),
              if (hasMultipleVariants) ...[
                _VariantPicker(
                  variants: variants,
                  selected: _selectedVariant,
                  resolveSourceName: (sourceId) =>
                      _findSource(sourceId)?.displayName ?? '—',
                  onChanged: _selectVariant,
                ),
                const Divider(height: 1, color: AppColors.border),
              ],
              _ActionToggle(
                isCopy: _isCopy,
                onChanged: (copy) {
                  setState(() {
                    _isCopy = copy;
                    // Switching to Move reduces the selection to
                    // at most one — multi-destination Move makes
                    // no semantic sense (you can't have one file
                    // in two places after a move).
                    if (!copy && _selectedDestIds.length > 1) {
                      final keep = _selectedDestIds.first;
                      _selectedDestIds
                        ..clear()
                        ..add(keep);
                    }
                  });
                },
              ),
              const Divider(height: 1, color: AppColors.border),
              Expanded(
                child: destinations.isEmpty
                    ? const _NoDestinationsState()
                    : ListView(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        children: [
                          for (final dest in destinations)
                            _DestinationRow(
                              source: dest,
                              checked: _selectedDestIds.contains(dest.id),
                              multiSelect: _isCopy,
                              isCurrent:
                                  dest.id == _selectedVariant.sourceId,
                              onToggle: () => _toggle(dest.id),
                            ),
                        ],
                      ),
              ),
              const Divider(height: 1, color: AppColors.border),
              _Footer(
                isCopy: _isCopy,
                selectedCount: _selectedDestIds.length,
                canApply: canApply,
                busy: _busy,
                onCancel: () => Navigator.of(context).pop(),
                onApply: () => _apply(destinations),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _selectVariant(Track v) {
    setState(() {
      _selectedVariant = v;
      // If the previously-selected destination is now the variant's
      // own source (copying to itself is rejected by the repo), drop
      // it from the selection so the Apply button reflects reality.
      _selectedDestIds.remove(v.sourceId);
    });
  }

  void _toggle(String destId) {
    setState(() {
      if (_isCopy) {
        if (_selectedDestIds.contains(destId)) {
          _selectedDestIds.remove(destId);
        } else {
          _selectedDestIds.add(destId);
        }
      } else {
        // Move = single-select. Tapping a different row replaces
        // the selection rather than adding to it.
        if (_selectedDestIds.contains(destId)) {
          _selectedDestIds.remove(destId);
        } else {
          _selectedDestIds
            ..clear()
            ..add(destId);
        }
      }
    });
  }

  List<Source> _validDestinations() {
    // Show every top-level watched folder — including the track's
    // current source. The current row renders disabled
    // ("CURRENT LOCATION") so the user sees the full routing graph
    // ("file is here → could go there") instead of a single
    // destination implying there's only one possible target.
    // Sub-views stay excluded — they're filter projections of a
    // parent source, not independent storage targets.
    return widget.controller.sources
        .where((s) => !s.isSubView)
        .toList(growable: false);
  }

  Source? _findSource(String id) {
    for (final s in widget.controller.sources) {
      if (s.id == id) return s;
    }
    return null;
  }

  Future<void> _apply(List<Source> destinations) async {
    if (_selectedDestIds.isEmpty) return;
    setState(() => _busy = true);
    final picked = destinations
        .where((s) => _selectedDestIds.contains(s.id))
        .toList(growable: false);
    final succeeded = <String>[];
    final failures = <({String destName, String reason})>[];

    if (_isCopy) {
      // Sequential — keeps Sqflite transactions ordered and gives
      // the user partial-success feedback if one destination fails.
      for (final dest in picked) {
        final r = await widget.controller.copyTrack(
          track: _selectedVariant,
          destSource: dest,
        );
        if (r.success) {
          succeeded.add(dest.displayName);
        } else {
          failures.add((
            destName: dest.displayName,
            reason: r.errorReason ?? 'unknown error',
          ));
        }
      }
    } else {
      // Move = exactly one destination (enforced by the
      // single-select toggle in _toggle).
      final dest = picked.single;
      final r = await widget.controller.moveTrack(
        track: _selectedVariant,
        destSource: dest,
      );
      if (r.success) {
        succeeded.add(dest.displayName);
      } else {
        failures.add((
          destName: dest.displayName,
          reason: r.errorReason ?? 'unknown error',
        ));
      }
    }

    if (!mounted) return;
    Navigator.of(context).pop(
      MoveCopyDialogOutcome(
        wasMove: !_isCopy,
        succeededDestNames: succeeded,
        failures: failures,
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final Track track;
  final Source? currentSource;
  final VoidCallback onClose;
  const _Header({
    required this.track,
    required this.currentSource,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Move or copy',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  track.filename,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (currentSource != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    'Currently in: ${currentSource!.displayName}',
                    style: const TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: 10,
                    ),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            tooltip: 'Close',
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded,
                size: 16, color: AppColors.textSecondary),
            splashRadius: 14,
          ),
        ],
      ),
    );
  }
}

/// Picker shown when the bucket has more than one physical variant
/// (e.g. an MP3, an AIFF, and a WAV that all share one song
/// identity). Codec choice is operationally meaningful — DJs pick
/// lossless for home decks and MP3 for travel drives — so the user
/// gets to choose which file the Move/Copy will actually act on,
/// rather than silently defaulting to whichever variant happened to
/// be the bucket's primary row.
///
/// One row per physical file. Codec label is the lead so the eye
/// scans down the format column; the source + filename appear as
/// secondary context to disambiguate same-codec siblings.
class _VariantPicker extends StatelessWidget {
  final List<Track> variants;
  final Track selected;
  final String Function(String sourceId) resolveSourceName;
  final ValueChanged<Track> onChanged;

  const _VariantPicker({
    required this.variants,
    required this.selected,
    required this.resolveSourceName,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'VARIANT',
                style: TextStyle(
                  color: AppColors.textTertiary,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 1.0,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${variants.length} variants of this song',
                style: const TextStyle(
                  color: AppColors.textTertiary,
                  fontSize: 11,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final v in variants)
            _VariantRow(
              variant: v,
              selected: identical(v, selected) || v.path == selected.path,
              sourceName: resolveSourceName(v.sourceId),
              onTap: () => onChanged(v),
            ),
        ],
      ),
    );
  }
}

class _VariantRow extends StatelessWidget {
  final Track variant;
  final bool selected;
  final String sourceName;
  final VoidCallback onTap;
  const _VariantRow({
    required this.variant,
    required this.selected,
    required this.sourceName,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final codec = fileFormatLabel(variant.filename);
    final codecLabel = codec.isEmpty ? 'FILE' : codec;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        hoverColor: AppColors.hoverRow,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 14,
                color: selected
                    ? AppColors.accent
                    : AppColors.textTertiary,
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 56,
                child: Text(
                  codecLabel,
                  style: TextStyle(
                    color: selected
                        ? AppColors.textPrimary
                        : AppColors.textSecondary,
                    fontSize: 12,
                    fontWeight:
                        selected ? FontWeight.w600 : FontWeight.w500,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  '$sourceName / ${variant.filename}',
                  style: const TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: 11,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionToggle extends StatelessWidget {
  final bool isCopy;
  final ValueChanged<bool> onChanged;
  const _ActionToggle({required this.isCopy, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: [
          const Text(
            'ACTION',
            style: TextStyle(
              color: AppColors.textTertiary,
              fontSize: 11,
              fontWeight: FontWeight.w500,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(width: 16),
          _ActionRadio(
            label: 'Copy',
            selected: isCopy,
            onTap: () => onChanged(true),
          ),
          const SizedBox(width: 12),
          _ActionRadio(
            label: 'Move',
            selected: !isCopy,
            onTap: () => onChanged(false),
          ),
          const Spacer(),
          Text(
            isCopy
                ? 'Pick one or more destinations'
                : 'Pick one destination',
            style: const TextStyle(
              color: AppColors.textTertiary,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionRadio extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _ActionRadio({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 14,
                color: selected
                    ? AppColors.accent
                    : AppColors.textTertiary,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: selected
                      ? AppColors.textPrimary
                      : AppColors.textSecondary,
                  fontSize: 12,
                  fontWeight:
                      selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DestinationRow extends StatelessWidget {
  final Source source;
  final bool checked;
  final bool multiSelect;
  final bool isCurrent;
  final VoidCallback onToggle;
  const _DestinationRow({
    required this.source,
    required this.checked,
    required this.multiSelect,
    required this.isCurrent,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    // Current source: muted text, no checkbox, no hover. Visible
    // so the user sees the full routing graph (where the file is
    // now vs. where it could go) but not selectable — sending a
    // file to the folder it already lives in is a no-op.
    if (isCurrent) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Row(
          children: [
            const Icon(
              Icons.place_rounded,
              size: 16,
              color: AppColors.textTertiary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Text(
                        source.displayName,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'CURRENT LOCATION',
                        style: TextStyle(
                          color: AppColors.textTertiary,
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.0,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    source.folderPath,
                    style: const TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: 10,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onToggle,
        hoverColor: AppColors.hoverRow,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: Row(
            children: [
              Icon(
                multiSelect
                    ? (checked
                        ? Icons.check_box_rounded
                        : Icons.check_box_outline_blank_rounded)
                    : (checked
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_unchecked_rounded),
                size: 16,
                color: checked
                    ? AppColors.accent
                    : AppColors.textTertiary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      source.displayName,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      source.folderPath,
                      style: const TextStyle(
                        color: AppColors.textTertiary,
                        fontSize: 10,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoDestinationsState extends StatelessWidget {
  const _NoDestinationsState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.folder_off_rounded,
              size: 28,
              color: AppColors.textTertiary,
            ),
            SizedBox(height: 12),
            Text(
              'No other watched folders available.',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 6),
            Text(
              'Add another folder as a source from the sidebar, '
              'then try again.',
              style: TextStyle(
                color: AppColors.textTertiary,
                fontSize: 11,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  final bool isCopy;
  final int selectedCount;
  final bool canApply;
  final bool busy;
  final VoidCallback onCancel;
  final VoidCallback onApply;

  const _Footer({
    required this.isCopy,
    required this.selectedCount,
    required this.canApply,
    required this.busy,
    required this.onCancel,
    required this.onApply,
  });

  @override
  Widget build(BuildContext context) {
    final label = _applyLabel();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: busy ? null : onCancel,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.textSecondary,
            ),
            child: const Text('Cancel'),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: canApply ? onApply : null,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.accent,
            ),
            child: busy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child:
                        CircularProgressIndicator(strokeWidth: 1.5),
                  )
                : Text(label),
          ),
        ],
      ),
    );
  }

  String _applyLabel() {
    if (selectedCount == 0) {
      return isCopy ? 'Copy' : 'Move';
    }
    if (isCopy) {
      return selectedCount == 1
          ? 'Copy to 1 folder'
          : 'Copy to $selectedCount folders';
    }
    return 'Move';
  }
}

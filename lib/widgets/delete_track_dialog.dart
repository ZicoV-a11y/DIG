import 'package:flutter/material.dart';

import '../models/source.dart';
import '../models/track.dart';
import '../state/library_controller.dart';
import '../theme/app_theme.dart';
import '../utils/file_format.dart';

/// User's confirmed answer from the delete dialog. Carries the exact
/// paths to trash, the intel uid for the favorite cascade, and the
/// user's FAV-preservation decision.
///
/// `null` return from [showDeleteTrackDialog] means the user
/// cancelled — no destructive action should run.
class DeleteDecision {
  /// Absolute filesystem paths to move to Trash. Always non-empty
  /// when this object is returned (cancel returns null instead).
  final List<String> paths;

  /// Intel uid for the song the deletion targets. Used by the
  /// controller's FAV-cascade to flip every variant sharing this
  /// uid when [clearFavorite] is true.
  final String intelUid;

  /// `true` when the user picked "Remove Favorite" in the popup,
  /// `false` when they picked "Keep Favorite" OR the popup never
  /// fired (no surviving favorited variants, no ambiguity).
  final bool clearFavorite;

  const DeleteDecision({
    required this.paths,
    required this.intelUid,
    required this.clearFavorite,
  });
}

/// Open the destructive-action dialog for [track]. Returns a
/// [DeleteDecision] when the user confirms, `null` when they cancel.
///
/// Variant-scope picker is always rendered. Default radio per the
/// approved plan: "this variant only" — matches the click target
/// regardless of whether the user is in a source view or All Tracks.
///
/// The favorite-preservation section fires conditionally: only when
/// the song is favorited AND the user chose "this variant only" AND
/// at least one variant survives the chosen scope.
Future<DeleteDecision?> showDeleteTrackDialog({
  required BuildContext context,
  required LibraryController controller,
  required Track track,
}) {
  return showGeneralDialog<DeleteDecision>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: Colors.black.withValues(alpha: 0.55),
    transitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (_, _, _) {
      return _DeleteTrackDialog(controller: controller, track: track);
    },
  );
}

class _DeleteTrackDialog extends StatefulWidget {
  final LibraryController controller;
  final Track track;
  const _DeleteTrackDialog({required this.controller, required this.track});

  @override
  State<_DeleteTrackDialog> createState() => _DeleteTrackDialogState();
}

class _DeleteTrackDialogState extends State<_DeleteTrackDialog> {
  /// Per-variant selection. Each entry is a file path the user has
  /// checked for deletion. Initialised to ONLY the clicked variant
  /// — preselect-clicked-row matches the right-click context
  /// (you clicked on this row, so this row is the obvious default).
  /// The user can check additional variants for mixed-format
  /// curation ("remove MP3 from DL Folder + AIFF from DL Folder,
  /// keep Z CRATE's AIFF") or hit "Select all" for whole-identity
  /// extinction.
  late Set<String> _selectedPaths = {widget.track.path};

  /// `true` when the user picked "Remove Favorite". Only meaningful
  /// when the FAV section is rendered (favorited + survivors exist).
  /// Defaults to false (Keep Favorite) per the approved plan — most
  /// deletes are workflow cleanup, not de-curation.
  bool _removeFavorite = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    // Re-render so variant counts stay live if the underlying bucket
    // changes (external delete during the dialog, scan completion).
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final variants = widget.controller.variantsFor(widget.track);
    final hasMultiple = variants.length > 1;
    final currentSource = _findSource(widget.track.sourceId);
    final favorited = widget.track.favorite;

    // Prune `_selectedPaths` against the current variant set in
    // case the underlying bucket changed (external delete during
    // the dialog, scan completion mid-session). Done in build()
    // rather than the listener so derived state stays consistent
    // within a single frame.
    final variantPaths = {for (final v in variants) v.path};
    _selectedPaths.removeWhere((p) => !variantPaths.contains(p));

    // If everything got pruned (extreme case — every variant
    // disappeared from the bucket while the dialog was open),
    // fall back to the clicked variant if it survives, else
    // leave empty (footer disables the confirm button).
    if (_selectedPaths.isEmpty &&
        variantPaths.contains(widget.track.path)) {
      _selectedPaths.add(widget.track.path);
    }

    // Variant objects partitioned by the checkbox set: `removed`
    // is what the user is about to trash, `survivors` is what
    // will remain. Both feed the AFTER THIS ACTION preview AND
    // the FAV-section ambiguity check.
    final removed = variants
        .where((v) => _selectedPaths.contains(v.path))
        .toList(growable: false);
    final List<String> targetPaths =
        removed.map((v) => v.path).toList(growable: false);
    final survivors = variants
        .where((v) => !_selectedPaths.contains(v.path))
        .toList(growable: false);

    final allSelected =
        hasMultiple && _selectedPaths.length == variants.length;
    final canConfirm = _selectedPaths.isNotEmpty;

    // FAV section visibility: only when the song is favorited AND
    // the chosen scope leaves at least one survivor (ambiguity exists
    // about whether the song should stay endorsed). Single-variant
    // buckets, non-favorited tracks, and "all variants" scope all
    // skip the section — no question to ask.
    final showFavSection = favorited && survivors.isNotEmpty;

    // Effective clearFavorite for the returned decision.
    // - showFavSection true → respect user's radio choice
    // - showFavSection false + favorited + no survivors → favorite
    //   has no representation anyway; pass `false` (intel row
    //   stays — re-add can restore)
    // - not favorited → irrelevant, pass `false`
    final effectiveClearFav = showFavSection ? _removeFavorite : false;

    // Cap the dialog at 90% of window height — anything more would
    // crowd the title bar / Dock. Within that ceiling the content
    // shrink-wraps via the column below, and the inner Flexible
    // around the variant checklist + favorite section absorbs
    // overflow gracefully (long variant lists scroll inside the
    // dialog instead of pushing the footer off-screen).
    final maxDialogHeight = MediaQuery.of(context).size.height * 0.9;

    return Center(
      child: Material(
        color: AppColors.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: BorderSide(color: AppColors.border),
        ),
        elevation: 10,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: 620,
            maxWidth: 620,
            maxHeight: maxDialogHeight,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(
                track: widget.track,
                currentSource: currentSource,
                onClose: () => Navigator.of(context).pop(),
              ),
              const Divider(height: 1, color: AppColors.border),
              // Middle scrollable region: the variant checklist
              // + (optional) favorite section. These grow with
              // bucket size; wrapping them in Flexible + scroll
              // means a 20-variant bucket doesn't push the
              // consequence preview off-screen.
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (hasMultiple)
                        _VariantChecklist(
                          variants: variants,
                          selected: _selectedPaths,
                          resolveSourceName: (sourceId) =>
                              _findSource(sourceId)?.displayName ?? '—',
                          onToggle: (path) {
                            setState(() {
                              if (_selectedPaths.contains(path)) {
                                _selectedPaths.remove(path);
                              } else {
                                _selectedPaths.add(path);
                              }
                            });
                          },
                          onSelectAll: () => setState(() {
                            _selectedPaths = {
                              for (final v in variants) v.path,
                            };
                          }),
                          onClear: () => setState(() {
                            // Never end up at zero — leave the
                            // originally-clicked row selected so
                            // the dialog has at least one path
                            // to operate on. Cancel is the right
                            // way to walk away with no action.
                            _selectedPaths = {widget.track.path};
                          }),
                        )
                      else
                        const _SingleVariantNote(),
                      if (showFavSection) ...[
                        const Divider(height: 1, color: AppColors.border),
                        _FavoriteSection(
                          survivors: survivors,
                          resolveSourceName: (sourceId) =>
                              _findSource(sourceId)?.displayName ?? '—',
                          removeFavorite: _removeFavorite,
                          onChanged: (remove) =>
                              setState(() => _removeFavorite = remove),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const Divider(height: 1, color: AppColors.border),
              _ConsequencePreview(
                removed: removed,
                survivors: survivors,
                favorited: favorited,
                clearFavorite: effectiveClearFav,
                showFavSection: showFavSection,
                allVariants: allSelected,
                resolveSourceName: (sourceId) =>
                    _findSource(sourceId)?.displayName ?? '—',
              ),
              const Divider(height: 1, color: AppColors.border),
              _Footer(
                fileCount: targetPaths.length,
                isAllVariants: allSelected,
                canConfirm: canConfirm,
                onCancel: () => Navigator.of(context).pop(),
                onConfirm: () => Navigator.of(context).pop(
                  DeleteDecision(
                    paths: targetPaths,
                    intelUid: widget.track.intelUid ?? widget.track.uid,
                    clearFavorite: effectiveClearFav,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Source? _findSource(String id) {
    for (final s in widget.controller.sources) {
      if (s.id == id) return s;
    }
    return null;
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
    // Same typographic vocabulary as MoveCopyDialog._Header — the
    // destructive counterpart reads as part of the same operational
    // family. Small uppercase action tag → dominant filename →
    // tertiary "currently in" line.
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'MOVE TO TRASH',
                  style: TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.4,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  track.filename,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                if (currentSource != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Currently in: ${currentSource!.displayName}',
                    style: const TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: 11,
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

class _SingleVariantNote extends StatelessWidget {
  const _SingleVariantNote();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(20, 14, 20, 14),
      child: Text(
        'This is the only file for this song in your library.',
        style: TextStyle(
          color: AppColors.textSecondary,
          fontSize: 12,
        ),
      ),
    );
  }
}

/// Best-effort cloud-provider name for a file path. Returns `null`
/// for local files. Same detection set the metadata + hash
/// pipelines use, so the operational vocabulary stays consistent
/// across surfaces. macOS exposes cloud-storage mounts under
/// `~/Library/CloudStorage/<Provider>-…` and iCloud under
/// `~/Library/Mobile Documents`.
String? _cloudProviderForPath(String path) {
  if (path.contains('/Library/CloudStorage/Dropbox')) return 'Dropbox';
  if (path.contains('/Library/CloudStorage/GoogleDrive')) return 'Google Drive';
  if (path.contains('/Library/CloudStorage/OneDrive')) return 'OneDrive';
  if (path.contains('/Library/Mobile Documents')) return 'iCloud';
  return null;
}

/// Per-variant checklist replacing the prior one-or-all radio
/// scope picker. Each variant is independently selectable so the
/// user can do arbitrary subset operations:
///   - prune one duplicate
///   - keep AIFF, drop MP3 + WAV
///   - clean Q after promotion to Z (keep Z's variant, drop Q's)
///   - everything (identity extinction)
///
/// Selection state lives on the parent's `_selectedPaths` and is
/// driven via callbacks. Per-row cloud-sync badge surfaces the
/// "this also propagates to other devices" consequence when the
/// variant lives in a synced folder — load-bearing for Dropbox
/// crate workflows where deletion isn't just local.
class _VariantChecklist extends StatelessWidget {
  final List<Track> variants;
  final Set<String> selected;
  final String Function(String sourceId) resolveSourceName;
  final ValueChanged<String> onToggle;
  final VoidCallback onSelectAll;
  final VoidCallback onClear;
  const _VariantChecklist({
    required this.variants,
    required this.selected,
    required this.resolveSourceName,
    required this.onToggle,
    required this.onSelectAll,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final allSelected = selected.length == variants.length;
    final noneSelectable = variants.isEmpty;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'VARIANTS',
                style: TextStyle(
                  color: AppColors.textTertiary,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.4,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${selected.length} of ${variants.length} selected',
                style: const TextStyle(
                  color: AppColors.textTertiary,
                  fontSize: 11,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const Spacer(),
              _ChecklistAction(
                label: allSelected ? '— Select all (all)' : 'Select all',
                onTap: noneSelectable || allSelected ? null : onSelectAll,
              ),
              const SizedBox(width: 4),
              _ChecklistAction(
                label: 'Clear',
                onTap: noneSelectable ||
                        selected.length <= 1
                    ? null
                    : onClear,
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final v in variants)
            _VariantRow(
              variant: v,
              sourceName: resolveSourceName(v.sourceId),
              checked: selected.contains(v.path),
              onToggle: () => onToggle(v.path),
            ),
          // Elevated-caution treatment when every variant is
          // checked — same identity-extinction call-out the old
          // "Delete all variants" radio used to surface, now
          // derived from the checklist state.
          if (allSelected && variants.length > 1) ...[
            const SizedBox(height: 8),
            const Text(
              'This removes the song from your active library.',
              style: TextStyle(
                color: AppColors.textTertiary,
                fontSize: 11,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _VariantRow extends StatelessWidget {
  final Track variant;
  final String sourceName;
  final bool checked;
  final VoidCallback onToggle;
  const _VariantRow({
    required this.variant,
    required this.sourceName,
    required this.checked,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final format = fileFormatLabel(variant.filename);
    final cloud = _cloudProviderForPath(variant.path);

    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              checked ? Icons.check_box : Icons.check_box_outline_blank,
              size: 16,
              color: checked ? AppColors.accent : AppColors.textTertiary,
            ),
            const SizedBox(width: 10),
            // Source · format pair stays at the front — that's
            // what the user scans down for "DL Folder vs Z CRATE".
            SizedBox(
              width: 180,
              child: Text(
                '$sourceName · $format',
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            const SizedBox(width: 8),
            // Cloud-sync badge. Surfaces when the variant lives
            // in a Dropbox / iCloud / Google Drive / OneDrive
            // folder. This is a load-bearing piece of operational
            // information: deleting a synced file removes it from
            // the cloud + propagates to every other device that
            // syncs the same folder. The user needs to see that
            // before they tick the box, not after.
            if (cloud != null) ...[
              _CloudBadge(provider: cloud),
              const SizedBox(width: 8),
            ],
            // Filename trails — secondary because format+source
            // is usually enough for disambiguation; the filename
            // matters only when two variants share both.
            Expanded(
              child: Text(
                variant.filename,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CloudBadge extends StatelessWidget {
  final String provider;
  const _CloudBadge({required this.provider});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'This file is in a $provider-synced folder. '
          'Moving it to Trash also deletes it from $provider '
          '(and propagates to other devices syncing this folder).',
      waitDuration: const Duration(milliseconds: 400),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: AppColors.surfaceAlt,
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.cloud_outlined,
              size: 11,
              color: AppColors.textTertiary,
            ),
            const SizedBox(width: 4),
            Text(
              provider,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChecklistAction extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  const _ChecklistAction({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          label,
          style: TextStyle(
            color: disabled ? AppColors.textTertiary : AppColors.accent,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
          ),
        ),
      ),
    );
  }
}

class _FavoriteSection extends StatelessWidget {
  final List<Track> survivors;
  final String Function(String sourceId) resolveSourceName;
  final bool removeFavorite;
  final ValueChanged<bool> onChanged;
  const _FavoriteSection({
    required this.survivors,
    required this.resolveSourceName,
    required this.removeFavorite,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    // Distinct surviving sources where the song will still exist
    // post-delete. Dedup so a song with two MP3 variants in the
    // same source shows that source once, not twice.
    final survivorSources = <String>{};
    for (final v in survivors) {
      final name = resolveSourceName(v.sourceId);
      survivorSources.add(name);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.star_rounded,
                size: 14,
                color: AppColors.favorite,
              ),
              const SizedBox(width: 8),
              const Text(
                'FAVORITE',
                style: TextStyle(
                  color: AppColors.textTertiary,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.4,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'This song is favorited.',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'A copy will remain in:',
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 4),
          for (final src in survivorSources)
            Padding(
              padding: const EdgeInsets.only(left: 12, top: 1),
              child: Text(
                '• $src',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ),
          const SizedBox(height: 10),
          _FavOption(
            label: 'Keep Favorite',
            selected: !removeFavorite,
            onTap: () => onChanged(false),
          ),
          const SizedBox(height: 4),
          _FavOption(
            label: 'Remove Favorite',
            selected: removeFavorite,
            onTap: () => onChanged(true),
          ),
        ],
      ),
    );
  }
}

class _FavOption extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _FavOption({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 16,
              color: selected ? AppColors.accent : AppColors.textTertiary,
            ),
            const SizedBox(width: 10),
            Text(
              label,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Outcome-centric consequence preview. Renders just above the
/// footer so the user reads it last, immediately before the
/// destructive button.
///
/// Two named lists + two summary lines, in deliberate order:
///   1. **REMOVED** — `source · filename` per file the user is
///      about to trash. Specific paths, not counts, so the user
///      sees exactly which file is leaving.
///   2. **REMAINING** — `source · filename` per surviving variant.
///      Subtly accent-tinted with a ✓ glyph so the eye finds it
///      first. Users fear accidental loss; the dialog should
///      visually reassure them that the keeper copy is safe.
///      Suppressed when there are no survivors (a "Remaining:
///      none" line would be more alarming than useful).
///   3. **FAVORITE** — single outcome line. "Remains ON / Will
///      be removed from all remaining copies / Will be removed
///      with this song / Preserved in library memory (no copies
///      remaining)". Skipped when the song wasn't favorited to
///      begin with.
///   4. **HISTORY** — always "Preserved (plays, reviews carry
///      forward)". The intel-row guardrail surfaced explicitly
///      so deletion never reads as wiping listening data.
///
/// Header label `AFTER THIS ACTION` to anchor the user mentally
/// in the post-delete state — matches the outcome-centric framing
/// throughout.
class _ConsequencePreview extends StatelessWidget {
  final List<Track> removed;
  final List<Track> survivors;
  final bool favorited;
  final bool clearFavorite;
  final bool showFavSection;
  final bool allVariants;
  final String Function(String sourceId) resolveSourceName;
  const _ConsequencePreview({
    required this.removed,
    required this.survivors,
    required this.favorited,
    required this.clearFavorite,
    required this.showFavSection,
    required this.allVariants,
    required this.resolveSourceName,
  });

  String _locationLabel(Track t) {
    final sourceName = resolveSourceName(t.sourceId);
    return '$sourceName · ${t.filename}';
  }

  /// Single-line outcome for the favorite. Returns `null` when the
  /// song wasn't favorited (no section emits).
  String? _favoriteOutcome() {
    if (!favorited) return null;
    if (showFavSection) {
      return clearFavorite
          ? 'Will be removed from all remaining copies'
          : 'Remains ON';
    }
    // No survivors. Two sub-cases:
    //   - The user picked "all variants" on a favorited song
    //     (identity leaving active circulation). Favorite has no
    //     row to live on, but intel persists for re-add.
    //   - Single-variant favorited song being deleted entirely.
    //   Both read the same: favorite has no representation now,
    //   but the intel row in `tracks` keeps it for reconnect.
    return 'Preserved in library memory (no copies remaining)';
  }

  /// Distinct cloud-sync providers represented in the about-to-be-
  /// removed set. Drives the cloud-warning line in the preview.
  /// Order-preserving so the rendered list reads as the user
  /// scanned the checklist (top-to-bottom variant ordering).
  List<String> _cloudProvidersInRemoved() {
    final seen = <String>{};
    final out = <String>[];
    for (final t in removed) {
      final provider = _cloudProviderForPath(t.path);
      if (provider != null && seen.add(provider)) {
        out.add(provider);
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final favOutcome = _favoriteOutcome();

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'AFTER THIS ACTION',
            style: TextStyle(
              color: AppColors.textTertiary,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.4,
            ),
          ),
          const SizedBox(height: 8),
          // Cloud-sync call-out. Lands when ANY removed file
          // lives in a synced folder — surfaces the propagation
          // consequence (Trash on this device → deletion
          // mirrored across every device that syncs the same
          // folder) before the user clicks confirm. Each variant
          // row already carries its own cloud badge in the
          // checklist above; this line aggregates the providers
          // so the post-decision read has the same information
          // without scrolling back up.
          if (_cloudProvidersInRemoved().isNotEmpty) ...[
            _OutcomeLine(
              label: 'Cloud sync',
              value: 'Also deletes from '
                  '${_cloudProvidersInRemoved().join(' · ')} · '
                  'propagates to other devices syncing these folders',
              accentValue: false,
            ),
            const SizedBox(height: 6),
          ],
          _OutcomeSection(
            label: 'Removed',
            tone: _OutcomeTone.removed,
            items: [for (final t in removed) _locationLabel(t)],
          ),
          if (survivors.isNotEmpty) ...[
            const SizedBox(height: 6),
            _OutcomeSection(
              label: 'Remaining',
              tone: _OutcomeTone.remaining,
              items: [for (final t in survivors) _locationLabel(t)],
            ),
          ] else if (allVariants && favorited) ...[
            // Identity-extinction call-out. Lands only when the
            // user has chosen to remove every variant of a
            // favorited song. Quieter than a warning banner, but
            // gives the action its weight.
            const SizedBox(height: 6),
            _OutcomeSection(
              label: 'Remaining',
              tone: _OutcomeTone.removed,
              items: const ['No copies of this song will remain in the library'],
            ),
          ],
          if (favOutcome != null) ...[
            const SizedBox(height: 6),
            _OutcomeLine(
              label: 'Favorite',
              value: favOutcome,
              accentValue:
                  !clearFavorite || !showFavSection,
            ),
          ],
          const SizedBox(height: 4),
          const _OutcomeLine(
            label: 'Listening history',
            value: 'Preserved (plays, reviews carry forward)',
            accentValue: true,
          ),
        ],
      ),
    );
  }
}

/// Visual treatment of an outcome section. `removed` uses a
/// muted ✗ glyph and tertiary text; `remaining` uses an accent ✓
/// glyph and primary text so the eye instantly registers "this
/// survives" — the load-bearing reassurance during destructive
/// curation.
enum _OutcomeTone { removed, remaining }

class _OutcomeSection extends StatelessWidget {
  final String label;
  final _OutcomeTone tone;
  final List<String> items;
  const _OutcomeSection({
    required this.label,
    required this.tone,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    final isRemaining = tone == _OutcomeTone.remaining;
    final glyph = isRemaining ? '✓' : '×';
    final glyphColor =
        isRemaining ? AppColors.accent : AppColors.textTertiary;
    final lineColor =
        isRemaining ? AppColors.textPrimary : AppColors.textSecondary;
    final lineWeight =
        isRemaining ? FontWeight.w500 : FontWeight.w400;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: const TextStyle(
                color: AppColors.textTertiary,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${items.length}',
              style: const TextStyle(
                color: AppColors.textTertiary,
                fontSize: 11,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 3),
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(top: 1, bottom: 1),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 3, right: 8),
                  child: Text(
                    glyph,
                    style: TextStyle(
                      color: glyphColor,
                      fontSize: 11,
                      height: 1.0,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    item,
                    style: TextStyle(
                      color: lineColor,
                      fontSize: 12,
                      fontWeight: lineWeight,
                      height: 1.3,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Single-line outcome row. Used for the FAVORITE and LISTENING
/// HISTORY summary lines below the REMOVED/REMAINING lists.
class _OutcomeLine extends StatelessWidget {
  final String label;
  final String value;
  /// When true, the value renders in the calmer "this survives"
  /// vocabulary (primary text); when false, the warning "this
  /// will change" vocabulary (warning tint). Drives the eye's
  /// scan toward losses vs preservations without a giant banner.
  final bool accentValue;
  const _OutcomeLine({
    required this.label,
    required this.value,
    required this.accentValue,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 110,
          child: Text(
            label,
            style: const TextStyle(
              color: AppColors.textTertiary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              color: accentValue
                  ? AppColors.textPrimary
                  : AppColors.favorite,
              fontSize: 12,
              fontWeight: accentValue ? FontWeight.w500 : FontWeight.w600,
              height: 1.3,
            ),
          ),
        ),
      ],
    );
  }
}

class _Footer extends StatelessWidget {
  final int fileCount;
  final bool isAllVariants;
  /// Gates the confirm button. `false` when the user has unchecked
  /// every variant (no destination for the operation). Cancel
  /// stays enabled — that's how the user walks away cleanly.
  final bool canConfirm;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;
  const _Footer({
    required this.fileCount,
    required this.isAllVariants,
    required this.canConfirm,
    required this.onCancel,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    // Button label reflects scope choice. The count is bolded
    // explicitly when every variant is checked — same elevated-
    // caution intent as the inline italic note in the checklist.
    final actionLabel = fileCount == 1
        ? 'Move 1 file to Trash'
        : 'Move $fileCount files to Trash';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: onCancel,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.textSecondary,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            ),
            child: const Text('Cancel'),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: canConfirm ? onConfirm : null,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.favorite,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.zero,
              ),
              textStyle: TextStyle(
                fontSize: 13,
                fontWeight: isAllVariants ? FontWeight.w800 : FontWeight.w700,
              ),
            ),
            child: Text(actionLabel),
          ),
        ],
      ),
    );
  }
}

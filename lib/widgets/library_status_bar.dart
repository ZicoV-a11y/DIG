import 'package:flutter/material.dart';

import '../state/library_controller.dart';
import '../theme/app_theme.dart';
import 'review_missing_dialog.dart';

/// Always-on status strip pinned to the bottom of the workspace.
///
/// Two layers of information:
///   - **Operation indicator (left)** when something is active:
///     scan, viewport enrichment, or per-track materialisation.
///     Shows the specific file currently being processed when
///     known, plus a numeric progress counter when determinate.
///   - **Library tally (right)**, always visible: total tracks,
///     enriched count, and missing count. Lets the user see at a
///     glance how complete the library's metadata coverage is.
///
/// The bar is fixed-height (24px) so the table doesn't reflow when
/// status changes.
class LibraryStatusBar extends StatelessWidget {
  final LibraryController controller;
  const LibraryStatusBar({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (ctx, _) {
        final op = _resolveOperation(controller);
        return Container(
          height: 24,
          color: AppColors.surface,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              if (op != null) ...[
                _OperationCluster(state: op),
              ] else
                const _IdleIndicator(),
              // Static FORMAT-sort indicator. The FORMAT header
              // cycles through 10 leads (4 singles + 6 pair
              // combos) but per the static-headers spec the header
              // text never changes. Without this chip the user
              // loses track of which lead they're on after a few
              // clicks (especially the pair combos like MP3·FLAC,
              // which interleave MP3-only and MP3+other rows
              // — correct behavior, but indistinguishable from
              // a bug if you can't see the lead).
              if (controller.sortColumn == TrackSortColumn.format) ...[
                const SizedBox(width: 16),
                _FormatSortChip(lead: controller.sortFormatLead),
              ],
              const SizedBox(width: 16),
              // Tally takes whatever's left and scrolls horizontally
              // if it can't all fit (large libraries → long file
              // counts). `reverse: true` anchors the scroll to the
              // right edge so the latest chunks are always visible.
              Flexible(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  reverse: true,
                  physics: const BouncingScrollPhysics(),
                  child: _LibraryTally(controller: controller),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Active background operation. `progress = null` means
/// indeterminate; in `[0, 1]` means determinate.
class _OperationState {
  final String label;
  final String? subject;
  final double? progress;
  final int? done;
  final int? total;
  const _OperationState({
    required this.label,
    this.subject,
    this.progress,
    this.done,
    this.total,
  });
}

_OperationState? _resolveOperation(LibraryController c) {
  if (c.isScanning) {
    return const _OperationState(label: 'Scanning library');
  }
  if (c.isMetadataProcessing && c.metadataProgressTotal > 0) {
    final done = c.metadataProgressDone;
    final total = c.metadataProgressTotal;
    return _OperationState(
      label: 'Enriching',
      subject: c.currentEnrichmentLabel,
      progress: total == 0 ? null : (done / total).clamp(0.0, 1.0),
      done: done,
      total: total,
    );
  }
  if (c.isLoadingTrack) {
    return _OperationState(
      label: 'Loading',
      subject: c.currentTrack?.filename,
    );
  }
  // content_hash backfill — background, lowest priority. Surfaces
  // only when no other foreground operation is active. The total
  // is unknown (just a count of NULL-hash candidates that drains
  // over time); show the running session count as "done" with no
  // total so the progress bar stays indeterminate.
  if (c.isBackfillingContentHashes) {
    return _OperationState(
      label: 'Hashing audio',
      done: c.backfillHashedThisSession,
    );
  }
  return null;
}

class _IdleIndicator extends StatelessWidget {
  const _IdleIndicator();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: const BoxDecoration(
            color: AppColors.textTertiary,
            shape: BoxShape.rectangle,
          ),
        ),
        const SizedBox(width: 8),
        const Text(
          'Idle',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.6,
            color: AppColors.textTertiary,
          ),
        ),
      ],
    );
  }
}

class _OperationCluster extends StatelessWidget {
  final _OperationState state;
  const _OperationCluster({required this.state});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Row(
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: state.progress == null
                ? const CircularProgressIndicator(
                    strokeWidth: 1.5,
                    valueColor:
                        AlwaysStoppedAnimation<Color>(AppColors.accent),
                  )
                : CircularProgressIndicator(
                    strokeWidth: 1.5,
                    value: state.progress,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      AppColors.accent,
                    ),
                    backgroundColor:
                        AppColors.border.withValues(alpha: 0.4),
                  ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              state.label,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              softWrap: false,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          if (state.subject != null && state.subject!.isNotEmpty) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                state.subject!,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ],
          if (state.done != null && state.total != null) ...[
            const SizedBox(width: 8),
            Text(
              '${state.done} / ${state.total}',
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.textSecondary,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ] else if (state.done != null) ...[
            // Backfill case — no total to show alongside; count by
            // itself is still useful as a "work is progressing"
            // signal.
            const SizedBox(width: 8),
            Text(
              '${state.done}',
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.textSecondary,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
          if (state.progress != null) ...[
            const SizedBox(width: 12),
            SizedBox(
              width: 120,
              height: 3,
              child: LinearProgressIndicator(
                value: state.progress,
                valueColor: const AlwaysStoppedAnimation<Color>(
                  AppColors.accent,
                ),
                backgroundColor:
                    AppColors.border.withValues(alpha: 0.4),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Compact chip showing the active FORMAT-column sort lead.
///
/// Only renders while FORMAT is the active sort. Solves the
/// "hidden state" problem from the static-headers refresh: FORMAT
/// cycles through 10 leads with no visible mode change on the
/// header itself, so the user can lose track of whether they're
/// on `MP3`, `MP3 · WAV`, `MP3 · FLAC`, etc. Pair leads in
/// particular create surprising-looking row orders (MP3-only
/// and MP3·AIFF interleave under lead `[MP3, FLAC]` — both
/// correctly land in tier 1 since each contains one of the
/// pair, but it reads as a sort bug without context).
class _FormatSortChip extends StatelessWidget {
  final String lead;
  const _FormatSortChip({required this.lead});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message:
          'FORMAT column sort. Click the FORMAT header to cycle '
          'through 10 leads (4 single formats, 6 pair combos). '
          'Pair leads cluster buckets that contain both formats '
          'together at the top.',
      waitDuration: const Duration(milliseconds: 400),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: AppColors.surfaceAlt,
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'SORT',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.0,
                color: AppColors.textTertiary,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              lead,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: AppColors.textPrimary,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LibraryTally extends StatelessWidget {
  final LibraryController controller;
  const _LibraryTally({required this.controller});

  @override
  Widget build(BuildContext context) {
    final total = controller.totalTrackCount;
    final songs = controller.songCount;
    final variants = controller.variantFileCount;
    final enriched = controller.enrichedCount;
    final missing = controller.missingCount;
    final moved = controller.movedCount;
    final reviewed = controller.reviewedSongCount;
    final unreviewed = controller.unreviewedSongCount;
    return Row(
      children: [
        _TallyChunk(
          label: 'files',
          value: total,
          tooltip:
              'Total file rows in the library — every MP3, AIFF, '
              'WAV, etc. counted separately.',
        ),
        const SizedBox(width: 12),
        _TallyChunk(
          label: 'songs',
          value: songs,
          tooltip:
              'Distinct song identities. Files with identical '
              'filename (minus extension), artist, title, and '
              'duration count as one song regardless of format.',
        ),
        // Files − songs. Only worth surfacing when the user
        // actually has duplicates / format variants in the library.
        if (variants > 0) ...[
          const SizedBox(width: 12),
          _TallyChunk(
            label: 'variants',
            value: variants,
            tooltip:
                'Files − songs. How many duplicate or alternate-'
                'format files (MP3 + AIFF, etc.) you hold beyond '
                'one canonical file per song.',
          ),
        ],
        const SizedBox(width: 12),
        _TallyChunk(
          label: 'enriched',
          value: enriched,
          tooltip:
              'Files whose ID3 / Vorbis metadata has been read. '
              'Pending files show filename-derived artist / title '
              'until they enrich.',
        ),
        if (missing > 0) ...[
          const SizedBox(width: 12),
          _TallyChunk(
            label: 'removed',
            value: missing,
            warning: true,
            tooltip:
                'Files that were on disk during a previous scan but '
                'are no longer found, with no byte-identical copy '
                'detected in any watched folder. Removed from the '
                "library's view but their intel (favorite, plays, "
                'reviews) is preserved on the row until you explicitly '
                "purge. Click to review.\n\n"
                'Use "Removed" for files that disappeared externally '
                '(deleted in Finder, drive disconnected, etc). The '
                'app reserves "Deleted" for a future in-app delete '
                'action that explicitly trashes the file from disk.',
            onTap: () => showReviewMissingDialog(
              context: context,
              controller: controller,
            ),
          ),
        ],
        if (moved > 0) ...[
          const SizedBox(width: 12),
          _TallyChunk(
            label: 'moved',
            value: moved,
            tooltip:
                'Files the scan detected as moved within their '
                'source — a same-fingerprint file now lives at a '
                'different path, so intel transferred and the old '
                'path was retired. Click to review or purge the '
                'retired rows.',
            onTap: () => showReviewMissingDialog(
              context: context,
              controller: controller,
            ),
          ),
        ],
        const SizedBox(width: 12),
        _TallyChunk(
          label: 'reviewed',
          value: reviewed,
          tooltip:
              'Songs you have listened to past the review threshold '
              '(currently 3 seconds cumulative). Counted at the song '
              'level — any variant crossing the threshold counts the '
              'whole song.',
        ),
        const SizedBox(width: 12),
        _TallyChunk(
          label: 'unreviewed',
          value: unreviewed,
          tooltip:
              'Songs you have not yet listened to past the review '
              'threshold. Equals songs − reviewed.',
        ),
      ],
    );
  }
}

class _TallyChunk extends StatelessWidget {
  final String label;
  final int value;
  final bool warning;
  final String? tooltip;
  /// When non-null, the chunk renders as an InkWell and fires this
  /// callback on tap. Used for the `missing` / `moved` chunks that
  /// open the Review-missing dialog. Other chunks pass null and
  /// remain non-interactive labels.
  final VoidCallback? onTap;
  const _TallyChunk({
    required this.label,
    required this.value,
    this.warning = false,
    this.tooltip,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final row = Row(
      children: [
        Text(
          '$value',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: warning ? AppColors.favorite : AppColors.textPrimary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            color: AppColors.textTertiary,
            letterSpacing: 0.4,
          ),
        ),
      ],
    );
    Widget body = row;
    if (onTap != null) {
      body = Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          hoverColor: AppColors.hoverRow,
          focusColor: AppColors.focusOverlay,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
            child: row,
          ),
        ),
      );
    }
    if (tooltip == null) return body;
    return Tooltip(
      message: tooltip!,
      waitDuration: const Duration(milliseconds: 400),
      child: body,
    );
  }
}

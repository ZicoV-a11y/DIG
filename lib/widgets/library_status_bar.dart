import 'package:flutter/material.dart';

import '../models/source.dart';
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

/// Source-scoped enrichment status. Renders the user-stated target:
///
///   Q · enriching · 32 / 87 ready   18 waiting on Dropbox
///
/// The progress bar reflects the source's ready/total ratio
/// (steady, library-completion view) rather than the run's
/// done/total (which can balloon under re-queue / large discovery).
/// Stall narration still applies: when the global isolate pool
/// is wedged on cloud reads, we surface the cloud-wait suffix
/// alongside the source name so the operational vocabulary stays
/// consistent across pipelines.
_OperationState _contextualEnrichmentState(
  LibraryController c,
  Source selected,
  ({int total, int ready, int enriching, int waitingOnCloud}) progress,
) {
  final ratio = progress.total == 0
      ? null
      : (progress.ready / progress.total).clamp(0.0, 1.0);
  // Subject text: lead with the "N waiting on Dropbox" call-out
  // when relevant — that's the user-facing reason this source's
  // progress is moving slowly. When nothing is cloud-blocked,
  // fall back to the rotating filename so the user still sees
  // *what* is being processed right now.
  final String? subject;
  if (progress.waitingOnCloud > 0) {
    subject =
        '${progress.waitingOnCloud} waiting on ${c.currentEnrichmentCloudLabel}';
  } else {
    subject = c.currentEnrichmentLabel;
  }
  final String label;
  if (c.isEnrichmentStalled) {
    final secs = c.enrichmentSinceLastCompletion?.inSeconds ?? 0;
    label = '${selected.displayName} · enriching · '
        'waiting on ${c.currentEnrichmentCloudLabel} · ${secs}s';
  } else {
    label = '${selected.displayName} · enriching';
  }
  return _OperationState(
    label: label,
    subject: subject,
    progress: ratio,
    done: progress.ready,
    total: progress.total,
  );
}

_OperationState? _resolveOperation(LibraryController c) {
  if (c.isScanning) {
    return const _OperationState(label: 'Scanning library');
  }
  if (c.isMetadataProcessing && c.metadataProgressTotal > 0) {
    // Contextual scope: when a source is selected AND it has
    // active enrichment of its own, swap the label to source-
    // scoped progress. The activity strip stays library-global —
    // these two surfaces deliberately answer different questions
    // ("what's true across the library" vs "what's happening in
    // my current view"). The user's mental scope matches the
    // sidebar selection, so the status bar should too.
    final selected = c.selectedSource;
    if (selected != null) {
      final progress = c.progressForSource(selected.id);
      if (progress != null && progress.enriching > 0) {
        return _contextualEnrichmentState(c, selected, progress);
      }
    }

    // Global fallback — no source selected, or selected source
    // has no enrichment activity (work happening elsewhere).
    final done = c.metadataProgressDone;
    final total = c.metadataProgressTotal;
    // Stall narration. When isolate workers haven't completed a
    // path in N seconds, they're almost certainly blocked on
    // cloud-storage materialisation (Dropbox / iCloud restoring
    // a placeholder, large AIFF download). Swap the label so
    // the user sees the EXTERNAL reason ("Waiting on Dropbox ·
    // 14s") instead of an apparently-frozen `Enriching 0/170`.
    // Mirrors the hash-backfill cloud-wait pattern so the
    // operational vocabulary is consistent across pipelines.
    final String label;
    if (c.isEnrichmentStalled) {
      final secs = c.enrichmentSinceLastCompletion?.inSeconds ?? 0;
      label = 'Enriching · waiting on ${c.currentEnrichmentCloudLabel} · ${secs}s';
    } else {
      label = 'Enriching';
    }
    return _OperationState(
      label: label,
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
  // only when no other foreground operation is active. The worker
  // samples `contentHashCandidatesCount()` every batch and reports
  // it via onProgress, so we can show determinate "12 / 873"
  // progress + a filled bar — calmer than an indeterminate spinner
  // sitting there for 30 seconds while Dropbox materialises a
  // dataless placeholder.
  if (c.isBackfillingContentHashes) {
    final remaining = c.backfillRemaining;
    final done = c.backfillHashedThisSession;
    // Label-state priority order:
    //   1. paused for playback (foreground audio outranks bg work)
    //   2. waiting on cloud (a single hash has been in flight past
    //      the patience threshold — almost certainly a Dropbox /
    //      iCloud dataless placeholder being hydrated by macOS)
    //   3. plain "Hashing audio"
    // Each label reads as deliberate, not stalled.
    final String label;
    final String? subject;
    if (c.isBackfillPaused) {
      label = 'Hashing audio · paused for playback';
      subject = null;
    } else if (c.isWaitingOnCloud) {
      // Elapsed seconds let the user distinguish ongoing hydration
      // from a permanent stall — "Waiting on Dropbox · 14s" reads
      // as "this is happening now", a static label would just look
      // frozen.
      final secs = c.currentHashElapsed?.inSeconds ?? 0;
      label = 'Waiting on ${c.currentHashCloudLabel} · ${secs}s';
      subject = c.currentHashFilename;
    } else {
      label = 'Hashing audio';
      subject = null;
    }
    if (remaining != null && remaining > 0) {
      final total = done + remaining;
      return _OperationState(
        label: label,
        subject: subject,
        done: done,
        total: total,
        progress: total == 0 ? null : (done / total).clamp(0.0, 1.0),
      );
    }
    return _OperationState(
      label: label,
      subject: subject,
      done: done,
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

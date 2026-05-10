import 'package:flutter/material.dart';

import '../state/library_controller.dart';
import '../theme/app_theme.dart';

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
              const Spacer(),
              _LibraryTally(controller: controller),
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
          Text(
            state.label,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
              color: AppColors.textPrimary,
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
    final reviewed = controller.reviewedSongCount;
    final unreviewed = controller.unreviewedSongCount;
    return Row(
      children: [
        _TallyChunk(label: 'files', value: total),
        const SizedBox(width: 12),
        _TallyChunk(label: 'songs', value: songs),
        // Files − songs. Only worth surfacing when the user
        // actually has duplicates / format variants in the library.
        if (variants > 0) ...[
          const SizedBox(width: 12),
          _TallyChunk(label: 'variants', value: variants),
        ],
        const SizedBox(width: 12),
        _TallyChunk(label: 'enriched', value: enriched),
        if (missing > 0) ...[
          const SizedBox(width: 12),
          _TallyChunk(label: 'missing', value: missing, warning: true),
        ],
        const SizedBox(width: 12),
        _TallyChunk(label: 'reviewed', value: reviewed),
        const SizedBox(width: 12),
        _TallyChunk(label: 'unreviewed', value: unreviewed),
      ],
    );
  }
}

class _TallyChunk extends StatelessWidget {
  final String label;
  final int value;
  final bool warning;
  const _TallyChunk({
    required this.label,
    required this.value,
    this.warning = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
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
  }
}

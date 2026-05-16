import 'package:flutter/material.dart';

import '../state/library_controller.dart';
import '../theme/app_theme.dart';

/// Persistent operational-state strip pinned above the status bar.
///
/// Always-visible breakdown of the library's enrichment ontology:
/// `DISCOVERED N · ENRICHING N · READY N · FAILED N`. Zeros are
/// not hidden — seeing `FAILED 0` is reassuring, and a strip that
/// reshuffles as counts hit zero would feel jittery. Calm, numeric,
/// no animation; reads as the operational heartbeat of the app.
///
/// Visual hierarchy is intentionally below the operation cluster
/// in the status bar (which narrates the active foreground task)
/// — this strip describes the steady-state shape of the library,
/// not what's happening right now.
class LibraryActivityStrip extends StatelessWidget {
  final LibraryController controller;
  const LibraryActivityStrip({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (ctx, _) {
        final discovered = controller.discoveredCount;
        final enriching = controller.enrichingCount;
        final ready = controller.enrichedCount;
        final failed = controller.failedEnrichmentCount;
        return Container(
          height: 22,
          color: AppColors.surfaceAlt,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.centerLeft,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            // Anchor right-edge so the latest chunk stays visible
            // when the library has a long-label state (e.g. when
            // counts cross 6-digit width on huge imports).
            reverse: false,
            physics: const BouncingScrollPhysics(),
            child: Row(
              children: [
                _ActivityChunk(
                  label: 'DISCOVERED',
                  value: discovered,
                  tooltip:
                      'Files known to the library but not yet '
                      "processed by the metadata-enrichment pipeline. "
                      'These rows render dimmed in the table; their '
                      'title / artist / duration come from filename '
                      'heuristics until the enrichment pipeline reads '
                      'their tags.',
                ),
                const _ActivityDot(),
                _ActivityChunk(
                  label: 'ENRICHING',
                  value: enriching,
                  // Visual cue when this is non-zero: brighten the
                  // value colour so the user can see "work is
                  // happening" without animation noise. Drops back
                  // to the calm tertiary when zero so an idle
                  // library looks idle.
                  emphasize: enriching > 0,
                  tooltip:
                      'Files currently in the metadata-extraction '
                      'pipeline. Each is being read by an isolate '
                      'worker; on completion the row flips to READY '
                      "and the table shows the full tag data. "
                      'Failures roll into FAILED.',
                ),
                const _ActivityDot(),
                _ActivityChunk(
                  label: 'READY',
                  value: ready,
                  tooltip:
                      'Files whose ID3 / Vorbis metadata has been '
                      'successfully read. These render at full '
                      'opacity in the table and are fully sortable '
                      'on every column.',
                ),
                const _ActivityDot(),
                _ActivityChunk(
                  label: 'FAILED',
                  value: failed,
                  warning: failed > 0,
                  tooltip:
                      "Files the metadata pipeline tried to read "
                      'but couldn\'t — corrupt tag block, unsupported '
                      'codec variant, permission error. Playback may '
                      'still work; display values fall back to '
                      'filename parsing. Remove + re-add the source '
                      'or a future "Retry failed" action will let '
                      'these be re-attempted.',
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ActivityChunk extends StatelessWidget {
  final String label;
  final int value;
  final bool warning;
  final bool emphasize;
  final String? tooltip;
  const _ActivityChunk({
    required this.label,
    required this.value,
    this.warning = false,
    this.emphasize = false,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final valueColor = warning
        ? AppColors.favorite
        : emphasize
            ? AppColors.textPrimary
            : AppColors.textSecondary;
    final body = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
            color: AppColors.textTertiary,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '$value',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: valueColor,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
    if (tooltip == null) return body;
    return Tooltip(
      message: tooltip!,
      waitDuration: const Duration(milliseconds: 400),
      child: body,
    );
  }
}

class _ActivityDot extends StatelessWidget {
  const _ActivityDot();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 10),
      child: Text(
        '·',
        style: TextStyle(
          fontSize: 11,
          color: AppColors.textTertiary,
          height: 1.0,
        ),
      ),
    );
  }
}

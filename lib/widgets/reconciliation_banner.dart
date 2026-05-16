import 'package:flutter/material.dart';

import '../models/reconciliation_summary.dart';
import '../state/library_controller.dart';
import '../theme/app_theme.dart';

/// Calm, non-modal narration of "what just happened" after a
/// reconciliation pass — i.e., a scan that flipped a non-trivial
/// number of rows from available to missing because their disk
/// presence changed.
///
/// Renders only when [LibraryController.reconciliationSummary] is
/// non-null. Auto-dismisses on the controller's timer; the user
/// can also dismiss earlier via the × button.
///
/// **UX choices** (intentional):
///   - Single horizontal strip, same height (24px) and surface
///     tone as the status bar so it slots into the operational
///     vocabulary instead of demanding attention.
///   - Preserved count rendered BEFORE removed count. Users
///     emotionally anchor to loss first; leading with "38 preserved
///     through other folders" reframes the operation as a curated
///     workflow step rather than data destruction.
///   - No animation noise. Appears, sits there, disappears. No
///     pulses, no slide-in. The system is making an operational
///     statement, not a celebration.
///   - Accent left-stripe to mark it as transient (same vocabulary
///     as currently-playing row in the table).
class ReconciliationBanner extends StatelessWidget {
  final LibraryController controller;
  const ReconciliationBanner({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (ctx, _) {
        final summary = controller.reconciliationSummary;
        if (summary == null) return const SizedBox.shrink();
        return _ReconciliationStrip(
          summary: summary,
          onDismiss: controller.dismissReconciliationSummary,
        );
      },
    );
  }
}

class _ReconciliationStrip extends StatelessWidget {
  final ReconciliationSummary summary;
  final VoidCallback onDismiss;
  const _ReconciliationStrip({
    required this.summary,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final preserved = summary.preservedElsewhere;
    final removed = summary.removed;
    return Container(
      height: 24,
      color: AppColors.surface,
      child: Row(
        children: [
          // Accent left-stripe — same visual language as the
          // currently-playing row in the table. Marks this strip as
          // a transient operational statement, not part of the
          // permanent layout vocabulary.
          Container(width: 2, color: AppColors.accent),
          const SizedBox(width: 10),
          // Source name: "Q removed", "Z CRATE removed", etc. The
          // word "removed" is the user's mental anchor for what
          // just happened to the watched root.
          Text(
            '${summary.sourceName} reconciled',
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(width: 14),
          // Preserved FIRST — UX anchor on survival, not loss.
          // Suppress when zero so a clean removal (nothing was
          // duplicated elsewhere) doesn't render confusingly.
          if (preserved > 0) ...[
            _SummaryChunk(
              value: preserved,
              label: preserved == 1
                  ? 'preserved through other folders'
                  : 'preserved through other folders',
              emphasize: true,
            ),
            const _Dot(),
          ],
          _SummaryChunk(
            value: removed,
            label: removed == 1 ? 'track removed' : 'tracks removed',
            emphasize: false,
          ),
          const Spacer(),
          // Dismiss affordance. Mouse-hover only; no permanent
          // visual weight so the strip's calm baseline stays
          // intact.
          _DismissButton(onTap: onDismiss),
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}

class _SummaryChunk extends StatelessWidget {
  final int value;
  final String label;
  final bool emphasize;
  const _SummaryChunk({
    required this.value,
    required this.label,
    required this.emphasize,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$value',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: emphasize
                ? AppColors.textPrimary
                : AppColors.textSecondary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: emphasize
                ? AppColors.textSecondary
                : AppColors.textTertiary,
            letterSpacing: 0.2,
          ),
        ),
      ],
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot();

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

class _DismissButton extends StatefulWidget {
  final VoidCallback onTap;
  const _DismissButton({required this.onTap});

  @override
  State<_DismissButton> createState() => _DismissButtonState();
}

class _DismissButtonState extends State<_DismissButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Icon(
            Icons.close_rounded,
            size: 12,
            color: _hovering
                ? AppColors.textPrimary
                : AppColors.textTertiary,
          ),
        ),
      ),
    );
  }
}

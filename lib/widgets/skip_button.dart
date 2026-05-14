import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Tertiary jump-skip control on the playback deck (−1m / −30 /
/// −10 / +10 / +30 / +1m). Intentionally lighter than prev/next
/// circle buttons and the play/pause button so visual hierarchy
/// reads play → navigation → jumps in descending dominance.
///
/// Earlier sizing (48 × 64, primary text colour, w600) made the
/// jump cluster visually heavier than the play button it
/// surrounded — confusing the eye about what the primary action
/// was. New proportions reduce footprint by ~25% and dim the
/// label to textSecondary so the cluster reads as tertiary
/// utility next to the bright play anchor.
class SkipButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;

  const SkipButton({super.key, required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Material(
      color: AppColors.surfaceAlt,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
        side: const BorderSide(color: AppColors.border),
      ),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.zero,
        hoverColor: AppColors.hoverRow,
        focusColor: AppColors.focusOverlay,
        child: Container(
          constraints: const BoxConstraints(minWidth: 42, minHeight: 52),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              color: enabled
                  ? AppColors.textSecondary
                  : AppColors.textTertiary,
              fontSize: 13,
              fontWeight: FontWeight.w500,
              height: 1.0,
            ),
          ),
        ),
      ),
    );
  }
}

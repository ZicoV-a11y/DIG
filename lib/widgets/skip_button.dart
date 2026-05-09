import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class SkipButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;

  const SkipButton({super.key, required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: Material(
        color: AppColors.surfaceAlt,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(5),
          side: const BorderSide(color: AppColors.border),
        ),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(5),
          hoverColor: AppColors.hoverRow,
          focusColor: AppColors.focusOverlay,
          child: Container(
            constraints: const BoxConstraints(minWidth: 38, minHeight: 32),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              label,
              style: TextStyle(
                color: enabled
                    ? AppColors.textPrimary
                    : AppColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                height: 1.0,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

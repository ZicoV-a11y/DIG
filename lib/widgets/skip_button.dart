import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

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
          constraints: const BoxConstraints(minWidth: 48, minHeight: 64),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              color: enabled
                  ? AppColors.textPrimary
                  : AppColors.textSecondary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
              height: 1.0,
            ),
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

class AppColors {
  static const background = Color(0xFF08090C);
  static const navSurface = Color(0xFF111114);
  static const workspaceSurface = Color(0xFF13161D);
  static const surface = Color(0xFF0F1116);
  static const surfaceAlt = Color(0xFF1F1F23);
  static const border = Color(0xFF23262E);
  static const textPrimary = Color(0xFFE7E7EA);
  static const textSecondary = Color(0xFF8A8A90);
  static const textTertiary = Color(0xFF5C5C62);
  static const accent = Color(0xFF6E4DFF);
  static const favorite = Color(0xFFFFC857);
  static const reviewed = Color(0xFF4CAF7E);
  static const trail = Color(0xFFC8523F);

  static final hoverRow = accent.withValues(alpha: 0.06);
  static final selectedRow = accent.withValues(alpha: 0.14);
  static final focusOverlay = accent.withValues(alpha: 0.20);

  static const trailAlphas = <double>[0.18, 0.13, 0.09, 0.06, 0.03];

  static Color? trailTint(int? index) {
    if (index == null || index < 0 || index >= trailAlphas.length) return null;
    return trail.withValues(alpha: trailAlphas[index]);
  }
}

ThemeData buildAppTheme() {
  const scheme = ColorScheme.dark(
    primary: AppColors.accent,
    surface: AppColors.surface,
    onSurface: AppColors.textPrimary,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.background,
    canvasColor: AppColors.background,
    dividerColor: AppColors.border,
    splashFactory: NoSplash.splashFactory,
    hoverColor: AppColors.hoverRow,
    focusColor: AppColors.focusOverlay,
    iconTheme: const IconThemeData(color: AppColors.textSecondary, size: 18),
    textTheme: const TextTheme(
      bodyMedium: TextStyle(color: AppColors.textPrimary, fontSize: 13),
      bodySmall: TextStyle(color: AppColors.textSecondary, fontSize: 12),
      titleMedium: TextStyle(
        color: AppColors.textPrimary,
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
    ),
    dataTableTheme: DataTableThemeData(
      headingRowColor: const WidgetStatePropertyAll(AppColors.surface),
      dataRowColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return AppColors.selectedRow;
        if (states.contains(WidgetState.hovered)) return AppColors.hoverRow;
        return AppColors.background;
      }),
      headingTextStyle: const TextStyle(
        color: AppColors.textSecondary,
        fontSize: 10,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.0,
      ),
      dataTextStyle: const TextStyle(
        color: AppColors.textPrimary,
        fontSize: 13,
      ),
      dividerThickness: 0,
      headingRowHeight: 30,
      dataRowMinHeight: 30,
      dataRowMaxHeight: 32,
      columnSpacing: 18,
      horizontalMargin: 14,
    ),
  );
}

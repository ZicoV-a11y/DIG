import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class TrackArtwork extends StatelessWidget {
  final String seed;
  final double size;
  final bool highlight;

  const TrackArtwork({
    super.key,
    required this.seed,
    this.size = 36,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    final hue = (seed.hashCode % 360).abs().toDouble();
    final base = HSLColor.fromAHSL(1.0, hue, 0.32, 0.30).toColor();
    final shade = HSLColor.fromAHSL(1.0, hue, 0.32, 0.18).toColor();
    final initial = seed.isEmpty ? '?' : seed[0].toUpperCase();

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [base, shade],
        ),
        borderRadius: BorderRadius.zero,
        border: Border.all(
          color: highlight ? AppColors.accent : AppColors.border,
          width: highlight ? 1.2 : 0.5,
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.92),
          fontSize: size * 0.42,
          fontWeight: FontWeight.w700,
          height: 1.0,
        ),
      ),
    );
  }
}

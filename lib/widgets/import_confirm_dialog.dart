import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Confirmation modal shown after parsing an intelligence file but
/// before applying the merge. Surfaces:
///   - record count
///   - parse errors (if any)
///   - per-bucket prediction (merge-by-uid / merge-by-fingerprint /
///     ghost) — populated by the caller after a dry-run.
///
/// For now we just show the total + a clear idempotency warning, so
/// the user understands re-importing the same file will sum play
/// counts again.
class ImportConfirmDialog extends StatelessWidget {
  final String filename;
  final int recordCount;
  final int parseErrors;

  const ImportConfirmDialog({
    super.key,
    required this.filename,
    required this.recordCount,
    required this.parseErrors,
  });

  /// Returns `true` if the user confirms, `false`/`null` if cancelled.
  static Future<bool?> show(
    BuildContext context, {
    required String filename,
    required int recordCount,
    required int parseErrors,
  }) {
    return showDialog<bool>(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) => ImportConfirmDialog(
        filename: filename,
        recordCount: recordCount,
        parseErrors: parseErrors,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
        side: const BorderSide(color: AppColors.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Import intelligence',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                filename,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 14),
              _StatRow(
                label: 'Records',
                value: '$recordCount',
              ),
              if (parseErrors > 0)
                _StatRow(
                  label: 'Parse errors',
                  value: '$parseErrors',
                  warning: true,
                ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.08),
                  border: Border.all(
                    color: AppColors.accent.withValues(alpha: 0.4),
                  ),
                ),
                child: const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 14,
                      color: AppColors.accent,
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Merge: matching tracks have play counts added, '
                        'favorites OR-merged, last-played pushed to most '
                        'recent. Importing the same file twice will sum '
                        'play counts again.',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.textPrimary,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _DialogButton(
                    label: 'Cancel',
                    onPressed: () => Navigator.of(context).pop(false),
                  ),
                  const SizedBox(width: 10),
                  _DialogButton(
                    label: 'Import',
                    primary: true,
                    onPressed: recordCount == 0
                        ? null
                        : () => Navigator.of(context).pop(true),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  final String label;
  final String value;
  final bool warning;
  const _StatRow({
    required this.label,
    required this.value,
    this.warning = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.0,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: warning ? AppColors.favorite : AppColors.textPrimary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _DialogButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool primary;

  const _DialogButton({
    required this.label,
    required this.onPressed,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: primary
          ? AppColors.accent.withValues(alpha: 0.15)
          : AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
        side: BorderSide(
          color: primary ? AppColors.accent : AppColors.border,
        ),
      ),
      child: InkWell(
        onTap: onPressed,
        hoverColor: AppColors.hoverRow,
        focusColor: AppColors.focusOverlay,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Text(
            label,
            style: TextStyle(
              color: onPressed == null
                  ? AppColors.textTertiary
                  : (primary ? AppColors.accent : AppColors.textPrimary),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

import 'dart:io';

import 'package:flutter/material.dart';

import '../models/track.dart';
import '../theme/app_theme.dart';
import '../utils/aggregated_track_view.dart';
import '../utils/file_format.dart';

/// Click-reveal panel that surfaces the per-variant metadata for a
/// multi-variant song bucket. Opened from the track row's right-
/// click menu when the bucket has at least one divergent field
/// (title or artist). Read-only for now — its job is to answer
/// "what's different between my variants?" — editing happens in
/// external tools (Mp3tag / Rekordbox / etc).
///
/// Per project memory: only title + artist participate in the
/// divergence display. Every other field (album, genre, BPM, key,
/// has_artwork) follows last-change-wins resolution; the bucket
/// row shows one value and that's that. This dialog also surfaces
/// the per-variant values for those fields so the user can confirm
/// which variant supplied what without leaving the app.
Future<void> showVariantMetadataDialog({
  required BuildContext context,
  required AggregatedTrackView view,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: Colors.black.withValues(alpha: 0.55),
    transitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (_, _, _) {
      return _VariantMetadataDialog(view: view);
    },
  );
}

class _VariantMetadataDialog extends StatelessWidget {
  final AggregatedTrackView view;
  const _VariantMetadataDialog({required this.view});

  @override
  Widget build(BuildContext context) {
    final variants = view.variants;
    final primary = view.primary;
    return Center(
      child: Material(
        color: AppColors.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: BorderSide(color: AppColors.border),
        ),
        elevation: 10,
        child: SizedBox(
          width: 760,
          height: 560,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(
                primary: primary,
                variantCount: variants.length,
                onClose: () => Navigator.of(context).pop(),
              ),
              const Divider(height: 1, color: AppColors.border),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  children: [
                    _FieldSection(
                      label: 'TITLE',
                      divergent: view.titleDivergent,
                      rows: [
                        for (final v in variants)
                          _VariantValueRow(
                            variant: v,
                            displayValue: v.displayTitle,
                          ),
                      ],
                    ),
                    _FieldSection(
                      label: 'ARTIST',
                      divergent: view.artistDivergent,
                      rows: [
                        for (final v in variants)
                          _VariantValueRow(
                            variant: v,
                            displayValue: v.displayArtist,
                          ),
                      ],
                    ),
                    _OperationalSection(view: view),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final Track primary;
  final int variantCount;
  final VoidCallback onClose;
  const _Header({
    required this.primary,
    required this.variantCount,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Variant metadata',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  primary.displayTitle,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '$variantCount '
                  '${variantCount == 1 ? "variant" : "variants"} in '
                  'this song bucket',
                  style: const TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Close',
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded,
                size: 16, color: AppColors.textSecondary),
            splashRadius: 14,
          ),
        ],
      ),
    );
  }
}

class _FieldSection extends StatelessWidget {
  final String label;
  final bool divergent;
  final List<Widget> rows;
  const _FieldSection({
    required this.label,
    required this.divergent,
    required this.rows,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: AppColors.textTertiary,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.0,
                ),
              ),
              const SizedBox(width: 8),
              if (divergent)
                const Icon(
                  Icons.warning_amber_rounded,
                  size: 11,
                  color: AppColors.favorite,
                )
              else
                const Text(
                  'agreed',
                  style: TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: 9,
                    fontStyle: FontStyle.italic,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          ...rows,
        ],
      ),
    );
  }
}

class _VariantValueRow extends StatelessWidget {
  final Track variant;
  final String displayValue;
  const _VariantValueRow({
    required this.variant,
    required this.displayValue,
  });

  @override
  Widget build(BuildContext context) {
    final format = fileFormatLabel(variant.filename);
    final parent = _parentDirNameOf(variant.path);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Pill(label: format.isEmpty ? '—' : format),
          const SizedBox(width: 8),
          SizedBox(
            width: 120,
            child: Text(
              parent.isEmpty ? '/' : '$parent/',
              style: const TextStyle(
                color: AppColors.textTertiary,
                fontSize: 11,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          const Text(
            '→',
            style: TextStyle(
              color: AppColors.textTertiary,
              fontSize: 11,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              displayValue.isEmpty ? '—' : displayValue,
              style: TextStyle(
                color: displayValue.isEmpty
                    ? AppColors.textTertiary
                    : AppColors.textPrimary,
                fontSize: 12,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Last-change-wins fields. The bucket row picks one value from the
/// variant with the freshest `metadata_read_at`; this section
/// explicitly names that variant (so the user can see *which* one
/// supplied the displayed BPM, key, album, etc.) and lists every
/// variant's value side-by-side for inspection.
class _OperationalSection extends StatelessWidget {
  final AggregatedTrackView view;
  const _OperationalSection({required this.view});

  @override
  Widget build(BuildContext context) {
    final source = view.operationalMetadataSource;
    final sourceLabel = '${fileFormatLabel(source.filename).isEmpty
        ? "?"
        : fileFormatLabel(source.filename)}'
        ' (${_parentDirNameOf(source.path)}/)';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'OPERATIONAL FIELDS  ·  last-change-wins',
            style: TextStyle(
              color: AppColors.textTertiary,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Bucket displays values from: $sourceLabel '
            '(most recently re-enriched).',
            style: const TextStyle(
              color: AppColors.textTertiary,
              fontSize: 10,
            ),
          ),
          const SizedBox(height: 10),
          _opFieldRow('BPM', view.variants, (t) => _bpmString(t.bpm)),
          _opFieldRow('Key', view.variants, (t) => t.displayKey),
          _opFieldRow('Album', view.variants, (t) => t.album),
          _opFieldRow('Genre', view.variants, (t) => t.genre),
        ],
      ),
    );
  }

  Widget _opFieldRow(
    String label,
    List<Track> variants,
    String Function(Track) extractor,
  ) {
    final values = variants.map(extractor).toList();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 60,
            child: Text(
              label,
              style: const TextStyle(
                color: AppColors.textTertiary,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < variants.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Row(
                      children: [
                        _Pill(
                          label: fileFormatLabel(variants[i].filename)
                                  .isEmpty
                              ? '—'
                              : fileFormatLabel(variants[i].filename),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          values[i].isEmpty ? '—' : values[i],
                          style: TextStyle(
                            color: values[i].isEmpty
                                ? AppColors.textTertiary
                                : AppColors.textPrimary,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _bpmString(double? bpm) {
    if (bpm == null || bpm <= 0) return '';
    if (bpm == bpm.roundToDouble()) return bpm.toStringAsFixed(0);
    return bpm.toStringAsFixed(1);
  }
}

class _Pill extends StatelessWidget {
  final String label;
  const _Pill({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: const BoxDecoration(color: AppColors.surfaceAlt),
      child: Text(
        label,
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 10,
          fontFeatures: [FontFeature.tabularFigures()],
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

String _parentDirNameOf(String path) {
  final sep = Platform.pathSeparator;
  final lastSep = path.lastIndexOf(sep);
  if (lastSep <= 0) return '';
  final parentPath = path.substring(0, lastSep);
  final prevSep = parentPath.lastIndexOf(sep);
  return prevSep < 0 ? parentPath : parentPath.substring(prevSep + 1);
}

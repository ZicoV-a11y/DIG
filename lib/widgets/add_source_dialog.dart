import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/source.dart';
import '../services/audio_scanner.dart';
import '../theme/app_theme.dart';

/// Modal shown after the user picks a folder. Captures the per-source
/// scan mode so the controller knows whether to recurse into
/// subdirectories.
///
/// Returns the chosen [ScanMode] on confirm, or `null` on cancel.
Future<ScanMode?> showAddSourceDialog(
  BuildContext context, {
  required String folderPath,
}) {
  return showDialog<ScanMode>(
    context: context,
    barrierColor: Colors.black54,
    builder: (ctx) => _AddSourceDialog(folderPath: folderPath),
  );
}

class _AddSourceDialog extends StatefulWidget {
  final String folderPath;
  const _AddSourceDialog({required this.folderPath});

  @override
  State<_AddSourceDialog> createState() => _AddSourceDialogState();
}

class _AddSourceDialogState extends State<_AddSourceDialog> {
  ScanMode _mode = ScanMode.recursive;
  // Live counts for both scan modes — surfaced next to the radio
  // labels so the user sees the actual file count *before*
  // committing. Catches the macOS folder-picker quirk where
  // selecting a parent vs the inner sibling looks identical in
  // path text but differs by orders of magnitude in audio count.
  int? _topLevelCount;
  int? _recursiveCount;

  @override
  void initState() {
    super.initState();
    _runCounts();
  }

  Future<void> _runCounts() async {
    final results = await Future.wait([
      compute(_countAudio, _CountReq(widget.folderPath, false)),
      compute(_countAudio, _CountReq(widget.folderPath, true)),
    ]);
    if (!mounted) return;
    setState(() {
      _topLevelCount = results[0];
      _recursiveCount = results[1];
    });
  }

  @override
  Widget build(BuildContext context) {
    final folderName = _basenameOf(widget.folderPath);
    final activeCount = _mode == ScanMode.recursive
        ? _recursiveCount
        : _topLevelCount;
    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
        side: const BorderSide(color: AppColors.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Add folder',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                folderName,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                widget.folderPath,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textTertiary,
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'SCAN MODE',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 6),
              _ModeRow(
                value: ScanMode.recursive,
                groupValue: _mode,
                onChanged: (v) => setState(() => _mode = v),
                title: 'Include subfolders',
                subtitle: 'Scan all nested directories.',
                count: _recursiveCount,
              ),
              _ModeRow(
                value: ScanMode.topLevelOnly,
                groupValue: _mode,
                onChanged: (v) => setState(() => _mode = v),
                title: 'Just this folder',
                subtitle: 'Files directly inside only.',
                count: _topLevelCount,
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _DialogButton(
                    label: 'Cancel',
                    onPressed: () => Navigator.of(context).pop(null),
                  ),
                  const SizedBox(width: 10),
                  _DialogButton(
                    label: activeCount == null
                        ? 'Add'
                        : 'Add $activeCount file${activeCount == 1 ? '' : 's'}',
                    primary: true,
                    enabled: activeCount == null || activeCount > 0,
                    onPressed: () => Navigator.of(context).pop(_mode),
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

class _ModeRow extends StatelessWidget {
  final ScanMode value;
  final ScanMode groupValue;
  final ValueChanged<ScanMode> onChanged;
  final String title;
  final String subtitle;
  final int? count;

  const _ModeRow({
    required this.value,
    required this.groupValue,
    required this.onChanged,
    required this.title,
    required this.subtitle,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    final selected = value == groupValue;
    return InkWell(
      onTap: () => onChanged(value),
      hoverColor: AppColors.hoverRow,
      focusColor: AppColors.focusOverlay,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                shape: BoxShape.rectangle,
                border: Border.all(
                  color: selected ? AppColors.accent : AppColors.border,
                  width: 1.5,
                ),
              ),
              child: selected
                  ? const Center(
                      child: SizedBox(
                        width: 6,
                        height: 6,
                        child: ColoredBox(color: AppColors.accent),
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 12,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.w500,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        count == null ? 'counting…' : _formatCount(count!),
                        style: TextStyle(
                          color: count == null
                              ? AppColors.textTertiary
                              : (count == 0
                                  ? AppColors.favorite
                                  : AppColors.accent),
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: 11,
                      height: 1.2,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatCount(int n) =>
    '$n file${n == 1 ? '' : 's'}';

class _DialogButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  final bool primary;
  final bool enabled;

  const _DialogButton({
    required this.label,
    required this.onPressed,
    this.primary = false,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: !enabled
          ? AppColors.surface
          : (primary
              ? AppColors.accent.withValues(alpha: 0.15)
              : AppColors.surface),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
        side: BorderSide(
          color: !enabled
              ? AppColors.border
              : (primary ? AppColors.accent : AppColors.border),
        ),
      ),
      child: InkWell(
        onTap: enabled ? onPressed : null,
        hoverColor: AppColors.hoverRow,
        focusColor: AppColors.focusOverlay,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Text(
            label,
            style: TextStyle(
              color: !enabled
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

String _basenameOf(String path) {
  final segs = path.split(Platform.pathSeparator);
  for (var i = segs.length - 1; i >= 0; i--) {
    if (segs[i].isNotEmpty) return segs[i];
  }
  return path;
}

class _CountReq {
  final String path;
  final bool recursive;
  const _CountReq(this.path, this.recursive);
}

@pragma('vm:entry-point')
int _countAudio(_CountReq req) {
  final root = Directory(req.path);
  if (!root.existsSync()) return 0;
  var n = 0;
  final stack = <Directory>[root];
  while (stack.isNotEmpty) {
    final dir = stack.removeLast();
    final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } catch (_) {
      continue;
    }
    for (final entity in entries) {
      if (entity is Directory) {
        if (req.recursive) stack.add(entity);
        continue;
      }
      if (entity is! File) continue;
      final p = entity.path;
      final i = p.lastIndexOf(Platform.pathSeparator);
      final name = i < 0 ? p : p.substring(i + 1);
      if (name.startsWith('.')) continue;
      final dot = name.lastIndexOf('.');
      if (dot <= 0 || dot == name.length - 1) continue;
      final ext = name.substring(dot + 1).toLowerCase();
      if (AudioScanner.audioExtensions.contains(ext)) n++;
    }
  }
  return n;
}

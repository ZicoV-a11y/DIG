import 'package:flutter/material.dart';

import '../models/operational_state.dart';
import '../models/state_preview.dart';
import '../services/library_state_browser.dart';
import '../state/library_controller.dart';
import '../theme/app_theme.dart';

/// Load Operational State dialog. Browse and switch the running
/// app's operational reality.
///
/// **Language guardrail:** the user-facing copy in this dialog
/// must NEVER use "backup," "restore," "snapshot," "revert,"
/// "import," or any other word that implies *secondary archival
/// semantics*. The `.library` files are *operational identity
/// objects* — lineage states, device realities, contribution
/// sources. Loading one means *entering another operational
/// reality*, not "rolling back to a backup."
///
/// **UI structure:**
///   - Left: fast list of operational states, grouped by source
///     (Current device / Other devices / Historical lineage /
///     Shared libraries). Filename + filesystem stat only at
///     render time — no DB open.
///   - Right: lazy-loaded preview pane for the SELECTED row only
///     (track count, favorites, reviewed, plays, last played).
///     One file open per selection.
///   - Footer: "Load this operational state" button.
///
/// **Selection is visually sacred** — the selected row gets a
/// prominent accent border + larger spacing so the user always
/// sees clearly *which operational reality they're about to
/// enter*.
Future<void> showLoadStateDialog({
  required BuildContext context,
  required LibraryController controller,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: Colors.black.withValues(alpha: 0.55),
    transitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (_, _, _) {
      return _LoadStateDialog(controller: controller);
    },
  );
}

class _LoadStateDialog extends StatefulWidget {
  final LibraryController controller;
  const _LoadStateDialog({required this.controller});

  @override
  State<_LoadStateDialog> createState() => _LoadStateDialogState();
}

class _LoadStateDialogState extends State<_LoadStateDialog> {
  late final LibraryStateBrowser _browser;
  List<OperationalState>? _states;
  OperationalState? _selected;
  StatePreview? _preview;
  bool _previewLoading = false;
  bool _busy = false;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    final root = widget.controller.libraryRoot;
    if (root != null) {
      _browser = LibraryStateBrowser(root: root);
      _loadList();
    }
  }

  Future<void> _loadList() async {
    final controller = widget.controller;
    final list = await _browser.listOperationalStates(
      currentMachineId: controller.machineId,
    );
    if (!mounted) return;
    setState(() {
      _states = list;
      // Default-select the live current-device entry so the user
      // sees a meaningful preview the moment the dialog opens.
      _selected = list.firstWhere(
        (s) => s.source == OperationalStateSource.currentDevice,
        orElse: () => list.isNotEmpty
            ? list.first
            : list.first, // safe — guarded by isEmpty above
      );
    });
    if (_selected != null) _enrich(_selected!);
  }

  Future<void> _enrich(OperationalState state) async {
    setState(() {
      _previewLoading = true;
      _preview = null;
    });
    final preview = await _browser.enrichPreview(state);
    if (!mounted) return;
    // Guard against rapid clicks — if the user moved on, drop
    // this result.
    if (_selected != state) return;
    setState(() {
      _previewLoading = false;
      _preview = preview;
    });
  }

  Future<void> _loadSelected() async {
    final target = _selected;
    if (target == null) return;
    setState(() {
      _busy = true;
      _statusMessage = null;
    });
    final err = await widget.controller.loadOperationalState(target);
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _busy = false;
        _statusMessage = err;
      });
      return;
    }
    setState(() {
      _busy = false;
      _statusMessage =
          'Loaded. Quit the app (Cmd+Q) and relaunch to enter this '
          'operational state.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final states = _states;
    return Center(
      child: Material(
        color: AppColors.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: BorderSide(color: AppColors.border),
        ),
        elevation: 10,
        child: SizedBox(
          width: 900,
          height: 640,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(onClose: () => Navigator.of(context).pop()),
              const Divider(height: 1, color: AppColors.border),
              Expanded(
                child: states == null
                    ? const Center(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 1.5),
                        ),
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Left: state list (grouped)
                          SizedBox(
                            width: 460,
                            child: _StateList(
                              states: states,
                              selected: _selected,
                              onSelect: (s) {
                                setState(() => _selected = s);
                                _enrich(s);
                              },
                            ),
                          ),
                          const VerticalDivider(
                            width: 1,
                            color: AppColors.border,
                          ),
                          // Right: preview pane
                          Expanded(
                            child: _PreviewPane(
                              selected: _selected,
                              preview: _preview,
                              loading: _previewLoading,
                            ),
                          ),
                        ],
                      ),
              ),
              const Divider(height: 1, color: AppColors.border),
              _Footer(
                statusMessage: _statusMessage,
                canLoad: !_busy &&
                    _selected != null &&
                    _statusMessage == null,
                onCancel: () => Navigator.of(context).pop(),
                onLoad: _loadSelected,
                busy: _busy,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final VoidCallback onClose;
  const _Header({required this.onClose});

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
                  'Load operational state',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Switch the running app to a different library reality. '
                  'Your current state is saved as a snapshot first; you '
                  'can always return to it.',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
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

class _StateList extends StatelessWidget {
  final List<OperationalState> states;
  final OperationalState? selected;
  final ValueChanged<OperationalState> onSelect;

  const _StateList({
    required this.states,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final groups = _groupStates(states);
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 6),
      children: [
        for (final group in groups) ...[
          _GroupHeader(label: group.label, hint: group.hint),
          if (group.entries.isEmpty)
            const _EmptyGroupRow()
          else
            for (final state in group.entries)
              _StateRow(
                state: state,
                isSelected: selected == state,
                onTap: group.loadable ? () => onSelect(state) : null,
              ),
          const SizedBox(height: 6),
        ],
      ],
    );
  }
}

class _Group {
  final String label;
  final String? hint;
  final List<OperationalState> entries;
  final bool loadable;
  const _Group({
    required this.label,
    required this.hint,
    required this.entries,
    required this.loadable,
  });
}

List<_Group> _groupStates(List<OperationalState> states) {
  final byType = <OperationalStateSource, List<OperationalState>>{};
  for (final s in states) {
    byType.putIfAbsent(s.source, () => []).add(s);
  }
  return [
    _Group(
      label: 'CURRENT DEVICE STATE',
      hint: 'The live library this device is running right now.',
      entries: byType[OperationalStateSource.currentDevice] ?? const [],
      loadable: true,
    ),
    _Group(
      label: 'OTHER DEVICE STATES',
      hint: 'Operational states from other devices in this library root.',
      entries: byType[OperationalStateSource.otherDevice] ?? const [],
      loadable: true,
    ),
    _Group(
      label: 'HISTORICAL OPERATIONAL STATES',
      hint: 'Rolling lineage points from this device.',
      entries:
          byType[OperationalStateSource.historicalLineage] ?? const [],
      loadable: true,
    ),
    _Group(
      label: 'SHARED LIBRARIES',
      hint: 'Future cross-device exchange (coming soon).',
      entries: byType[OperationalStateSource.sharedLibrary] ?? const [],
      loadable: false,
    ),
  ];
}

class _GroupHeader extends StatelessWidget {
  final String label;
  final String? hint;
  const _GroupHeader({required this.label, this.hint});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: AppColors.textTertiary,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
          if (hint != null) ...[
            const SizedBox(height: 2),
            Text(
              hint!,
              style: const TextStyle(
                color: AppColors.textTertiary,
                fontSize: 10,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _EmptyGroupRow extends StatelessWidget {
  const _EmptyGroupRow();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(18, 2, 18, 8),
      child: Text(
        '(none)',
        style: TextStyle(
          color: AppColors.textTertiary,
          fontSize: 11,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }
}

class _StateRow extends StatelessWidget {
  final OperationalState state;
  final bool isSelected;
  final VoidCallback? onTap;

  const _StateRow({
    required this.state,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    final accent = isSelected ? AppColors.accent : Colors.transparent;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        hoverColor: disabled ? null : AppColors.hoverRow,
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: accent, width: 3),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(15, 10, 18, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Text(
                          state.machineId,
                          style: TextStyle(
                            color: disabled
                                ? AppColors.textTertiary
                                : AppColors.textPrimary,
                            fontSize: 12,
                            fontWeight: isSelected
                                ? FontWeight.w600
                                : FontWeight.w500,
                          ),
                        ),
                        if (state.source ==
                            OperationalStateSource.currentDevice) ...[
                          const SizedBox(width: 8),
                          const _Pill(label: 'LIVE'),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${_displayCapturedAt(state.capturedAt)} '
                      '• ${_displayFileSize(state.fileSize)}',
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                    if (state.libraryName != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        state.libraryName!,
                        style: const TextStyle(
                          color: AppColors.textTertiary,
                          fontSize: 10,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
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

class _Pill extends StatelessWidget {
  final String label;
  const _Pill({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.18),
        border: Border.all(color: AppColors.accent),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: AppColors.accent,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
        ),
      ),
    );
  }
}

class _PreviewPane extends StatelessWidget {
  final OperationalState? selected;
  final StatePreview? preview;
  final bool loading;

  const _PreviewPane({
    required this.selected,
    required this.preview,
    required this.loading,
  });

  @override
  Widget build(BuildContext context) {
    final s = selected;
    if (s == null) {
      return const _EmptyPreview();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 16, 22, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s.machineId,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _displayCapturedAt(s.capturedAt),
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 2),
          if (s.libraryName != null)
            Text(
              s.libraryName!,
              style: const TextStyle(
                color: AppColors.textTertiary,
                fontSize: 10,
                letterSpacing: 0.5,
              ),
            ),
          const SizedBox(height: 18),
          if (loading)
            const _PreviewLoading()
          else if (preview == null)
            const SizedBox.shrink()
          else if (preview!.errored)
            _PreviewError(message: preview!.errorMessage ?? '')
          else
            _PreviewStats(preview: preview!),
          const Spacer(),
          Text(
            'File: ${_displayFileSize(s.fileSize)}',
            style: const TextStyle(
              color: AppColors.textTertiary,
              fontSize: 10,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            s.filePath,
            style: const TextStyle(
              color: AppColors.textTertiary,
              fontSize: 9,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _EmptyPreview extends StatelessWidget {
  const _EmptyPreview();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(36),
        child: Text(
          'Select a state to preview its operational identity.',
          style: TextStyle(
            color: AppColors.textTertiary,
            fontSize: 11,
            fontStyle: FontStyle.italic,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _PreviewLoading extends StatelessWidget {
  const _PreviewLoading();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: const [
        SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(strokeWidth: 1.5),
        ),
        SizedBox(width: 10),
        Text(
          'Reading operational state…',
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 11,
          ),
        ),
      ],
    );
  }
}

class _PreviewError extends StatelessWidget {
  final String message;
  const _PreviewError({required this.message});

  @override
  Widget build(BuildContext context) {
    return Text(
      message,
      style: const TextStyle(
        color: AppColors.textSecondary,
        fontSize: 11,
        fontStyle: FontStyle.italic,
      ),
    );
  }
}

class _PreviewStats extends StatelessWidget {
  final StatePreview preview;
  const _PreviewStats({required this.preview});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StatRow(
          label: 'Tracks indexed',
          value: _intOrDash(preview.trackCount),
        ),
        _StatRow(
          label: 'Favorites',
          value: _intOrDash(preview.favoriteCount),
        ),
        _StatRow(
          label: 'Reviewed',
          value: _intOrDash(preview.reviewedCount),
        ),
        _StatRow(
          label: 'Total plays',
          value: _intOrDash(preview.totalPlays),
        ),
        _StatRow(
          label: 'Last played',
          value: preview.lastPlayedAt == null
              ? '—'
              : _displayCapturedAt(preview.lastPlayedAt!),
        ),
      ],
    );
  }
}

class _StatRow extends StatelessWidget {
  final String label;
  final String value;
  const _StatRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: const TextStyle(
                color: AppColors.textTertiary,
                fontSize: 11,
                letterSpacing: 0.4,
              ),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w500,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  final String? statusMessage;
  final bool canLoad;
  final bool busy;
  final VoidCallback onCancel;
  final VoidCallback onLoad;

  const _Footer({
    required this.statusMessage,
    required this.canLoad,
    required this.busy,
    required this.onCancel,
    required this.onLoad,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: statusMessage == null
                ? const SizedBox.shrink()
                : Text(
                    statusMessage!,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 11,
                    ),
                  ),
          ),
          TextButton(
            onPressed: busy ? null : onCancel,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.textSecondary,
            ),
            child: const Text('Cancel'),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: canLoad ? onLoad : null,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.accent,
            ),
            child: busy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child:
                        CircularProgressIndicator(strokeWidth: 1.5),
                  )
                : const Text('Load this operational state'),
          ),
        ],
      ),
    );
  }
}

String _intOrDash(int? v) {
  if (v == null) return '—';
  return _formatNumber(v);
}

String _formatNumber(int v) {
  // Thousands separator, no locale dependency.
  final s = v.toString();
  final out = StringBuffer();
  var count = 0;
  for (var i = s.length - 1; i >= 0; i--) {
    out.write(s[i]);
    count++;
    if (count == 3 && i > 0 && s[i - 1] != '-') {
      out.write(',');
      count = 0;
    }
  }
  return out.toString().split('').reversed.join();
}

String _displayFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String _displayCapturedAt(DateTime at) {
  final now = DateTime.now();
  final diff = now.difference(at);
  String rel;
  if (diff.inMinutes < 1) {
    rel = 'just now';
  } else if (diff.inMinutes < 60) {
    rel = '${diff.inMinutes} min ago';
  } else if (diff.inHours < 24) {
    rel = '${diff.inHours}h ago';
  } else if (diff.inDays < 7) {
    rel = '${diff.inDays}d ago';
  } else {
    rel = '${at.month}/${at.day}/${(at.year % 100).toString().padLeft(2, '0')}';
  }
  final hour12 = at.hour == 0
      ? 12
      : at.hour > 12
          ? at.hour - 12
          : at.hour;
  final ampm = at.hour >= 12 ? 'PM' : 'AM';
  final minute = at.minute.toString().padLeft(2, '0');
  return '$hour12:$minute $ampm • $rel';
}

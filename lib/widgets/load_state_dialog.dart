import 'package:flutter/material.dart';

import '../models/activity_event.dart';
import '../models/operational_state.dart';
import '../models/state_preview.dart';
import '../services/library_state_browser.dart';
import '../state/library_controller.dart';
import '../theme/app_theme.dart';
import 'event_log_format.dart';

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
                  'Your current state is saved as a lineage point first; '
                  'you can always return to it.',
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
    final at = state.capturedAt;
    // Time is identity in this system — render date + time as the
    // dominant element. Device label is supporting metadata; age
    // and filesize live below as smaller hint text.
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
          padding: const EdgeInsets.fromLTRB(15, 12, 18, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Date — dominant, uppercase, "MAY 12, 2026" form.
              Text(
                _displayDateLong(at),
                style: TextStyle(
                  color: disabled
                      ? AppColors.textTertiary
                      : AppColors.textPrimary,
                  fontSize: 13,
                  fontWeight:
                      isSelected ? FontWeight.w700 : FontWeight.w600,
                  letterSpacing: 0.6,
                  height: 1.1,
                ),
              ),
              const SizedBox(height: 2),
              // Time — strong, second-most-prominent.
              Row(
                children: [
                  Text(
                    _displayTime(at),
                    style: TextStyle(
                      color: disabled
                          ? AppColors.textTertiary
                          : AppColors.textPrimary,
                      fontSize: 16,
                      fontWeight: isSelected
                          ? FontWeight.w600
                          : FontWeight.w500,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      height: 1.0,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _displayRelativeAge(at),
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              // Device + library + filesize — supporting metadata.
              Row(
                children: [
                  Text(
                    state.machineId,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.4,
                    ),
                  ),
                  if (state.source ==
                      OperationalStateSource.currentDevice) ...[
                    const SizedBox(width: 8),
                    const _Pill(label: 'LIVE'),
                  ],
                ],
              ),
              if (state.libraryName != null) ...[
                const SizedBox(height: 1),
                Text(
                  state.libraryName!,
                  style: const TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: 10,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
              const SizedBox(height: 2),
              Text(
                _displayFileSize(state.fileSize),
                style: const TextStyle(
                  color: AppColors.textTertiary,
                  fontSize: 10,
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
          // Header — date dominant, then time + library + device.
          Text(
            _displayDateLong(s.capturedAt),
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${_displayTime(s.capturedAt)} • '
            '${_displayRelativeAge(s.capturedAt)}',
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text(
                s.machineId,
                style: const TextStyle(
                  color: AppColors.textTertiary,
                  fontSize: 11,
                  letterSpacing: 0.5,
                ),
              ),
              if (s.libraryName != null) ...[
                const SizedBox(width: 8),
                Text(
                  '• ${s.libraryName!}',
                  style: const TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: 11,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 14),
          const Divider(height: 1, color: AppColors.border),
          const SizedBox(height: 14),
          // "Changes in this save period" — the right pane's
          // narrative is what happened during this operational
          // reality, not database diagnostics or file paths.
          const _SectionLabel('CHANGES IN THIS SAVE PERIOD'),
          const SizedBox(height: 2),
          const Text(
            'Last 25 operational changes',
            style: TextStyle(
              color: AppColors.textTertiary,
              fontSize: 10,
            ),
          ),
          const SizedBox(height: 10),
          if (loading)
            const _PreviewLoading()
          else if (preview == null)
            const SizedBox.shrink()
          else if (preview!.errored)
            _PreviewError(message: preview!.errorMessage ?? '')
          else
            Expanded(
              child: _ActivityTimeline(
                events: preview!.recentEvents,
              ),
            ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel(this.label);

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        color: AppColors.textTertiary,
        fontSize: 10,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.2,
      ),
    );
  }
}

class _ActivityTimeline extends StatelessWidget {
  final List<ActivityEvent>? events;
  const _ActivityTimeline({required this.events});

  @override
  Widget build(BuildContext context) {
    final list = events;
    if (list == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'No recorded activity (older state file).',
          style: TextStyle(
            color: AppColors.textTertiary,
            fontSize: 11,
            fontStyle: FontStyle.italic,
          ),
        ),
      );
    }
    if (list.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'No activity has been logged in this state yet.',
          style: TextStyle(
            color: AppColors.textTertiary,
            fontSize: 11,
            fontStyle: FontStyle.italic,
          ),
        ),
      );
    }
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: list.length,
      itemBuilder: (_, i) => _ActivityRow(event: list[i]),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  final ActivityEvent event;
  const _ActivityRow({required this.event});

  @override
  Widget build(BuildContext context) {
    final descriptor = eventDescriptorFor(event);
    final detail = eventDetailLineFor(event);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            descriptor.icon,
            size: 13,
            color: descriptor.color,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  descriptor.label,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (event.path != null) ...[
                  const SizedBox(height: 1),
                  Text(
                    _basename(event.path!),
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 10,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                if (detail != null) ...[
                  const SizedBox(height: 1),
                  Text(
                    detail,
                    style: const TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: 10,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            _displayRelativeAge(event.recordedAt),
            style: const TextStyle(
              color: AppColors.textTertiary,
              fontSize: 10,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

String _basename(String path) {
  final i = path.lastIndexOf('/');
  if (i < 0 || i == path.length - 1) return path;
  return path.substring(i + 1);
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

String _displayFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

const _monthsLong = [
  'JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN',
  'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC',
];

/// "MAY 12, 2026" — date as identity, dominant in the left list.
String _displayDateLong(DateTime at) {
  return '${_monthsLong[at.month - 1]} ${at.day}, ${at.year}';
}

/// "3:44 PM" — time, second-most-dominant.
String _displayTime(DateTime at) {
  final hour12 = at.hour == 0
      ? 12
      : at.hour > 12
          ? at.hour - 12
          : at.hour;
  final ampm = at.hour >= 12 ? 'PM' : 'AM';
  final minute = at.minute.toString().padLeft(2, '0');
  return '$hour12:$minute $ampm';
}

/// "6h ago" / "just now" / "2d ago" / fallback short date. Used as
/// soft supporting hint next to the dominant time.
String _displayRelativeAge(DateTime at) {
  final now = DateTime.now();
  final diff = now.difference(at);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  return '${at.month}/${at.day}/'
      '${(at.year % 100).toString().padLeft(2, '0')}';
}


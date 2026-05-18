import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/operational_log.dart';

/// On-device chronological view of [OperationalLog.events].
///
/// PR2.8.D.3 promotes this from "ugly read-only console" to
/// the **primary debugging surface** during real-device
/// validation:
///
///   - Newest at top; `[HH:MM:SS.mmm] [tag] message` rows that
///     match the clipboard / JSONL export shape exactly.
///   - Tag tint matches the operational palette (sync/manifest
///     purple, engine amber, playback teal, generation/file
///     green, dev/boot muted).
///   - Filter chips along the top — derived from the tags
///     currently in the buffer — toggle domains on / off.
///     Crucial once rotation, interruption, and sync-block fire
///     concurrently.
///   - Copy → drops every visible row into the iOS clipboard,
///     ready to paste into a bug report.
///   - Clear → wipes the in-memory buffer (in-flight session
///     only; the persisted JSONL is untouched until next
///     lifecycle flush).
///   - Session-boundary rows (tag `session`) render as a
///     visual divider, not a tagged line.
class TimelineView extends StatefulWidget {
  const TimelineView({super.key, this.maxRows = 80});

  /// Cap on rows rendered. Defers to [OperationalLog.maxEntries]
  /// for the actual buffer.
  final int maxRows;

  @override
  State<TimelineView> createState() => _TimelineViewState();
}

class _TimelineViewState extends State<TimelineView> {
  /// Tags the user has filtered OUT. Default empty = show all.
  /// Survives buffer rebuilds (filter is a view concern, not a
  /// data concern).
  final Set<String> _hiddenTags = <String>{};

  void _toggleTag(String tag) {
    setState(() {
      if (_hiddenTags.contains(tag)) {
        _hiddenTags.remove(tag);
      } else {
        _hiddenTags.add(tag);
      }
    });
  }

  Future<void> _copy(List<OperationalEvent> visible) async {
    final text = visible.map(OperationalLog.formatEvent).join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: const Color(0xFF1C1F26),
        content: Text(
          'Copied ${visible.length} rows',
          style: const TextStyle(color: Color(0xFFF2F2F7)),
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _clear() {
    OperationalLog.clear();
    OperationalLog.boundary('timeline cleared');
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF14161A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2A2D36)),
      ),
      child: ValueListenableBuilder<List<OperationalEvent>>(
        valueListenable: OperationalLog.events,
        builder: (_, events, _) {
          final tags = <String>{for (final e in events) e.tag};
          final visible = events
              .where((e) => !_hiddenTags.contains(e.tag))
              .toList();
          final cap = visible.length > widget.maxRows
              ? visible.length - widget.maxRows
              : 0;
          final shown = visible.sublist(cap).reversed.toList();

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _header(events.length, visible.length, () => _copy(visible)),
              if (tags.isNotEmpty) _filterChips(tags),
              const SizedBox(height: 6),
              if (shown.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    '<no events match current filter>',
                    style: TextStyle(
                      color: Color(0xFF7D7D85),
                      fontFamily: 'Menlo',
                      fontSize: 11,
                    ),
                  ),
                )
              else
                for (final e in shown) _TimelineRow(event: e),
            ],
          );
        },
      ),
    );
  }

  Widget _header(int total, int visible, VoidCallback onCopy) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          const Text(
            'TIMELINE',
            style: TextStyle(
              color: Color(0xFFA1A1AA),
              fontWeight: FontWeight.bold,
              fontSize: 11,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$visible / $total',
            style: const TextStyle(
              color: Color(0xFF7D7D85),
              fontFamily: 'Menlo',
              fontSize: 11,
            ),
          ),
          const Spacer(),
          _HeaderAction(
            label: 'Copy',
            onTap: total == 0 ? null : onCopy,
          ),
          const SizedBox(width: 6),
          _HeaderAction(
            label: 'Clear',
            onTap: total == 0 ? null : _clear,
          ),
        ],
      ),
    );
  }

  Widget _filterChips(Set<String> tags) {
    final sorted = tags.toList()..sort();
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final tag in sorted)
          _FilterChip(
            tag: tag,
            hidden: _hiddenTags.contains(tag),
            onTap: () => _toggleTag(tag),
          ),
      ],
    );
  }
}

class _HeaderAction extends StatelessWidget {
  const _HeaderAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFF1C1F26),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFF2A2D36)),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: enabled
                ? const Color(0xFFF2F2F7)
                : const Color(0xFF7D7D85),
            fontFamily: 'Menlo',
            fontSize: 11,
          ),
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.tag,
    required this.hidden,
    required this.onTap,
  });

  final String tag;
  final bool hidden;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tint = _tagColor(tag);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: hidden ? const Color(0xFF14161A) : tint.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: hidden ? const Color(0xFF2A2D36) : tint.withValues(alpha: 0.5),
          ),
        ),
        child: Text(
          tag,
          style: TextStyle(
            color: hidden ? const Color(0xFF7D7D85) : tint,
            fontFamily: 'Menlo',
            fontSize: 10,
            fontWeight: hidden ? FontWeight.w400 : FontWeight.w600,
            decoration: hidden ? TextDecoration.lineThrough : null,
            decorationColor: const Color(0xFF7D7D85),
          ),
        ),
      ),
    );
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({required this.event});

  final OperationalEvent event;

  @override
  Widget build(BuildContext context) {
    if (event.tag == OperationalLog.sessionTag) {
      return _BoundaryRow(event: event);
    }
    final ts = event.timestamp;
    final stamp = '${_two(ts.hour)}:${_two(ts.minute)}:${_two(ts.second)}'
        '.${ts.millisecond.toString().padLeft(3, '0')}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: DefaultTextStyle(
        style: const TextStyle(fontFamily: 'Menlo', fontSize: 11, height: 1.3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 86,
              child: Text(
                stamp,
                style: const TextStyle(color: Color(0xFF7D7D85)),
              ),
            ),
            SizedBox(
              width: 78,
              child: Text(
                '[${event.tag}]',
                style: TextStyle(
                  color: _tagColor(event.tag),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Expanded(
              child: Text(
                event.message,
                style: const TextStyle(color: Color(0xFFF2F2F7)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
}

class _BoundaryRow extends StatelessWidget {
  const _BoundaryRow({required this.event});

  final OperationalEvent event;

  @override
  Widget build(BuildContext context) {
    final ts = event.timestamp;
    final stamp = '${_two(ts.hour)}:${_two(ts.minute)}:${_two(ts.second)}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            stamp,
            style: const TextStyle(
              color: Color(0xFF7D7D85),
              fontFamily: 'Menlo',
              fontSize: 10,
            ),
          ),
          const SizedBox(width: 8),
          const Expanded(child: Divider(color: Color(0xFF2A2D36), height: 1)),
          const SizedBox(width: 8),
          Text(
            event.message,
            style: const TextStyle(
              color: Color(0xFFA1A1AA),
              fontFamily: 'Menlo',
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(width: 8),
          const Expanded(child: Divider(color: Color(0xFF2A2D36), height: 1)),
        ],
      ),
    );
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
}

/// Same tone vocabulary the rest of the companion uses — dev/
/// boot muted, runtime green, sync-side accent purple, engine
/// warm orange, playback teal, session-boundary slate.
Color _tagColor(String tag) {
  switch (tag) {
    case 'boot':
    case 'dev':
      return const Color(0xFFA1A1AA);
    case 'generation':
    case 'file':
    case 'reconciled':
      return const Color(0xFF4CAF50);
    case 'pair':
    case 'sync':
    case 'manifest':
    case 'telemetry':
      return const Color(0xFF7C4DFF);
    case 'engine':
      return const Color(0xFFFFB300);
    case 'playback':
      return const Color(0xFF03DAC6);
    case OperationalLog.sessionTag:
      return const Color(0xFFA1A1AA);
    default:
      return const Color(0xFFF2F2F7);
  }
}

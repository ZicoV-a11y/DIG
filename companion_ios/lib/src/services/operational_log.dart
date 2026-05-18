import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Process-global ring buffer of operational events.
///
/// PR2.8.D.2 promoted the existing `debugPrint('[tag] msg')`
/// convention to a UI-observable [ValueListenable]. PR2.8.D.3
/// freezes the **entry shape as an operational contract** and
/// adds the persistence + boundary primitives the on-device
/// debugging phase will lean on.
///
/// ## Canonical event shape (frozen)
///
/// Every line in the timeline / clipboard export / JSONL store
/// takes the form:
///
///     [HH:MM:SS.mmm] [tag] message
///
/// JSONL representation:
///
///     {"ts":"<ISO-8601 ms UTC>","tag":"<tag>","message":"<...>"}
///
/// Rules — load-bearing for future export / parsing / replay
/// tooling:
///
///   - `tag` is a short lowercase domain word
///     (`boot` `pair` `sync` `manifest` `telemetry` `reconciled`
///     `generation` `file` `playback` `engine` `dev` `session`).
///   - `message` is operational narration, NEVER compressed.
///     `playback resume rebound intel=abc oldGen=41 newGen=42 pos=18342ms`
///     is correct; `rebound` is not. Clarity > shortness.
///   - Future event_id field is reserved — if it lands, it goes
///     as an additional JSONL key without breaking older
///     readers. Don't pack ids into the message string.
///
/// ## Session boundaries
///
/// `OperationalLog.boundary(label)` emits a special row with
/// tag `'session'` that renders as a visual divider in the
/// TimelineView and as `──── label ────` in clipboard exports.
/// Reserved for sparse high-signal lifecycle moments
/// (app launch, generation rotation, interruption begin /
/// resume) — never per-event noise.
///
/// ## Persistence
///
/// Buffer flushes to JSONL on app-pause via a
/// [WidgetsBindingObserver] wired in `main.dart`; restores on
/// boot. Periodic / critical-event flushes are a known
/// future-work item — hard kills bypass the pause hook.
class OperationalLog {
  OperationalLog._();

  static const int maxEntries = 200;

  /// Reserved tag for [boundary] rows. Treated specially by
  /// the timeline UI and the clipboard exporter.
  static const String sessionTag = 'session';

  static final ValueNotifier<List<OperationalEvent>> events =
      ValueNotifier<List<OperationalEvent>>(const []);

  /// Emit a tagged operational event. Always prints to console
  /// (preserving the existing debugPrint contract); also
  /// appends to the in-memory ring buffer.
  static void emit(String tag, String message) {
    debugPrint('[$tag] $message');
    _append(OperationalEvent(
      timestamp: DateTime.now(),
      tag: tag,
      message: message,
    ));
  }

  /// Emit a session-boundary row. Sparse markers only —
  /// "app launch" / "rotate to gen abc". Rendered specially in
  /// the timeline + exports.
  static void boundary(String label) {
    debugPrint('[$sessionTag] ──── $label ────');
    _append(OperationalEvent(
      timestamp: DateTime.now(),
      tag: sessionTag,
      message: label,
    ));
  }

  static void _append(OperationalEvent entry) {
    final next = List<OperationalEvent>.from(events.value)..add(entry);
    if (next.length > maxEntries) {
      next.removeRange(0, next.length - maxEntries);
    }
    events.value = next;
  }

  /// Wipe the buffer (UI Clear button + tests). Doesn't touch
  /// the persisted JSONL — call [persistTo] after if you want
  /// the on-disk copy cleared too.
  static void clear() {
    events.value = const [];
  }

  /// Format an event the way it shows up in the timeline /
  /// clipboard export. Single source of truth for the canonical
  /// `[HH:MM:SS.mmm] [tag] message` shape.
  static String formatEvent(OperationalEvent e) {
    final ts = e.timestamp;
    final stamp = '${_two(ts.hour)}:${_two(ts.minute)}:${_two(ts.second)}'
        '.${ts.millisecond.toString().padLeft(3, '0')}';
    if (e.tag == sessionTag) {
      return '[$stamp] [$sessionTag] ──── ${e.message} ────';
    }
    return '[$stamp] [${e.tag}] ${e.message}';
  }

  /// Render the full current buffer as a newline-joined string
  /// suitable for clipboard / share / bug-report attachment.
  static String exportText() {
    return events.value.map(formatEvent).join('\n');
  }

  /// Write the buffer to [path] as JSONL (one event per line).
  /// Overwrites — caller decides when to flush.
  static Future<void> persistTo(String path) async {
    final lines = events.value
        .map((e) => jsonEncode(e.toJson()))
        .join('\n');
    await File(path).writeAsString(
      lines.isEmpty ? '' : '$lines\n',
      flush: true,
    );
  }

  /// Load a previously-flushed JSONL file into the buffer.
  /// Idempotent — appends to whatever's already in memory.
  /// Capped at [maxEntries] (oldest discarded).
  ///
  /// Missing / empty / malformed files are tolerated silently;
  /// individual bad lines are skipped. The whole point of
  /// timeline persistence is to NEVER block the boot path.
  static Future<void> restoreFrom(String path) async {
    final file = File(path);
    if (!await file.exists()) return;
    final raw = await file.readAsString();
    if (raw.isEmpty) return;
    final restored = <OperationalEvent>[];
    for (final line in const LineSplitter().convert(raw)) {
      if (line.isEmpty) continue;
      try {
        final json = jsonDecode(line) as Map<String, Object?>;
        restored.add(OperationalEvent.fromJson(json));
      } catch (_) {
        // Skip — single bad line shouldn't destroy a timeline.
      }
    }
    final combined = [...restored, ...events.value];
    if (combined.length > maxEntries) {
      combined.removeRange(0, combined.length - maxEntries);
    }
    events.value = combined;
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
}

/// One operational event. Immutable. Shape frozen as part of
/// the PR2.8.D.3 operational contract — see [OperationalLog]
/// for the rules.
class OperationalEvent {
  const OperationalEvent({
    required this.timestamp,
    required this.tag,
    required this.message,
  });

  final DateTime timestamp;
  final String tag;
  final String message;

  Map<String, Object?> toJson() => {
        'ts': timestamp.toUtc().toIso8601String(),
        'tag': tag,
        'message': message,
      };

  static OperationalEvent fromJson(Map<String, Object?> json) {
    return OperationalEvent(
      timestamp: DateTime.parse(json['ts']! as String),
      tag: json['tag']! as String,
      message: json['message']! as String,
    );
  }
}

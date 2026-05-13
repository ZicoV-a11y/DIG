import 'package:flutter/material.dart';

import '../models/activity_event.dart';
import '../theme/app_theme.dart';

/// Single source of truth for rendering [ActivityEvent]s in any
/// change-log / history surface. Two helpers:
///
///   * [eventDescriptorFor] — icon + label + color for the row's
///     primary glyph.
///   * [eventDetailLineFor] — optional small grey caption that
///     surfaces signal-specific evidence (where did it move, why
///     was the supersession safe, what is the new content hash).
///
/// Adding a new [EventType] only needs one update here; both the
/// Activity Log dialog (utility rail) and the Load Operational
/// State dialog's per-state activity timeline pull from this.
/// Drift between surfaces is the smell this module exists to
/// prevent — see the AIFF-disappearance and Current/-as-authority
/// regressions for the cost of duplicated rendering pipelines.
class EventDescriptor {
  final String label;
  final IconData icon;
  final Color color;
  const EventDescriptor({
    required this.label,
    required this.icon,
    required this.color,
  });
}

EventDescriptor eventDescriptorFor(ActivityEvent event) {
  switch (event.eventType) {
    // ---------------------------------------------------------------
    // Aggregate operational-journal entries (autosave-period
    // summaries). path is null — they describe activity across many
    // tracks, not a single file.
    // ---------------------------------------------------------------
    case EventType.tracksPlayed:
      final count = _countFrom(event);
      return EventDescriptor(
        label: 'Played ${_formatNumber(count)} '
            '${count == 1 ? "track" : "tracks"}',
        icon: Icons.play_circle_filled_rounded,
        color: AppColors.accent,
      );
    case EventType.favoritesAdded:
      final count = _countFrom(event);
      return EventDescriptor(
        label: 'Added ${_formatNumber(count)} '
            '${count == 1 ? "favorite" : "favorites"}',
        icon: Icons.star_rounded,
        color: AppColors.favorite,
      );
    case EventType.scanCompleted:
      final source = event.payload['source_name'] as String?;
      return EventDescriptor(
        label: source == null
            ? 'Library scan completed'
            : 'Library scan completed — $source',
        icon: Icons.refresh_rounded,
        color: AppColors.reviewed,
      );

    // ---------------------------------------------------------------
    // Per-file lifecycle events. path is non-null; the basename
    // renders on the row beneath the label.
    // ---------------------------------------------------------------
    case EventType.removedExternal:
      return const EventDescriptor(
        label: 'File removed externally',
        icon: Icons.link_off_rounded,
        color: AppColors.favorite,
      );
    case EventType.autoMoveSameSource:
      return const EventDescriptor(
        label: 'Auto-resolved as moved (same source)',
        icon: Icons.drive_file_move_rounded,
        color: AppColors.reviewed,
      );
    case EventType.autoMoveCrossSource:
      return const EventDescriptor(
        label: 'Auto-resolved as moved (across sources)',
        icon: Icons.swap_horiz_rounded,
        color: AppColors.reviewed,
      );
    case EventType.foundElsewhere:
      return const EventDescriptor(
        label: 'Found coexisting copy elsewhere',
        icon: Icons.content_copy_rounded,
        color: AppColors.reviewed,
      );
    case EventType.purged:
      return const EventDescriptor(
        label: 'Purged from library',
        icon: Icons.delete_sweep_rounded,
        color: AppColors.textSecondary,
      );
    case EventType.manualRelink:
      return const EventDescriptor(
        label: 'Manually linked',
        icon: Icons.link_rounded,
        color: AppColors.accent,
      );
    case EventType.contentUpdatedExternal:
      return const EventDescriptor(
        label: 'Tags / content edited externally',
        icon: Icons.edit_note_rounded,
        color: AppColors.textSecondary,
      );
    case EventType.appInitiatedMove:
      return const EventDescriptor(
        label: 'Moved via app',
        icon: Icons.drive_file_move_outlined,
        color: AppColors.accent,
      );
    case EventType.appInitiatedCopy:
      return const EventDescriptor(
        label: 'Copied via app',
        icon: Icons.file_copy_rounded,
        color: AppColors.accent,
      );

    // ---------------------------------------------------------------
    // Forward-compat: a future build wrote an event_type this build
    // doesn't recognise (after a downgrade, or pre-release tooling).
    // Render with a neutral glyph so the panel keeps working.
    // ---------------------------------------------------------------
    default:
      return EventDescriptor(
        label: event.eventType,
        icon: Icons.fiber_manual_record,
        color: AppColors.textTertiary,
      );
  }
}

/// Secondary line beneath the primary label. `null` skips the
/// row entirely. Keep terse — this is the "what specifically
/// happened" line; the descriptor's label is the "what kind."
String? eventDetailLineFor(ActivityEvent event) {
  switch (event.eventType) {
    case EventType.autoMoveSameSource:
    case EventType.autoMoveCrossSource:
      final successor = event.payload['successor_path'] as String?;
      final matched = event.payload['matched_on'] as String?;
      final overlapMs = _intFrom(event.payload['overlap_ms']);
      if (successor == null) return null;
      final parts = <String>['→ ${_basename(successor)}'];
      if (matched != null) {
        parts.add('matched on $matched');
      }
      // Phase 2 temporal evidence. Negative or zero overlap is
      // the clean-succession case (successor appeared at or after
      // the missing row vanished) — no need to clutter the row.
      // Positive overlap means the two rows briefly coexisted as
      // available within the grace window; surface it so the user
      // sees *why* the system was confident to auto-resolve.
      if (overlapMs != null && overlapMs > 0) {
        parts.add('${_formatOverlap(overlapMs)} overlap');
      }
      return parts.join('  ·  ');
    case EventType.appInitiatedMove:
      final dest = event.payload['dest_path'] as String?;
      final via = event.payload['via'] as String?;
      if (dest == null) return null;
      if (via != null) {
        return '→ ${_basename(dest)}  ·  via $via';
      }
      return '→ ${_basename(dest)}';
    case EventType.appInitiatedCopy:
      final dest = event.payload['dest_path'] as String?;
      if (dest == null) return null;
      return '→ ${_basename(dest)}';
    case EventType.purged:
      final prior = event.payload['prior_state'] as String?;
      if (prior == null) return null;
      return 'prior state: $prior';
    case EventType.manualRelink:
      final linked = event.payload['linked_to'] as String?;
      if (linked == null) return null;
      return 'linked to ${_basename(linked)}';
    case EventType.contentUpdatedExternal:
      final oldHash = event.payload['old_content_hash_prefix'] as String?;
      final newHash = event.payload['new_content_hash_prefix'] as String?;
      if (oldHash == null || newHash == null) return null;
      return 'sha: $oldHash… → $newHash…';
    case EventType.foundElsewhere:
      final paths = event.payload['matching_paths'];
      if (paths is! List || paths.isEmpty) return null;
      final basenames = paths
          .whereType<String>()
          .map(_basename)
          .toList(growable: false);
      if (basenames.isEmpty) return null;
      if (basenames.length == 1) return '↔ ${basenames.first}';
      return '↔ ${basenames.first}  ·  +${basenames.length - 1} more';
    default:
      return null;
  }
}

// ---------------------------------------------------------------
// Internals
// ---------------------------------------------------------------

int _countFrom(ActivityEvent event) {
  final raw = event.payload['count'];
  return _intFrom(raw) ?? 0;
}

int? _intFrom(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return null;
}

String _formatNumber(int n) {
  // Thousands separator so "Played 1,420 tracks" reads cleanly
  // during long sessions.
  final s = n.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}

String _basename(String path) {
  for (final sep in const ['/', r'\\']) {
    final i = path.lastIndexOf(sep);
    if (i >= 0 && i < path.length - 1) return path.substring(i + 1);
  }
  return path;
}

/// Format a millisecond duration into the smallest natural unit.
/// Seeds: "300ms", "5s", "3m". Used for the within-grace overlap
/// hint on auto-move event detail lines.
String _formatOverlap(int ms) {
  if (ms < 1000) return '${ms}ms';
  final seconds = ms ~/ 1000;
  if (seconds < 60) return '${seconds}s';
  final minutes = seconds ~/ 60;
  return '${minutes}m';
}

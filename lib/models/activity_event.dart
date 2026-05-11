import 'dart:convert';

/// Canonical event-type strings stored in `events.event_type`.
/// Stable identifiers — never rename in place once a value has
/// been written to a user's DB, because old rows would become
/// orphans the UI can't classify. Add new constants, deprecate
/// old ones via migration if necessary.
///
/// One-line meanings (the UI lookup table lives in
/// `widgets/activity_log_panel.dart`):
abstract class EventType {
  /// A file that was previously available is no longer on disk
  /// and the scan found no replacement (a Removed event in the
  /// user's vocabulary). Payload: `{}`.
  static const removedExternal = 'removed_external';

  /// `markMovedSupersessions` auto-resolved a missing row by
  /// finding a same-fingerprint available row in the same
  /// source. Payload: `{"successor_path": "/path/to/new"}`.
  static const autoMoveSameSource = 'auto_move_same_source';

  /// `markCrossSourceMoves` auto-resolved a missing row by
  /// finding a unique content_hash (or fingerprint-fallback)
  /// match in a different watched source. Payload:
  /// `{"successor_path": "/path", "matched_on": "content_hash"|"fingerprint"}`.
  static const autoMoveCrossSource = 'auto_move_cross_source';

  /// A `missing` row was reclassified as "found elsewhere" — its
  /// content_hash matches at least one available row, but
  /// uniqueness fails so the system won't auto-pick a successor.
  /// Payload: `{"matching_paths": ["/a", "/b", ...]}`.
  /// Logged on first detection per (path, scan); not on every
  /// re-classification pass.
  static const foundElsewhere = 'found_elsewhere';

  /// The user explicitly purged the row via the Review dialog.
  /// Payload: `{"prior_state": "missing"|"superseded"|...}`.
  static const purged = 'purged';

  /// User manually paired two song identities via the right-click
  /// "Link with another song" action. Payload:
  /// `{"linked_to": "/path/of/sibling"}`.
  static const manualRelink = 'manual_relink';
}

/// Hydrated event row. Constructed by [LibraryRepository.loadRecentEvents]
/// for the History panel.
class ActivityEvent {
  final int id;
  final DateTime recordedAt;
  final String eventType;
  final String? path;
  final String? sourceId;
  final Map<String, Object?> payload;

  const ActivityEvent({
    required this.id,
    required this.recordedAt,
    required this.eventType,
    required this.path,
    required this.sourceId,
    required this.payload,
  });

  factory ActivityEvent.fromRow(Map<String, Object?> r) {
    final raw = r['payload'] as String?;
    Map<String, Object?> parsed;
    if (raw == null || raw.isEmpty) {
      parsed = const {};
    } else {
      try {
        final decoded = jsonDecode(raw);
        parsed = decoded is Map
            ? Map<String, Object?>.from(decoded)
            : const {};
      } catch (_) {
        // Malformed JSON shouldn't crash the History panel —
        // surface as an empty payload, the type+timestamp+path
        // are still useful.
        parsed = const {};
      }
    }
    return ActivityEvent(
      id: r['id'] as int,
      recordedAt: DateTime.fromMillisecondsSinceEpoch(
        r['recorded_at'] as int,
      ),
      eventType: r['event_type'] as String,
      path: r['path'] as String?,
      sourceId: r['source_id'] as String?,
      payload: parsed,
    );
  }
}

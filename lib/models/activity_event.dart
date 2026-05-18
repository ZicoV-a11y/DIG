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

  /// App-initiated move: user picked "Move to..." in the right-
  /// click menu and the app performed the FS rename + DB update
  /// itself. Distinct from the auto-detect events because the
  /// app KNOWS the move happened — no inference required.
  /// Payload: `{"dest_path": "/new/path",
  ///            "dest_source_id": "...",
  ///            "via": "rename"|"copy_then_delete"}`.
  static const appInitiatedMove = 'app_initiated_move';

  /// App-initiated copy: user picked "Copy to..." in the right-
  /// click menu. New indexed_files row lands at dest_path,
  /// sharing intel_uid with the source so favorites/plays live
  /// at the song-identity layer rather than per-file. Payload:
  /// `{"dest_path": "/new/path", "dest_source_id": "..."}`.
  static const appInitiatedCopy = 'app_initiated_copy';

  /// The file at this path has been modified by an external
  /// process — Mp3tag/Rekordbox/Serato/Mixed In Key/etc rewrote
  /// the tags, a DAW re-rendered an in-place export, the user
  /// deliberately edited audio bytes. The system detects this
  /// when a scan upsert finds an existing row whose stored
  /// `content_hash` no longer matches the freshly-computed one
  /// (path unchanged → same row, but bytes diverged).
  ///
  /// For v1 we record one event regardless of whether only tags
  /// changed or actual audio bytes did — distinguishing the two
  /// requires audio-content hashing, which is a future refinement.
  /// What matters now: the row stays, intel survives, lifecycle
  /// continues, but the audit trail captures the mutation so the
  /// History panel can narrate it.
  ///
  /// Payload: `{"old_content_hash_prefix": "abc12345",
  ///            "new_content_hash_prefix": "def67890"}`.
  static const contentUpdatedExternal = 'content_updated_external';

  // -------------------------------------------------------------
  // Lightweight operational-journal entries — aggregate user-
  // activity summaries written at autosave boundaries. NOT full
  // event sourcing; just human-readable counts so the Load
  // Operational State dialog can answer "what happened during
  // this save period?" without parsing low-level state.
  // -------------------------------------------------------------

  /// One or more tracks were played during this save period.
  /// Aggregated at autosave time. Path is null (multi-subject).
  /// Payload: `{"count": <int>}`.
  static const tracksPlayed = 'tracks_played';

  /// One or more favorites were added during this save period
  /// (favorite flag went `false → true`). Aggregated at autosave
  /// time. Path is null (multi-subject). Toggling OFF doesn't
  /// decrement the count — direction-only.
  /// Payload: `{"count": <int>}`.
  static const favoritesAdded = 'favorites_added';

  /// A library scan finished. Single event per scan completion,
  /// not aggregated. Path is null; source attribution lives in
  /// payload.
  /// Payload: `{"source_name": "Afro:Tech:Deep"}`.
  static const scanCompleted = 'scan_completed';
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

  /// Which node originated this event. Stable values:
  /// `'desktop'` (default) and `'mobile:&lt;device_id&gt;'`. Lets the
  /// activity strip render phone-sourced events distinctly from
  /// local plays.
  final String origin;

  const ActivityEvent({
    required this.id,
    required this.recordedAt,
    required this.eventType,
    required this.path,
    required this.sourceId,
    required this.payload,
    this.origin = 'desktop',
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
      origin: (r['origin'] as String?) ?? 'desktop',
    );
  }
}

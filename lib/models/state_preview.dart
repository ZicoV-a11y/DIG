import 'activity_event.dart';

/// Lazy-loaded inspection of one [OperationalState] file, populated
/// when the user selects it in the dialog. Opening the `.library`
/// file to fetch these would be too slow at dialog-open time
/// across 20+ entries — the hybrid model is "filename + filesystem
/// stat immediate; rich DB stats + activity on selection" (per
/// `feedback_save_trust_cycle.md` /
/// `feedback_operational_state_language.md`).
///
/// The right pane of the Load Operational State dialog renders this
/// as **operational delta intelligence** — what happened in this
/// state, narrated. NOT filesystem details. The path / filesize
/// information lives elsewhere; this object is about activity.
///
/// All fields are nullable to express "preview unavailable" — for
/// example when the `.library` file is from an incompatible schema
/// version, or read-only open failed. The UI renders "—" for
/// missing scalar fields and an empty timeline for missing events.
///
/// Future extensions (resolver inspection / contribution comparison
/// / device overlays) will reuse this shape — the structure is
/// designed to scale forward, not just serve the V1 Load dialog.
class StatePreview {
  final int? trackCount;
  final int? favoriteCount;
  final int? reviewedCount;
  final int? totalPlays;
  final DateTime? lastPlayedAt;

  /// Most-recent activity events from the file's `events` table,
  /// newest first, capped at ~25 entries. Drives the right pane's
  /// timeline: "what happened in this operational reality."
  ///
  /// Null when the file doesn't have an `events` table (very old
  /// schema versions) — the UI shows "No recorded activity" rather
  /// than an error.
  final List<ActivityEvent>? recentEvents;

  /// True when the preview couldn't be loaded (file unreadable,
  /// schema mismatch on a critical query). UI shows a brief
  /// explanation rather than blank stats.
  final bool errored;

  /// Human-readable reason when [errored] is true — surfaced under
  /// the stats so the user understands the failure rather than
  /// seeing silently-blank cells.
  final String? errorMessage;

  const StatePreview({
    this.trackCount,
    this.favoriteCount,
    this.reviewedCount,
    this.totalPlays,
    this.lastPlayedAt,
    this.recentEvents,
    this.errored = false,
    this.errorMessage,
  });

  const StatePreview.failure(String message)
      : trackCount = null,
        favoriteCount = null,
        reviewedCount = null,
        totalPlays = null,
        lastPlayedAt = null,
        recentEvents = null,
        errored = true,
        errorMessage = message;
}

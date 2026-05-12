/// Lazy-loaded stats for one [OperationalState] row, populated when
/// the user selects it in the dialog. Opening the `.library` file
/// to fetch these would be too slow at dialog-open time across 20+
/// entries — the hybrid model is "filename + filesystem stat
/// immediate; rich DB stats on selection" (per
/// `feedback_save_trust_cycle.md` UI direction).
///
/// All counts are nullable to express "preview unavailable" — for
/// example when the `.library` file is from an incompatible schema
/// version, or read-only open failed. The UI renders "—" for
/// missing fields rather than failing the whole preview.
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

  /// True when the preview couldn't be loaded (file unreadable,
  /// schema mismatch, etc.). UI shows a brief explanation rather
  /// than blank stats.
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
    this.errored = false,
    this.errorMessage,
  });

  const StatePreview.failure(String message)
      : trackCount = null,
        favoriteCount = null,
        reviewedCount = null,
        totalPlays = null,
        lastPlayedAt = null,
        errored = true,
        errorMessage = message;
}

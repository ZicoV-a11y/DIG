/// Parsed identity of one `.library` save file. Pure value object —
/// no I/O. The companion service [LibrarySaveManager] handles
/// filesystem reads/writes; this just describes one file by name
/// and the moment it was captured.
///
/// Filename format (locked, do not reshape without thinking about
/// every save the user already has on disk):
///
///   {LIBRARY}__{MACHINE}__{YYYY-MMM-DD}__{HH-MMam|pm}.library
///
/// Examples:
///
///   AFRO_LIBRARY__DJMAC__2026-MAY-12__06-47PM.library
///   ZCRATE__MBP14__2026-MAY-12__02-15AM.library
///
/// Rules from the user spec:
///
///   - Double-underscore separators between fields
///   - UPPERCASE preferred for library + machine fields
///   - Month is the 3-letter ENG abbreviation (JAN/FEB/.../DEC)
///   - Time is 12-hour with AM/PM suffix, no space
///   - No spaces, no slashes, no colons — filesystem-safe everywhere
///   - Human-readable first, sortable enough chronologically
///
/// Files that don't match this format are ignored by the manager
/// (won't crash startup, just skipped during the listing pass).
class SaveSnapshot {
  final String libraryName;
  final String machineId;
  final DateTime capturedAt;
  final String filename;

  const SaveSnapshot({
    required this.libraryName,
    required this.machineId,
    required this.capturedAt,
    required this.filename,
  });

  /// Format a snapshot filename from its components. Inverse of
  /// [tryParse]. The library and machine fields are sanitised
  /// (uppercased, non-alphanumeric collapsed to underscore) so the
  /// result is always filesystem-safe regardless of what the user
  /// configured.
  static String formatFilename({
    required String libraryName,
    required String machineId,
    required DateTime capturedAt,
  }) {
    final lib = sanitiseFilesystemLabel(libraryName);
    final mach = sanitiseFilesystemLabel(machineId, emptyFallback: 'MACHINE');
    final date = _formatDate(capturedAt);
    final time = _formatTime(capturedAt);
    return '${lib}__${mach}__${date}__$time.library';
  }

  /// Parse a filename back into a [SaveSnapshot]. Returns `null` if
  /// the name doesn't match the expected format — callers must
  /// handle that (the listing pass treats unmatched files as
  /// foreign and skips them rather than failing).
  static SaveSnapshot? tryParse(String filename) {
    if (!filename.endsWith('.library')) return null;
    final stem = filename.substring(0, filename.length - '.library'.length);
    final parts = stem.split('__');
    if (parts.length != 4) return null;
    final library = parts[0];
    final machine = parts[1];
    final dateStr = parts[2];
    final timeStr = parts[3];
    final date = _tryParseDate(dateStr);
    if (date == null) return null;
    final time = _tryParseTime(timeStr);
    if (time == null) return null;
    final capturedAt = DateTime(
      date.year,
      date.month,
      date.day,
      time.$1,
      time.$2,
    );
    return SaveSnapshot(
      libraryName: library,
      machineId: machine,
      capturedAt: capturedAt,
      filename: filename,
    );
  }

  /// Collapse anything filesystem-unfriendly to underscores and
  /// uppercase. Empty input falls back to [emptyFallback] so we
  /// never emit zero-length fields, which would make any filename
  /// using this output unparseable.
  ///
  /// Public so the device-channel file builder
  /// (`LibrarySaveManager.writeDeviceChannel`) can share the exact
  /// same sanitisation rules — having two divergent label-cleaners
  /// for save-related filenames would let one path produce names
  /// the other can't round-trip.
  static String sanitiseFilesystemLabel(
    String raw, {
    String emptyFallback = 'LIBRARY',
  }) {
    final out = StringBuffer();
    for (final c in raw.runes) {
      final ch = String.fromCharCode(c);
      if (RegExp(r'[A-Za-z0-9]').hasMatch(ch)) {
        out.write(ch.toUpperCase());
      } else {
        out.write('_');
      }
    }
    final s = out.toString();
    // Collapse runs of underscores, trim edges.
    final collapsed = s
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return collapsed.isEmpty ? emptyFallback : collapsed;
  }

  static const _months = [
    'JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN',
    'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC',
  ];

  static String _formatDate(DateTime t) {
    final y = t.year.toString().padLeft(4, '0');
    final m = _months[t.month - 1];
    final d = t.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  static String _formatTime(DateTime t) {
    final hour24 = t.hour;
    final ampm = hour24 >= 12 ? 'PM' : 'AM';
    var hour12 = hour24 % 12;
    if (hour12 == 0) hour12 = 12;
    final hh = hour12.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return '$hh-$mm$ampm';
  }

  static DateTime? _tryParseDate(String s) {
    final parts = s.split('-');
    if (parts.length != 3) return null;
    final y = int.tryParse(parts[0]);
    final mIdx = _months.indexOf(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || mIdx < 0 || d == null) return null;
    if (d < 1 || d > 31) return null;
    return DateTime(y, mIdx + 1, d);
  }

  /// Returns `(hour24, minute)` or `null` if malformed.
  static (int, int)? _tryParseTime(String s) {
    if (s.length < 6) return null;
    final ampm = s.substring(s.length - 2);
    if (ampm != 'AM' && ampm != 'PM') return null;
    final body = s.substring(0, s.length - 2);
    final parts = body.split('-');
    if (parts.length != 2) return null;
    final h12 = int.tryParse(parts[0]);
    final mm = int.tryParse(parts[1]);
    if (h12 == null || mm == null) return null;
    if (h12 < 1 || h12 > 12) return null;
    if (mm < 0 || mm > 59) return null;
    var h24 = h12 % 12;
    if (ampm == 'PM') h24 += 12;
    return (h24, mm);
  }
}

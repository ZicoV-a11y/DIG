/// Camelot Wheel normalization for musical keys.
///
/// The app displays keys in Camelot only (1A–12A minor, 1B–12B major) so
/// the KEY column is visually consistent and DJ-centric regardless of
/// what notation the source metadata used. Raw strings on
/// `Track.musicalKey` and the underlying database row are never mutated;
/// this is a read-side transform applied at the display/sort/search
/// boundary.
library;

const Map<String, String> _majorToCamelot = {
  'B': '1B',
  'Cb': '1B',
  'F#': '2B',
  'Gb': '2B',
  'C#': '3B',
  'Db': '3B',
  'G#': '4B',
  'Ab': '4B',
  'D#': '5B',
  'Eb': '5B',
  'A#': '6B',
  'Bb': '6B',
  'F': '7B',
  'C': '8B',
  'G': '9B',
  'D': '10B',
  'A': '11B',
  'E': '12B',
};

const Map<String, String> _minorToCamelot = {
  'G#m': '1A',
  'Abm': '1A',
  'D#m': '2A',
  'Ebm': '2A',
  'A#m': '3A',
  'Bbm': '3A',
  'Fm': '4A',
  'Cm': '5A',
  'Gm': '6A',
  'Dm': '7A',
  'Am': '8A',
  'Em': '9A',
  'Bm': '10A',
  'F#m': '11A',
  'Gbm': '11A',
  'C#m': '12A',
  'Dbm': '12A',
};

/// Convert any supported key notation to canonical Camelot form
/// ("1A".."12A" minor, "1B".."12B" major).
///
/// Returns `null` if [raw] is null/empty or cannot be parsed.
///
/// Accepted inputs:
///   - musical: "Dm", "F#", "Bb", "A#m", "C", "F#m", with lowercase
///     variants and unicode ♯/♭. Trailing "min"/"maj" suffixes are
///     supported (e.g. "Dmin" → 7A, "Dmaj" → 10B).
///   - Camelot: "8A", "8a", " 8 b ", with whitespace tolerated.
///   - Open Key (Mixed In Key style): "Nm" → "NA", "Nd" → "NB"
///     (e.g. "7m" → 7A, "7d" → 7B). Numeric range 1–12.
String? normalizeKeyToCamelot(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;

  // 1) Compact numeric form: Camelot ("8A") or Open Key ("8m" / "8d").
  //    Whitespace between number and letter is tolerated.
  final compact = RegExp(r'^(\d{1,2})\s*([abdmABDM])$').firstMatch(trimmed);
  if (compact != null) {
    final n = int.parse(compact.group(1)!);
    if (n < 1 || n > 12) return null;
    final letter = switch (compact.group(2)!.toLowerCase()) {
      'a' || 'm' => 'A',
      'b' || 'd' => 'B',
      _ => null,
    };
    if (letter == null) return null;
    return '$n$letter';
  }

  // 2) Musical notation. Normalize unicode accidentals and strip spaces
  //    so "B ♭ m" becomes "Bbm".
  var body =
      trimmed.replaceAll('♯', '#').replaceAll('♭', 'b').replaceAll(' ', '');

  // Strip explicit min/maj suffixes first; otherwise treat trailing
  // lowercase 'm' as minor and uppercase 'M' as major (a no-op).
  bool isMinor = false;
  final lower = body.toLowerCase();
  if (lower.endsWith('min')) {
    body = body.substring(0, body.length - 3);
    isMinor = true;
  } else if (lower.endsWith('maj')) {
    body = body.substring(0, body.length - 3);
  } else if (body.endsWith('m')) {
    body = body.substring(0, body.length - 1);
    isMinor = true;
  } else if (body.endsWith('M')) {
    body = body.substring(0, body.length - 1);
  }

  if (body.isEmpty) return null;

  // Capitalize note letter; preserve accidental case ('#' / 'b').
  final root =
      body[0].toUpperCase() + (body.length > 1 ? body.substring(1) : '');
  final musicMatch = RegExp(r'^([A-G])([#b])?$').firstMatch(root);
  if (musicMatch == null) return null;
  final canonical =
      '${musicMatch.group(1)!}${musicMatch.group(2) ?? ''}';

  return isMinor
      ? _minorToCamelot['${canonical}m']
      : _majorToCamelot[canonical];
}

/// Sort index that orders keys around the harmonic wheel:
/// 1A, 1B, 2A, 2B, ..., 12A, 12B (range 0..23).
///
/// Unparseable / empty values return [unknownSortIndex] so they sort to
/// the end regardless of direction (consumers handle empty-bucket
/// flipping themselves).
int camelotSortIndex(String? raw) {
  final c = normalizeKeyToCamelot(raw);
  if (c == null) return unknownSortIndex;
  final m = RegExp(r'^(\d{1,2})([AB])$').firstMatch(c);
  if (m == null) return unknownSortIndex;
  final n = int.parse(m.group(1)!);
  return (n - 1) * 2 + (m.group(2)! == 'A' ? 0 : 1);
}

/// Sentinel used by [camelotSortIndex] for unknown / unparseable input.
const int unknownSortIndex = 1 << 20;

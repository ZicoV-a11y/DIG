/// Returns a display-ready file-format label for [filename], e.g. `"MP3"`,
/// `"AIFF"`, `"FLAC"`. Empty string when there's no usable extension.
///
/// Pure string transform — uppercases the part after the last `.`,
/// trims, and skips dotfile basenames (`.hidden` → `""`). No I/O,
/// no audio decoding, safe to call per-row at 60fps.
///
/// Special-case: `aif` is normalised to `AIFF` because both extensions
/// describe the same container and DJ libraries use them
/// interchangeably; we don't want them to appear as two separate
/// formats when grouping or filtering by format.
String fileFormatLabel(String filename) {
  final dot = filename.lastIndexOf('.');
  if (dot <= 0 || dot == filename.length - 1) return '';
  final raw = filename.substring(dot + 1).trim().toUpperCase();
  if (raw.isEmpty) return '';
  if (raw == 'AIF') return 'AIFF';
  return raw;
}

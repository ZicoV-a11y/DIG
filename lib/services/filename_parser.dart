// Heuristic parser for DJ-style audio filenames.
//
// **Strictly a presentation-layer fallback** — never persisted, never
// written into `tracks`/`indexed_files`, never treated as canonical
// truth. The only purpose is to give the UI a sortable artist/title
// pair when embedded metadata is missing or hasn't been extracted
// yet. The moment ID3/Vorbis/etc. tags are populated by
// MetadataExtractor, canonical metadata wins and these fallbacks
// are bypassed.
//
// Common patterns handled:
// - "Joey Negro - Free Bass (Dub Mix)" → artist "Joey Negro", title "Free Bass (Dub Mix)"
// - "Joey Negro – Free Bass" (en-dash) → split
// - "Joey Negro — Free Bass" (em-dash) → split
// - "01 - Joey Negro - Free Bass" / "01. Joey Negro - Free Bass" → strip the prefix, then split
//
// Patterns it intentionally doesn't try to be clever about
// (heuristics poison canonical intelligence — see architectural doc):
// - "Promo Only - Joey Negro - Free Bass" — first " - " wins, so
//   artist becomes "Promo Only". Acceptable: display-only fallback;
//   metadata extraction will override it.
// - "FREEBASS_MASTER_V2_FINAL.aiff" (no delimiter) — returns empty
//   so the caller can fall through to the raw basename.

/// Display-only key extraction from DJ filenames. Same rules as
/// [parseDjFilename]: never persisted, never authoritative — it's
/// purely a presentation fallback when ID3/Vorbis tags don't
/// contain `initialKey`. Audio analysis is explicitly **not** done
/// here.
///
/// Recognised patterns at the trailing edge of the basename:
///   - `Camelot`: `(7A)`, `[11B]`, `7A` at end after a delimiter
///   - `Standard / Open Key`: `(Bm)`, `[F#m]`, `(C)`, `(Bbm)`
///
/// Returns `null` if no usable key was detected — caller treats
/// the row as keyless.
String? parseDjKey(String filename) {
  if (filename.isEmpty) return null;
  // Strip extension.
  String base = filename;
  final dot = base.lastIndexOf('.');
  if (dot > 0) base = base.substring(0, dot);
  base = base.trim();
  if (base.isEmpty) return null;

  // Trailing `(XX)` or `[XX]` — most reliable since DJ pools and
  // tagging tools put the key in brackets at the end.
  final trailingBracket = RegExp(
    r'[\(\[](\d{1,2}[AaBb]|[A-Ga-g][#b]?[mM]?)[\)\]]\s*$',
  );
  final m1 = trailingBracket.firstMatch(base);
  if (m1 != null) return _normaliseKey(m1.group(1)!);

  // Bare trailing token after " - " or "_" (e.g. "Title - 7A").
  final trailingBare = RegExp(
    r'[\s\-_](\d{1,2}[AaBb]|[A-G][#b]?m?)$',
  );
  final m2 = trailingBare.firstMatch(base);
  if (m2 != null) return _normaliseKey(m2.group(1)!);

  return null;
}

/// Extract people-related tokens from a track for the
/// "Now Playing" contextual pivots. Order is preserved and follows
/// the priority requested by the spec:
///
///   1. Artist (or comma-/&-/feat.-separated co-artists)
///   2. Featured artist (`feat.` / `ft.` / `featuring` in the title)
///   3. Remixer / re-edit author (trailing parenthetical "(X Remix)")
///
/// Strictly token-extraction — no recommendation engine, no
/// similarity, no audio analysis. Whatever the canonical metadata
/// or filename literally says about people, surfaced as a clickable
/// pivot.
///
/// Common reduction rules:
/// - Trailing `(Original Mix)` / `(Extended Mix)` / `(Vocal Mix)`
///   etc. don't reference a person — they get dropped.
/// - `(A & B Remix)` → `[A, B]`.
/// - Artist `"X feat. Y"` → `[X, Y]`.
/// - Duplicates collapse case-insensitively, first occurrence wins.
List<String> extractPeoplePivots({
  required String artist,
  required String title,
}) {
  final names = <String>[];
  final lowerSeen = <String>{};

  void addAll(Iterable<String> ns) {
    for (var n in ns) {
      n = n.trim();
      if (n.isEmpty) continue;
      final key = n.toLowerCase();
      if (lowerSeen.contains(key)) continue;
      lowerSeen.add(key);
      names.add(n);
    }
  }

  if (artist.isNotEmpty) addAll(_splitPeople(artist));

  // Trailing `(... Remix)` / `(... Edit)` / `(... Mix)` / `(... Dub)`.
  final trailing = RegExp(r'\(([^)]+)\)\s*$').firstMatch(title);
  if (trailing != null) {
    var inner = trailing.group(1)!.trim();
    // Strip role-suffix words so `Punky Wash Remix` → `Punky Wash`.
    const roleWords = [
      'Re-Edit',
      'Re Edit',
      'Reprise',
      'Bootleg',
      'Rework',
      'Version',
      'Remix',
      'Mashup',
      'Mash-Up',
      'Dub',
      'Edit',
      'Mix',
    ];
    var stripped = false;
    for (final role in roleWords) {
      final re = RegExp(
        r'\s+' + RegExp.escape(role) + r's?\s*$',
        caseSensitive: false,
      );
      if (re.hasMatch(inner)) {
        inner = inner.replaceAll(re, '').trim();
        stripped = true;
        break;
      }
    }
    // Drop common keyless modifiers entirely. These describe the
    // version, not a person.
    const keylessModifiers = [
      'original',
      'extended',
      'radio',
      'club',
      'album',
      'vocal',
      'instrumental',
      'acapella',
      'a cappella',
      'main',
      'short',
      'long',
      'percussion',
      'percapella',
    ];
    final low = inner.toLowerCase();
    final isKeyless = keylessModifiers.any(
      (k) => low == k || low.endsWith(' $k'),
    );
    if (stripped && !isKeyless && inner.isNotEmpty) {
      addAll(_splitPeople(inner));
    }
  }

  // `feat.` / `ft.` / `featuring` mentions inside the title.
  final featRe = RegExp(
    r'(?:\bfeat\.?|\bft\.?|\bfeaturing)\s+([^()\-_]+)',
    caseSensitive: false,
  );
  for (final m in featRe.allMatches(title)) {
    addAll(_splitPeople(m.group(1)!));
  }

  return names;
}

/// Split a string of names on the common DJ-pool separators:
/// `, ` (comma), ` & ` (ampersand), ` x ` (collab), ` vs(.) `,
/// ` feat./ft./featuring ` (case-insensitive), ` with `,
/// ` presents `.
Iterable<String> _splitPeople(String s) {
  final separators = RegExp(
    r'\s*,\s*|\s+&\s+|\s+x\s+|\s+vs\.?\s+|'
    r'\s+(?:feat\.?|ft\.?|featuring|with|presents)\s+',
    caseSensitive: false,
  );
  return s.split(separators).map((p) => p.trim()).where((p) => p.isNotEmpty);
}

String _normaliseKey(String raw) {
  // Camelot: uppercase the letter (`7a` → `7A`).
  if (RegExp(r'^\d{1,2}[AaBb]$').hasMatch(raw)) return raw.toUpperCase();
  // Standard: capital pitch, optional `#`/`b`, lowercase `m`.
  // `bm` → `Bm`, `F#M` → `F#m`, `bbm` → `Bbm`.
  if (raw.length == 1) return raw.toUpperCase();
  final first = raw[0].toUpperCase();
  final rest = raw.substring(1).replaceAll('M', 'm');
  return '$first$rest';
}

class ParsedFilename {
  /// Best-guess artist, or `null` if no usable split was found.
  final String? artist;

  /// Best-guess title, or `null` if no usable split was found (in
  /// which case the caller should fall back to the raw basename).
  final String? title;

  const ParsedFilename({this.artist, this.title});

  static const empty = ParsedFilename();
}

/// Parse [filename] (with or without extension) using the priority
/// rules above. Pure / no I/O.
ParsedFilename parseDjFilename(String filename) {
  if (filename.isEmpty) return ParsedFilename.empty;

  // Strip extension.
  String base = filename;
  final dot = base.lastIndexOf('.');
  if (dot > 0) base = base.substring(0, dot);
  base = base.trim();
  if (base.isEmpty) return ParsedFilename.empty;

  // Strip a leading track-number prefix like "01 - ", "01. ", "1) ".
  // Common in DJ-pool / promo / catalogue naming. We only strip if
  // the prefix is followed by a delimiter so we don't accidentally
  // eat a numeric artist (e.g. "2pac - …").
  final numPrefix = RegExp(r'^\d{1,3}\s*[-.\):]\s+');
  final mPrefix = numPrefix.firstMatch(base);
  if (mPrefix != null) {
    base = base.substring(mPrefix.end);
  }

  // Try canonical " - " (ASCII space-hyphen-space) first; then en-dash
  // and em-dash variants common in modern stores / promos.
  for (final sep in const [' - ', ' – ', ' — ']) {
    final idx = base.indexOf(sep);
    if (idx > 0 && idx < base.length - sep.length) {
      final artist = base.substring(0, idx).trim();
      final title = base.substring(idx + sep.length).trim();
      if (artist.isNotEmpty && title.isNotEmpty) {
        return ParsedFilename(artist: artist, title: title);
      }
    }
  }

  // No usable split — caller falls back to the raw basename.
  return ParsedFilename.empty;
}

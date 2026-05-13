import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Architectural invariants — automated assertions that fail when
/// a load-bearing law gets silently violated. See
/// `docs/architecture/architectural_laws.md` for the conceptual
/// source of truth. This file is the *enforcement* layer for the
/// subset of laws that lend themselves to lexical detection.
///
/// What goes here: invariants where a regression would be silent
/// (no exception, no failing data test) but would still violate
/// architecture. The flagship case is L10 (no backup-software
/// language in user-facing copy) — there's no functional bug if a
/// future widget adopts "Restore from backup" framing, just a slow
/// collapse of the operational-state ontology into archival
/// semantics. Hard to catch in review; trivial to catch with a
/// targeted test.
///
/// What does NOT go here: data invariants enforced by SQL
/// constraints, behavioral invariants covered by integration tests,
/// invariants that depend on runtime state (use widget tests for
/// those instead).
void main() {
  group('L10 — no backup-software language in user-facing UI copy',
      () {
    // The forbidden words. Words case-insensitive on first letter
    // because user-facing copy starts with an uppercase; checking
    // the lowercase form too catches mid-sentence occurrences.
    // Reasoning per word — see feedback_operational_state_language.md:
    //
    //   * Backup / Backups — frames Saves as disaster-recovery
    //     artifacts. Saves are navigable operational states.
    //   * Restore / Restores / Restoring — frames load as recovery
    //     from corruption. The user is *switching* operational
    //     truth, not undoing damage.
    //   * Snapshot (UI strings only) — internal code may use the
    //     term for class names / debug logs (SaveSnapshot, etc.);
    //     the UI must not.
    //   * Revert / Reverts / Reverting — implies undoing a fault.
    //   * Rollback / Roll back — same archival framing.
    //
    // 'Import' is intentionally NOT in this list — it's reserved
    // for the legacy intelligence.json flow and may legitimately
    // appear in UI copy related to that surface. Tighten only if
    // the legacy flow is retired.
    const forbiddenPatterns = [
      r'\bBackup\b',
      r'\bBackups\b',
      r'\bbackup\b',
      r'\bbackups\b',
      r'\bRestore\b',
      r'\bRestores\b',
      r'\bRestoring\b',
      r'\brestore\b',
      r'\brestores\b',
      r'\brestoring\b',
      r'\bSnapshot\b',
      r'\bSnapshots\b',
      r'\bsnapshot\b',
      r'\bsnapshots\b',
      r'\bRevert\b',
      r'\bReverts\b',
      r'\bReverting\b',
      r'\brevert\b',
      r'\breverts\b',
      r'\breverting\b',
      r'\bRollback\b',
      r'\bRoll back\b',
      r'\brollback\b',
      r'\broll back\b',
    ];

    final compiled =
        forbiddenPatterns.map((p) => RegExp(p)).toList(growable: false);

    /// Strip Dart line + block comments + doc comments so we don't
    /// false-positive on architectural commentary that *discusses*
    /// the forbidden words (the L10 documentation itself, the
    /// "must NEVER use 'backup'…" line in load_state_dialog.dart,
    /// etc.). What's left after stripping is approximately the
    /// executable code surface, where string literals live.
    String stripComments(String source) {
      // Block comments first (greedy across newlines).
      var s = source.replaceAll(
        RegExp(r'/\*.*?\*/', dotAll: true),
        '',
      );
      // Line comments (everything from // to end-of-line). Doc
      // comments (///) are a subset of // so this catches them.
      s = s.replaceAll(RegExp(r'//[^\n]*'), '');
      return s;
    }

    /// Extract Dart string-literal contents (single-quote, double-
    /// quote, both ' and " variants). Raw strings (r'...' / r"...")
    /// included — they're still user-facing if used in widgets.
    /// Doesn't handle triple-quoted strings comprehensively; if a
    /// future widget uses one for user-facing copy, this test
    /// under-covers. Acceptable for V1.
    List<String> extractStringLiterals(String source) {
      final out = <String>[];
      // Match either '...' or "...", allowing escaped quotes
      // inside. Non-greedy so we don't run past the closing quote.
      // Two regexes — one per quote style — so we don't get the
      // greedy-merge problem when both appear on the same line.
      final patterns = [
        RegExp(r"'((?:[^'\\]|\\.)*)'"),
        RegExp(r'"((?:[^"\\]|\\.)*)"'),
      ];
      for (final p in patterns) {
        for (final m in p.allMatches(source)) {
          final body = m.group(1);
          if (body != null) out.add(body);
        }
      }
      return out;
    }

    /// Discover every `.dart` file under `lib/widgets/` so the test
    /// adapts when new widgets are added without manual list upkeep.
    List<File> widgetFiles() {
      final dir = Directory('lib/widgets');
      if (!dir.existsSync()) return const [];
      return dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList(growable: false);
    }

    test('lib/widgets/**.dart user-facing strings free of forbidden words',
        () {
      final files = widgetFiles();
      expect(
        files,
        isNotEmpty,
        reason: 'Could not find any widget files under lib/widgets/. '
            'Either the test is running from the wrong cwd or the '
            'widget directory moved — either way, this test would '
            'silently pass without checking anything.',
      );

      final violations = <String>[];
      for (final file in files) {
        final raw = file.readAsStringSync();
        final code = stripComments(raw);
        final strings = extractStringLiterals(code);
        for (final s in strings) {
          for (final pattern in compiled) {
            if (pattern.hasMatch(s)) {
              violations.add(
                '${file.path}: forbidden word matches '
                "'${pattern.pattern}' in string literal: \"$s\"",
              );
            }
          }
        }
      }

      expect(
        violations,
        isEmpty,
        reason: 'L10 violated. Forbidden archival-semantics words '
            'appeared in user-facing UI copy:\n'
            '  ${violations.join('\n  ')}\n\n'
            'See docs/architecture/architectural_laws.md L10 and '
            'docs/architecture/ui_philosophy.md §2 for the rule '
            'and approved alternatives.',
      );
    });

    test('the test itself stops working if the strip-comments helper '
        'misses doc comments', () {
      // Meta-test — defensive. If stripComments ever stops
      // removing doc comments, the L10 test above starts firing
      // on architectural commentary instead of real strings. This
      // canary verifies the helper does what it claims.
      const sample = '''
/// must NEVER use "backup," "restore," "snapshot,"
// inline restore mention
String? msg = 'OK';
String? alsoOk = "fine";
''';
      final stripped = stripComments(sample);
      expect(stripped.contains('backup'), isFalse);
      expect(stripped.contains('restore'), isFalse);
      expect(stripped.contains('snapshot'), isFalse);
      // Real string literals survive.
      expect(stripped.contains("'OK'"), isTrue);
      expect(stripped.contains('"fine"'), isTrue);
    });
  });
}

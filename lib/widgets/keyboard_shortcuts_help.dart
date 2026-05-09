import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

class ShortcutEntry {
  final List<String> keys;
  final String label;
  const ShortcutEntry(this.keys, this.label);
}

class ShortcutSection {
  final String title;
  final List<ShortcutEntry> entries;
  const ShortcutSection(this.title, this.entries);
}

const shortcutSections = <ShortcutSection>[
  ShortcutSection('PLAYBACK', [
    ShortcutEntry(['Space'], 'Play / Pause'),
    ShortcutEntry(['←'], 'Skip −10s'),
    ShortcutEntry(['→'], 'Skip +10s'),
    ShortcutEntry(['⇧', '←'], 'Recover / prev'),
    ShortcutEntry(['⇧', '→'], 'Next track'),
    ShortcutEntry(['S'], 'Cycle mode'),
  ]),
  ShortcutSection('NAVIGATION', [
    ShortcutEntry(['↑'], 'Select previous'),
    ShortcutEntry(['↓'], 'Select next'),
    ShortcutEntry(['Enter'], 'Play selected'),
  ]),
  ShortcutSection('REVIEW ACTIONS', [
    ShortcutEntry(['F'], 'Toggle favorite'),
    ShortcutEntry(['R'], 'Toggle reviewed'),
    ShortcutEntry(['U'], 'Unreviewed-only'),
  ]),
  ShortcutSection('SEARCH', [
    ShortcutEntry(['⌘', 'F'], 'Focus search'),
    ShortcutEntry(['Esc'], 'Clear / blur'),
  ]),
];

void showKeyboardShortcutsDialog(BuildContext context) {
  showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (_) => const _KeyboardShortcutsDialog(),
  );
}

class _KeyboardShortcutsDialog extends StatelessWidget {
  const _KeyboardShortcutsDialog();

  @override
  Widget build(BuildContext context) {
    final left = [shortcutSections[0], shortcutSections[3]];
    final right = [shortcutSections[1], shortcutSections[2]];
    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
        side: const BorderSide(color: AppColors.border),
      ),
      insetPadding: const EdgeInsets.all(40),
      child: Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape) {
            Navigator.of(context).pop();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 8, 10),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Keyboard shortcuts',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(
                        Icons.close_rounded,
                        size: 18,
                        color: AppColors.textSecondary,
                      ),
                      splashRadius: 16,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: AppColors.border),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: _ColumnView(sections: left)),
                      const SizedBox(width: 14),
                      const VerticalDivider(
                        width: 1,
                        thickness: 1,
                        color: AppColors.border,
                      ),
                      const SizedBox(width: 14),
                      Expanded(child: _ColumnView(sections: right)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ColumnView extends StatelessWidget {
  final List<ShortcutSection> sections;
  const _ColumnView({required this.sections});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < sections.length; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          _SectionView(section: sections[i]),
        ],
      ],
    );
  }
}

class _SectionView extends StatelessWidget {
  final ShortcutSection section;
  const _SectionView({required this.section});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 5),
          child: Text(
            section.title,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
        ),
        for (final entry in section.entries) _EntryRow(entry: entry),
      ],
    );
  }
}

class _EntryRow extends StatelessWidget {
  final ShortcutEntry entry;
  const _EntryRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.5),
      child: Row(
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 70),
            child: Wrap(
              spacing: 3,
              runSpacing: 3,
              children: [for (final k in entry.keys) _KeyCap(label: k)],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              entry.label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _KeyCap extends StatelessWidget {
  final String label;
  const _KeyCap({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.zero,
        border: Border.all(color: AppColors.border),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: AppColors.textPrimary,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

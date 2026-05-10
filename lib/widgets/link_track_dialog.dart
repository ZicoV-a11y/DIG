import 'package:flutter/material.dart';

import '../models/track.dart';
import '../state/library_controller.dart';
import '../theme/app_theme.dart';
import '../utils/file_format.dart';

/// Modal picker: choose a target [Track] to manually link [origin]
/// with, so the two rows bucket together even when the strict
/// 4-field matcher refuses (renamed-between-encodes, missing tags,
/// etc).
///
/// Returns the chosen target Track, or `null` if the user cancels.
Future<Track?> showLinkTrackDialog({
  required BuildContext context,
  required LibraryController controller,
  required Track origin,
}) {
  return showDialog<Track>(
    context: context,
    barrierColor: Colors.black54,
    builder: (_) => _LinkTrackDialog(controller: controller, origin: origin),
  );
}

class _LinkTrackDialog extends StatefulWidget {
  final LibraryController controller;
  final Track origin;

  const _LinkTrackDialog({
    required this.controller,
    required this.origin,
  });

  @override
  State<_LinkTrackDialog> createState() => _LinkTrackDialogState();
}

class _LinkTrackDialogState extends State<_LinkTrackDialog> {
  final TextEditingController _query = TextEditingController();
  final FocusNode _queryFocus = FocusNode();
  String _q = '';

  @override
  void initState() {
    super.initState();
    _query.addListener(() {
      final v = _query.text.toLowerCase();
      if (v != _q) setState(() => _q = v);
    });
    // Auto-focus the search field so the user can start typing
    // immediately — matches the keyboard-first principle.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queryFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _query.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  Iterable<Track> _candidates() {
    final all = widget.controller.allTracks;
    final originUid = widget.origin.uid;
    return all.where((t) {
      if (t.uid == originUid) return false;
      if (_q.isEmpty) return true;
      if (t.displayTitle.toLowerCase().contains(_q)) return true;
      if (t.displayArtist.toLowerCase().contains(_q)) return true;
      if (t.filename.toLowerCase().contains(_q)) return true;
      return false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final candidates = _candidates().take(200).toList();
    final originLabel =
        '${widget.origin.displayArtist.isEmpty ? "—" : widget.origin.displayArtist} '
        '— ${widget.origin.displayTitle}';
    return Center(
      child: Material(
        color: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: const BorderSide(color: AppColors.border),
        ),
        elevation: 10,
        child: SizedBox(
          width: 640,
          height: 520,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Link with another song',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                        letterSpacing: 0.4,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Pair "$originLabel" with another file so they '
                      'group together regardless of automatic matching.',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textTertiary,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: AppColors.border),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: TextField(
                  controller: _query,
                  focusNode: _queryFocus,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Search title, artist, or filename…',
                    hintStyle: const TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: 13,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.zero,
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.zero,
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.zero,
                      borderSide:
                          const BorderSide(color: AppColors.accent, width: 1),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                  ),
                ),
              ),
              const Divider(height: 1, color: AppColors.border),
              Expanded(
                child: candidates.isEmpty
                    ? const Center(
                        child: Text(
                          'No matches',
                          style: TextStyle(
                            color: AppColors.textTertiary,
                            fontSize: 12,
                          ),
                        ),
                      )
                    : ListView.builder(
                        itemCount: candidates.length,
                        itemBuilder: (_, i) {
                          final t = candidates[i];
                          return _CandidateRow(
                            track: t,
                            onTap: () => Navigator.of(context).pop(t),
                          );
                        },
                      ),
              ),
              const Divider(height: 1, color: AppColors.border),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.textSecondary,
                      ),
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CandidateRow extends StatelessWidget {
  final Track track;
  final VoidCallback onTap;

  const _CandidateRow({required this.track, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final fmt = fileFormatLabel(track.filename);
    final dur = _formatDuration(track.duration);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        hoverColor: AppColors.hoverRow,
        focusColor: AppColors.focusOverlay,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      track.displayTitle.isEmpty
                          ? track.filename
                          : track.displayTitle,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      track.displayArtist.isEmpty ? '—' : track.displayArtist,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 11,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(
                dur,
                style: const TextStyle(
                  color: AppColors.textTertiary,
                  fontSize: 11,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 2,
                ),
                decoration: const BoxDecoration(
                  color: AppColors.surfaceAlt,
                ),
                child: Text(
                  fmt.isEmpty ? '—' : fmt,
                  style: const TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: 10,
                    fontFeatures: [FontFeature.tabularFigures()],
                    letterSpacing: 0.4,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    if (d == Duration.zero) return '—';
    final m = d.inMinutes;
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

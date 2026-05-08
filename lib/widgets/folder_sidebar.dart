import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../state/library_controller.dart';
import '../theme/app_theme.dart';

class FolderSidebar extends StatelessWidget {
  final LibraryController controller;
  const FolderSidebar({super.key, required this.controller});

  Future<void> _pickFolder() async {
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: 'Select a music folder',
    );
    if (path == null) return;
    await controller.addWatchedFolder(path);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      color: AppColors.surface,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _SectionHeader('LIBRARY'),
              _FolderTile(
                label: 'All Tracks',
                count: controller.totalTrackCount,
                selected: controller.selectedFolderPath == null,
                icon: Icons.library_music_outlined,
                onTap: () => controller.selectFolder(null),
              ),
              const SizedBox(height: 6),
              const _SectionHeader('WATCHED FOLDERS'),
              if (controller.folders.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(14, 4, 14, 8),
                  child: Text(
                    'No folders yet.',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                )
              else
                ...controller.folders.map(
                  (f) => _FolderTile(
                    label: f.displayName,
                    count: controller.folderTrackCount(f.path),
                    selected: controller.selectedFolderPath == f.path,
                    icon: Icons.folder_outlined,
                    onTap: () => controller.selectFolder(f.path),
                    onRemove: () => controller.removeWatchedFolder(f.path),
                  ),
                ),
              const Spacer(),
              if (controller.isScanning)
                const Padding(
                  padding: EdgeInsets.fromLTRB(14, 0, 14, 6),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: AppColors.accent,
                        ),
                      ),
                      SizedBox(width: 8),
                      Text(
                        'Scanning…',
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(10),
                child: OutlinedButton.icon(
                  onPressed: controller.isScanning ? null : _pickFolder,
                  icon: const Icon(Icons.add, size: 14),
                  label: const Text('Add folder'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textSecondary,
                    side: const BorderSide(color: AppColors.border),
                    minimumSize: const Size.fromHeight(30),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    textStyle: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
      child: Text(
        label,
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

class _FolderTile extends StatefulWidget {
  final String label;
  final int count;
  final bool selected;
  final IconData icon;
  final VoidCallback onTap;
  final VoidCallback? onRemove;

  const _FolderTile({
    required this.label,
    required this.count,
    required this.selected,
    required this.icon,
    required this.onTap,
    this.onRemove,
  });

  @override
  State<_FolderTile> createState() => _FolderTileState();
}

class _FolderTileState extends State<_FolderTile> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: SizedBox(
        height: 28,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            hoverColor: AppColors.hoverRow,
            focusColor: AppColors.focusOverlay,
            child: Stack(
              children: [
                if (widget.selected)
                  Positioned.fill(
                    child: Container(color: AppColors.selectedRow),
                  ),
                if (widget.selected)
                  const Positioned(
                    left: 0,
                    top: 4,
                    bottom: 4,
                    child: SizedBox(
                      width: 2,
                      child: ColoredBox(color: AppColors.accent),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    children: [
                      Icon(
                        widget.icon,
                        size: 14,
                        color: widget.selected
                            ? AppColors.accent
                            : AppColors.textSecondary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          widget.label,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 13,
                            fontWeight: widget.selected
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                      if (_hovering && widget.onRemove != null)
                        InkWell(
                          onTap: widget.onRemove,
                          borderRadius: BorderRadius.circular(3),
                          child: const Padding(
                            padding: EdgeInsets.all(2),
                            child: Icon(
                              Icons.close_rounded,
                              size: 12,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        )
                      else
                        Text(
                          '${widget.count}',
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 11,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../state/library_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/folder_sidebar.dart';
import '../widgets/library_toolbar.dart';
import '../widgets/playback_bar.dart';
import '../widgets/track_table.dart';

class HomeScreen extends StatelessWidget {
  final LibraryController controller;
  const HomeScreen({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FolderSidebar(controller: controller),
                const VerticalDivider(width: 1, color: AppColors.border),
                Expanded(
                  child: Column(
                    children: [
                      LibraryToolbar(controller: controller),
                      const Divider(height: 1, color: AppColors.border),
                      Expanded(child: TrackTable(controller: controller)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.border),
          PlaybackBar(controller: controller),
        ],
      ),
    );
  }
}

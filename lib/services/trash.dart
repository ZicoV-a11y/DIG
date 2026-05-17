import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Thin wrapper around the macOS native trash bridge.
///
/// Calls `FileManager.trashItem` on the platform side (see
/// `macos/Runner/TrashHandler.swift`). Returns `true` when the file
/// was successfully moved to the user's `~/.Trash`, `false` on any
/// failure (file missing, permission denied, channel unavailable).
///
/// Never throws — callers iterate over a batch of paths and a
/// single failure mustn't abort the rest of the deletion. The
/// caller logs and proceeds with the next path.
class TrashService {
  static const _channel = MethodChannel('app.musictracker/trash');

  static Future<bool> moveToTrash(String path) async {
    try {
      final ok = await _channel.invokeMethod<bool>(
        'moveToTrash',
        {'path': path},
      );
      return ok ?? false;
    } on PlatformException catch (e) {
      debugPrint('[trash] platform error for $path: ${e.code} ${e.message}');
      return false;
    } on MissingPluginException {
      // Channel not registered (e.g., running in a non-macOS test
      // host or before MainFlutterWindow.awakeFromNib). Tests stub
      // this via the platform-channel mock; production paths will
      // always have the channel registered.
      debugPrint('[trash] missing plugin for $path (channel not registered)');
      return false;
    } catch (e) {
      debugPrint('[trash] unexpected error for $path: $e');
      return false;
    }
  }
}

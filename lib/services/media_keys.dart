import 'package:flutter/services.dart';

/// Bridge to the macOS native MPRemoteCommandCenter / MPNowPlayingInfoCenter
/// integration. Native side: macos/Runner/MediaKeysHandler.swift.
///
/// Two directions:
/// - **Native → Dart**: media key events (Play/Pause, Next, Previous, Seek)
///   arrive as MethodCalls and fire the registered callbacks.
/// - **Dart → Native**: `updateNowPlaying` / `clearNowPlaying` push the
///   current track + playback state to the system Now Playing center
///   (Control Center, Touch Bar, lock screen).
class MediaKeysBridge {
  static const _channel = MethodChannel('app.musictracker/media');

  void Function()? onPlay;
  void Function()? onPause;
  void Function()? onTogglePlayPause;
  void Function()? onNext;
  void Function()? onPrevious;
  void Function(double seconds)? onSeek;

  MediaKeysBridge() {
    _channel.setMethodCallHandler(_handle);
  }

  Future<void> _handle(MethodCall call) async {
    switch (call.method) {
      case 'play':
        onPlay?.call();
        break;
      case 'pause':
        onPause?.call();
        break;
      case 'togglePlayPause':
        onTogglePlayPause?.call();
        break;
      case 'next':
        onNext?.call();
        break;
      case 'previous':
        onPrevious?.call();
        break;
      case 'seekTo':
        final seconds = (call.arguments as num?)?.toDouble();
        if (seconds != null) onSeek?.call(seconds);
        break;
    }
  }

  Future<void> updateNowPlaying({
    required String? title,
    required String? artist,
    required double durationSeconds,
    required double positionSeconds,
    required bool isPlaying,
  }) async {
    try {
      await _channel.invokeMethod('updateNowPlaying', {
        'title': title,
        'artist': artist,
        'duration': durationSeconds,
        'position': positionSeconds,
        'isPlaying': isPlaying,
      });
    } on PlatformException {
      // Channel not yet wired (e.g., before native handler registered).
      // Swallow — non-critical UI metadata.
    } on MissingPluginException {
      // Same — fail silently if native side isn't available.
    }
  }

  Future<void> clearNowPlaying() async {
    try {
      await _channel.invokeMethod('clearNowPlaying');
    } on PlatformException {
      // ignore
    } on MissingPluginException {
      // ignore
    }
  }
}

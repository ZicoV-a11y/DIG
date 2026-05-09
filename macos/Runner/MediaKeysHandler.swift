import Cocoa
import FlutterMacOS
import MediaPlayer

/// Native handler for macOS system media controls.
///
/// Bridges between Flutter (via MethodChannel) and the system Now Playing
/// center / remote command center:
/// - **Native → Flutter**: F-keys, Touch Bar, headset, lock-screen play
///   controls invoke the Flutter side via `channel.invokeMethod`.
/// - **Flutter → Native**: track / playback state updates from Flutter
///   are pushed into `MPNowPlayingInfoCenter`.
class MediaKeysHandler {
  private let channel: FlutterMethodChannel
  private let cc = MPRemoteCommandCenter.shared()
  private let nowPlaying = MPNowPlayingInfoCenter.default()

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "app.musictracker/media",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    registerCommands()
  }

  private func registerCommands() {
    cc.playCommand.isEnabled = true
    cc.pauseCommand.isEnabled = true
    cc.togglePlayPauseCommand.isEnabled = true
    cc.nextTrackCommand.isEnabled = true
    cc.previousTrackCommand.isEnabled = true
    cc.changePlaybackPositionCommand.isEnabled = true

    cc.playCommand.addTarget { [weak self] _ in
      self?.channel.invokeMethod("play", arguments: nil)
      return .success
    }
    cc.pauseCommand.addTarget { [weak self] _ in
      self?.channel.invokeMethod("pause", arguments: nil)
      return .success
    }
    cc.togglePlayPauseCommand.addTarget { [weak self] _ in
      self?.channel.invokeMethod("togglePlayPause", arguments: nil)
      return .success
    }
    cc.nextTrackCommand.addTarget { [weak self] _ in
      self?.channel.invokeMethod("next", arguments: nil)
      return .success
    }
    cc.previousTrackCommand.addTarget { [weak self] _ in
      self?.channel.invokeMethod("previous", arguments: nil)
      return .success
    }
    cc.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let e = event as? MPChangePlaybackPositionCommandEvent else {
        return .commandFailed
      }
      self?.channel.invokeMethod("seekTo", arguments: e.positionTime)
      return .success
    }
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "updateNowPlaying":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "ARGS", message: "expected map", details: nil))
        return
      }
      var info: [String: Any] = [:]
      if let title = args["title"] as? String, !title.isEmpty {
        info[MPMediaItemPropertyTitle] = title
      }
      if let artist = args["artist"] as? String, !artist.isEmpty {
        info[MPMediaItemPropertyArtist] = artist
      }
      if let duration = args["duration"] as? Double, duration > 0 {
        info[MPMediaItemPropertyPlaybackDuration] = duration
      }
      if let position = args["position"] as? Double, position >= 0 {
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
      }
      let isPlaying = args["isPlaying"] as? Bool ?? false
      info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
      nowPlaying.nowPlayingInfo = info
      if #available(macOS 10.12.2, *) {
        nowPlaying.playbackState = isPlaying ? .playing : .paused
      }
      result(nil)
    case "clearNowPlaying":
      nowPlaying.nowPlayingInfo = nil
      if #available(macOS 10.12.2, *) {
        nowPlaying.playbackState = .stopped
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

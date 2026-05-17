import Cocoa
import FlutterMacOS

/// Native handler for moving files to the macOS Trash.
///
/// Channel name: `app.musictracker/trash`.
///
/// Methods:
///   - `moveToTrash` (args: `{ "path": String }`) →
///     returns `true` if the file was successfully moved to the Trash,
///     `false` if the move failed (file gone, permission denied, etc.).
///     Never throws to Flutter — the app's delete flow logs failures
///     per-path and continues with the rest so a single unreadable
///     file doesn't abort a multi-variant deletion.
///
/// `NSFileManager.trashItem(at:resultingItemURL:)` is the modern
/// (10.8+) API — the file lands in `~/.Trash` and is recoverable
/// from Finder. We deliberately do NOT use `removeItem` — destructive
/// deletion without a recovery path violates the crate-management
/// workflow where deletion is routine de-curation, not permanent.
class TrashHandler {
  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "app.musictracker/trash",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "moveToTrash":
      guard
        let args = call.arguments as? [String: Any],
        let path = args["path"] as? String
      else {
        result(FlutterError(
          code: "ARGS",
          message: "expected map with `path: String`",
          details: nil
        ))
        return
      }
      let url = URL(fileURLWithPath: path)
      do {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        result(true)
      } catch {
        // Soft failure — controller logs and proceeds with the
        // remaining files in the batch. We surface false rather
        // than throwing so the Dart side has a uniform `bool`
        // contract per path.
        NSLog("[trash] failed for \(path): \(error.localizedDescription)")
        result(false)
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

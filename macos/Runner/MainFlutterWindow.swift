import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  // Strong reference keeps the handler alive for the window's lifetime.
  // Without this, the MPRemoteCommandCenter target registrations would
  // be released and media keys would silently stop working.
  private var mediaKeys: MediaKeysHandler?
  // Same strong-reference rule: keep the trash channel handler alive
  // for the window's lifetime so `moveToTrash` calls don't silently
  // start returning `FlutterMethodNotImplemented` after GC.
  private var trash: TrashHandler?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // Wire macOS system media controls (F-keys, headset, lock screen,
    // Touch Bar, Control Center) through a method channel.
    self.mediaKeys = MediaKeysHandler(
      messenger: flutterViewController.engine.binaryMessenger
    )
    self.trash = TrashHandler(
      messenger: flutterViewController.engine.binaryMessenger
    )

    // Hard minimum window size. contentMinSize constrains the content area
    // (the part Flutter renders into); minSize constrains the whole window.
    // Setting both prevents the user from dragging the window into a state
    // where the table/toolbar/playback bar lose structural integrity.
    let minContent = NSSize(width: 1180, height: 600)
    self.contentMinSize = minContent
    self.minSize = NSSize(
      width: minContent.width,
      height: minContent.height + 28  // approx. title bar
    )

    // Launch frame must respect the minimum. If the storyboard / saved state
    // is smaller, expand to the minimum before the first layout pass — keeps
    // the playback bar from overflowing during the brief interval before the
    // OS clamps to minSize.
    var launchFrame = self.frame
    if launchFrame.size.width < self.minSize.width {
      launchFrame.size.width = self.minSize.width
    }
    if launchFrame.size.height < self.minSize.height {
      launchFrame.size.height = self.minSize.height
    }
    self.setFrame(launchFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}

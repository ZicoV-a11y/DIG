import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Hard minimum window size. contentMinSize constrains the content area
    // (the part Flutter renders into); minSize constrains the whole window.
    // Setting both prevents the user from dragging the window into a state
    // where the table/toolbar/playback bar lose structural integrity.
    let minContent = NSSize(width: 960, height: 540)
    self.contentMinSize = minContent
    self.minSize = NSSize(
      width: minContent.width,
      height: minContent.height + 28  // approx. title bar
    )

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}

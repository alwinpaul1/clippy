import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Hide the "clippy" window-title text (keep the traffic-light controls).
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    // Closing only hides the window (window_manager intercepts it), so keep the
    // instance alive when it does close.
    self.isReleasedWhenClosed = false

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  // Required by window_manager for correct show/hide ordering.
  override public func order(
    _ place: NSWindow.OrderingMode, relativeTo otherWin: Int
  ) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
  }
}

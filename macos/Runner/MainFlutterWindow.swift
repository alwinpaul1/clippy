import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Hide the "clippy" window-title text (keep the traffic-light controls).
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true

    // Keep the window (and thus the Flutter engine + clipboard sync) alive when
    // the user closes it — just hide it. The Dock icon reopens it.
    self.delegate = self
    self.isReleasedWhenClosed = false

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    orderOut(nil)
    return false
  }
}

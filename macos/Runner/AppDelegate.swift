import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // Keep Clippy running — and syncing — after its window is closed. The window
  // only hides (see MainFlutterWindow), so the Flutter engine stays alive.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  // Cmd+Q and Dock → Quit must NOT exit — they hide the window and keep syncing
  // in the menu bar. The ONLY real quit is the tray menu's "Quit Clippy", which
  // hard-exits from Dart (exit(0)), bypassing this handler. (Force Quit still
  // works — we only cancel the graceful path.)
  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    for window in sender.windows {
      window.orderOut(nil)
    }
    return .terminateCancel
  }

  // Clicking the Dock icon (or reopening) brings the window back.
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
      for window in sender.windows {
        window.makeKeyAndOrderFront(self)
      }
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

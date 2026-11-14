import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationDidFinishLaunching(_ notification: Notification) {
    // Keep C ABI exports referenced so dead-code stripping preserves them for dart:ffi.
    _ = atermMacosRetainedCExports.count
    super.applicationDidFinishLaunching(notification)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    if let window = mainFlutterWindow as? MainFlutterWindow, window.shouldInterceptClose {
      return false
    }
    return true
  }

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if let window = mainFlutterWindow as? MainFlutterWindow, window.shouldInterceptClose {
      window.requestGuardedClose()
      return .terminateCancel
    }
    return .terminateNow
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag, let window = mainFlutterWindow as? MainFlutterWindow {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return true
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

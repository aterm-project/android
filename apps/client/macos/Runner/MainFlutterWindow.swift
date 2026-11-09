import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var fullscreenChannel: FlutterMethodChannel?
  private var fullscreenObservers: [NSObjectProtocol] = []
  private var pendingFullscreen: FlutterResult?
  private var fullscreenEpoch = 0

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let channel = FlutterMethodChannel(
      name: "atermius/fullscreen",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    fullscreenChannel = channel
    // The owning NSWindow is captured directly; Dart cannot name another
    // window or process. Native fullscreen preserves macOS Space semantics.
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "window_closed", message: "Window is closed", details: nil))
        return
      }
      if call.method == "get" {
        result(self.styleMask.contains(.fullScreen))
      } else if call.method == "set" {
        guard let args = call.arguments as? [String: Any], let enabled = args["enabled"] as? Bool else {
          result(FlutterError(code: "invalid_arguments", message: "Expected enabled boolean", details: nil))
          return
        }
        guard self.pendingFullscreen == nil else {
          result(FlutterError(code: "fullscreen_busy", message: "Window is transitioning", details: nil))
          return
        }
        if self.styleMask.contains(.fullScreen) == enabled {
          result(enabled)
          return
        }
        self.fullscreenEpoch += 1
        let epoch = self.fullscreenEpoch
        self.pendingFullscreen = result
        self.collectionBehavior.insert(.fullScreenPrimary)
        self.toggleFullScreen(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
          guard let self = self, self.fullscreenEpoch == epoch else { return }
          self.finishFullscreenTransition()
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
      fullscreenObservers.append(NotificationCenter.default.addObserver(
        forName: name, object: self, queue: .main) { [weak self] _ in
          self?.finishFullscreenTransition()
        })
    }

    super.awakeFromNib()
  }

  private func finishFullscreenTransition() {
    let enabled = styleMask.contains(.fullScreen)
    let completion = pendingFullscreen
    pendingFullscreen = nil
    completion?(enabled)
    fullscreenChannel?.invokeMethod("changed", arguments: enabled)
  }

  deinit {
    for observer in fullscreenObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    fullscreenChannel?.setMethodCallHandler(nil)
  }
}

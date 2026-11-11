import Cocoa
import Darwin
import FlutterMacOS

private func runOnMainSync<T>(_ block: () -> T) -> T {
  if Thread.isMainThread {
    return block()
  }
  return DispatchQueue.main.sync(execute: block)
}

private func makeOwnedCString(_ text: String) -> UnsafeMutablePointer<CChar>? {
  return text.withCString { cStr in
    strdup(cStr)
  }
}

/// C ABI exports consumed via `DynamicLibrary.executable()` in `local_desktop_io.dart`.
@_cdecl("aterm_macos_free_string")
public func atermMacosFreeString(_ ptr: UnsafeMutablePointer<CChar>?) {
  if let ptr = ptr {
    free(ptr)
  }
}

@_cdecl("aterm_macos_monitor_layout")
public func atermMacosMonitorLayout() -> UnsafeMutablePointer<CChar>? {
  let jsonText: String? = runOnMainSync {
    let screens = Array(NSScreen.screens.prefix(16))
    guard let primaryHeight = screens.first?.frame.height else {
      return "[]"
    }
    var payload: [[String: Any]] = []
    payload.reserveCapacity(screens.count)
    for (index, screen) in screens.enumerated() {
      let frame = screen.frame
      let x = Int(frame.origin.x.rounded())
      let y = Int((primaryHeight - frame.maxY).rounded())
      let width = Int(frame.width.rounded())
      let height = Int(frame.height.rounded())
      payload.append([
        "x": x,
        "y": y,
        "width": width,
        "height": height,
        "primary": index == 0,
      ])
    }
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          let encoded = String(data: data, encoding: .utf8) else {
      return nil
    }
    return encoded
  }
  guard let jsonText = jsonText else { return nil }
  return makeOwnedCString(jsonText)
}

@_cdecl("aterm_macos_default_printer")
public func atermMacosDefaultPrinter() -> UnsafeMutablePointer<CChar>? {
  let printerName: String? = runOnMainSync {
    let name = NSPrintInfo.shared.printer.name.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? nil : name
  }
  guard let printerName = printerName else { return nil }
  return makeOwnedCString(printerName)
}

@_cdecl("aterm_macos_read_clipboard_files")
public func atermMacosReadClipboardFiles() -> UnsafeMutablePointer<CChar>? {
  let jsonText: String? = runOnMainSync {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [
      .urlReadingFileURLsOnly: true,
    ]
    guard let urls = NSPasteboard.general.readObjects(
      forClasses: [NSURL.self],
      options: options
    ) as? [URL] else {
      return "[]"
    }
    let paths = urls
      .filter { $0.isFileURL }
      .prefix(4096)
      .map(\.path)
      .filter { !$0.isEmpty }
    guard let data = try? JSONSerialization.data(withJSONObject: paths),
          let encoded = String(data: data, encoding: .utf8) else {
      return "[]"
    }
    return encoded
  }
  guard let jsonText = jsonText else { return nil }
  return makeOwnedCString(jsonText)
}

@_cdecl("aterm_macos_write_clipboard_files")
public func atermMacosWriteClipboardFiles(_ jsonPtr: UnsafePointer<CChar>?) -> Int32 {
  guard let jsonPtr = jsonPtr else { return 0 }
  let jsonString = String(cString: jsonPtr)
  guard let data = jsonString.data(using: .utf8),
        let rawList = try? JSONSerialization.jsonObject(with: data) as? [String],
        !rawList.isEmpty else {
    return 0
  }
  let fileUrls: [NSURL] = rawList.prefix(4096).compactMap { rawPath in
    guard rawPath.hasPrefix("/"), !rawPath.isEmpty else { return nil }
    return NSURL(fileURLWithPath: rawPath)
  }
  guard !fileUrls.isEmpty else { return 0 }
  return runOnMainSync {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    return pasteboard.writeObjects(fileUrls) ? 1 : 0
  }
}

/// Retains symbol references so Release dead-code stripping never removes C exports.
let atermMacosRetainedCExports: [Any] = [
  atermMacosFreeString as Any,
  atermMacosMonitorLayout as Any,
  atermMacosDefaultPrinter as Any,
  atermMacosReadClipboardFiles as Any,
  atermMacosWriteClipboardFiles as Any,
]

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private var fullscreenChannel: FlutterMethodChannel?
  private var chromeChannel: FlutterMethodChannel?
  private var geometryChannel: FlutterMethodChannel?
  private var windowObservers: [NSObjectProtocol] = []
  private var pendingFullscreen: FlutterResult?
  private var fullscreenEpoch = 0

  private var chromeEnabled = false
  private var closeGuardEnabled = false
  private var forceClosing = false

  private var savedNormalFrame: NSRect?
  private var isCoveringMonitor = false
  private var preCoverFrame: NSRect?
  private var preCoverStyleMask: NSWindow.StyleMask?
  private var preCoverPresentationOptions: NSApplication.PresentationOptions?

  /// True while Dart owns an active close guard (e.g., hidden parent keeping detached SSH/RDP child windows alive).
  var shouldInterceptClose: Bool {
    return closeGuardEnabled && !forceClosing
  }

  /// Filters out macOS LaunchServices / Cocoa flags (e.g. `-NSDocumentRevisionsDebugMode YES`, `-psn_*`)
  /// while preserving multi-window entrypoint arguments (`--new-window`, `--files-window <payload>`, etc.).
  private static func extractDartEntrypointArguments(_ rawArgs: [String]) -> [String] {
    let args = Array(rawArgs.dropFirst())
    var out: [String] = []
    var index = 0
    while index < args.count {
      let arg = args[index]
      if arg == "--files-window" {
        out.append(arg)
        if index + 1 < args.count {
          out.append(args[index + 1])
          index += 2
          continue
        }
      } else if arg == "--new-window"
        || arg.hasPrefix("--file-geometry-")
        || arg.hasPrefix("--terminal-window-")
        || arg.hasPrefix("--desktop-window-") {
        out.append(arg)
      } else if arg.hasPrefix("-") && !arg.hasPrefix("--") {
        if !arg.hasPrefix("-psn_"), index + 1 < args.count, !args[index + 1].hasPrefix("-") {
          index += 2
          continue
        }
      }
      index += 1
    }
    return out
  }

  override func awakeFromNib() {
    let project = FlutterDartProject()
    let dartArgs = Self.extractDartEntrypointArguments(CommandLine.arguments)
    if !dartArgs.isEmpty {
      project.dartEntrypointArguments = dartArgs
    }

    let flutterViewController = FlutterViewController(project: project)
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.savedNormalFrame = windowFrame
    self.delegate = self

    RegisterGeneratedPlugins(registry: flutterViewController)

    let messenger = flutterViewController.engine.binaryMessenger
    setupFullscreenChannel(messenger: messenger)
    setupWindowChromeChannel(messenger: messenger)
    setupWindowGeometryChannel(messenger: messenger)
    registerWindowObservers()

    super.awakeFromNib()
  }

  // MARK: - Fullscreen (`atermius/fullscreen`)

  private func setupFullscreenChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "atermius/fullscreen",
      binaryMessenger: messenger
    )
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
  }

  private func finishFullscreenTransition() {
    let enabled = styleMask.contains(.fullScreen)
    let completion = pendingFullscreen
    pendingFullscreen = nil
    completion?(enabled)
    fullscreenChannel?.invokeMethod("changed", arguments: enabled)
    emitChromeState()
  }

  // MARK: - Window Chrome & Close Guard (`atermius/window_chrome`)

  private func currentChromeState() -> [String: Any] {
    return [
      "enabled": chromeEnabled,
      "customFrame": false,
      "maximized": isZoomed || styleMask.contains(.fullScreen),
      "minimized": isMiniaturized,
      "focused": isKeyWindow,
    ]
  }

  private func emitChromeState() {
    guard chromeEnabled else { return }
    chromeChannel?.invokeMethod("stateChanged", arguments: currentChromeState())
  }

  func requestGuardedClose() {
    chromeChannel?.invokeMethod("closeRequested", arguments: nil)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if shouldInterceptClose {
      requestGuardedClose()
      return false
    }
    return true
  }

  private func setupWindowChromeChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "atermius/window_chrome",
      binaryMessenger: messenger
    )
    chromeChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "window_closed", message: "Window is closed", details: nil))
        return
      }
      switch call.method {
      case "enable":
        self.chromeEnabled = true
        result(self.currentChromeState())
      case "getState":
        result(self.currentChromeState())
      case "enableCloseGuard":
        let args = call.arguments as? [String: Any]
        self.closeGuardEnabled = (args?["enabled"] as? Bool) ?? false
        result(nil)
      case "hide":
        self.orderOut(nil)
        self.emitChromeState()
        result(nil)
      case "show":
        if self.isMiniaturized {
          self.deminiaturize(nil)
        }
        self.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.emitChromeState()
        result(nil)
      case "closeNow":
        self.forceClosing = true
        self.closeGuardEnabled = false
        if self.isCoveringMonitor {
          self.uncoverMonitor()
        }
        self.close()
        DispatchQueue.main.async {
          let anyVisible = NSApp.windows.contains { $0 !== self && $0.isVisible }
          if !anyVisible {
            NSApp.terminate(nil)
          }
        }
        result(nil)
      case "minimize":
        self.miniaturize(nil)
        result(nil)
      case "toggleMaximize":
        if self.styleMask.contains(.fullScreen) {
          self.toggleFullScreen(nil)
        } else {
          self.zoom(nil)
        }
        self.emitChromeState()
        result(nil)
      case "close":
        if self.shouldInterceptClose {
          self.requestGuardedClose()
        } else if self.styleMask.contains(.closable) {
          self.performClose(nil)
        } else {
          self.close()
        }
        result(nil)
      case "beginDrag":
        if let event = NSApp.currentEvent {
          self.performDrag(with: event)
        }
        result(nil)
      case "showSystemMenu":
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: - Window Geometry (`atermius/window_geometry`)

  private static func primaryScreenHeight() -> CGFloat {
    return NSScreen.screens.first?.frame.height ?? 0
  }

  private static func toTopLeftRect(_ nsRect: NSRect) -> [String: Int] {
    let primaryHeight = primaryScreenHeight()
    return [
      "x": Int(nsRect.origin.x.rounded()),
      "y": Int((primaryHeight - nsRect.maxY).rounded()),
      "width": Int(nsRect.width.rounded()),
      "height": Int(nsRect.height.rounded()),
    ]
  }

  private static func fromTopLeftRect(x: Int, y: Int, width: Int, height: Int) -> NSRect {
    let primaryHeight = primaryScreenHeight()
    let nsY = primaryHeight - CGFloat(y) - CGFloat(height)
    return NSRect(x: CGFloat(x), y: nsY, width: CGFloat(width), height: CGFloat(height))
  }

  private static func parseRectArguments(_ raw: Any?) -> NSRect? {
    guard let map = raw as? [String: Any],
          let x = map["x"] as? Int,
          let y = map["y"] as? Int,
          let width = map["width"] as? Int,
          let height = map["height"] as? Int,
          width >= 120,
          height >= 90 else {
      return nil
    }
    return fromTopLeftRect(x: x, y: y, width: width, height: height)
  }

  private func updateNormalFrameIfNeeded() {
    if !isZoomed && !isMiniaturized && !styleMask.contains(.fullScreen) && !isCoveringMonitor {
      savedNormalFrame = frame
    }
  }

  @discardableResult
  private func uncoverMonitor() -> Bool {
    guard isCoveringMonitor else { return false }
    isCoveringMonitor = false
    if let savedOptions = preCoverPresentationOptions {
      NSApp.presentationOptions = savedOptions
      preCoverPresentationOptions = nil
    }
    if let mask = preCoverStyleMask {
      styleMask = mask
      preCoverStyleMask = nil
    }
    if let restore = preCoverFrame {
      setFrame(restore, display: true)
      savedNormalFrame = restore
      preCoverFrame = nil
    }
    emitChromeState()
    return true
  }

  private func setupWindowGeometryChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "atermius/window_geometry",
      binaryMessenger: messenger
    )
    geometryChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      switch call.method {
      case "getMonitors":
        let monitors: [[String: Any]] = Array(NSScreen.screens.prefix(16)).enumerated().map { index, screen in
          return [
            "bounds": Self.toTopLeftRect(screen.frame),
            "work": Self.toTopLeftRect(screen.visibleFrame),
            "primary": index == 0,
            "dpi": Int((96.0 * screen.backingScaleFactor).rounded()),
          ]
        }
        result(monitors)
      case "getBounds":
        let normal = self.savedNormalFrame ?? self.frame
        result([
          "bounds": Self.toTopLeftRect(self.frame),
          "normal": Self.toTopLeftRect(normal),
          "maximized": self.isZoomed || self.styleMask.contains(.fullScreen),
          "minimized": self.isMiniaturized,
          "covering": self.isCoveringMonitor,
        ])
      case "setBounds":
        guard let target = Self.parseRectArguments(call.arguments) else {
          result(false)
          return
        }
        let onAnyScreen = NSScreen.screens.contains { $0.frame.intersects(target) }
        guard onAnyScreen else {
          result(false)
          return
        }
        if self.styleMask.contains(.fullScreen) {
          result(false)
          return
        }
        if self.isCoveringMonitor {
          self.uncoverMonitor()
        }
        self.setFrame(target, display: true)
        self.savedNormalFrame = target
        self.emitChromeState()
        result(true)
      case "coverMonitor":
        guard let requested = Self.parseRectArguments(call.arguments) else {
          result(false)
          return
        }
        guard let screen = NSScreen.screens.first(where: { candidate in
          abs(candidate.frame.origin.x - requested.origin.x) <= 2 &&
          abs(candidate.frame.origin.y - requested.origin.y) <= 2 &&
          abs(candidate.frame.width - requested.width) <= 2 &&
          abs(candidate.frame.height - requested.height) <= 2
        }) else {
          result(false)
          return
        }
        if self.styleMask.contains(.fullScreen) {
          result(false)
          return
        }
        if !self.isCoveringMonitor {
          self.preCoverFrame = self.savedNormalFrame ?? self.frame
          self.preCoverStyleMask = self.styleMask
          self.preCoverPresentationOptions = NSApp.presentationOptions
        }
        self.isCoveringMonitor = true
        self.styleMask = [.borderless]
        NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
        self.setFrame(screen.frame, display: true)
        self.makeKeyAndOrderFront(nil)
        self.emitChromeState()
        result(true)
      case "uncover":
        result(self.uncoverMonitor())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: - Window Observers

  private func registerWindowObservers() {
    for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
      windowObservers.append(NotificationCenter.default.addObserver(
        forName: name, object: self, queue: .main) { [weak self] _ in
          self?.finishFullscreenTransition()
        })
    }
    let stateNotifications: [Notification.Name] = [
      NSWindow.didBecomeKeyNotification,
      NSWindow.didResignKeyNotification,
      NSWindow.didMiniaturizeNotification,
      NSWindow.didDeminiaturizeNotification,
      NSWindow.didResizeNotification,
      NSWindow.didMoveNotification,
    ]
    for name in stateNotifications {
      windowObservers.append(NotificationCenter.default.addObserver(
        forName: name, object: self, queue: .main) { [weak self] _ in
          guard let self = self else { return }
          self.updateNormalFrameIfNeeded()
          self.emitChromeState()
        })
    }
  }

  deinit {
    for observer in windowObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    fullscreenChannel?.setMethodCallHandler(nil)
    chromeChannel?.setMethodCallHandler(nil)
    geometryChannel?.setMethodCallHandler(nil)
  }
}

import ApplicationServices
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

/// Carbon `kVK_*` virtual key codes (HIToolbox/Events.h) used by keyboard capture.
private enum MacVirtualKey {
  static let ansiH = 0x04 // kVK_ANSI_H
  static let ansiQ = 0x0C // kVK_ANSI_Q
  static let ansiW = 0x0D // kVK_ANSI_W
  static let ansiM = 0x2E // kVK_ANSI_M
  static let tab = 0x30 // kVK_Tab
  static let space = 0x31 // kVK_Space
  static let grave = 0x32 // kVK_ANSI_Grave
  static let escape = 0x35 // kVK_Escape
  static let leftArrow = 0x7B // kVK_LeftArrow
  static let rightArrow = 0x7C // kVK_RightArrow
  static let downArrow = 0x7D // kVK_DownArrow
  static let upArrow = 0x7E // kVK_UpArrow
}

/// CGEventTap callback of the keyboard capture mode (`atermius/keyboard_capture`).
/// The tap's run loop source is added to the main run loop, so this always runs
/// on the main thread. Returning nil swallows the event.
private func atermKeyboardCaptureTapCallback(
  _ proxy: CGEventTapProxy,
  _ type: CGEventType,
  _ event: CGEvent,
  _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let userInfo = userInfo else {
    return Unmanaged.passUnretained(event)
  }
  let window = Unmanaged<MainFlutterWindow>.fromOpaque(userInfo).takeUnretainedValue()
  let swallow = MainActor.assumeIsolated {
    window.keyboardCaptureShouldSwallow(type: type, event: event)
  }
  return swallow ? nil : Unmanaged.passUnretained(event)
}

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private var fullscreenChannel: FlutterMethodChannel?
  private var chromeChannel: FlutterMethodChannel?
  private var geometryChannel: FlutterMethodChannel?
  private var filePanelChannel: FlutterMethodChannel?
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

  private var keyboardCaptureChannel: FlutterMethodChannel?
  private var keyboardCaptureObservers: [NSObjectProtocol] = []
  private var keyboardCaptureArmed = false
  private var keyboardCaptureTap: CFMachPort?
  private var keyboardCaptureTapSource: CFRunLoopSource?
  /// Keys whose down was swallowed and forwarded to Dart, mapped to their base character.
  private var keyboardCaptureForwarded: [Int: String] = [:]
  /// Keys already released towards Dart (capture stopped mid-press) whose OS events stay
  /// swallowed until the physical key-up, so their auto-repeat never fires a local shortcut.
  private var keyboardCaptureSuppressed: Set<Int> = []
  private var keyboardCaptureSuppressDeadline: DispatchTime = .now()
  private var keyboardCaptureReconcileScheduled = false
  private var keyboardCaptureTapWasDisabled = false
  private var keyboardCaptureLastFocus: Bool?

  /// True while Dart owns an active close guard (e.g., hidden parent keeping detached SSH/RDP child windows alive).
  var shouldInterceptClose: Bool {
    return closeGuardEnabled && !forceClosing
  }

  /// Borderless monitor-covering windows (RDP monitor windows) still take keyboard
  /// focus; AppKit defaults this to false for windows without a title or resize bar.
  override var canBecomeKey: Bool {
    return true
  }

  override var canBecomeMain: Bool {
    return true
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
    self.configureUnifiedTitlebar()

    RegisterGeneratedPlugins(registry: flutterViewController)

    let messenger = flutterViewController.engine.binaryMessenger
    setupFullscreenChannel(messenger: messenger)
    setupWindowChromeChannel(messenger: messenger)
    setupWindowGeometryChannel(messenger: messenger)
    setupFilePanelChannel(messenger: messenger)
    setupKeyboardCaptureChannel(messenger: messenger)
    registerWindowObservers()
    registerKeyboardCaptureObservers()

    super.awakeFromNib()
  }

  private func configureUnifiedTitlebar() {
    guard !isCoveringMonitor else { return }
    styleMask.insert(.fullSizeContentView)
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    isMovableByWindowBackground = false
    if #available(macOS 11.0, *) {
      toolbarStyle = .unifiedCompact
    }
  }

  private func trafficLightLeadingInset() -> Double {
    if styleMask.contains(.fullScreen) || isCoveringMonitor || !styleMask.contains(.titled) {
      return 0.0
    }
    let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    var maxX: CGFloat = 0
    for type in buttons {
      if let button = standardWindowButton(type), !button.isHidden {
        maxX = max(maxX, button.frame.maxX)
      }
    }
    if maxX > 0 {
      return Double(ceil(maxX + 12.0))
    }
    return 76.0
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
    let fullscreenOrCover = styleMask.contains(.fullScreen) || isCoveringMonitor
    return [
      "enabled": chromeEnabled,
      "customFrame": false,
      "maximized": isZoomed || styleMask.contains(.fullScreen),
      "minimized": isMiniaturized,
      "focused": isKeyWindow,
      "captionHeight": fullscreenOrCover ? 36.0 : 38.0,
      "leadingInset": trafficLightLeadingInset(),
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
    configureUnifiedTitlebar()
    if let restore = preCoverFrame {
      setFrame(restore, display: true)
      savedNormalFrame = restore
      preCoverFrame = nil
    }
    emitChromeState()
    return true
  }

  // MARK: - Native File Panel (`atermius/file_panel`)

  private func setupFilePanelChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "atermius/file_panel",
      binaryMessenger: messenger
    )
    filePanelChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      guard call.method == "openFile" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let args = call.arguments as? [String: Any]
      let showsHidden = (args?["showsHiddenFiles"] as? Bool) ?? false
      let initialDir = args?["initialDirectory"] as? String

      let panel = NSOpenPanel()
      panel.canChooseFiles = true
      panel.canChooseDirectories = false
      panel.allowsMultipleSelection = false
      panel.resolvesAliases = true
      panel.showsHiddenFiles = showsHidden
      if let dirPath = initialDir, !dirPath.isEmpty {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue {
          panel.directoryURL = URL(fileURLWithPath: dirPath, isDirectory: true)
        }
      }
      if self.isVisible && !self.isMiniaturized {
        panel.beginSheetModal(for: self) { response in
          result(response == .OK ? panel.url?.path : nil)
        }
      } else {
        let response = panel.runModal()
        result(response == .OK ? panel.url?.path : nil)
      }
    }
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

  // MARK: - Keyboard Capture (`atermius/keyboard_capture`)

  // While Dart arms it (a focused remote desktop under the pointer), a session
  // CGEventTap swallows macOS-reserved shortcuts (Command+Tab, Spotlight, Mission
  // Control, Quit/Hide/Minimize/Close) before the system or the menu bar acts on
  // them and forwards the keys to Dart for the remote computer. Modifier changes
  // are never tapped, so modifiers keep reaching Flutter. Key contents only
  // travel in memory to Dart; nothing is logged or stored.

  private func keyboardCaptureTrusted() -> Bool {
    return AXIsProcessTrusted()
  }

  private func keyboardCaptureState(includeFocus: Bool) -> [String: Any] {
    var state: [String: Any] = [
      "supported": true,
      "permission": keyboardCaptureTrusted() ? "granted" : "required",
    ]
    if includeFocus {
      state["windowFocused"] = keyboardCaptureWindowFocused()
    }
    return state
  }

  private func keyboardCaptureWindowFocused() -> Bool {
    return NSApp.isActive && isKeyWindow
  }

  /// Event-time gate: armed, Atermius active, this window key and the pointer inside it.
  private func keyboardCaptureGateOpen() -> Bool {
    guard keyboardCaptureArmed, keyboardCaptureWindowFocused(), isVisible, !isMiniaturized else {
      return false
    }
    return frame.contains(NSEvent.mouseLocation)
  }

  private func setupKeyboardCaptureChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "atermius/keyboard_capture",
      binaryMessenger: messenger
    )
    keyboardCaptureChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(["supported": false, "permission": "notRequired"])
        return
      }
      switch call.method {
      case "configure":
        let args = call.arguments as? [String: Any]
        self.keyboardCaptureArmed = (args?["armed"] as? Bool) ?? false
        self.updateKeyboardCaptureTap()
        result(self.keyboardCaptureState(includeFocus: false))
      case "getState":
        result(self.keyboardCaptureState(includeFocus: true))
      case "requestPermission":
        // Literal value of kAXTrustedCheckOptionPrompt (its Swift import differs between SDKs).
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        self.updateKeyboardCaptureTap()
        result(self.keyboardCaptureState(includeFocus: false))
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func registerKeyboardCaptureObservers() {
    let center = NotificationCenter.default
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
      keyboardCaptureObservers.append(center.addObserver(
        forName: name, object: self, queue: .main) { [weak self] _ in
          self?.keyboardCaptureFocusChanged()
        })
    }
    for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
      keyboardCaptureObservers.append(center.addObserver(
        forName: name, object: nil, queue: .main) { [weak self] _ in
          self?.keyboardCaptureFocusChanged()
        })
    }
    keyboardCaptureObservers.append(center.addObserver(
      forName: NSWindow.willCloseNotification, object: self, queue: .main) { [weak self] _ in
        self?.stopKeyboardCapture()
      })
  }

  private func keyboardCaptureFocusChanged() {
    // Releases forwarded keys (when focus was lost) before Dart hears about it.
    updateKeyboardCaptureTap()
    guard let channel = keyboardCaptureChannel else { return }
    let focused = keyboardCaptureWindowFocused()
    guard keyboardCaptureLastFocus != focused else { return }
    keyboardCaptureLastFocus = focused
    channel.invokeMethod("windowFocus", arguments: ["focused": focused])
  }

  /// Creates the tap while capture can run (armed, focused, Accessibility trusted) or
  /// while early-released keys still await their physical key-up; removes it otherwise.
  private func updateKeyboardCaptureTap() {
    let active = keyboardCaptureArmed && keyboardCaptureWindowFocused() && keyboardCaptureTrusted()
    if !active {
      releaseKeyboardCaptureKeys()
    }
    if active || !keyboardCaptureSuppressed.isEmpty {
      installKeyboardCaptureTap()
    } else {
      removeKeyboardCaptureTap()
    }
  }

  private func installKeyboardCaptureTap() {
    guard keyboardCaptureTap == nil, keyboardCaptureTrusted() else { return }
    let mask = (CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue))
      | (CGEventMask(1) << CGEventMask(CGEventType.keyUp.rawValue))
    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: mask,
      callback: atermKeyboardCaptureTapCallback,
      userInfo: Unmanaged.passUnretained(self).toOpaque()
    ) else {
      return
    }
    guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
      CFMachPortInvalidate(tap)
      return
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    keyboardCaptureTap = tap
    keyboardCaptureTapSource = source
  }

  private func removeKeyboardCaptureTap() {
    if let tap = keyboardCaptureTap {
      CGEvent.tapEnable(tap: tap, enable: false)
    }
    if let source = keyboardCaptureTapSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    }
    if let tap = keyboardCaptureTap {
      CFMachPortInvalidate(tap)
    }
    keyboardCaptureTap = nil
    keyboardCaptureTapSource = nil
    keyboardCaptureTapWasDisabled = false
  }

  /// Window closing: release everything remotely and stop tapping at once.
  private func stopKeyboardCapture() {
    keyboardCaptureArmed = false
    releaseKeyboardCaptureKeys()
    keyboardCaptureSuppressed.removeAll()
    removeKeyboardCaptureTap()
  }

  private func sendKeyboardCaptureKey(down: Bool, code: Int, char: String) {
    keyboardCaptureChannel?.invokeMethod("key", arguments: [
      "platform": "macos",
      "down": down,
      "code": code,
      "scan": 0,
      "extended": false,
      "char": char,
    ])
  }

  /// Sends the up of every forwarded key; their remaining OS events stay swallowed.
  private func releaseKeyboardCaptureKeys() {
    guard !keyboardCaptureForwarded.isEmpty else { return }
    let released = keyboardCaptureForwarded
    keyboardCaptureForwarded.removeAll()
    for (code, char) in released {
      sendKeyboardCaptureKey(down: false, code: code, char: char)
      keyboardCaptureSuppressed.insert(code)
    }
    keyboardCaptureSuppressDeadline = .now() + 5
    scheduleKeyboardCaptureReconcile()
  }

  private static func keyboardCaptureKeyIsDown(_ code: Int) -> Bool {
    return CGEventSource.keyState(.hidSystemState, key: CGKeyCode(truncatingIfNeeded: code))
  }

  private func scheduleKeyboardCaptureReconcile() {
    guard !keyboardCaptureReconcileScheduled else { return }
    keyboardCaptureReconcileScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      guard let self = self else { return }
      self.keyboardCaptureReconcileScheduled = false
      self.reconcileKeyboardCaptureKeys()
    }
  }

  /// Recovers key-ups the tap never saw (it was disabled by a timeout or secure
  /// input) and ends the post-release suppression once keys are physically up.
  private func reconcileKeyboardCaptureKeys() {
    if keyboardCaptureTapWasDisabled {
      keyboardCaptureTapWasDisabled = false
      for (code, char) in keyboardCaptureForwarded where !Self.keyboardCaptureKeyIsDown(code) {
        keyboardCaptureForwarded.removeValue(forKey: code)
        sendKeyboardCaptureKey(down: false, code: code, char: char)
      }
    }
    if DispatchTime.now() >= keyboardCaptureSuppressDeadline {
      keyboardCaptureSuppressed.removeAll()
    } else {
      keyboardCaptureSuppressed = keyboardCaptureSuppressed.filter { Self.keyboardCaptureKeyIsDown($0) }
    }
    updateKeyboardCaptureTap()
    if !keyboardCaptureSuppressed.isEmpty {
      scheduleKeyboardCaptureReconcile()
    }
  }

  /// Lowercased key character; "" when there is none or it is a function key
  /// (arrows, F-keys use private-use code points).
  private static func keyboardCaptureNormalizedCharacter(_ raw: String?) -> String {
    guard let raw = raw, !raw.isEmpty else { return "" }
    if raw.unicodeScalars.contains(where: { $0.value >= 0xF700 && $0.value <= 0xF8FF }) {
      return ""
    }
    return raw.lowercased()
  }

  /// Unmodified, lowercased base character of the key in the current layout
  /// (the "char" of the `key` payload).
  private static func keyboardCaptureBaseCharacter(_ nsEvent: NSEvent?) -> String {
    guard let nsEvent = nsEvent else { return "" }
    return keyboardCaptureNormalizedCharacter(
      nsEvent.characters(byApplyingModifiers: []) ?? nsEvent.charactersIgnoringModifiers)
  }

  private static func keyboardCaptureIsPrintableASCII(_ text: String) -> Bool {
    let scalars = text.unicodeScalars
    return scalars.count == 1 && scalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F }
  }

  /// Character Command key equivalents (menus, the system) match on this key.
  /// Non-Latin layouts (Russian, Greek, ...) and "Dvorak – QWERTY ⌘" switch to a
  /// Latin key map while Command is held, so it can differ from the base character.
  private static func keyboardCaptureShortcutCharacter(_ nsEvent: NSEvent?, code: Int, base: String) -> String {
    let command = keyboardCaptureNormalizedCharacter(nsEvent?.characters(byApplyingModifiers: .command))
    for candidate in [command, base] where keyboardCaptureIsPrintableASCII(candidate) {
      return candidate
    }
    // No Latin character even with Command: match the ANSI key position, like the
    // ASCII-capable layout macOS falls back to for shortcuts. A wrong guess only
    // sends the combination to the remote computer instead of the local app.
    switch code {
    case MacVirtualKey.ansiQ:
      return "q"
    case MacVirtualKey.ansiW:
      return "w"
    case MacVirtualKey.ansiH:
      return "h"
    case MacVirtualKey.ansiM:
      return "m"
    default:
      return ""
    }
  }

  /// Shortcuts macOS or the app menu would act on instead of the remote computer.
  /// `shortcut` is the key's Command key-equivalent character.
  private static func keyboardCaptureIsReserved(code: Int, flags: CGEventFlags, shortcut: String) -> Bool {
    let command = flags.contains(.maskCommand)
    let control = flags.contains(.maskControl)
    let option = flags.contains(.maskAlternate)
    switch code {
    case MacVirtualKey.tab, MacVirtualKey.grave:
      // App switcher (Shift reverses it) and next window of the app.
      return command
    case MacVirtualKey.space:
      // Spotlight / Finder search and input source switching.
      return command || control
    case MacVirtualKey.leftArrow, MacVirtualKey.rightArrow, MacVirtualKey.downArrow, MacVirtualKey.upArrow:
      // Spaces, Mission Control and App Exposé.
      return control
    case MacVirtualKey.escape:
      // Force Quit Applications.
      return command && option
    default:
      break
    }
    guard command else { return false }
    switch shortcut {
    case "`":
      return true // Next window on layouts where ` is not on kVK_ANSI_Grave.
    case "q":
      return !control // Control+Command+Q (Lock Screen) stays local.
    case "h", "m", "w":
      return true // Hide, Minimize, Close.
    default:
      return false
    }
  }

  /// Decides, at event time and on the main thread, whether the tap swallows the
  /// event; swallowed key events are forwarded to Dart.
  fileprivate func keyboardCaptureShouldSwallow(type: CGEventType, event: CGEvent) -> Bool {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
      if let tap = keyboardCaptureTap {
        CGEvent.tapEnable(tap: tap, enable: true)
      }
      // Key-ups may have been missed while the tap was disabled.
      keyboardCaptureTapWasDisabled = true
      scheduleKeyboardCaptureReconcile()
      return false
    case .keyDown, .keyUp:
      break
    default:
      return false
    }
    let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
    if type == .keyUp {
      if let char = keyboardCaptureForwarded.removeValue(forKey: code) {
        sendKeyboardCaptureKey(down: false, code: code, char: char)
        return true
      }
      if keyboardCaptureSuppressed.remove(code) != nil {
        // The tap is removed by the next reconcile once nothing is left to drain.
        scheduleKeyboardCaptureReconcile()
        return true
      }
      return false
    }
    if keyboardCaptureSuppressed.contains(code) {
      return true
    }
    let gateOpen = keyboardCaptureGateOpen()
    if let char = keyboardCaptureForwarded[code] {
      if gateOpen {
        sendKeyboardCaptureKey(down: true, code: code, char: char) // auto-repeat
      } else {
        releaseKeyboardCaptureKeys()
      }
      return true
    }
    let flags = event.flags
    // Only a fresh press starts a capture: a key already down when capture began
    // keeps going to Flutter, so its up is never lost there.
    guard gateOpen,
          flags.contains(.maskCommand) || flags.contains(.maskControl),
          event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
      return false
    }
    let nsEvent = NSEvent(cgEvent: event)
    let char = Self.keyboardCaptureBaseCharacter(nsEvent)
    let shortcut = Self.keyboardCaptureShortcutCharacter(nsEvent, code: code, base: char)
    guard Self.keyboardCaptureIsReserved(code: code, flags: flags, shortcut: shortcut) else {
      return false
    }
    keyboardCaptureForwarded[code] = char
    sendKeyboardCaptureKey(down: true, code: code, char: char)
    return true
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
    for observer in keyboardCaptureObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    // The tap holds an unretained pointer to this window: it must never outlive it.
    if let tap = keyboardCaptureTap {
      CGEvent.tapEnable(tap: tap, enable: false)
    }
    if let source = keyboardCaptureTapSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    }
    if let tap = keyboardCaptureTap {
      CFMachPortInvalidate(tap)
    }
    fullscreenChannel?.setMethodCallHandler(nil)
    chromeChannel?.setMethodCallHandler(nil)
    geometryChannel?.setMethodCallHandler(nil)
    filePanelChannel?.setMethodCallHandler(nil)
    keyboardCaptureChannel?.setMethodCallHandler(nil)
  }
}

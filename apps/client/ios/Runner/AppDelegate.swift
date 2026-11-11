import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var sshChannel: FlutterMethodChannel?
  private var transferChannel: FlutterMethodChannel?
  private var mcpChannel: FlutterMethodChannel?
  private var externalEditChannel: FlutterMethodChannel?
  private var rdpStorageChannel: FlutterMethodChannel?

  private var sshRevision: Int = 0
  private var sshSessions: Int = 0
  private var sshBackgroundTask: UIBackgroundTaskIdentifier = .invalid

  private var transferTasks: [String: UIBackgroundTaskIdentifier] = [:]
  private var transferTimers: [String: Timer] = [:]

  private var mcpLeaseId: String?
  private var mcpBackgroundTask: UIBackgroundTaskIdentifier = .invalid

  private var lifecycleObservers: [NSObjectProtocol] = []

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    installLifecycleObservers()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    setupSshKeepaliveChannel(messenger: messenger)
    setupTransferForegroundChannel(messenger: messenger)
    setupMcpForegroundChannel(messenger: messenger)
    setupExternalEditChannel(messenger: messenger)
    setupRdpStorageChannel(messenger: messenger)
  }

  // MARK: - App Lifecycle Background Task Rotation

  private func installLifecycleObservers() {
    let center = NotificationCenter.default
    lifecycleObservers.append(
      center.addObserver(
        forName: UIApplication.didEnterBackgroundNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.handleDidEnterBackground()
      }
    )
    lifecycleObservers.append(
      center.addObserver(
        forName: UIApplication.willEnterForegroundNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.handleWillEnterForeground()
      }
    )
  }

  private func handleDidEnterBackground() {
    if sshSessions > 0 {
      acquireSshBackgroundTaskIfNeeded()
      sshRevision += 1
      sshChannel?.invokeMethod("state", arguments: [
        "revision": sshRevision,
        "active": sshBackgroundTask != .invalid,
        "starting": false,
        "notifications": false,
      ])
    }
    if let leaseId = mcpLeaseId {
      acquireMcpBackgroundTask(for: leaseId)
    }
  }

  private func handleWillEnterForeground() {
    endSshBackgroundTask()
    if sshSessions > 0 {
      sshRevision += 1
      sshChannel?.invokeMethod("state", arguments: [
        "revision": sshRevision,
        "active": true,
        "starting": false,
        "notifications": false,
      ])
    }
    endMcpBackgroundTask()
  }

  // MARK: - SSH Background Keepalive (`atermius/ssh_keepalive`)

  private func acquireSshBackgroundTaskIfNeeded() {
    guard sshBackgroundTask == .invalid else { return }
    var taskId: UIBackgroundTaskIdentifier = .invalid
    taskId = UIApplication.shared.beginBackgroundTask(withName: "com.atermius.ssh_keepalive") { [weak self] in
      guard let self = self else {
        if taskId != .invalid {
          UIApplication.shared.endBackgroundTask(taskId)
        }
        return
      }
      let expiredId = self.sshBackgroundTask != .invalid ? self.sshBackgroundTask : taskId
      self.sshBackgroundTask = .invalid
      self.sshRevision += 1
      self.sshChannel?.invokeMethod("state", arguments: [
        "revision": self.sshRevision,
        "active": false,
        "starting": false,
        "notifications": false,
        "reason": "timeout",
      ])
      if expiredId != .invalid {
        UIApplication.shared.endBackgroundTask(expiredId)
      }
    }
    sshBackgroundTask = taskId
  }

  private func endSshBackgroundTask() {
    guard sshBackgroundTask != .invalid else { return }
    let taskId = sshBackgroundTask
    sshBackgroundTask = .invalid
    UIApplication.shared.endBackgroundTask(taskId)
  }

  private func setupSshKeepaliveChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "atermius/ssh_keepalive",
      binaryMessenger: messenger
    )
    sshChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      guard call.method == "sync" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let args = call.arguments as? [String: Any]
      let sessions = max(0, (args?["sessions"] as? Int) ?? 0)
      self.sshSessions = sessions
      self.sshRevision += 1
      if sessions > 0 {
        if UIApplication.shared.applicationState != .active {
          self.acquireSshBackgroundTaskIfNeeded()
        }
        let isActive = UIApplication.shared.applicationState == .active || self.sshBackgroundTask != .invalid
        var reply: [String: Any] = [
          "revision": self.sshRevision,
          "active": isActive,
          "starting": false,
          "notifications": false,
        ]
        if !isActive {
          reply["reason"] = "timeout"
        }
        result(reply)
      } else {
        self.endSshBackgroundTask()
        result([
          "revision": self.sshRevision,
          "active": false,
          "starting": false,
          "notifications": false,
        ])
      }
    }
  }

  // MARK: - File Transfer Foreground Guard (`atermius/transfer_foreground`)

  private func releaseTransferLease(_ leaseId: String) {
    transferTimers.removeValue(forKey: leaseId)?.invalidate()
    if let taskId = transferTasks.removeValue(forKey: leaseId), taskId != .invalid {
      UIApplication.shared.endBackgroundTask(taskId)
    }
  }

  private func scheduleTransferLeaseTimeout(_ leaseId: String) {
    transferTimers[leaseId]?.invalidate()
    transferTimers[leaseId] = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
      self?.releaseTransferLease(leaseId)
    }
  }

  private func setupTransferForegroundChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "atermius/transfer_foreground",
      binaryMessenger: messenger
    )
    transferChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(false)
        return
      }
      let args = call.arguments as? [String: Any]
      guard let leaseId = args?["leaseId"] as? String, !leaseId.isEmpty, leaseId.count <= 128 else {
        result(call.method == "release" ? nil : false)
        return
      }
      switch call.method {
      case "acquire":
        self.releaseTransferLease(leaseId)
        var taskId: UIBackgroundTaskIdentifier = .invalid
        taskId = UIApplication.shared.beginBackgroundTask(withName: "com.atermius.transfer.\(leaseId)") { [weak self] in
          self?.releaseTransferLease(leaseId)
          if taskId != .invalid {
            UIApplication.shared.endBackgroundTask(taskId)
          }
        }
        self.transferTasks[leaseId] = taskId
        self.scheduleTransferLeaseTimeout(leaseId)
        result(true)
      case "renew":
        guard self.transferTasks[leaseId] != nil else {
          result(false)
          return
        }
        self.scheduleTransferLeaseTimeout(leaseId)
        result(true)
      case "release":
        self.releaseTransferLease(leaseId)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: - MCP Foreground Guard (`atermius/mcp_foreground`)

  private func acquireMcpBackgroundTask(for leaseId: String) {
    guard mcpBackgroundTask == .invalid else { return }
    var taskId: UIBackgroundTaskIdentifier = .invalid
    taskId = UIApplication.shared.beginBackgroundTask(withName: "com.atermius.mcp_foreground") { [weak self] in
      guard let self = self else {
        if taskId != .invalid {
          UIApplication.shared.endBackgroundTask(taskId)
        }
        return
      }
      let expiredId = self.mcpBackgroundTask != .invalid ? self.mcpBackgroundTask : taskId
      self.mcpBackgroundTask = .invalid
      if self.mcpLeaseId == leaseId {
        self.mcpLeaseId = nil
        self.mcpChannel?.invokeMethod("revoked", arguments: [
          "leaseId": leaseId,
          "reason": "timeout",
        ])
      }
      if expiredId != .invalid {
        UIApplication.shared.endBackgroundTask(expiredId)
      }
    }
    mcpBackgroundTask = taskId
  }

  private func endMcpBackgroundTask() {
    guard mcpBackgroundTask != .invalid else { return }
    let taskId = mcpBackgroundTask
    mcpBackgroundTask = .invalid
    UIApplication.shared.endBackgroundTask(taskId)
  }

  private func setupMcpForegroundChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "atermius/mcp_foreground",
      binaryMessenger: messenger
    )
    mcpChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      let args = call.arguments as? [String: Any]
      guard let leaseId = args?["leaseId"] as? String, !leaseId.isEmpty, leaseId.count <= 128 else {
        result(FlutterError(code: "invalid_lease", message: "Missing leaseId", details: nil))
        return
      }
      switch call.method {
      case "start":
        if let previous = self.mcpLeaseId, previous != leaseId {
          self.endMcpBackgroundTask()
          self.mcpChannel?.invokeMethod("revoked", arguments: [
            "leaseId": previous,
            "reason": "replaced",
          ])
        }
        self.mcpLeaseId = leaseId
        if UIApplication.shared.applicationState != .active {
          self.acquireMcpBackgroundTask(for: leaseId)
        }
        let active = UIApplication.shared.applicationState == .active || self.mcpBackgroundTask != .invalid
        result([
          "active": active,
          "notifications": false,
        ])
      case "stop":
        if self.mcpLeaseId == leaseId {
          self.mcpLeaseId = nil
          self.endMcpBackgroundTask()
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: - External File Open / Share Sheet (`atermius/external_edit`)

  private static func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .sorted { lhs, rhs in
        let lhsActive = lhs.activationState == .foregroundActive ? 0 : 1
        let rhsActive = rhs.activationState == .foregroundActive ? 0 : 1
        return lhsActive < rhsActive
      }
    guard let root = scenes.first?.windows.first(where: { $0.isKeyWindow })?.rootViewController
      ?? scenes.first?.windows.first?.rootViewController else {
      return nil
    }
    var current = root
    while let presented = current.presentedViewController, !presented.isBeingDismissed {
      current = presented
    }
    return current
  }

  private func setupExternalEditChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "atermius/external_edit",
      binaryMessenger: messenger
    )
    externalEditChannel = channel
    channel.setMethodCallHandler { call, result in
      guard call.method == "open" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String,
            path.hasPrefix("/"),
            FileManager.default.fileExists(atPath: path) else {
        result(FlutterError(code: "file_not_found", message: "Local copy does not exist", details: nil))
        return
      }
      guard let presenter = Self.topViewController() else {
        result(FlutterError(code: "no_presenter", message: "No active window scene", details: nil))
        return
      }
      let fileUrl = URL(fileURLWithPath: path)
      let activityController = UIActivityViewController(
        activityItems: [fileUrl],
        applicationActivities: nil
      )
      if let popover = activityController.popoverPresentationController {
        popover.sourceView = presenter.view
        popover.sourceRect = CGRect(
          x: presenter.view.bounds.midX,
          y: presenter.view.bounds.midY,
          width: 1,
          height: 1
        )
        popover.permittedArrowDirections = []
      }
      presenter.present(activityController, animated: true) {
        result(nil)
      }
    }
  }

  // MARK: - RDP Local Folder Redirection (`atermius/rdp_storage`)

  private func setupRdpStorageChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "atermius/rdp_storage",
      binaryMessenger: messenger
    )
    rdpStorageChannel = channel
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "roots":
        guard let docUrl = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
          result([])
          return
        }
        try? FileManager.default.createDirectory(at: docUrl, withIntermediateDirectories: true)
        result([
          [
            "path": docUrl.path,
            "label": "Files (Atermius)",
            "primary": true,
          ],
        ])
      case "checkAccess", "requestAccess":
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  deinit {
    for observer in lifecycleObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    endSshBackgroundTask()
    endMcpBackgroundTask()
    for leaseId in Array(transferTasks.keys) {
      releaseTransferLease(leaseId)
    }
  }
}

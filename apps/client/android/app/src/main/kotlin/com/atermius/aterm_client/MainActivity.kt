package com.atermius.aterm_client

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var fullscreenChannel: MethodChannel? = null
    private var fullscreenRequested = false
    private var savedSystemUiFlags: Int? = null
    private var transferChannel: MethodChannel? = null
    private var mcpChannel: MethodChannel? = null
    private var sshKeepaliveChannel: MethodChannel? = null
    private var frameworkRequestsBack = false
    private var leaseOwner: Any? = null
    private var resumed = false
    private var rdpStorage: RdpStorageAccess? = null
    private var externalFileOpener: ExternalFileOpener? = null
    private var keyboardCapture: KeyboardCapture? = null
    private var windowFocused = false
    private var topResumed = false

    override fun onResume() {
        super.onResume()
        resumed = true
        updateFirstWindow()
        if (fullscreenRequested) applyFullscreen(true)
        // Notification settings may have changed while the app was away
        // (e.g. in system settings); restore or downgrade MCP protection.
        McpForegroundLease.recheckNotifications(applicationContext)
        SshSessionKeepalive.recheckNotifications(applicationContext)
    }
    override fun onPause() { resumed = false; updateFirstWindow(); super.onPause() }

    override fun onTopResumedActivityChanged(isTopResumedActivity: Boolean) {
        super.onTopResumedActivityChanged(isTopResumedActivity)
        topResumed = isTopResumedActivity
        updateFirstWindow()
    }

    /**
     * Android's "first window" for remote-desktop keyboard full mapping: this
     * activity holds window focus and is resumed and, on API 29+ where split
     * screen, freeform, DeX and foldables resume several activities, also the
     * top-resumed one.
     */
    private fun firstWindow() =
        windowFocused && resumed && (Build.VERSION.SDK_INT < 29 || topResumed)

    private fun updateFirstWindow() { keyboardCapture?.focusChanged(firstWindow()) }

    // SSH session keepalive follows visibility (onStart/onStop), not focus:
    // IME, permission and picker dialogs only pause the activity.
    override fun onStart() {
        super.onStart()
        SshSessionKeepalive.visibility(applicationContext, true)
    }

    override fun onStop() {
        SshSessionKeepalive.visibility(applicationContext, false)
        super.onStop()
    }

    /**
     * Back from the root route normally finishes the activity, which destroys
     * the Flutter engine and with it every SSH transport. While SSH sessions
     * exist, move the task to the background instead (as Home would).
     */
    override fun popSystemNavigator(): Boolean {
        if (SshSessionKeepalive.hasSessions() && moveTaskToBack(true)) return true
        return super.popSystemNavigator()
    }

    /**
     * On API 33+ the framework unregisters Flutter's OnBackInvokedCallback at
     * the root route, so system Back would bypass [popSystemNavigator] and
     * finish the activity. While SSH sessions exist keep the callback
     * registered; nested routes, dialogs and the IME still get Back first and
     * the root route ends in SystemNavigator.pop -> moveTaskToBack.
     */
    override fun setFrameworkHandlesBack(frameworkHandlesBack: Boolean) {
        frameworkRequestsBack = frameworkHandlesBack
        super.setFrameworkHandlesBack(frameworkHandlesBack || SshSessionKeepalive.hasSessions())
    }

    private fun refreshBackHandling() {
        super.setFrameworkHandlesBack(frameworkRequestsBack || SshSessionKeepalive.hasSessions())
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        loadRdpEngine()
        rdpStorage = RdpStorageAccess(this, flutterEngine.dartExecutor.binaryMessenger)
        externalFileOpener = ExternalFileOpener(this, flutterEngine.dartExecutor.binaryMessenger)
        keyboardCapture = KeyboardCapture(this, flutterEngine.dartExecutor.binaryMessenger, firstWindow())
        fullscreenChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "atermius/fullscreen").also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "get" -> result.success(fullscreenRequested)
                    "set" -> {
                        val enabled = call.argument<Boolean>("enabled")
                        if (enabled == null) {
                            result.error("invalid_arguments", "Expected enabled boolean", null)
                        } else {
                            fullscreenRequested = enabled
                            applyFullscreen(enabled)
                            result.success(fullscreenRequested)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
        val owner = Any()
        leaseOwner = owner
        transferChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "atermius/transfer_foreground").also { channel ->
            channel.setMethodCallHandler { call, result ->
                val id = call.argument<String>("leaseId")
                if (id == null || !id.matches(LEASE_ID)) {
                    result.error("invalid_lease", "Invalid transfer lease", null)
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "acquire" -> {
                        val operation = call.argument<String>("operation")
                        if (!resumed || (operation != "upload" && operation != "download")) {
                            result.error("unavailable", "File transfer protection requires a visible activity", null)
                        } else TransferForegroundLeases.acquire(applicationContext, owner, id) { result.success(it) }
                    }
                    "renew" -> result.success(TransferForegroundLeases.renew(owner, id))
                    "release" -> { TransferForegroundLeases.release(owner, id); result.success(null) }
                    else -> result.notImplemented()
                }
            }
        }
        mcpChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "atermius/mcp_foreground").also { channel ->
            McpForegroundLease.register(owner, McpForegroundLease.Listener(
                revoked = { id, reason ->
                    channel.invokeMethod("revoked", mapOf("leaseId" to id, "reason" to reason))
                },
                notifications = { id, visible ->
                    channel.invokeMethod("notifications", mapOf("leaseId" to id, "visible" to visible))
                },
            ))
            channel.setMethodCallHandler { call, result ->
                val id = call.argument<String>("leaseId")
                if (id == null || !id.matches(LEASE_ID)) {
                    result.error("invalid_lease", "Invalid MCP lease", null)
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "start" -> startMcp(owner, id, call.argument<Int>("port"), result,
                        listOf("channelName", "title", "body", "stopLabel").map { call.argument<String>(it) })
                    "stop" -> { McpForegroundLease.stop(owner, id); result.success(null) }
                    else -> result.notImplemented()
                }
            }
        }
        sshKeepaliveChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "atermius/ssh_keepalive").also { channel ->
            SshSessionKeepalive.register(owner, SshSessionKeepalive.Listener(
                state = { state ->
                    refreshBackHandling()
                    channel.invokeMethod("state", state)
                    if (state["active"] == true && state["notifications"] != true) {
                        requestSshNotificationPermission()
                    }
                },
                disconnectAll = { channel.invokeMethod("disconnectAll", null) },
            ))
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "sync" -> {
                        val sessions = call.argument<Int>("sessions")
                        val texts = listOf("channelName", "title", "body", "disconnectLabel")
                            .map { call.argument<String>(it) }
                        if (sessions == null || sessions !in 0..MAX_SSH_SESSIONS ||
                            texts.any { it == null || it.isBlank() || it.length > 160 }) {
                            result.error("invalid_arguments", "Invalid SSH keepalive request", null)
                        } else {
                            val state = SshSessionKeepalive.sync(applicationContext, owner, sessions,
                                SshSessionKeepalive.Texts(texts[0]!!, texts[1]!!, texts[2]!!, texts[3]!!))
                            refreshBackHandling()
                            result.success(state)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun applyFullscreen(enabled: Boolean) {
        if (Build.VERSION.SDK_INT >= 30) {
            window.insetsController?.let { controller ->
                controller.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                if (enabled) controller.hide(WindowInsets.Type.systemBars())
                else controller.show(WindowInsets.Type.systemBars())
            }
        } else {
            if (enabled && savedSystemUiFlags == null) savedSystemUiFlags = window.decorView.systemUiVisibility
            window.decorView.systemUiVisibility = if (enabled)
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or View.SYSTEM_UI_FLAG_FULLSCREEN or
                    View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
                    View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
            else savedSystemUiFlags ?: View.SYSTEM_UI_FLAG_VISIBLE
            if (!enabled) savedSystemUiFlags = null
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        windowFocused = hasFocus
        updateFirstWindow()
        if (hasFocus && fullscreenRequested) applyFullscreen(true)
    }

    private fun startMcp(owner: Any, id: String, port: Int?, result: MethodChannel.Result, texts: List<String?>) {
        if (port == null || port !in 1..65535 || texts.any { it == null || it.isBlank() || it.length > 160 }) {
            result.error("invalid_arguments", "Invalid MCP foreground request", null)
            return
        }
        // Android forbids starting a foreground service from the background
        // (API 31+); require the user-visible activity that took the action.
        if (!resumed) {
            result.error("unavailable", "MCP background protection requires a visible activity", null)
            return
        }
        val strings = McpForegroundLease.Texts(texts[0]!!, texts[1]!!, texts[2]!!, texts[3]!!)
        McpForegroundLease.start(applicationContext, owner, id, strings) { active ->
            val visible = active && McpForegroundLease.notificationsVisible(applicationContext)
            if (active) McpForegroundLease.acknowledgedVisibility(id, visible)
            result.success(mapOf("active" to active, "notifications" to visible))
            // Without a visible notification Dart keeps MCP foreground-only.
            if (active && !visible) requestNotificationPermission()
        }
    }

    private fun requestSshNotificationPermission() {
        // Asked at most once per process, only after the SSH service actually
        // started while visible. Refusal is fine: the service still runs (it
        // is listed in Android's active apps), only the notification and its
        // Disconnect all action are hidden.
        if (sshNotificationsAsked || Build.VERSION.SDK_INT < 33 || !resumed) return
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return
        sshNotificationsAsked = true
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_SSH_NOTIFICATIONS)
    }

    private fun requestNotificationPermission() {
        // Only on the explicit MCP start; Android suppresses repeated prompts
        // after the user declines. Until notifications are visible Dart keeps
        // MCP foreground-only (revoked when the app is hidden).
        if (Build.VERSION.SDK_INT < 33 || !resumed) return
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        rdpStorage?.activityResult(requestCode)
        if (requestCode != REQUEST_NOTIFICATIONS && requestCode != REQUEST_SSH_NOTIFICATIONS) return
        McpForegroundLease.recheckNotifications(applicationContext)
        SshSessionKeepalive.recheckNotifications(applicationContext)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // Ends any capture and Samsung Meta key request with the engine (onDestroy).
        keyboardCapture?.close()
        keyboardCapture = null
        externalFileOpener?.close()
        externalFileOpener = null
        rdpStorage?.close()
        rdpStorage = null
        transferChannel?.setMethodCallHandler(null)
        transferChannel = null
        mcpChannel?.setMethodCallHandler(null)
        mcpChannel = null
        sshKeepaliveChannel?.setMethodCallHandler(null)
        sshKeepaliveChannel = null
        leaseOwner?.let {
            TransferForegroundLeases.releaseOwner(it)
            // The Dart listener dies with the engine; never keep its service.
            McpForegroundLease.releaseOwner(it)
            // So do its SSH transports: drop their holds and the service.
            SshSessionKeepalive.releaseOwner(applicationContext, it)
        }
        leaseOwner = null
        fullscreenChannel?.setMethodCallHandler(null)
        fullscreenChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        rdpStorage?.activityResult(requestCode)
    }

    companion object {
        /**
         * The embedded RDP engine (libatermius_rdp.so, driven from Dart via
         * FFI) needs WinPR's JNI_OnLoad to record the JavaVM; a dart:ffi
         * dlopen never runs it. Loading through ART does, once per process.
         * Without it the engine refuses to start and Dart reports RDP as
         * unavailable. APKs built without the engine skip this.
         */
        @Volatile private var rdpEngineLoaded = false

        @Synchronized private fun loadRdpEngine() {
            if (rdpEngineLoaded) return
            try {
                System.loadLibrary("atermius_rdp")
                rdpEngineLoaded = true
            } catch (e: UnsatisfiedLinkError) {
                // No packaged engine (or unsupported ABI): RDP stays unavailable.
            }
        }

        private val LEASE_ID = Regex("[A-Za-z0-9_-]{16,128}")
        private const val REQUEST_NOTIFICATIONS = 4108
        private const val REQUEST_SSH_NOTIFICATIONS = 4109
        private const val MAX_SSH_SESSIONS = 4096
        @Volatile private var sshNotificationsAsked = false
    }
}

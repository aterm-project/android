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
    private var leaseOwner: Any? = null
    private var resumed = false
    private var rdpStorage: RdpStorageAccess? = null
    private var externalFileOpener: ExternalFileOpener? = null

    override fun onResume() {
        super.onResume()
        resumed = true
        if (fullscreenRequested) applyFullscreen(true)
        // Notification settings may have changed while the app was away
        // (e.g. in system settings); restore or downgrade MCP protection.
        McpForegroundLease.recheckNotifications(applicationContext)
    }
    override fun onPause() { resumed = false; super.onPause() }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        loadRdpEngine()
        rdpStorage = RdpStorageAccess(this, flutterEngine.dartExecutor.binaryMessenger)
        externalFileOpener = ExternalFileOpener(this, flutterEngine.dartExecutor.binaryMessenger)
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
        if (requestCode != REQUEST_NOTIFICATIONS) return
        McpForegroundLease.recheckNotifications(applicationContext)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        externalFileOpener?.close()
        externalFileOpener = null
        rdpStorage?.close()
        rdpStorage = null
        transferChannel?.setMethodCallHandler(null)
        transferChannel = null
        mcpChannel?.setMethodCallHandler(null)
        mcpChannel = null
        leaseOwner?.let {
            TransferForegroundLeases.releaseOwner(it)
            // The Dart listener dies with the engine; never keep its service.
            McpForegroundLease.releaseOwner(it)
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
    }
}

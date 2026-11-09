package com.atermius.aterm_client

import android.Manifest
import android.app.NotificationManager
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var transferChannel: MethodChannel? = null
    private var mcpChannel: MethodChannel? = null
    private var leaseOwner: Any? = null
    private var resumed = false

    override fun onResume() { super.onResume(); resumed = true }
    override fun onPause() { resumed = false; super.onPause() }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
            val visible = active && notificationsVisible()
            result.success(mapOf("active" to active, "notifications" to visible))
            if (active && !visible) requestNotificationPermission()
        }
    }

    private fun notificationsVisible(): Boolean = try {
        getSystemService(NotificationManager::class.java).areNotificationsEnabled()
    } catch (_: RuntimeException) { false }

    private fun requestNotificationPermission() {
        // Only on the explicit MCP start; Android suppresses repeated prompts
        // after the user declines. Without it the service is still listed in
        // the system's active-apps (Task Manager) panel.
        if (Build.VERSION.SDK_INT < 33 || !resumed) return
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_NOTIFICATIONS) return
        leaseOwner?.let { McpForegroundLease.notificationsChanged(it, notificationsVisible()) }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
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
        super.cleanUpFlutterEngine(flutterEngine)
    }

    companion object {
        private val LEASE_ID = Regex("[A-Za-z0-9_-]{16,128}")
        private const val REQUEST_NOTIFICATIONS = 4108
    }
}

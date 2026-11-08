package com.atermius.aterm_client

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var transferChannel: MethodChannel? = null
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
                if (id == null || !id.matches(Regex("[A-Za-z0-9_-]{16,128}"))) {
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
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        transferChannel?.setMethodCallHandler(null)
        transferChannel = null
        leaseOwner?.let { TransferForegroundLeases.releaseOwner(it) }
        leaseOwner = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}

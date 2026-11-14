package com.atermius.aterm_client

import android.app.Activity
import android.content.ComponentName
import android.os.Build
import android.view.WindowManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.lang.reflect.Method

/**
 * Keyboard full mapping for remote-desktop sessions ("atermius/keyboard_capture").
 * Dart arms it while a remote-desktop view of this engine has keyboard focus;
 * system shortcuts are captured only while this activity is also the first
 * window ([focusChanged]: window focus, resumed and, on API 29+, top-resumed).
 *
 * Captured keys reach Flutter through the normal key dispatch, so nothing is
 * swallowed here and this channel never sends "key". Mechanisms:
 * - Android 16 QPR2 (36.1)+: WindowManager.LayoutParams#setKeyboardCaptureEnabled
 *   with the normal CAPTURE_KEYBOARD permission lets the focused window take
 *   Meta, Alt+Tab and other system shortcuts first. Home, Overview, Power and
 *   other reserved keys stay with the system; a long Escape press or leaving
 *   the app ends capture.
 * - Samsung DeX: SemWindowManager#requestMetaKeyEvent delivers the Meta key
 *   to this activity instead of the DeX start menu. Not part of the Android
 *   SDK; reflective and best effort (as in Moonlight, bVNC and AVNC).
 */
class KeyboardCapture(private val activity: Activity, messenger: BinaryMessenger, focused: Boolean) {
    private val channel = MethodChannel(messenger, "atermius/keyboard_capture")
    private var armed = false
    private var focused = focused
    private var systemShortcuts = false
    private var samsungMetaKeys = false

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "configure" -> {
                    val enabled = call.argument<Boolean>("armed")
                    if (enabled == null) {
                        result.error("invalid_arguments", "Expected armed boolean", null)
                    } else {
                        armed = enabled
                        apply()
                        result.success(state())
                    }
                }
                "getState" -> result.success(state() + ("windowFocused" to focused))
                // CAPTURE_KEYBOARD is a normal permission, granted at install.
                "requestPermission" -> result.success(state())
                else -> result.notImplemented()
            }
        }
    }

    /** The activity's first-window state changed; capture follows it at once. */
    fun focusChanged(value: Boolean) {
        if (value == focused) return
        focused = value
        apply()
        channel.invokeMethod("windowFocus", mapOf("focused" to value))
    }

    fun close() {
        channel.setMethodCallHandler(null)
        armed = false
        apply()
    }

    /**
     * Supported only where a mechanism can take system shortcuts from the OS.
     * Without one, arming still works (keys reach Flutter as before) but Meta,
     * Alt+Tab and similar shortcuts stay with the system.
     */
    private fun state() = mapOf(
        "supported" to (keyboardCaptureSetter != null || samsungMetaKeyRequest != null),
        "permission" to "notRequired",
    )

    private fun apply() {
        val capture = armed && focused
        if (capture != systemShortcuts) setSystemShortcuts(capture)
        if (capture != samsungMetaKeys) setSamsungMetaKeys(capture)
    }

    private fun setSystemShortcuts(enabled: Boolean) {
        val setter = keyboardCaptureSetter ?: return
        try {
            val window = activity.window ?: return
            val params = window.attributes
            setter.invoke(params, enabled)
            window.attributes = params
            systemShortcuts = enabled
        } catch (_: Exception) {
            // Keys still reach the session; system shortcuts stay local.
        }
    }

    private fun setSamsungMetaKeys(enabled: Boolean) {
        val (getInstance, request) = samsungMetaKeyRequest ?: return
        try {
            val manager = getInstance.invoke(null) ?: return
            request.invoke(manager, activity.componentName, enabled)
            samsungMetaKeys = enabled
        } catch (_: Throwable) {
            // OEM framework without (or with a changed) Meta key request.
        }
    }

    companion object {
        /** Build.VERSION_CODES_FULL.BAKLAVA_1 (Android 16 QPR2); compileSdk 36 predates it. */
        private const val BAKLAVA_1_FULL = 3_600_001

        /** Public SDK API since 36.1, looked up reflectively only because compileSdk is 36. */
        private val keyboardCaptureSetter: Method? by lazy {
            if (Build.VERSION.SDK_INT >= 36 && Build.VERSION.SDK_INT_FULL >= BAKLAVA_1_FULL) {
                try {
                    WindowManager.LayoutParams::class.java
                        .getMethod("setKeyboardCaptureEnabled", Boolean::class.javaPrimitiveType)
                } catch (_: Exception) {
                    null
                }
            } else null
        }

        private val samsungMetaKeyRequest: Pair<Method, Method>? by lazy {
            if (!Build.MANUFACTURER.equals("samsung", ignoreCase = true)) return@lazy null
            try {
                val manager = Class.forName("com.samsung.android.view.SemWindowManager")
                manager.getMethod("getInstance") to manager.getDeclaredMethod("requestMetaKeyEvent",
                    ComponentName::class.java, Boolean::class.javaPrimitiveType)
            } catch (_: Throwable) {
                null
            }
        }
    }
}

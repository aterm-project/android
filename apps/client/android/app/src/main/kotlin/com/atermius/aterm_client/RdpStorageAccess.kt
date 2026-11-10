package com.atermius.aterm_client

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.storage.StorageManager
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** Native RDPDR uses live filesystem paths, rather than a copied SAF cache.
 * Storage access is requested only when the user adds a mapping. The engine
 * receives only the explicitly selected roots/folders for the current host. */
class RdpStorageAccess(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "atermius/rdp_storage")
    private var pending: MethodChannel.Result? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "checkAccess" -> result.success(hasAccess())
                "requestAccess" -> request(result)
                "roots" -> {
                    if (!hasAccess()) result.error("permission", "Storage access is required", null)
                    else result.success(roots())
                }
                else -> result.notImplemented()
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun hasAccess(): Boolean = if (Build.VERSION.SDK_INT >= 30) {
        Environment.isExternalStorageManager()
    } else {
        activity.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
    }

    @Suppress("DEPRECATION")
    private fun request(result: MethodChannel.Result) {
        if (hasAccess()) { result.success(true); return }
        if (pending != null) { result.error("busy", "A storage request is already open", null); return }
        pending = result
        try {
            if (Build.VERSION.SDK_INT >= 30) {
                val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                    Uri.parse("package:${activity.packageName}"))
                if (intent.resolveActivity(activity.packageManager) != null) {
                    activity.startActivityForResult(intent, REQUEST_ACCESS)
                } else {
                    activity.startActivityForResult(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION), REQUEST_ACCESS)
                }
            } else {
                activity.requestPermissions(arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE,
                    Manifest.permission.WRITE_EXTERNAL_STORAGE), REQUEST_ACCESS)
            }
        } catch (_: Exception) {
            pending = null
            result.success(false)
        }
    }

    fun activityResult(requestCode: Int) {
        if (requestCode != REQUEST_ACCESS) return
        val result = pending
        pending = null
        result?.success(hasAccess())
    }

    @Suppress("DEPRECATION")
    private fun roots(): List<Map<String, Any>> {
        val manager = activity.getSystemService(StorageManager::class.java)
        if (Build.VERSION.SDK_INT >= 30) {
            return manager.storageVolumes.mapNotNull { volume ->
                val directory = volume.directory ?: return@mapNotNull null
                if (volume.state != Environment.MEDIA_MOUNTED || !directory.canRead()) return@mapNotNull null
                mapOf("path" to directory.absolutePath, "label" to volume.getDescription(activity), "primary" to volume.isPrimary)
            }
        }
        val paths = linkedSetOf(Environment.getExternalStorageDirectory().absolutePath)
        activity.getExternalFilesDirs(null).filterNotNull().forEach { directory ->
            paths.add(directory.absolutePath.substringBefore("/Android/"))
        }
        return paths.mapNotNull { path ->
            val directory = File(path)
            if (!directory.isDirectory || !directory.canRead()) null
            else mapOf("path" to path, "primary" to (path == Environment.getExternalStorageDirectory().absolutePath))
        }
    }

    fun close() {
        channel.setMethodCallHandler(null)
        pending?.success(false)
        pending = null
    }

    companion object { private const val REQUEST_ACCESS = 0x4153 }
}

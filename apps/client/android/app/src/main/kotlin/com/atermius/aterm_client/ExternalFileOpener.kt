package com.atermius.aterm_client

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** Only the app-owned per-file editing copies are shareable. The selected
 * editor gets a content URI, never a file URI or access to the whole disk. */
class ExternalFileOpener(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "atermius/external_edit")
    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "open") { result.notImplemented(); return@setMethodCallHandler }
            try {
                val path = call.argument<String>("path") ?: throw IllegalArgumentException()
                val root = File(activity.filesDir, "atermius-external-edit").canonicalFile
                val file = File(path).canonicalFile
                require(file.isFile && file.length() <= 16L * 1024L * 1024L)
                require(file.path.startsWith(root.path + File.separator))
                val segments = file.relativeTo(root).invariantSeparatorsPath.split('/')
                require(segments.size == 3 && segments[0].matches(UUID) && segments[1].matches(UUID))
                val uri = FileProvider.getUriForFile(activity, activity.packageName + ".externaledit", file)
                val mime = if (call.argument<Boolean>("text") == true) "text/plain" else
                    MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase()) ?: "application/octet-stream"
                val view = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime).apply {
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                    clipData = ClipData.newUri(activity.contentResolver, file.name, uri)
                }
                activity.startActivity(Intent.createChooser(view, null).apply {
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                })
                result.success(null)
            } catch (_: Exception) {
                result.error("open_failed", "Could not open the private editing copy", null)
            }
        }
    }
    fun close() { channel.setMethodCallHandler(null) }
    companion object { private val UUID = Regex("[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}") }
}

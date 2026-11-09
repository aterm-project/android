package com.atermius.aterm_client

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper

/**
 * Single in-memory lease that keeps the process in the foreground while the
 * Dart MCP listener runs. Holds only a random lease ID, the loopback port and
 * display strings: no token, host, session or policy data, and nothing is
 * persisted or restored after process death (START_NOT_STICKY).
 *
 * All methods run on the main looper (MethodChannel handlers and Service
 * callbacks), so no additional synchronisation is required.
 */
internal object McpForegroundLease {
    private const val START_TIMEOUT_MS = 10_000L

    data class Texts(val channelName: String, val title: String, val body: String, val stop: String)

    class Listener(
        val revoked: (leaseId: String, reason: String) -> Unit,
        val notifications: (leaseId: String, visible: Boolean) -> Unit,
    )

    private class Lease(
        val owner: Any,
        val id: String,
        val texts: Texts,
        var ready: ((Boolean) -> Unit)?,
        var visible: Boolean? = null,
    )

    private val handler = Handler(Looper.getMainLooper())
    private val listeners = HashMap<Any, Listener>()
    private var lease: Lease? = null
    private var service: McpForegroundService? = null

    fun register(owner: Any, listener: Listener) { listeners[owner] = listener }

    /** Engine teardown: the Dart listener is gone, so the service must go too. */
    fun releaseOwner(owner: Any) {
        listeners.remove(owner)
        val current = lease ?: return
        if (current.owner !== owner) return
        end(current, reason = null)
    }

    fun currentTexts(): Texts? = lease?.texts

    fun start(context: Context, owner: Any, id: String, texts: Texts, callback: (Boolean) -> Unit) {
        val previous = lease
        if (previous != null) {
            if (previous.id == id) { callback(false); return }
            // One MCP listener per process: a new start supersedes the old lease
            // and tells its owner to revoke the old token.
            lease = null
            previous.ready?.invoke(false)
            previous.ready = null
            listeners[previous.owner]?.revoked?.invoke(previous.id, "replaced")
        }
        val next = Lease(owner, id, texts, callback)
        lease = next
        val running = service
        if (running != null) {
            next.ready = null
            running.refresh(texts)
            callback(true)
            return
        }
        try {
            val intent = Intent(context, McpForegroundService::class.java)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent)
            else context.startService(intent)
            handler.postDelayed({
                if (lease === next && next.ready != null) end(next, reason = null)
            }, START_TIMEOUT_MS)
        } catch (_: RuntimeException) {
            // Includes ForegroundServiceStartNotAllowedException (API 31+).
            lease = null
            next.ready = null
            callback(false)
        }
    }

    fun stop(owner: Any, id: String) {
        val current = lease ?: return
        if (current.owner === owner && current.id == id) end(current, reason = null)
    }

    /**
     * Whether the MCP notification (and its Stop action) can actually be shown:
     * app notifications enabled, POST_NOTIFICATIONS granted on API 33+, and
     * the MCP channel not blocked by the user.
     */
    fun notificationsVisible(context: Context): Boolean = try {
        val manager = context.getSystemService(NotificationManager::class.java)
        val permitted = Build.VERSION.SDK_INT < 33 ||
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        val channelOpen = Build.VERSION.SDK_INT < 26 ||
            manager.getNotificationChannel(McpForegroundService.CHANNEL)?.importance !=
            NotificationManager.IMPORTANCE_NONE
        permitted && manager.areNotificationsEnabled() && channelOpen
    } catch (_: RuntimeException) { false }

    /** Visibility recorded at ACK time for the acknowledged lease. */
    fun acknowledgedVisibility(id: String, visible: Boolean) {
        val current = lease ?: return
        if (current.id == id && current.ready == null) current.visible = visible
    }

    /**
     * Re-evaluates notification visibility (permission answer, activity
     * resume, app/channel block broadcast) and reports only real changes for
     * an acknowledged lease, so Dart can downgrade to foreground-only, revoke
     * in the background, or restore protection.
     */
    fun recheckNotifications(context: Context) {
        val current = lease ?: return
        if (current.ready != null || service == null) return
        val visible = notificationsVisible(context)
        if (current.visible == visible) return
        current.visible = visible
        if (visible) service?.refresh(current.texts)
        listeners[current.owner]?.notifications?.invoke(current.id, visible)
    }

    fun started(instance: McpForegroundService) {
        val current = lease
        if (current == null) {
            if (service === instance) service = null
            instance.finish()
            return
        }
        service = instance
        val callback = current.ready
        current.ready = null
        callback?.invoke(true)
    }

    fun failedStartup(instance: McpForegroundService) {
        if (service != null && service !== instance) return
        val wasActive = service === instance
        service = null
        val current = lease ?: return
        // Pending start: report failure to the waiting caller. Active lease:
        // the visible service is gone, so Dart must revoke.
        if (current.ready != null) end(current, reason = null)
        else if (wasActive) end(current, reason = "service_destroyed")
    }

    /** Service-originated end (Stop action, task removal, OS timeout, destroy). */
    fun revoke(instance: McpForegroundService, reason: String) {
        // Only the instance that ACKed the current lease may end it; a late
        // onDestroy of a previous instance must not revoke a newer lease.
        if (service !== instance) return
        val current = lease
        if (current == null) {
            service = null
            return
        }
        end(current, reason)
    }

    private fun end(current: Lease, reason: String?) {
        if (lease !== current) return
        lease = null
        val callback = current.ready
        current.ready = null
        callback?.invoke(false)
        if (reason != null) listeners[current.owner]?.revoked?.invoke(current.id, reason)
        val ending = service
        service = null
        ending?.finish()
    }
}

/**
 * Unexported, user-visible foreground service for the local MCP listener.
 * Type `specialUse` (API 34+): no other FGS type describes a user-started
 * loopback server for an external AI client. It never restarts itself.
 */
class McpForegroundService : Service() {
    private var finishing = false
    private var blockReceiver: BroadcastReceiver? = null

    override fun onCreate() {
        super.onCreate()
        // The user can block the app's or the MCP channel's notifications from
        // system settings while Atermius is in the background. Both
        // broadcasts are sent by the system only to this package (API 28+).
        if (Build.VERSION.SDK_INT >= 28) {
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) {
                    McpForegroundLease.recheckNotifications(applicationContext)
                }
            }
            val filter = IntentFilter().apply {
                addAction(NotificationManager.ACTION_APP_BLOCK_STATE_CHANGED)
                addAction(NotificationManager.ACTION_NOTIFICATION_CHANNEL_BLOCK_STATE_CHANGED)
            }
            try {
                if (Build.VERSION.SDK_INT >= 33) {
                    registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
                } else {
                    @Suppress("UnspecifiedRegisterReceiverFlag")
                    registerReceiver(receiver, filter)
                }
                blockReceiver = receiver
            } catch (_: RuntimeException) {
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            // Notification Stop: revoke in Dart, then end the service.
            McpForegroundLease.revoke(this, "user_stop")
            finish()
            return START_NOT_STICKY
        }
        try {
            // Always promote first: startForegroundService requires it even if
            // the lease was released while the service was being created.
            promote(McpForegroundLease.currentTexts() ?: DEFAULT_TEXTS)
            if (finishing) {
                McpForegroundLease.failedStartup(this)
                finish()
            } else McpForegroundLease.started(this)
        } catch (_: RuntimeException) {
            McpForegroundLease.failedStartup(this)
            finish()
        }
        return START_NOT_STICKY
    }

    private fun promote(texts: McpForegroundLease.Texts) {
        val notification = build(texts)
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else startForeground(NOTIFICATION_ID, notification)
    }

    internal fun refresh(texts: McpForegroundLease.Texts) {
        if (finishing) return
        try {
            getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, build(texts))
        } catch (_: RuntimeException) {
        }
    }

    private fun build(texts: McpForegroundLease.Texts): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, texts.channelName, NotificationManager.IMPORTANCE_LOW))
        }
        val immutable = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        // Explicit intent to this unexported service; immutable so no other app
        // can redirect or fill it in.
        val stop = PendingIntent.getService(this, REQUEST_STOP,
            Intent(this, McpForegroundService::class.java).setAction(ACTION_STOP), immutable)
        val open = packageManager.getLaunchIntentForPackage(packageName)?.let {
            it.setPackage(packageName)
            PendingIntent.getActivity(this, REQUEST_OPEN, it, immutable)
        }
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL)
            else @Suppress("DEPRECATION") Notification.Builder(this)
        builder.setSmallIcon(android.R.drawable.stat_notify_sync_noanim)
            .setContentTitle(texts.title)
            .setContentText(texts.body)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .addAction(Notification.Action.Builder(
                Icon.createWithResource(this, android.R.drawable.ic_menu_close_clear_cancel),
                texts.stop, stop).build())
        if (open != null) builder.setContentIntent(open)
        if (Build.VERSION.SDK_INT >= 31) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }
        return builder.build()
    }

    internal fun finish() {
        finishing = true
        if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE)
        else @Suppress("DEPRECATION") stopForeground(true)
        stopSelf()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Swiping the task away ends the Flutter UI; never leave MCP running
        // without it.
        McpForegroundLease.revoke(this, "task_removed")
        finish()
        super.onTaskRemoved(rootIntent)
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        McpForegroundLease.revoke(this, "timeout")
        finish()
    }

    override fun onDestroy() {
        blockReceiver?.let { try { unregisterReceiver(it) } catch (_: RuntimeException) {} }
        blockReceiver = null
        McpForegroundLease.revoke(this, "service_destroyed")
        super.onDestroy()
    }

    companion object {
        internal const val CHANNEL = "atermius_mcp"
        private const val NOTIFICATION_ID = 4108
        private const val REQUEST_STOP = 1
        private const val REQUEST_OPEN = 2
        private const val ACTION_STOP = "com.atermius.aterm_client.action.MCP_STOP"
        private val DEFAULT_TEXTS = McpForegroundLease.Texts(
            "External AI (MCP)", "External AI access is on", "Stop to revoke access.", "Stop")
    }
}

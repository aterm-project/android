package com.atermius.aterm_client

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager

/**
 * Process-local mirror of the Dart SSH session holds (count only). While at
 * least one SSH session (connecting, open or awaiting its automatic retry)
 * exists, a `connectedDevice` foreground service keeps the process out of the
 * cached/frozen state so the Dart SSH transports and their keepalives keep
 * running in the background.
 *
 * Holds no host, user, key, credential or Vault data, persists nothing and
 * never restarts itself (START_NOT_STICKY): after process death nothing is
 * reconnected. The service is only ever first started while an activity is
 * visible (Android 12+ forbids background starts); a session that appears
 * while hidden waits for the next visible moment.
 *
 * All methods run on the main looper (MethodChannel handlers, Activity and
 * Service callbacks), so no additional synchronisation is required.
 */
internal object SshSessionKeepalive {
    private const val START_TIMEOUT_MS = 10_000L

    /** Upper bound of the CPU/Wi-Fi locks per background episode. */
    internal const val BACKGROUND_LOCK_MS = 10 * 60 * 1000L

    data class Texts(val channelName: String, val title: String, val body: String, val disconnect: String)

    class Listener(
        val state: (Map<String, Any?>) -> Unit,
        val disconnectAll: () -> Unit,
    )

    private val handler = Handler(Looper.getMainLooper())
    private val sessions = HashMap<Any, Int>()
    private val listeners = HashMap<Any, Listener>()
    private var texts: Texts? = null
    private var visible = false
    private var service: SshSessionService? = null
    private var pendingStart: Runnable? = null
    private var reason: String? = null
    private var notificationsVisible = false
    private var userStopped = false
    private var revision = 0L
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    fun hasSessions(): Boolean = sessions.values.any { it > 0 }

    fun currentTexts(): Texts? = texts

    fun register(owner: Any, listener: Listener) { listeners[owner] = listener }

    /** Engine teardown: its Dart sessions are gone, so are its holds. */
    fun releaseOwner(context: Context, owner: Any) {
        listeners.remove(owner)
        if (sessions.remove(owner) != null) reconcile(context)
    }

    fun sync(context: Context, owner: Any, count: Int, next: Texts): Map<String, Any?> {
        // A session opened after Disconnect all (count grows) is a new user
        // action; only the disconnected ones stay without the service.
        if (count > (sessions[owner] ?: 0)) userStopped = false
        if (count > 0) sessions[owner] = count else sessions.remove(owner)
        texts = next
        reconcile(context)
        return state()
    }

    /** Activity onStart/onStop. Only a visible activity may first start the service. */
    fun visibility(context: Context, isVisible: Boolean) {
        val becameVisible = isVisible && !visible
        visible = isVisible
        if (isVisible) {
            releaseLocks()
            if (becameVisible) userStopped = false
            reconcile(context)
            recheckNotifications(context)
        } else if (service != null) acquireLocks(context)
    }

    private fun reconcile(context: Context) {
        if (!hasSessions()) {
            userStopped = false
            reason = null
            cancelPendingStart()
            val ending = service
            service = null
            releaseLocks()
            ending?.finish()
            emit()
            return
        }
        val running = service
        if (running != null) {
            texts?.let { running.refresh(it) }
            return
        }
        if (pendingStart != null || userStopped) return
        if (!visible) {
            reason = "waiting_visible"
            emit()
            return
        }
        try {
            val intent = Intent(context, SshSessionService::class.java)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent)
            else context.startService(intent)
            val timeout = Runnable {
                pendingStart = null
                if (service == null) {
                    reason = "start_timeout"
                    emit()
                }
            }
            pendingStart = timeout
            handler.postDelayed(timeout, START_TIMEOUT_MS)
            reason = null
        } catch (_: RuntimeException) {
            // Includes ForegroundServiceStartNotAllowedException (API 31+) and
            // SecurityException for a missing connectedDevice prerequisite.
            reason = "denied"
        }
        emit()
    }

    private fun cancelPendingStart() {
        pendingStart?.let { handler.removeCallbacks(it) }
        pendingStart = null
    }

    /** The service promoted itself; adopt it unless the sessions are gone. */
    fun started(instance: SshSessionService) {
        val context = instance.applicationContext
        if (!hasSessions() || pendingStart == null || (service != null && service !== instance)) {
            if (service === instance) service = null
            instance.finish()
            if (!hasSessions()) emit()
            return
        }
        cancelPendingStart()
        service = instance
        reason = null
        notificationsVisible = notificationsVisible(context)
        texts?.let { instance.refresh(it) }
        if (!visible) acquireLocks(context)
        emit()
    }

    fun failedStartup(instance: SshSessionService) {
        if (service != null && service !== instance) return
        service = null
        cancelPendingStart()
        releaseLocks()
        if (hasSessions()) reason = "denied"
        emit()
    }

    /** Service-originated end (task removal, OS timeout, destroy). */
    fun ended(instance: SshSessionService, why: String) {
        if (service !== instance) return
        service = null
        releaseLocks()
        reason = if (hasSessions()) why else null
        emit()
    }

    /**
     * Notification action. Dart closes every SSH transport and stops automatic
     * retries; the service is not restarted until the app is visible again.
     */
    fun userDisconnect(instance: SshSessionService) {
        if (service !== instance) {
            // Stale notification. Never stop an instance that still owes
            // startForeground() for a pending start; that start handles it.
            if (pendingStart == null) instance.finish()
            return
        }
        userStopped = true
        service = null
        cancelPendingStart()
        releaseLocks()
        reason = "user_disconnect"
        instance.finish()
        // Only engines that reported SSH sessions; never MCP or transfers.
        listeners.filterKeys { (sessions[it] ?: 0) > 0 }.values.toList()
            .forEach { it.disconnectAll() }
        emit()
    }

    fun notificationsVisible(context: Context): Boolean = try {
        val manager = context.getSystemService(NotificationManager::class.java)
        val permitted = Build.VERSION.SDK_INT < 33 ||
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        val channelOpen = Build.VERSION.SDK_INT < 26 ||
            manager.getNotificationChannel(SshSessionService.CHANNEL)?.importance !=
            NotificationManager.IMPORTANCE_NONE
        permitted && manager.areNotificationsEnabled() && channelOpen
    } catch (_: RuntimeException) { false }

    fun recheckNotifications(context: Context) {
        val running = service ?: return
        val visibleNow = notificationsVisible(context)
        if (visibleNow == notificationsVisible) return
        notificationsVisible = visibleNow
        if (visibleNow) texts?.let { running.refresh(it) }
        emit()
    }

    fun state(): Map<String, Any?> = mapOf(
        "revision" to revision,
        "active" to (service != null),
        "starting" to (pendingStart != null),
        "notifications" to (service != null && notificationsVisible),
        "reason" to reason,
    )

    private fun emit() {
        revision++
        val snapshot = state()
        listeners.values.toList().forEach { it.state(snapshot) }
    }

    /**
     * Bounded background locks: a partial wake lock keeps the CPU awake for
     * SSH keepalive/receive work, and on API < 26 (where Wi-Fi could sleep
     * with the screen) a Wi-Fi lock keeps the radio up. Both auto-expire after
     * [BACKGROUND_LOCK_MS] per background episode and are released as soon as
     * the app is visible again or the last session ends.
     */
    private fun acquireLocks(context: Context) {
        try {
            val lock = wakeLock ?: context.getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Atermius:ssh_sessions")
                .also { it.setReferenceCounted(false); wakeLock = it }
            lock.acquire(BACKGROUND_LOCK_MS)
        } catch (_: RuntimeException) {
        }
        if (Build.VERSION.SDK_INT < 26) {
            try {
                @Suppress("DEPRECATION")
                val lock = wifiLock ?: (context.applicationContext
                    .getSystemService(Context.WIFI_SERVICE) as WifiManager)
                    .createWifiLock(WifiManager.WIFI_MODE_FULL, "Atermius:ssh_sessions")
                    .also { it.setReferenceCounted(false); wifiLock = it }
                if (!lock.isHeld) lock.acquire()
                handler.removeCallbacks(releaseWifi)
                handler.postDelayed(releaseWifi, BACKGROUND_LOCK_MS)
            } catch (_: RuntimeException) {
            }
        }
    }

    private val releaseWifi = Runnable {
        try { wifiLock?.takeIf { it.isHeld }?.release() } catch (_: RuntimeException) {}
    }

    private fun releaseLocks() {
        try { wakeLock?.takeIf { it.isHeld }?.release() } catch (_: RuntimeException) {}
        handler.removeCallbacks(releaseWifi)
        releaseWifi.run()
    }
}

/**
 * Unexported, user-visible foreground service for open SSH sessions. Type
 * `connectedDevice` (API 29+, required with its prerequisite permission on
 * API 34+): interaction with an external device over a network connection,
 * with no time limit unlike `dataSync` (Android 15+). It never restarts.
 */
class SshSessionService : Service() {
    private var finishing = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_DISCONNECT) {
            SshSessionKeepalive.userDisconnect(this)
            return START_NOT_STICKY
        }
        try {
            // Always promote first: startForegroundService requires it even if
            // the sessions ended while the service was being created.
            promote(SshSessionKeepalive.currentTexts() ?: DEFAULT_TEXTS)
            if (finishing) {
                SshSessionKeepalive.failedStartup(this)
                finish()
            } else SshSessionKeepalive.started(this)
        } catch (_: RuntimeException) {
            SshSessionKeepalive.failedStartup(this)
            finish()
        }
        return START_NOT_STICKY
    }

    private fun promote(texts: SshSessionKeepalive.Texts) {
        val notification = build(texts)
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else startForeground(NOTIFICATION_ID, notification)
    }

    internal fun refresh(texts: SshSessionKeepalive.Texts) {
        if (finishing) return
        try {
            getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, build(texts))
        } catch (_: RuntimeException) {
        }
    }

    private fun build(texts: SshSessionKeepalive.Texts): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, texts.channelName, NotificationManager.IMPORTANCE_LOW))
        }
        val immutable = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        // Explicit intent to this unexported service; immutable so no other
        // app can redirect or fill it in.
        val disconnect = PendingIntent.getService(this, REQUEST_DISCONNECT,
            Intent(this, SshSessionService::class.java).setAction(ACTION_DISCONNECT), immutable)
        val open = packageManager.getLaunchIntentForPackage(packageName)?.let {
            it.setPackage(packageName)
            PendingIntent.getActivity(this, REQUEST_OPEN, it, immutable)
        }
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL)
            else @Suppress("DEPRECATION") Notification.Builder(this)
        builder.setSmallIcon(R.drawable.ic_atermius_notification)
            .setContentTitle(texts.title)
            .setContentText(texts.body)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .addAction(Notification.Action.Builder(
                Icon.createWithResource(this, android.R.drawable.ic_menu_close_clear_cancel),
                texts.disconnect, disconnect).build())
        if (open != null) builder.setContentIntent(open)
        // Default (deferred) FGS notification behaviour: a short-lived SSH
        // operation finishing within a few seconds does not flash a
        // notification on Android 12+.
        return builder.build()
    }

    internal fun finish() {
        finishing = true
        if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE)
        else @Suppress("DEPRECATION") stopForeground(true)
        stopSelf()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Swiping the task away destroys the Flutter engine that owns the
        // SSH transports; never leave this service behind.
        SshSessionKeepalive.ended(this, "task_removed")
        finish()
        super.onTaskRemoved(rootIntent)
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        SshSessionKeepalive.ended(this, "timeout")
        finish()
    }

    override fun onDestroy() {
        SshSessionKeepalive.ended(this, "service_destroyed")
        super.onDestroy()
    }

    companion object {
        internal const val CHANNEL = "atermius_ssh_sessions"
        private const val NOTIFICATION_ID = 4109
        private const val REQUEST_DISCONNECT = 1
        private const val REQUEST_OPEN = 2
        private const val ACTION_DISCONNECT = "com.atermius.aterm_client.action.SSH_DISCONNECT_ALL"
        private val DEFAULT_TEXTS = SshSessionKeepalive.Texts(
            "SSH sessions", "Atermius SSH sessions", "SSH connections open", "Disconnect all")
    }
}

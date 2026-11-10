package com.atermius.aterm_client

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock

/** In-memory leases only; no paths, servers, credentials or restart persistence. */
internal object TransferForegroundLeases {
    private const val TTL = 120_000L
    private data class Lease(val owner: Any, var deadline: Long, var ready: ((Boolean) -> Unit)?)
    private val leases = mutableMapOf<String, Lease>()
    private val handler = Handler(Looper.getMainLooper())
    private var service: TransferForegroundService? = null
    private val sweep = object : Runnable {
        override fun run() {
            val now = SystemClock.elapsedRealtime()
            leases.keys.toList().filter { leases[it]!!.deadline <= now }.forEach { remove(it) }
            if (leases.isNotEmpty()) handler.postDelayed(this, 1000)
        }
    }

    fun acquire(context: Context, owner: Any, id: String, callback: (Boolean) -> Unit) {
        if (leases.containsKey(id) || leases.size >= 8) { callback(false); return }
        val lease = Lease(owner, SystemClock.elapsedRealtime() + TTL, callback)
        leases[id] = lease
        handler.removeCallbacks(sweep)
        handler.postDelayed(sweep, 1000)
        if (service != null) { lease.ready = null; callback(true); return }
        try {
            val intent = Intent(context, TransferForegroundService::class.java)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent)
            else context.startService(intent)
            // A timed-out acquire cannot leave a late-started service holding an orphan lease.
            handler.postDelayed({ if (leases[id] === lease && lease.ready != null) remove(id) }, 10_000)
        } catch (_: RuntimeException) { remove(id) }
    }

    fun renew(owner: Any, id: String): Boolean {
        val lease = leases[id] ?: return false
        if (lease.owner !== owner) return false
        if (lease.deadline <= SystemClock.elapsedRealtime()) { remove(id); return false }
        if (lease.ready != null || service == null) return false
        lease.deadline = SystemClock.elapsedRealtime() + TTL
        return true
    }

    fun release(owner: Any, id: String) {
        if (leases[id]?.owner === owner) remove(id)
    }

    fun releaseOwner(owner: Any) {
        leases.keys.toList().filter { leases[it]?.owner === owner }.forEach { remove(it) }
    }

    private fun remove(id: String) {
        val lease = leases.remove(id) ?: return
        lease.ready?.invoke(false)
        if (leases.isEmpty()) {
            handler.removeCallbacks(sweep)
            val ending = service
            service = null
            ending?.finish()
        }
    }

    fun started(instance: TransferForegroundService) {
        if (leases.isEmpty()) {
            if (service === instance) service = null
            instance.finish()
            return
        }
        service = instance
        leases.values.toList().forEach { lease ->
            val callback = lease.ready
            lease.ready = null
            callback?.invoke(true)
        }
    }

    fun stopped(instance: TransferForegroundService) {
        if (service !== instance) return
        service = null
        clearPending()
    }

    fun failedStartup() {
        if (service == null) clearPending()
    }

    private fun clearPending() {
        val pending = leases.values.mapNotNull { it.ready }
        leases.clear()
        handler.removeCallbacks(sweep)
        pending.forEach { it(false) }
    }
}

class TransferForegroundService : Service() {
    private var finishing = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            val manager = getSystemService(NotificationManager::class.java)
            if (Build.VERSION.SDK_INT >= 26) {
                manager.createNotificationChannel(NotificationChannel(
                    CHANNEL, "File transfers", NotificationManager.IMPORTANCE_LOW))
            }
            val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL)
                else Notification.Builder(this)
            val notification = builder.setSmallIcon(R.drawable.ic_atermius_notification)
                .setContentTitle("Atermius file transfer")
                .setContentText("Selecting or transferring a file")
                .setOngoing(true).setCategory(Notification.CATEGORY_SERVICE).build()
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else startForeground(NOTIFICATION_ID, notification)
            // A new start can race with delivery of destruction for this old
            // instance. Promote promptly to satisfy startForegroundService, but
            // never ACK a lease from an instance already committed to stopping.
            if (finishing) {
                TransferForegroundLeases.failedStartup()
                finish()
            } else TransferForegroundLeases.started(this)
        } catch (_: RuntimeException) {
            TransferForegroundLeases.failedStartup()
            finish()
        }
        return START_NOT_STICKY
    }

    internal fun finish() {
        finishing = true
        if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE)
        else @Suppress("DEPRECATION") stopForeground(true)
        stopSelf()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        TransferForegroundLeases.stopped(this)
        finish()
        super.onTaskRemoved(rootIntent)
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        TransferForegroundLeases.stopped(this)
        finish()
    }

    override fun onDestroy() {
        TransferForegroundLeases.stopped(this)
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "atermius_file_transfer"
        private const val NOTIFICATION_ID = 4107
    }
}

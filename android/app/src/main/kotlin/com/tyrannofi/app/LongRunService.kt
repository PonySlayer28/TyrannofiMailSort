package com.tyrannofi.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Keeps the process alive while a long mailbox operation runs.
 *
 * Without this, a sort is an ordinary backgrounded app: Android may kill it the
 * moment it wants memory, and once the screen goes off Doze throttles the
 * network. A run over tens of thousands of mails takes hours, so "may be killed
 * at any time" means "will be killed".
 *
 * The service does no work itself. Its only job is to tell Android that the
 * process is doing something the user asked for and is watching, and to carry
 * the progress notification. The IMAP work stays where it was, in the Dart
 * isolate.
 */
class LongRunService : Service() {

    companion object {
        const val CHANNEL_ID = "tyrannofi_longrun"
        const val NOTIFICATION_ID = 4711

        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        const val ACTION_START = "start"
        const val ACTION_UPDATE = "update"
        const val ACTION_STOP = "stop"
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
            else -> {
                val title = intent?.getStringExtra(EXTRA_TITLE) ?: "TyrannoFi"
                val text = intent?.getStringExtra(EXTRA_TEXT) ?: ""
                startForegroundCompat(build(title, text))
            }
        }
        // Not sticky: if the system does kill us anyway, restarting an empty
        // service would only show a notification for work that is no longer
        // running.
        return START_NOT_STICKY
    }

    /**
     * From Android 14 on a foreground service must name its type, and network
     * work is `dataSync`. Declaring it wrong is not a warning — the system
     * refuses to start the service.
     */
    private fun startForegroundCompat(n: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
    }

    private fun build(title: String, text: String): Notification {
        val tap = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentIntent(tap)
            .setOngoing(true)
            // Low importance: the notification exists because the system
            // demands one, not because it has news. It must not buzz every
            // time a folder is finished.
            .setOnlyAlertOnce(true)
            .build()
    }

    private fun createChannel() {
        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
        val ch = NotificationChannel(
            CHANNEL_ID,
            "Running mailbox work",
            NotificationManager.IMPORTANCE_LOW
        )
        ch.description = "Shows that a sort or scan run is still working."
        ch.setShowBadge(false)
        mgr.createNotificationChannel(ch)
    }
}

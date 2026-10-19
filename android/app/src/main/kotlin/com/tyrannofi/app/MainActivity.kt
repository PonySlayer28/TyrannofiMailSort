package com.tyrannofi.app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val channelName = "tyrannofi/longrun"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        requestNotificationPermission()
                        send(
                            LongRunService.ACTION_START,
                            call.argument("title"),
                            call.argument("text")
                        )
                        result.success(true)
                    }
                    "update" -> {
                        send(
                            LongRunService.ACTION_UPDATE,
                            call.argument("title"),
                            call.argument("text")
                        )
                        result.success(true)
                    }
                    "stop" -> {
                        send(LongRunService.ACTION_STOP, null, null)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun send(action: String, title: String?, text: String?) {
        val i = Intent(this, LongRunService::class.java).setAction(action)
        title?.let { i.putExtra(LongRunService.EXTRA_TITLE, it) }
        text?.let { i.putExtra(LongRunService.EXTRA_TEXT, it) }
        if (action == LongRunService.ACTION_STOP) {
            startService(i)
        } else {
            ContextCompat.startForegroundService(this, i)
        }
    }

    /**
     * Asked for, not insisted on. Without it the progress notification stays
     * invisible from Android 13 on — but the service still runs and still keeps
     * the process alive, which is the part that matters. Refusing the
     * permission must not cost the user their sort.
     */
    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val granted = ContextCompat.checkSelfPermission(
            this, Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            ActivityCompat.requestPermissions(
                this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 4711
            )
        }
    }
}

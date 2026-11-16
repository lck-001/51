package com.shiyu.probe.shiyu_playback_probe

import android.app.ActivityManager
import android.content.ComponentName
import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Process
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Capture application scope, not this Activity: the cached engine may
        // continue after its foreground Activity has been detached/destroyed.
        val probe = PlaybackHostStatus(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "shiyu/playback_host")
            .setMethodCallHandler { call, result ->
                if (call.method == "hostStatus") result.success(probe.read())
                else result.notImplemented()
            }
    }
}

private class PlaybackHostStatus(private val app: Context) {
    private val serviceClass = "com.ryanheise.audioservice.AudioService"

    @Suppress("DEPRECATION")
    fun read(): Map<String, Any> {
        try {
            val declared = app.packageManager.getServiceInfo(
                ComponentName(app.packageName, serviceClass), 0
            )
            val configured = Build.VERSION.SDK_INT < 29 ||
                (declared.foregroundServiceType and
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK) != 0
            if (!configured) return status(false, false, "notConfigured")
            val manager = app.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
                ?: return status(true, false, "unknown")
            // Android O+ returns own services. On earlier APIs discard records
            // of other UIDs before reading component/foreground information.
            val own = manager.getRunningServices(Int.MAX_VALUE).asSequence()
                .filter { it.uid == Process.myUid() }
                .firstOrNull {
                    it.service.packageName == app.packageName &&
                        it.service.className == serviceClass
                }
            return when {
                own == null -> status(true, false, "notRunning")
                own.pid == 0 -> status(true, false, "unknown")
                own.foreground -> status(true, true, "foreground")
                else -> status(true, false, "notForeground")
            }
        } catch (_: Exception) {
            return status(false, false, "unknown")
        }
    }

    private fun status(configured: Boolean, foreground: Boolean, state: String) = mapOf(
        "configured" to configured,
        "foreground" to foreground,
        "state" to state
    )
}

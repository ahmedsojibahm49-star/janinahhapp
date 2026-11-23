package com.kizoo.streambox

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File

/**
 * In-app updater: installs a downloaded APK over the running app with the
 * system PackageInstaller (no FileProvider, no external dependency).
 *
 * Channel `streambox/update`:
 *   version()              -> JSON {versionName, versionCode, canInstall}
 *   openInstallSettings()  -> opens "Install unknown apps" for this app
 *   install({path})        -> commits an install session; the outcome comes
 *                             back later as invokeMethod("installResult")
 *
 * Android only replaces an app when the new APK is signed with the SAME
 * key. If it is not, the installer reports an INCOMPATIBLE failure which is
 * forwarded to Dart verbatim so the UI can explain it.
 */
class AppUpdater(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL)
    private val ctx: Context get() = activity.applicationContext
    private var receiverRegistered = false

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "version" -> result.success(versionJson())
                "openInstallSettings" -> {
                    openInstallSettings()
                    result.success(true)
                }
                "install" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("BAD_ARGS", "path is required", null)
                    } else {
                        install(path, result)
                    }
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("UPDATER_FAILED", e.message ?: e.javaClass.simpleName, null)
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        if (receiverRegistered) {
            try {
                ctx.unregisterReceiver(receiver)
            } catch (_: Exception) {
            }
            receiverRegistered = false
        }
    }

    private fun versionJson(): String {
        val info = ctx.packageManager.getPackageInfo(ctx.packageName, 0)
        val code =
            if (Build.VERSION.SDK_INT >= 28) info.longVersionCode
            else @Suppress("DEPRECATION") info.versionCode.toLong()
        return JSONObject()
            .put("versionName", info.versionName ?: "")
            .put("versionCode", code)
            .put("canInstall", canInstall())
            .toString()
    }

    private fun canInstall(): Boolean =
        Build.VERSION.SDK_INT < 26 || ctx.packageManager.canRequestPackageInstalls()

    private fun openInstallSettings() {
        val intent = Intent(
            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
            Uri.parse("package:${ctx.packageName}"),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        activity.startActivity(intent)
    }

    private fun install(path: String, result: MethodChannel.Result) {
        val file = File(path)
        if (!file.isFile || file.length() == 0L) {
            result.error("NO_FILE", "The downloaded update file is missing.", null)
            return
        }
        if (!canInstall()) {
            result.error(
                "NEEDS_PERMISSION",
                "Allow StreamBox to install updates, then try again.",
                null,
            )
            return
        }
        registerReceiverOnce()

        val installer = ctx.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(
            PackageInstaller.SessionParams.MODE_FULL_INSTALL,
        )
        params.setAppPackageName(ctx.packageName)
        if (Build.VERSION.SDK_INT >= 31) {
            // After the first confirmed install Android 12+ may apply later
            // updates without another prompt.
            params.setRequireUserAction(
                PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED,
            )
        }
        val sessionId = installer.createSession(params)
        installer.openSession(sessionId).use { session ->
            file.inputStream().use { input ->
                session.openWrite("streambox.apk", 0, file.length()).use { out ->
                    input.copyTo(out)
                    session.fsync(out)
                }
            }
            val intent = Intent(ACTION_RESULT).setPackage(ctx.packageName)
            var flags = PendingIntent.FLAG_UPDATE_CURRENT
            if (Build.VERSION.SDK_INT >= 31) flags = flags or PendingIntent.FLAG_MUTABLE
            val pending = PendingIntent.getBroadcast(ctx, sessionId, intent, flags)
            session.commit(pending.intentSender)
        }
        result.success(true)
    }

    private fun registerReceiverOnce() {
        if (receiverRegistered) return
        val filter = IntentFilter(ACTION_RESULT)
        if (Build.VERSION.SDK_INT >= 33) {
            ctx.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            ctx.registerReceiver(receiver, filter)
        }
        receiverRegistered = true
    }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -1)
            val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: ""
            if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
                // The system needs the user to confirm: show its dialog.
                @Suppress("DEPRECATION")
                val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                if (confirm != null) {
                    confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    context.startActivity(confirm)
                }
                return
            }
            val payload = HashMap<String, Any>()
            payload["status"] = status
            payload["success"] = status == PackageInstaller.STATUS_SUCCESS
            payload["message"] = message
            activity.runOnUiThread { channel.invokeMethod("installResult", payload) }
        }
    }

    companion object {
        const val CHANNEL = "streambox/update"
        private const val ACTION_RESULT = "com.kizoo.streambox.INSTALL_RESULT"
    }
}

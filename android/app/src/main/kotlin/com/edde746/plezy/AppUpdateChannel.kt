package com.edde746.plezy

import android.app.Activity
import android.app.PendingIntent
import android.content.ActivityNotFoundException
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * In-app updates for sideloaded installs: hands a release APK that Dart has already downloaded to
 * the system installer through a [PackageInstaller] session. Same package and same signing key,
 * so it upgrades in place and keeps the app's data.
 */
internal class AppUpdateChannel(private val activity: Activity) {
  companion object {
    private const val CHANNEL = "com.plezy/app_update"
    private const val TAG = "AppUpdateChannel"

    private val mainHandler = Handler(Looper.getMainLooper())

    /** The attached channel, so [AppUpdateInstallReceiver] can report a failed install to Dart. */
    @Volatile
    private var activeChannel: MethodChannel? = null

    fun reportStatus(status: Int, message: String?) {
      mainHandler.post {
        activeChannel?.invokeMethod("onInstallStatus", mapOf("status" to status, "message" to message))
      }
    }
  }

  private val executor = Executors.newSingleThreadExecutor()

  fun attach(messenger: BinaryMessenger) {
    val channel = MethodChannel(messenger, CHANNEL)
    channel.setMethodCallHandler(::onMethodCall)
    activeChannel = channel
  }

  private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "canInstall" -> result.success(canInstall())
      "openInstallSettings" -> result.success(openInstallSettings())
      "install" -> {
        val path = call.argument<String>("path")
        if (path.isNullOrEmpty()) {
          result.error("bad_args", "No APK path", null)
        } else {
          install(File(path), result)
        }
      }
      else -> result.notImplemented()
    }
  }

  private fun canInstall(): Boolean =
    Build.VERSION.SDK_INT < Build.VERSION_CODES.O || activity.packageManager.canRequestPackageInstalls()

  /** Opens "Install unknown apps" for this app (or the global setting before Android 8). */
  private fun openInstallSettings(): Boolean {
    val intents = buildList {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        add(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}")))
      }
      add(Intent(Settings.ACTION_SECURITY_SETTINGS))
    }
    for (intent in intents) {
      try {
        activity.startActivity(intent)
        return true
      } catch (_: ActivityNotFoundException) {
        // Some TV builds leave out the per-app page; try the next one.
      }
    }
    return false
  }

  private fun install(apk: File, result: MethodChannel.Result) {
    val context = activity.applicationContext
    executor.execute {
      try {
        if (!apk.isFile) throw IllegalStateException("APK not found: ${apk.path}")
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
          setAppPackageName(context.packageName)
          setSize(apk.length())
          // Android 12+ skips the confirmation when this app is the installer of record for
          // itself. After a Downloader or ADB install it is not, and the system asks anyway.
          if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
          }
        }
        val sessionId = installer.createSession(params)
        installer.openSession(sessionId).use { session ->
          apk.inputStream().use { input ->
            session.openWrite("update.apk", 0, apk.length()).use { output ->
              input.copyTo(output)
              session.fsync(output)
            }
          }
          val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0)
          val statusIntent = PendingIntent.getBroadcast(
            context,
            sessionId,
            Intent(context, AppUpdateInstallReceiver::class.java),
            flags
          )
          session.commit(statusIntent.intentSender)
        }
        mainHandler.post { result.success(true) }
      } catch (e: Exception) {
        Log.e(TAG, "Update install failed", e)
        mainHandler.post { result.error("install_failed", e.message, null) }
      }
    }
  }
}

/** Receives the installer's status for an update session started by [AppUpdateChannel]. */
class AppUpdateInstallReceiver : BroadcastReceiver() {
  override fun onReceive(context: Context, intent: Intent) {
    val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
    val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
    when (status) {
      PackageInstaller.STATUS_PENDING_USER_ACTION -> {
        val confirm = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
          intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
        } else {
          @Suppress("DEPRECATION")
          intent.getParcelableExtra(Intent.EXTRA_INTENT)
        }
        if (confirm == null) {
          AppUpdateChannel.reportStatus(PackageInstaller.STATUS_FAILURE, "No confirmation screen")
          return
        }
        confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
          context.startActivity(confirm)
        } catch (e: ActivityNotFoundException) {
          AppUpdateChannel.reportStatus(PackageInstaller.STATUS_FAILURE, e.message)
        }
      }
      // On success the system replaces this process; nothing left to do.
      PackageInstaller.STATUS_SUCCESS -> Log.i("AppUpdateInstall", "Update installed")
      else -> {
        Log.w("AppUpdateInstall", "Update install ended with status $status: $message")
        AppUpdateChannel.reportStatus(status, message)
      }
    }
  }
}

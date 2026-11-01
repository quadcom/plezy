package com.edde746.plezy

import android.Manifest
import android.app.Activity
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Old School reminders on a phone or tablet while Plezy is in the background
 * (local/plans/old-school-future-details.md, stage 2). Dart hands over the
 * upcoming reminders; each gets an alarm a minute before it starts. When it
 * fires and Plezy is not on screen, [OldSchoolReminderReceiver] posts a
 * notification; tapping it opens Plezy, which tunes that channel. With Plezy
 * on screen the in-app countdown notice does the job instead.
 *
 * Alarms are inexact unless the system allows exact ones, so a notice in
 * deep sleep can come a few minutes late. They don't survive a reboot; the
 * next app start schedules them again from the server's list.
 */
internal class OldSchoolReminderAlarms(private val activity: Activity) {
  companion object {
    private const val CHANNEL = "com.plezy/old_school_reminders"
    private const val TAG = "PlezyOSReminders"
    const val PERMISSION_REQUEST_CODE = 7471
    const val EXTRA_CHANNEL_ID = "plezy_old_school_channel"
    const val NOTIFICATION_CHANNEL_ID = "old_school_reminders"
    private const val PREFS = "old_school_reminders"
    private const val KEY_IDS = "scheduled_ids"

    /** Set by MainActivity: whether Plezy is on screen now. */
    @Volatile
    var appVisible = false

    fun ensureNotificationChannel(context: Context) {
      if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
      val manager = context.getSystemService(NotificationManager::class.java) ?: return
      if (manager.getNotificationChannel(NOTIFICATION_CHANNEL_ID) != null) return
      manager.createNotificationChannel(
        NotificationChannel(NOTIFICATION_CHANNEL_ID, "Old School reminders", NotificationManager.IMPORTANCE_HIGH)
      )
    }
  }

  private var channel: MethodChannel? = null
  private var pendingPermission: MethodChannel.Result? = null

  /** A channel to tune from the notification that started or resumed Plezy. */
  private var launchChannelId: String? = null

  fun attach(messenger: BinaryMessenger) {
    channel = MethodChannel(messenger, CHANNEL).also { it.setMethodCallHandler(::onMethodCall) }
  }

  fun dispose() {
    channel?.setMethodCallHandler(null)
    channel = null
    pendingPermission = null
  }

  /**
   * From MainActivity: onCreate ([live] false; Dart takes it with
   * `takeLaunchChannel` once it is ready) or onNewIntent ([live] true, sent
   * straight to Dart).
   */
  fun handleIntent(intent: Intent?, live: Boolean) {
    val channelId = intent?.getStringExtra(EXTRA_CHANNEL_ID) ?: return
    intent.removeExtra(EXTRA_CHANNEL_ID)
    Log.i(TAG, "opened from a reminder for $channelId")
    val target = channel
    if (live && target != null) {
      target.invokeMethod("open", channelId)
    } else {
      launchChannelId = channelId
    }
  }

  private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "schedule" -> {
        @Suppress("UNCHECKED_CAST")
        val items = call.argument<List<Map<String, Any?>>>("reminders") ?: emptyList()
        schedule(items)
        result.success(null)
      }
      "requestPermission" -> requestPermission(result)
      "takeLaunchChannel" -> {
        result.success(launchChannelId)
        launchChannelId = null
      }
      else -> result.notImplemented()
    }
  }

  private fun requestPermission(result: MethodChannel.Result) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
      activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
    ) {
      result.success(true)
      return
    }
    if (pendingPermission != null) {
      result.success(false)
      return
    }
    pendingPermission = result
    activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), PERMISSION_REQUEST_CODE)
  }

  /** From MainActivity. True when the request was ours. */
  fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
    if (requestCode != PERMISSION_REQUEST_CODE) return false
    val granted = grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
    pendingPermission?.success(granted)
    pendingPermission = null
    return true
  }

  private fun alarmIntent(id: String, item: Map<String, Any?>?): PendingIntent {
    val intent = Intent(activity, OldSchoolReminderReceiver::class.java).apply {
      action = "com.plezy.OLD_SCHOOL_REMINDER.$id"
      putExtra(OldSchoolReminderReceiver.EXTRA_ID, id)
      if (item != null) {
        putExtra(OldSchoolReminderReceiver.EXTRA_TITLE, item["title"] as? String ?: "")
        putExtra(OldSchoolReminderReceiver.EXTRA_TEXT, item["text"] as? String ?: "")
        putExtra(EXTRA_CHANNEL_ID, item["channelId"] as? String ?: "")
      }
    }
    return PendingIntent.getBroadcast(
      activity,
      id.hashCode(),
      intent,
      PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
    )
  }

  /** Replace every scheduled alarm with [items] ({id, at (ms), title, text, channelId}). */
  private fun schedule(items: List<Map<String, Any?>>) {
    val alarms = activity.getSystemService(AlarmManager::class.java) ?: return
    val prefs = activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    val old = prefs.getStringSet(KEY_IDS, emptySet()) ?: emptySet()
    for (id in old) alarms.cancel(alarmIntent(id, null))

    val now = System.currentTimeMillis()
    val ids = mutableSetOf<String>()
    for (item in items) {
      val id = item["id"] as? String ?: continue
      val at = (item["at"] as? Number)?.toLong() ?: continue
      if (at <= now) continue
      val pending = alarmIntent(id, item)
      val exact = Build.VERSION.SDK_INT < Build.VERSION_CODES.S || alarms.canScheduleExactAlarms()
      try {
        if (exact) {
          alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending)
        } else {
          alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending)
        }
        ids.add(id)
      } catch (e: SecurityException) {
        Log.w(TAG, "could not schedule $id", e)
      }
    }
    prefs.edit().putStringSet(KEY_IDS, ids).apply()
    Log.i(TAG, "scheduled ${ids.size} reminder(s)")
  }
}

/** Posts an Old School reminder's notification, unless Plezy is on screen. */
class OldSchoolReminderReceiver : BroadcastReceiver() {
  companion object {
    const val EXTRA_ID = "plezy_reminder_id"
    const val EXTRA_TITLE = "plezy_reminder_title"
    const val EXTRA_TEXT = "plezy_reminder_text"
  }

  override fun onReceive(context: Context, intent: Intent) {
    if (OldSchoolReminderAlarms.appVisible) return
    val id = intent.getStringExtra(EXTRA_ID) ?: return
    val channelId = intent.getStringExtra(OldSchoolReminderAlarms.EXTRA_CHANNEL_ID) ?: return
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
      context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
    ) {
      return
    }
    OldSchoolReminderAlarms.ensureNotificationChannel(context)
    val open = Intent(context, MainActivity::class.java).apply {
      flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
      putExtra(OldSchoolReminderAlarms.EXTRA_CHANNEL_ID, channelId)
    }
    val content = PendingIntent.getActivity(
      context,
      id.hashCode(),
      open,
      PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
    )
    val notification = NotificationCompat.Builder(context, OldSchoolReminderAlarms.NOTIFICATION_CHANNEL_ID)
      .setSmallIcon(R.drawable.ic_stat_notification)
      .setContentTitle(intent.getStringExtra(EXTRA_TITLE) ?: "")
      .setContentText(intent.getStringExtra(EXTRA_TEXT) ?: "")
      .setPriority(NotificationCompat.PRIORITY_HIGH)
      .setCategory(NotificationCompat.CATEGORY_REMINDER)
      .setAutoCancel(true)
      .setContentIntent(content)
      .build()
    val manager = context.getSystemService(NotificationManager::class.java) ?: return
    manager.notify(id.hashCode(), notification)
  }
}

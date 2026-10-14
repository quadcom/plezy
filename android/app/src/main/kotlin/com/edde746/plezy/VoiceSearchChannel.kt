package com.edde746.plezy

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.speech.RecognizerIntent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Voice search through the platform's speech-input screen.
 *
 * Gboard's own voice typing fails on some Google TV boxes (it cancels the
 * recognizer the moment it starts), while the system voice screen behind
 * RECOGNIZE_SPEECH works: the voice app records from the remote's mic and
 * hands back text, so Plezy needs no microphone permission of its own.
 */
internal class VoiceSearchChannel(private val activity: Activity) {
  companion object {
    private const val CHANNEL = "com.plezy/voice_search"
    const val REQUEST_CODE = 7462

    // Several apps can answer RECOGNIZE_SPEECH (a Google TV box lists the
    // Assistant's voice screen and Speech Services' one); naming one avoids
    // Android's "Open with" chooser. Earlier entries win.
    private val preferredPackages = listOf(
      "com.google.android.katniss",
      "com.google.android.googlequicksearchbox"
    )
  }

  private var pendingResult: MethodChannel.Result? = null

  fun attach(messenger: BinaryMessenger) {
    MethodChannel(messenger, CHANNEL).setMethodCallHandler(::onMethodCall)
  }

  fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
    if (requestCode != REQUEST_CODE) return false
    val result = pendingResult
    pendingResult = null
    val text = if (resultCode == Activity.RESULT_OK) {
      data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
        ?.firstOrNull { it.isNotBlank() }
        ?.trim()
    } else {
      null
    }
    result?.success(text)
    return true
  }

  fun dispose() {
    pendingResult?.success(null)
    pendingResult = null
  }

  private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "isAvailable" -> result.success(findRecognizer() != null)
      "listen" -> listen(call.argument<String>("prompt"), result)
      else -> result.notImplemented()
    }
  }

  private fun listen(prompt: String?, result: MethodChannel.Result) {
    if (pendingResult != null) {
      result.error("ALREADY_ACTIVE", "Voice search is already listening", null)
      return
    }
    val recognizer = findRecognizer()
    if (recognizer == null) {
      result.error("UNAVAILABLE", "No voice input app found", null)
      return
    }
    val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
      component = ComponentName(recognizer.activityInfo.packageName, recognizer.activityInfo.name)
      putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
      putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
      prompt?.takeIf(String::isNotBlank)?.let { putExtra(RecognizerIntent.EXTRA_PROMPT, it) }
    }
    try {
      pendingResult = result
      activity.startActivityForResult(intent, REQUEST_CODE)
    } catch (error: ActivityNotFoundException) {
      pendingResult = null
      result.error("UNAVAILABLE", error.message ?: "No voice input app found", null)
    } catch (error: SecurityException) {
      pendingResult = null
      result.error("LAUNCH_FAILED", error.message ?: error.javaClass.simpleName, null)
    }
  }

  private fun findRecognizer(): ResolveInfo? {
    val candidates = activity.packageManager.queryIntentActivities(
      Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH),
      PackageManager.MATCH_DEFAULT_ONLY
    ).filter { it.activityInfo?.exported == true }
    if (candidates.isEmpty()) return null
    for (packageName in preferredPackages) {
      candidates.firstOrNull { it.activityInfo.packageName == packageName }?.let { return it }
    }
    return candidates.first()
  }
}

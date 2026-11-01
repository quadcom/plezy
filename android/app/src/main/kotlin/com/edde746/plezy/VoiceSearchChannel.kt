package com.edde746.plezy

import android.Manifest
import android.app.Activity
import android.app.SearchManager
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Voice search inside Plezy's own screen.
 *
 * Plezy talks to Android's speech service directly ([SpeechRecognizer]) and
 * shows its own listening card. The system voice screen behind
 * RECOGNIZE_SPEECH is only a fallback: on the Greatroom Google TV
 * (2026-10-31) that screen (Google TV's katniss) recognised the words but
 * handed nothing back to Plezy, and it covered Plezy's page with Google's bar.
 * Talking to the service needs the microphone permission, asked the first
 * time the mic is used. The remote's mic reaches the service through Android
 * TV's remote-audio bridge, as it did for Google's own screen.
 *
 * Events to Dart on the same channel, method "onEvent", {type, text?}:
 * ready, speech, partial (text), end. The listen call answers with the final
 * text, null for no match or a cancel, or an error code.
 */
internal class VoiceSearchChannel(private val activity: Activity) {
  companion object {
    private const val CHANNEL = "com.plezy/voice_search"
    private const val TAG = "PlezyVoiceSearch"
    const val REQUEST_CODE = 7462
    const val PERMISSION_REQUEST_CODE = 7463

    // Fallback screen: several apps can answer RECOGNIZE_SPEECH; naming one
    // avoids Android's "Open with" chooser. Earlier entries win.
    private val preferredPackages = listOf(
      "com.google.android.katniss",
      "com.google.android.googlequicksearchbox"
    )
  }

  private var channel: MethodChannel? = null
  private var pendingResult: MethodChannel.Result? = null
  private var pendingPrompt: String? = null
  private var recognizer: SpeechRecognizer? = null
  private var partialCount = 0

  fun attach(messenger: BinaryMessenger) {
    channel = MethodChannel(messenger, CHANNEL).also { it.setMethodCallHandler(::onMethodCall) }
  }

  private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "isAvailable" -> result.success(serviceAvailable() || findRecognizerScreen() != null)
      "listen" -> listen(call.argument<String>("prompt"), result)
      "cancel" -> {
        cancel("cancel requested")
        result.success(null)
      }
      else -> result.notImplemented()
    }
  }

  private fun serviceAvailable(): Boolean = SpeechRecognizer.isRecognitionAvailable(activity)

  private fun listen(prompt: String?, result: MethodChannel.Result) {
    if (pendingResult != null) {
      result.error("ALREADY_ACTIVE", "Voice search is already listening", null)
      return
    }
    if (!serviceAvailable()) {
      listenWithScreen(prompt, result)
      return
    }
    pendingResult = result
    if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
      Log.i(TAG, "asking for the microphone permission")
      pendingPrompt = prompt
      activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), PERMISSION_REQUEST_CODE)
      return
    }
    startService()
  }

  /** From MainActivity. True when the request was ours. */
  fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
    if (requestCode != PERMISSION_REQUEST_CODE) return false
    val granted = grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
    Log.i(TAG, "microphone permission granted=$granted")
    pendingPrompt = null
    if (pendingResult == null) return true
    if (granted) {
      startService()
    } else {
      finish { it.error("PERMISSION_DENIED", "Microphone permission refused", null) }
    }
    return true
  }

  private fun startService() {
    // The default service (not the on-device-only one): on the Greatroom TV
    // it runs on-device and online together and needs no downloaded pack.
    val speech = try {
      SpeechRecognizer.createSpeechRecognizer(activity)
    } catch (error: RuntimeException) {
      Log.w(TAG, "speech service failed to start: ${error.javaClass.simpleName}")
      finish { it.error("UNAVAILABLE", error.message ?: "Speech service unavailable", null) }
      return
    }
    recognizer = speech
    partialCount = 0
    speech.setRecognitionListener(listener)
    val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
      putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
      putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
      putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
      putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, activity.packageName)
    }
    Log.i(TAG, "listening via speech service")
    speech.startListening(intent)
  }

  private val listener = object : RecognitionListener {
    override fun onReadyForSpeech(params: Bundle?) = sendEvent("ready")
    override fun onBeginningOfSpeech() = sendEvent("speech")
    override fun onRmsChanged(rmsdB: Float) {}
    override fun onBufferReceived(buffer: ByteArray?) {}
    override fun onEndOfSpeech() = sendEvent("end")

    override fun onPartialResults(partialResults: Bundle?) {
      val text = firstResult(partialResults) ?: return
      partialCount++
      sendEvent("partial", text)
    }

    override fun onResults(results: Bundle?) {
      val text = firstResult(results)
      // Length only: what someone says stays out of the log.
      Log.i(TAG, "result partials=$partialCount text=${text?.let { "${it.length} chars" } ?: "none"}")
      finish { it.success(text) }
    }

    override fun onError(error: Int) {
      Log.i(TAG, "speech service error=$error partials=$partialCount")
      when (error) {
        SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> finish { it.success(null) }
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS ->
          finish { it.error("PERMISSION_DENIED", "Microphone permission refused", null) }
        else -> finish { it.error("RECOGNIZER_ERROR", "Speech service error $error", error) }
      }
    }

    override fun onEvent(eventType: Int, params: Bundle?) {}
  }

  private fun firstResult(bundle: Bundle?): String? =
    bundle?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
      ?.firstOrNull { it.isNotBlank() }
      ?.trim()

  private fun sendEvent(type: String, text: String? = null) {
    channel?.invokeMethod("onEvent", mapOf("type" to type, "text" to text))
  }

  /** Answers the pending listen call once and frees the recogniser. */
  private fun finish(answer: (MethodChannel.Result) -> Unit) {
    val result = pendingResult
    pendingResult = null
    releaseRecognizer()
    result?.let(answer)
  }

  private fun cancel(reason: String) {
    if (pendingResult == null && recognizer == null) return
    Log.i(TAG, reason)
    recognizer?.cancel()
    finish { it.success(null) }
  }

  private fun releaseRecognizer() {
    recognizer?.let {
      it.setRecognitionListener(null)
      it.destroy()
    }
    recognizer = null
  }

  fun dispose() {
    cancel("disposed")
    pendingResult?.success(null)
    pendingResult = null
  }

  // ---------- Fallback: the system voice screen ----------

  fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
    if (requestCode != REQUEST_CODE) return false
    val result = pendingResult
    pendingResult = null
    val text = extractText(data)
    Log.i(
      TAG,
      "screen result code=$resultCode keys=${data?.extras?.keySet()?.sorted()} " +
        "text=${text?.let { "${it.length} chars" } ?: "none"} pending=${result != null}"
    )
    result?.success(text)
    return true
  }

  private fun extractText(data: Intent?): String? {
    if (data == null) return null
    data.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
      ?.firstOrNull { it.isNotBlank() }
      ?.let { return it.trim() }
    data.getStringExtra(SearchManager.QUERY)?.takeIf(String::isNotBlank)?.let { return it.trim() }
    val extras = data.extras ?: return null
    for (key in extras.keySet().sorted()) {
      @Suppress("DEPRECATION")
      when (val value = extras.get(key)) {
        is String -> if (value.isNotBlank() && key.contains("result", ignoreCase = true)) return value.trim()
        is ArrayList<*> -> value.firstOrNull { it is String && it.isNotBlank() }?.let { return (it as String).trim() }
      }
    }
    return null
  }

  private fun listenWithScreen(prompt: String?, result: MethodChannel.Result) {
    val screen = findRecognizerScreen()
    if (screen == null) {
      result.error("UNAVAILABLE", "No voice input app found", null)
      return
    }
    val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
      component = ComponentName(screen.activityInfo.packageName, screen.activityInfo.name)
      putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
      putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
      putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, activity.packageName)
      prompt?.takeIf(String::isNotBlank)?.let { putExtra(RecognizerIntent.EXTRA_PROMPT, it) }
    }
    try {
      pendingResult = result
      Log.i(TAG, "no speech service; listening via ${screen.activityInfo.packageName}/${screen.activityInfo.name}")
      activity.startActivityForResult(intent, REQUEST_CODE)
    } catch (error: ActivityNotFoundException) {
      pendingResult = null
      result.error("UNAVAILABLE", error.message ?: "No voice input app found", null)
    } catch (error: SecurityException) {
      pendingResult = null
      result.error("LAUNCH_FAILED", error.message ?: error.javaClass.simpleName, null)
    }
  }

  private fun findRecognizerScreen(): ResolveInfo? {
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

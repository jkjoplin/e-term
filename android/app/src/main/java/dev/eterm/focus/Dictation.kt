package dev.eterm.focus

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer

/**
 * Continuous dictation: partial results show as forming text, each final phrase is typed,
 * and listening starts again until stop() is called. Runs on the main thread.
 */
class Dictation(
    private val context: Context,
    private val onPartial: (String) -> Unit,
    private val onPhrase: (String) -> Unit,
    private val onStopped: (String?) -> Unit,
) {
    private var recognizer: SpeechRecognizer? = null
    private var active = false
    private var onDevice = false
    private var heardAnything = false

    val isActive: Boolean get() = active

    fun start() {
        if (active) return
        if (!SpeechRecognizer.isRecognitionAvailable(context)) {
            onStopped("Speech recognition is not available on this phone.")
            return
        }
        active = true
        heardAnything = false
        open(onDeviceFirst = true)
        listen()
    }

    private fun open(onDeviceFirst: Boolean) {
        recognizer?.destroy()
        onDevice = onDeviceFirst && SpeechRecognizer.isOnDeviceRecognitionAvailable(context)
        val r = if (onDevice) {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        } else {
            SpeechRecognizer.createSpeechRecognizer(context)
        }
        r.setRecognitionListener(listener)
        recognizer = r
    }

    fun stop() {
        if (!active) return
        active = false
        recognizer?.stopListening()
        recognizer?.destroy()
        recognizer = null
        onStopped(null)
    }

    private fun listen() {
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
        }
        recognizer?.startListening(intent)
    }

    private val listener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {}
        override fun onBeginningOfSpeech() {}
        override fun onRmsChanged(rmsdB: Float) {}
        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEndOfSpeech() {}
        override fun onEvent(eventType: Int, params: Bundle?) {}

        override fun onPartialResults(partialResults: Bundle) {
            val text = partialResults.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()
            if (!text.isNullOrBlank()) {
                heardAnything = true
                onPartial(text)
            }
        }

        override fun onResults(results: Bundle) {
            val text = results.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()
            if (!text.isNullOrBlank()) {
                heardAnything = true
                onPhrase(text)
            }
            if (active) listen()
        }

        override fun onError(error: Int) {
            // The on-device recognizer fails at once when its language pack is missing.
            // Fall back to the regular recognizer before giving up.
            if (active && onDevice && !heardAnything &&
                error != SpeechRecognizer.ERROR_NO_MATCH && error != SpeechRecognizer.ERROR_SPEECH_TIMEOUT &&
                error != SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS
            ) {
                open(onDeviceFirst = false)
                listen()
                return
            }
            when (error) {
                SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> if (active) listen()
                SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> {}
                SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> {
                    stop()
                    onStopped("Eink Focus needs the microphone to dictate.")
                }
                else -> {
                    stop()
                    onStopped("Dictation stopped (error $error).")
                }
            }
        }
    }
}

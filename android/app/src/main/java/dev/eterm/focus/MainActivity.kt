package dev.eterm.focus

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import android.util.Log
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.eterm.focus.core.FocusEngine
import dev.eterm.focus.core.PhoneConfig
import dev.eterm.focus.ui.Actions
import dev.eterm.focus.ui.FocusScreen
import dev.eterm.focus.ui.SetupScreen
import java.io.File

private const val TAG = "EinkFocus"
private const val PREF_TEXT_MODE = "textMode"

class MainActivity : ComponentActivity() {
    private var engine: FocusEngine? = null
    private var dictation: Dictation? = null
    private var keyView: KeyCaptureView? = null
    private var textMode by mutableStateOf(false)

    private val askMic = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) {
            engine?.setListening(true)
            dictation?.start()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        val configFile = File(filesDir, "config.json")
        val keyFile = File(filesDir, "id_ed25519")
        val problem = when {
            !configFile.exists() -> "No config.json yet."
            !keyFile.exists() -> "No SSH key yet."
            else -> null
        }
        val config = if (problem == null) runCatching { PhoneConfig.parse(configFile.readText()) } else null
        if (problem != null || config == null || config.isFailure) {
            val reason = problem ?: config?.exceptionOrNull()?.message ?: "Config could not be read."
            setContent { SetupScreen(reason) }
            return
        }

        // A key JSch cannot read fails here. Show it instead of crashing before any UI.
        val e = try {
            FocusEngine(config.getOrThrow(), keyFile.readBytes(), File(filesDir, "known_hosts"))
        } catch (t: Throwable) {
            Log.e(TAG, "engine setup failed", t)
            setContent { SetupScreen("The SSH key could not be loaded: ${t.message ?: t::class.java.simpleName}") }
            return
        }
        e.log = { Log.w(TAG, it) }
        engine = e
        dictation = Dictation(
            context = this,
            onPartial = { e.dictating(it) },
            onPhrase = {
                keyView?.forgetLine()
                e.dictated(it)
            },
            onStopped = { message ->
                e.setListening(false)
                if (message != null) e.showNotice(message)
            },
        )
        val sink = object : KeySink {
            override fun text(text: String) = e.typeText(text)
            override fun key(name: String) = e.sendKey(name)
            override fun nextComputer() = e.stepComputer(forward = true)
        }
        // Keys sent from the screen change the terminal line, so text mode starts a fresh copy.
        val forget = { keyView?.forgetLine() }
        val actions = Actions(
            key = { forget(); e.sendKey(it) },
            toggleCtrl = { e.toggleCtrl() },
            nextSession = { forget(); e.nextSession() },
            stepComputer = { forget(); e.stepComputer(it) },
            moveTo = { forget(); e.moveTo(it) },
            nextKindle = { forget(); e.nextKindle() },
            toggleMic = { toggleMic() },
            toggleTextMode = { applyTextMode(!textMode) },
            focusKeys = { keyView?.showKeyboard() },
        )
        textMode = getPreferences(MODE_PRIVATE).getBoolean(PREF_TEXT_MODE, false)
        setContent {
            val state by e.state.collectAsStateWithLifecycle()
            val target = state.target
            // A different Kindle, computer or session has a different line.
            LaunchedEffect(target?.computer?.id, target?.client, target?.session) { keyView?.forgetLine() }
            FocusScreen(
                state = state,
                textMode = textMode,
                actions = actions,
                makeKeyView = { context ->
                    KeyCaptureView(context, sink).also { view ->
                        view.textMode = textMode
                        keyView = view
                        // The first onStart runs before this view exists.
                        view.post { view.showKeyboard() }
                    }
                },
            )
        }
    }

    private fun applyTextMode(on: Boolean) {
        textMode = on
        getPreferences(MODE_PRIVATE).edit().putBoolean(PREF_TEXT_MODE, on).apply()
        keyView?.textMode = on
        keyView?.showKeyboard()
    }

    private fun toggleMic() {
        val d = dictation ?: return
        val e = engine ?: return
        if (d.isActive) {
            d.stop()
            return
        }
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            askMic.launch(Manifest.permission.RECORD_AUDIO)
            return
        }
        e.setListening(true)
        d.start()
    }

    override fun onStart() {
        super.onStart()
        engine?.start()
        keyView?.post { keyView?.showKeyboard() }
    }

    override fun onStop() {
        dictation?.stop()
        engine?.stop()
        super.onStop()
    }
}

package dev.eterm.focus.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File

/** Where keys go: the Kindle's tmux client on one computer. */
data class Target(
    val computer: Computer,
    val device: String,
    val client: String,
    val session: String,
    val label: String = device,
)

data class FocusState(
    val computers: List<Computer> = emptyList(),
    /** Computer id to whether its last probe answered. Missing means not tried yet. */
    val online: Map<String, Boolean> = emptyMap(),
    /** Computer id to why its last probe failed, for the card to show. */
    val errors: Map<String, String> = emptyMap(),
    val kindles: List<Target> = emptyList(),
    val target: Target? = null,
    val searching: Boolean = true,
    val moving: String? = null,
    val notice: String? = null,
    /** What has been typed since the last Return, as the card shows it. */
    val line: String = "",
    /** Dictation that is still forming. */
    val ghost: String = "",
    val listening: Boolean = false,
    val ctrl: Boolean = false,
)

/**
 * The phone side of Eink Focus. Polls each computer over SSH for a Kindle's tmux client,
 * keeps one key loop open to that session, and moves the Kindle between sessions and
 * computers the way the Mac app does.
 */
class FocusEngine(
    private val config: PhoneConfig,
    privateKey: ByteArray,
    knownHosts: File,
) {
    private val _state = MutableStateFlow(FocusState(computers = config.computers))
    val state: StateFlow<FocusState> = _state

    private val links = config.readyComputers.associate { it.id to SshLink(it, privateKey, knownHosts) }
    private var scope: CoroutineScope? = null
    private var ops = Channel<Op>(Channel.UNLIMITED)
    private var pipe: KeyPipe? = null
    private var pipeKey: String? = null
    private var preferDevice: String? = null
    private var movingFrom: String? = null
    private var movingSince = 0L
    private var noticeJob: Job? = null

    /** Diagnostics sink. The app points it at android.util.Log. */
    var log: ((String) -> Unit)? = null

    private data class Probe(val computer: Computer, val clients: List<Protocol.Client>?, val error: String?)

    private fun describe(e: Throwable): String {
        val root = generateSequence(e) { it.cause }.last()
        val name = root::class.java.simpleName
        return if (root.message.isNullOrBlank()) name else "$name: ${root.message}"
    }

    private sealed class Op {
        data class Text(val text: String) : Op()
        data class Key(val name: String) : Op()
    }

    fun start() {
        if (scope != null) return
        val s = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        scope = s
        ops = Channel(Channel.UNLIMITED)
        _state.update { it.copy(searching = it.target == null) }
        s.launch {
            while (isActive) {
                probe()
                val st = _state.value
                delay(if (st.target == null || st.moving != null) 700 else 2000)
            }
        }
        s.launch { for (op in ops) deliver(op) }
    }

    /** Closing a channel writes to the socket, so it happens off the caller's (main) thread. */
    fun stop() {
        scope?.cancel()
        scope = null
        ops.close()
        val open = pipe
        pipe = null
        pipeKey = null
        CoroutineScope(Dispatchers.IO).launch {
            runCatching { open?.close() }
            links.values.forEach { runCatching { it.close() } }
        }
    }

    // ----- typing -----

    /** True when [text] was queued as typing. False when no Kindle took it or sticky ctrl turned it into a key. */
    fun typeText(text: String): Boolean {
        if (text.isEmpty()) return true
        val st = _state.value
        if (st.ctrl && text.length == 1 && text[0].isLetter()) {
            _state.update { it.copy(ctrl = false) }
            sendKey("C-" + text.lowercase())
            return false
        }
        if (text == "\n") {
            sendKey("Enter")
            return false
        }
        if (st.target == null) return false
        _state.update { it.copy(line = it.line + text) }
        ops.trySend(Op.Text(text))
        return true
    }

    fun sendKey(name: String) {
        if (_state.value.target == null) return
        _state.update {
            it.copy(
                line = when (name) {
                    "Enter", "C-c", "C-u", "Escape" -> ""
                    "BSpace" -> it.line.dropLast(1)
                    else -> it.line
                },
                ctrl = false,
            )
        }
        ops.trySend(Op.Key(name))
    }

    fun toggleCtrl() = _state.update { it.copy(ctrl = !it.ctrl) }

    // ----- dictation -----

    fun setListening(on: Boolean) = _state.update { it.copy(listening = on, ghost = if (on) it.ghost else "") }

    fun dictating(partial: String) = _state.update { it.copy(ghost = partial) }

    /** A settled phrase. A space keeps it apart from what came before. Return is never pressed. */
    fun dictated(text: String) {
        val clean = text.trim()
        _state.update { it.copy(ghost = "") }
        if (clean.isEmpty()) return
        val line = _state.value.line
        val spaced = if (line.isNotEmpty() && !line.endsWith(" ")) " $clean" else clean
        typeText(spaced)
    }

    // ----- sessions and computers -----

    fun nextSession() {
        val s = scope ?: return
        val t = _state.value.target ?: return notice("No Kindle is attached yet.")
        val link = links[t.computer.id] ?: return
        s.launch {
            val names = runCatching { link.exec(Protocol.listSessionsCommand(t.computer.tmux)).text }
                .getOrDefault("")
                .lines().map { it.trim() }.filter { it.isNotEmpty() }
            if (names.size < 2) return@launch notice("Only one tmux session: ${t.session}.")
            val index = names.indexOf(t.session)
            val next = names[(index + 1) % names.size]
            val ok = runCatching {
                link.exec(Protocol.switchClientCommand(t.computer.tmux, t.client, next)).status == 0
            }.getOrDefault(false)
            if (!ok) return@launch notice("Could not switch to $next.")
            resetPipe()
            _state.update { st -> st.copy(target = st.target?.copy(session = next), line = "") }
        }
    }

    /** Move one step along the hosts list. */
    fun stepComputer(forward: Boolean) {
        val t = _state.value.target ?: return notice("No Kindle to move.")
        val ready = config.readyComputers
        if (ready.size < 2) return notice("Only one computer is set up.")
        val here = ready.indexOfFirst { it.id == t.computer.id }
        val next = ready[((if (here < 0) 0 else here) + (if (forward) 1 else ready.size - 1)) % ready.size]
        requestMove(if (forward) "next" else "prev", next.label)
    }

    /** Move straight to one computer, by its place among the ready rows. */
    fun moveTo(computer: Computer) {
        val t = _state.value.target ?: return notice("No Kindle to move.")
        if (!computer.ready) return notice("${computer.label} is not set up yet.")
        if (computer.id == t.computer.id) return
        val index = config.readyIndex(computer.id) ?: return
        requestMove(index.toString(), computer.label)
    }

    private fun requestMove(token: String, label: String) {
        val s = scope ?: return
        val t = _state.value.target ?: return
        val link = links[t.computer.id] ?: return
        _state.update { it.copy(moving = "Moving to $label.") }
        s.launch {
            val out = runCatching {
                link.exec(Protocol.switchScript(t.computer.tmux, t.client, token), timeoutMs = 5000).text
            }.getOrDefault("")
            when (Protocol.parseSwitch(out)) {
                Protocol.SwitchResult.SENT -> {
                    movingFrom = t.computer.id
                    movingSince = System.currentTimeMillis()
                    resetPipe()
                    _state.update { it.copy(target = null, line = "") }
                }
                Protocol.SwitchResult.OLD_LOGIN -> {
                    _state.update { it.copy(moving = null) }
                    notice("This login can't switch yet.\nLeave it and pick a computer once.\nAfter that, ‹ and › move the Kindle.")
                }
                Protocol.SwitchResult.FAILED -> {
                    _state.update { it.copy(moving = null) }
                    notice("Could not move the Kindle.")
                }
            }
        }
    }

    /** With two Kindles logged in, choose which one receives keys. */
    fun nextKindle() {
        val st = _state.value
        val devices = st.kindles.map { it.device }.distinct()
        if (devices.size < 2) return notice(if (devices.isEmpty()) "No Kindle is attached." else "Only the ${config.deviceLabel(devices[0])} is connected.")
        val current = st.target?.device ?: devices[0]
        preferDevice = devices[(devices.indexOf(current) + 1) % devices.size]
        val hit = st.kindles.first { it.device == preferDevice }
        _state.update { it.copy(target = hit, line = "") }
        scope?.launch { resetPipe() }
    }

    // ----- internals -----

    private suspend fun probe() = coroutineScope {
        val results = config.readyComputers.map { computer ->
            async {
                val link = links.getValue(computer.id)
                var error: String? = null
                val text = withTimeoutOrNull(7000) {
                    runInterruptible {
                        runCatching { link.exec(Protocol.probeCommand(computer.tmux), timeoutMs = 4000).text }
                            .onFailure {
                                error = describe(it)
                                runCatching { link.close() }
                            }
                            .getOrNull()
                    }
                }
                if (text == null && error == null) error = "No answer in 7 seconds."
                val clients = text?.let { Protocol.parseProbe(it, config.kindles) }
                if (text != null && clients == null) error = "Unexpected reply: ${text.take(120)}"
                Probe(computer, clients, error)
            }
        }.awaitAll()

        val online = results.associate { it.computer.id to (it.clients != null) }
        val errors = results.mapNotNull { r -> r.error?.let { r.computer.id to it } }.toMap()
        errors.forEach { (id, why) -> log?.invoke("probe $id: $why") }
        val found = results.flatMap { (c, clients) ->
            clients.orEmpty().map { Target(c, it.device, it.client, it.session, config.deviceLabel(it.device)) }
        }
        val st = _state.value
        val current = st.target
        val keep = current?.let { cur -> found.firstOrNull { it.computer.id == cur.computer.id && it.client == cur.client } }
        var pick = keep
            ?: preferDevice?.let { d -> found.firstOrNull { it.device == d } }
            ?: found.firstOrNull()

        var moving = st.moving
        val from = movingFrom
        if (from != null) {
            val arrived = pick != null && pick.computer.id != from
            val gaveUp = System.currentTimeMillis() - movingSince > 25_000
            if (arrived || gaveUp) {
                movingFrom = null
                moving = null
                if (gaveUp && !arrived) notice("The Kindle did not show up on another computer.")
            } else {
                pick = null
            }
        }

        if (pick?.computer?.id != current?.computer?.id || pick?.session != current?.session || pick?.client != current?.client) {
            resetPipe()
        }
        _state.update {
            it.copy(
                online = online,
                errors = errors,
                kindles = found,
                target = pick,
                searching = false,
                moving = moving,
                line = if (pick == null) "" else it.line,
            )
        }
    }

    private fun deliver(op: Op) {
        val t = _state.value.target ?: return
        val lines = when (op) {
            is Op.Text -> Protocol.encodeText(op.text)
            is Op.Key -> listOf(Protocol.encodeKey(op.name))
        }
        for (attempt in 0..1) {
            val p = ensurePipe(t) ?: return notice("Could not reach ${t.computer.label}.")
            if (p.send(lines)) return
            resetPipe()
            links[t.computer.id]?.let { runCatching { it.close() } }
        }
        notice("Lost the connection to ${t.computer.label}.")
    }

    @Synchronized
    private fun ensurePipe(t: Target): KeyPipe? {
        val key = "${t.computer.id}:${t.session}"
        val open = pipe
        if (open != null && open.isOpen && pipeKey == key) return open
        open?.close()
        pipe = null
        val link = links[t.computer.id] ?: return null
        return runCatching { link.openPipe(Protocol.keyLoopScript(t.computer.tmux, t.session)) }
            .getOrNull()
            ?.also {
                pipe = it
                pipeKey = key
            }
    }

    @Synchronized
    private fun resetPipe() {
        pipe?.close()
        pipe = null
        pipeKey = null
    }

    fun showNotice(text: String) = notice(text)

    private fun notice(text: String) {
        _state.update { it.copy(notice = text) }
        noticeJob?.cancel()
        noticeJob = scope?.launch {
            delay(4000)
            _state.update { if (it.notice == text) it.copy(notice = null) else it }
        }
    }
}

package dev.eterm.focus.core

/**
 * Shell commands and wire formats shared with the Mac app (mac/EinkFocus.swift).
 *
 * Every remote command starts with a UTF-8 LC_CTYPE. tmux 3.7 prints the tabs in a
 * -F format as "_" without one, and nothing on the phone sends LC_* over SSH, so a
 * Mac login from here would otherwise get LC_CTYPE="C" and no Kindle would be found.
 */
object Protocol {
    const val LOCALE = "export LC_CTYPE=en_US.UTF-8; "

    fun shellQuote(value: String): String = "'" + value.replace("'", "'\\''") + "'"

    /**
     * sshd runs commands in the login shell, which is zsh on these Macs. zsh does not split
     * an unquoted $rest into words, so `send-keys -H $rest` would get one bad argument.
     * Scripts that rely on sh word splitting run under /bin/sh explicitly.
     */
    private fun posix(script: String): String = LOCALE + "exec /bin/sh -c " + shellQuote(script)

    /** Logins with their source address, then the tmux clients. Same split as the Mac. */
    fun probeCommand(tmux: String): String =
        LOCALE + "who; echo ---; ${shellQuote(tmux)} list-clients -F '#{client_tty}\t#{client_name}\t#{session_name}'"

    fun listSessionsCommand(tmux: String): String =
        LOCALE + "${shellQuote(tmux)} list-sessions -F '#{session_name}'"

    fun switchClientCommand(tmux: String, client: String, session: String): String =
        LOCALE + "${shellQuote(tmux)} switch-client -c ${shellQuote(client)} -t ${shellQuote(session)}"

    /**
     * One long-lived shell per session. Lines are "K <tmux key name>" or "H <hex bytes>".
     * The Mac app's LocalKeys and RemoteKeys run the same loop.
     */
    fun keyLoopScript(tmux: String, session: String): String = posix("""
        S=${shellQuote(session)}
        TMUX=${shellQuote(tmux)}
        "${'$'}TMUX" has-session -t "${'$'}S" </dev/null || exit 3
        while IFS= read -r line; do
          kind=${'$'}{line%% *}
          rest=${'$'}{line#* }
          case "${'$'}kind" in
            K) "${'$'}TMUX" send-keys -t "${'$'}S" "${'$'}rest" </dev/null ;;
            H) "${'$'}TMUX" send-keys -t "${'$'}S" -H ${'$'}rest </dev/null ;;
          esac
        done
    """.trimIndent())

    /**
     * Ask connect.sh on the Kindle to move to another computer: write the token to
     * ~/.eterm-switch and detach the Kindle's client. A login started by the old
     * connect.sh has no eterm-switch marker, so it answers "old" and nothing happens.
     */
    fun switchScript(tmux: String, client: String, token: String): String {
        val clean = token.lowercase().filter { it.isLetterOrDigit() }.take(8).ifEmpty { "next" }
        val tmuxQ = shellQuote(tmux)
        val clientQ = shellQuote(client)
        val tokenQ = shellQuote(clean)
        return posix("""
            tty=${'$'}($tmuxQ display-message -p -c $clientQ '#{client_tty}' 2>/dev/null || true)
            short=${'$'}{tty#/dev/}
            cmd=${'$'}(ps -t "${'$'}short" -o command= 2>/dev/null || true)
            case "${'$'}cmd" in
              *eterm-switch*)
                printf '%s\n' $tokenQ > "${'$'}HOME/.eterm-switch"
                if $tmuxQ detach-client -t $clientQ; then
                  echo sent
                else
                  rm -f "${'$'}HOME/.eterm-switch"
                  echo fail
                fi
                ;;
              *)
                echo old
                ;;
            esac
        """.trimIndent())
    }

    /** Text goes as hex in 48-byte lines, like the Mac, so quotes and UTF-8 survive the shell. */
    fun encodeText(text: String): List<String> {
        val bytes = text.toByteArray(Charsets.UTF_8)
        return bytes.toList().chunked(48).map { chunk ->
            "H " + chunk.joinToString(" ") { "%02x".format(it.toInt() and 0xff) }
        }
    }

    fun encodeKey(name: String): String = "K $name"

    enum class SwitchResult { SENT, OLD_LOGIN, FAILED }

    fun parseSwitch(output: String): SwitchResult = when {
        output.contains("sent") -> SwitchResult.SENT
        output.contains("old") -> SwitchResult.OLD_LOGIN
        else -> SwitchResult.FAILED
    }

    /** A Kindle's tmux client on one computer. */
    data class Client(val tty: String, val client: String, val session: String, val device: String)

    /**
     * Port of the Mac app's remoteSightings: a tmux client counts when its tty is an SSH
     * login from a Kindle's Tailscale address. Returns null when the output is not a probe reply.
     */
    fun parseProbe(output: String, kindles: Map<String, String>): List<Client>? {
        // A leading newline lets an empty `who` still split into two parts.
        val chunks = ("\n" + output).split("\n---\n")
        if (chunks.size != 2) return null
        val (whoPart, clientPart) = chunks
        val ttyIp = mutableMapOf<String, String>()
        for (line in whoPart.lines()) {
            val open = line.lastIndexOf('(')
            val close = line.lastIndexOf(')')
            if (open < 0 || close <= open) continue
            val raw = line.substring(open + 1, close)
            val ip = raw.substringBefore('%')
            val known = if (kindles.isEmpty()) ip.startsWith("100.") else ip in kindles
            if (!known) continue
            val parts = line.trim().split(Regex("[ \t]+"))
            if (parts.size < 2) continue
            ttyIp[parts[1]] = ip
            ttyIp["/dev/" + parts[1]] = ip
        }
        if (ttyIp.isEmpty()) return emptyList()
        val found = mutableListOf<Client>()
        for (line in clientPart.lines()) {
            val bits = line.split('\t')
            if (bits.size != 3) continue
            val tty = bits[0]
            val ip = ttyIp[tty] ?: ttyIp[tty.removePrefix("/dev/")] ?: continue
            found += Client(tty = tty, client = bits[1], session = bits[2], device = kindles[ip] ?: ip)
        }
        return found
    }
}

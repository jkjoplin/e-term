package dev.eterm.focus.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProtocolTest {
    private val kindles = mapOf("100.64.0.11" to "kindle", "100.64.0.12" to "scribe")

    private val who = """
        alice            console      Oct  5 21:29
        alice            ttys000      Nov  6 22:35 (100.64.0.11)
        alice            ttys003      Nov  6 22:40 (100.64.0.20)
    """.trimIndent()

    @Test
    fun findsTheKindleClient() {
        val out = who + "\n---\n" + "/dev/ttys000\t/dev/ttys000\teink\n/dev/ttys003\t/dev/ttys003\twork\n"
        val found = Protocol.parseProbe(out, kindles)!!
        assertEquals(1, found.size)
        assertEquals("kindle", found[0].device)
        assertEquals("eink", found[0].session)
        assertEquals("/dev/ttys000", found[0].client)
    }

    /** What tmux 3.7c prints without a UTF-8 locale. The probe must not invent a match from it. */
    @Test
    fun underscoredOutputFindsNothing() {
        val out = who + "\n---\n" + "/dev/ttys000_/dev/ttys000_eink\n"
        assertEquals(emptyList<Protocol.Client>(), Protocol.parseProbe(out, kindles))
    }

    @Test
    fun emptyWhoStillParses() {
        assertEquals(emptyList<Protocol.Client>(), Protocol.parseProbe("---\n", kindles))
    }

    @Test
    fun nonProbeOutputIsNull() {
        assertNull(Protocol.parseProbe("ssh: connect to host failed", kindles))
    }

    @Test
    fun everyCommandSetsTheLocale() {
        val tmux = "/opt/homebrew/bin/tmux"
        listOf(
            Protocol.probeCommand(tmux),
            Protocol.listSessionsCommand(tmux),
            Protocol.switchClientCommand(tmux, "/dev/ttys000", "eink"),
            Protocol.keyLoopScript(tmux, "eink"),
            Protocol.switchScript(tmux, "/dev/ttys000", "next"),
        ).forEach { assertTrue(it, it.startsWith("export LC_CTYPE=en_US.UTF-8; ")) }
        assertTrue(Protocol.probeCommand(tmux).contains("#{client_tty}\t#{client_name}\t#{session_name}"))
    }

    @Test
    fun textIsHexInChunks() {
        assertEquals(listOf("H 68 69"), Protocol.encodeText("hi"))
        assertEquals(listOf("H c3 a9"), Protocol.encodeText("é"))
        val long = Protocol.encodeText("x".repeat(100))
        assertEquals(3, long.size)
        assertEquals(48, long[0].removePrefix("H ").split(" ").size)
        assertEquals("K Enter", Protocol.encodeKey("Enter"))
    }

    @Test
    fun switchTokensAreCleaned() {
        val script = Protocol.switchScript("/t", "/dev/ttys000", "N;rm -rf ~")
        // Inside the sh -c quoting, the token's own quotes are escaped as '\''.
        assertTrue(script, script.contains("printf '\\''%s\\n'\\'' '\\''nrmrf'\\''"))
        assertTrue(script.contains("exec /bin/sh -c '"))
        assertEquals(Protocol.SwitchResult.SENT, Protocol.parseSwitch("sent\n"))
        assertEquals(Protocol.SwitchResult.OLD_LOGIN, Protocol.parseSwitch("old\n"))
        assertEquals(Protocol.SwitchResult.FAILED, Protocol.parseSwitch(""))
    }

    @Test
    fun configKeepsHostOrderAndReadyIndex() {
        val cfg = PhoneConfig.parse(
            """
            {"kindles": {"kindle": "100.64.0.11"},
             "labels": {"kindle": "Paperwhite"},
             "computers": [
               {"id": "personal", "label": "MacBook Pro", "user": "u", "host": "a.ts.net"},
               {"id": "work", "label": "Work laptop", "user": "u", "host": "REPLACE"},
               {"id": "mini", "label": "Mac mini", "user": "u", "host": "b.ts.net", "tmux": "/usr/local/bin/tmux"}
             ]}
            """.trimIndent(),
        )
        assertEquals(listOf("personal", "work", "mini"), cfg.computers.map { it.id })
        assertEquals(listOf("personal", "mini"), cfg.readyComputers.map { it.id })
        assertEquals(1, cfg.readyIndex("mini"))
        assertNull(cfg.readyIndex("work"))
        assertEquals(PhoneConfig.DEFAULT_TMUX, cfg.computers[0].tmux)
        assertEquals("kindle", cfg.kindles["100.64.0.11"])
        assertEquals("Paperwhite", cfg.deviceLabel("kindle"))
        // A Kindle with no label shows its hostname.
        assertEquals("scribe", cfg.deviceLabel("scribe"))
    }
}

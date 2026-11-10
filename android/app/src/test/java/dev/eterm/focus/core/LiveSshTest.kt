package dev.eterm.focus.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * Runs against a real Mac over SSH. Skipped unless EF_LIVE_HOST is set:
 *
 *   EF_LIVE_HOST=mac.example.ts.net EF_LIVE_USER=me EF_LIVE_KEY=../ssh/kindle_eterm ./gradlew testDebugUnitTest
 *
 * It only reads the Kindle's session. Typing goes to a scratch session it creates and kills.
 */
class LiveSshTest {
    private val host = System.getenv("EF_LIVE_HOST")
    private val user = System.getenv("EF_LIVE_USER") ?: System.getProperty("user.name")
    private val keyPath = System.getenv("EF_LIVE_KEY")
    private val tmux = System.getenv("EF_LIVE_TMUX") ?: PhoneConfig.DEFAULT_TMUX

    private fun link(): SshLink {
        assumeTrue("EF_LIVE_HOST not set", !host.isNullOrBlank() && !keyPath.isNullOrBlank())
        val known = Files.createTempFile("ef-known", "").toFile().also { it.writeText("") }
        val computer = Computer("live", "Live", user, host!!, 22, tmux)
        return SshLink(computer, File(keyPath!!).readBytes(), known)
    }

    @Test
    fun probeKeepsTabsAndParses() {
        val link = link()
        try {
            val out = link.exec(Protocol.probeCommand(tmux)).text
            val clients = out.substringAfter("\n---\n", "")
            if (clients.isNotBlank()) {
                assertTrue("tmux replaced the tabs: $clients", clients.contains('\t'))
            }
            val parsed = Protocol.parseProbe(out, emptyMap())
            assertTrue("probe reply did not parse: $out", parsed != null)
            println("live probe: $parsed")
        } finally {
            link.close()
        }
    }

    @Test
    fun keyLoopTypesIntoAScratchSession() {
        val link = link()
        val session = "ef-test-${System.currentTimeMillis() % 100000}"
        try {
            link.exec(Protocol.LOCALE + "${Protocol.shellQuote(tmux)} new-session -d -s $session -x 120 -y 20 'cat'")
            val pipe = link.openPipe(Protocol.keyLoopScript(tmux, session))
            assertTrue(pipe.send(Protocol.encodeText("héllo-ef 'quoted'")))
            Thread.sleep(800)
            val screen = link.exec(Protocol.LOCALE + "${Protocol.shellQuote(tmux)} capture-pane -p -t $session").text
            pipe.close()
            assertTrue("screen was: $screen", screen.contains("héllo-ef 'quoted'"))
        } finally {
            link.exec("${Protocol.shellQuote(tmux)} kill-session -t $session")
            link.close()
        }
    }

    /** The engine finds a logged-in Kindle on its own. Read only: nothing is typed. */
    @Test
    fun engineFindsAKindle() {
        assumeTrue("EF_LIVE_HOST not set", !host.isNullOrBlank() && !keyPath.isNullOrBlank())
        val known = Files.createTempFile("ef-known", "").toFile().also { it.writeText("") }
        val config = PhoneConfig(listOf(Computer("live", "Live", user, host!!, 22, tmux)), emptyMap())
        val engine = FocusEngine(config, File(keyPath!!).readBytes(), known)
        engine.start()
        try {
            val deadline = System.currentTimeMillis() + 10_000
            while (engine.state.value.searching && System.currentTimeMillis() < deadline) Thread.sleep(100)
            val st = engine.state.value
            println("live engine: online=${st.online} target=${st.target}")
            assertEquals(true, st.online["live"])
            if (st.kindles.isNotEmpty()) assertEquals(st.kindles.first(), st.target)
        } finally {
            engine.stop()
        }
    }

    @Test
    fun listSessionsAnswers() {
        val link = link()
        try {
            val result = link.exec(Protocol.listSessionsCommand(tmux))
            assertEquals(0, result.status)
        } finally {
            link.close()
        }
    }
}

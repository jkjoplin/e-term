package dev.eterm.focus.core

import com.jcraft.jsch.HostKeyRepository
import com.jcraft.jsch.JSch
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.File
import java.util.concurrent.CountDownLatch
import kotlin.concurrent.thread
import kotlin.random.Random
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class HostKeyStoreTest {
    private fun ed25519Blob(seed: Int): ByteArray {
        val out = ByteArrayOutputStream()
        DataOutputStream(out).apply {
            val type = "ssh-ed25519".toByteArray()
            writeInt(type.size); write(type)
            writeInt(32); write(Random(seed).nextBytes(32))
        }
        return out.toByteArray()
    }

    @Test
    fun linksPinningAtOnceKeepEveryHost() {
        SshSetup.configure()
        val file = File.createTempFile("known_hosts", "").apply { delete(); deleteOnExit() }
        val hosts = (1..8).map { "host$it.example" }
        val start = CountDownLatch(1)
        val workers = hosts.mapIndexed { i, host ->
            thread {
                // Each link asks for the store itself, as SshLink does.
                val store = HostKeyStore.forFile(file)
                start.await()
                assertEquals(HostKeyRepository.OK, store.check(host, ed25519Blob(i)))
            }
        }
        start.countDown()
        workers.forEach { it.join() }

        assertSame(HostKeyStore.forFile(file), HostKeyStore.forFile(file))
        // A fresh read of the file, as the next launch would do, has every host pinned.
        val reread = JSch().apply { setKnownHosts(file.absolutePath) }.hostKeyRepository
        hosts.forEachIndexed { i, host ->
            assertEquals(host, HostKeyRepository.OK, reread.check(host, ed25519Blob(i)))
        }
        // A pinned host that shows a different key is refused.
        assertEquals(HostKeyRepository.CHANGED, HostKeyStore.forFile(file).check(hosts[0], ed25519Blob(99)))
    }
}

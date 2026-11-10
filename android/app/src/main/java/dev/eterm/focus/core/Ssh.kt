package dev.eterm.focus.core

import com.jcraft.jsch.ChannelExec
import com.jcraft.jsch.HostKey
import com.jcraft.jsch.HostKeyRepository
import com.jcraft.jsch.JSch
import com.jcraft.jsch.Session
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.OutputStream

data class ExecResult(val text: String, val status: Int)

object SshSetup {
    @Volatile private var done = false

    /**
     * Android has no JDK Ed25519 or X25519, and JSch's JDK versions of those live in
     * multi-release jar folders Android never loads. Point JSch at BouncyCastle on every
     * platform so the JVM tests exercise the same code the phone runs.
     */
    fun configure() {
        if (done) return
        synchronized(this) {
            if (done) return
            JSch.setConfig("ssh-ed25519", "com.jcraft.jsch.bc.SignatureEd25519")
            JSch.setConfig("ssh-ed448", "com.jcraft.jsch.bc.SignatureEd448")
            JSch.setConfig("keypairgen.eddsa", "com.jcraft.jsch.bc.KeyPairGenEdDSA")
            JSch.setConfig("xdh", "com.jcraft.jsch.bc.XDH")
            JSch.setConfig("mlkem768", "com.jcraft.jsch.bc.MLKEM768")
            JSch.setConfig("mlkem1024", "com.jcraft.jsch.bc.MLKEM1024")
            done = true
        }
    }
}

/**
 * One SSH connection to one computer, opened on first use and reopened after a drop.
 * Host keys are trusted on first use and pinned in [knownHosts], like the Mac's
 * StrictHostKeyChecking=accept-new.
 */
class SshLink(
    val computer: Computer,
    private val privateKey: ByteArray,
    private val knownHosts: File,
    private val connectTimeoutMs: Int = 5000,
) {
    private val jsch: JSch
    private var session: Session? = null

    init {
        SshSetup.configure()
        jsch = JSch()
        jsch.hostKeyRepository = HostKeyStore.forFile(knownHosts)
        jsch.addIdentity("kindle_eterm", privateKey, null, null)
    }

    @Synchronized
    private fun connected(): Session {
        session?.let { if (it.isConnected) return it }
        val s = jsch.getSession(computer.user, computer.host, computer.port)
        s.setConfig("StrictHostKeyChecking", "yes")
        s.setConfig("PreferredAuthentications", "publickey")
        s.setServerAliveInterval(15_000)
        s.setServerAliveCountMax(2)
        s.connect(connectTimeoutMs)
        session = s
        return s
    }

    /** Runs one command and returns stdout. A hung command is cut off at [timeoutMs]. */
    fun exec(command: String, timeoutMs: Long = 4000): ExecResult {
        val channel = connected().openChannel("exec") as ChannelExec
        channel.setCommand(command)
        channel.setInputStream(null)
        val input = channel.inputStream
        channel.connect(connectTimeoutMs)
        val out = ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        val deadline = System.currentTimeMillis() + timeoutMs
        val status: Int
        try {
            while (true) {
                while (input.available() > 0) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    out.write(buffer, 0, n)
                }
                if (channel.isClosed) {
                    if (input.available() > 0) continue
                    break
                }
                if (System.currentTimeMillis() > deadline) break
                Thread.sleep(15)
            }
            status = if (channel.isClosed) channel.exitStatus else -1
        } finally {
            channel.disconnect()
        }
        return ExecResult(out.toString(Charsets.UTF_8.name()), status)
    }

    /** A long-lived command with an open stdin, for the key loop. */
    fun openPipe(command: String): KeyPipe {
        val channel = connected().openChannel("exec") as ChannelExec
        channel.setCommand(command)
        val stdin = channel.outputStream
        channel.connect(connectTimeoutMs)
        return KeyPipe(channel, stdin)
    }

    @Synchronized
    fun close() {
        session?.disconnect()
        session = null
    }
}

class KeyPipe(private val channel: ChannelExec, private val stdin: OutputStream) {
    val isOpen: Boolean get() = channel.isConnected && !channel.isClosed

    /** Writes the lines and flushes. False means the pipe is gone and must be reopened. */
    fun send(lines: List<String>): Boolean = try {
        for (line in lines) stdin.write((line + "\n").toByteArray(Charsets.UTF_8))
        stdin.flush()
        true
    } catch (_: Exception) {
        false
    }

    fun close() {
        try { stdin.close() } catch (_: Exception) {}
        channel.disconnect()
    }
}

/**
 * One pinned-key store per known_hosts file, shared by every link. Each JSch known_hosts
 * rewrites the whole file when it adds a key, so separate copies racing on first launch
 * dropped each other's entries.
 */
internal object HostKeyStore {
    private val stores = HashMap<String, HostKeyRepository>()

    @Synchronized
    fun forFile(file: File): HostKeyRepository = stores.getOrPut(file.absolutePath) {
        if (!file.exists()) {
            file.parentFile?.mkdirs()
            file.writeText("")
        }
        val loader = JSch()
        loader.setKnownHosts(file.absolutePath)
        TrustOnFirstUse(loader.hostKeyRepository)
    }
}

/** Accepts and pins an unknown host key. A changed key is still refused. */
private class TrustOnFirstUse(private val pinned: HostKeyRepository) : HostKeyRepository by pinned {
    @Synchronized
    override fun check(host: String, key: ByteArray): Int {
        val result = pinned.check(host, key)
        if (result != HostKeyRepository.NOT_INCLUDED) return result
        pinned.add(HostKey(host, key), null)
        return HostKeyRepository.OK
    }
}

package dev.eterm.focus.core

import org.json.JSONObject

/** One computer the Kindle can log into, in the same order as the Kindle's hosts file. */
data class Computer(
    val id: String,
    val label: String,
    val user: String,
    val host: String,
    val port: Int,
    val tmux: String,
) {
    /** A REPLACE row is shown on the card but cannot be reached. */
    val ready: Boolean get() = host.isNotBlank() && host != "REPLACE" && host != "REPLACE_ME"
}

/**
 * Phone settings, pushed into the app's private files by android/provision.sh.
 * kindles maps a Kindle's Tailscale address to its Tailscale hostname.
 * labels maps a hostname to the name shown on the card. docs/configuration.md has the format.
 */
data class PhoneConfig(
    val computers: List<Computer>,
    val kindles: Map<String, String>,
    val labels: Map<String, String> = emptyMap(),
) {
    /** The card's name for a Kindle: its label, or its hostname when it has none. */
    fun deviceLabel(name: String): String = labels[name] ?: name

    val readyComputers: List<Computer> get() = computers.filter { it.ready }

    /** Position among ready rows, counted from zero. connect.sh uses this number to pick a host. */
    fun readyIndex(id: String): Int? = readyComputers.indexOfFirst { it.id == id }.takeIf { it >= 0 }

    companion object {
        const val DEFAULT_TMUX = "/opt/homebrew/bin/tmux"

        fun parse(text: String): PhoneConfig {
            val json = JSONObject(text)
            val rows = json.optJSONArray("computers") ?: throw IllegalArgumentException("config has no computers")
            val computers = (0 until rows.length()).map { i ->
                val row = rows.getJSONObject(i)
                Computer(
                    id = row.getString("id"),
                    label = row.optString("label", row.getString("id")),
                    user = row.optString("user", ""),
                    host = row.optString("host", ""),
                    port = row.optInt("port", 22),
                    tmux = row.optString("tmux", "").ifBlank { DEFAULT_TMUX },
                )
            }
            val kindles = mutableMapOf<String, String>()
            json.optJSONObject("kindles")?.let { map ->
                for (name in map.keys()) {
                    val ip = map.optString(name, "")
                    if (ip.isNotBlank()) kindles[ip] = name
                }
            }
            val labels = mutableMapOf<String, String>()
            json.optJSONObject("labels")?.let { map ->
                for (name in map.keys()) {
                    val label = map.optString(name, "")
                    if (label.isNotBlank()) labels[name] = label
                }
            }
            return PhoneConfig(computers, kindles, labels)
        }
    }
}

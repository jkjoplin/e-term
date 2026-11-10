package dev.eterm.focus.ui

import android.content.Context
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import dev.eterm.focus.KeyCaptureView
import dev.eterm.focus.core.Computer
import dev.eterm.focus.core.FocusState

/** Colors from the Mac desk card: a dark frame around a paper panel. */
private object Ink {
    val frame = Color(0xFF0F0F0E)
    val rule = Color(0xFF6F6E69)
    val text = Color(0xFFEDEBE4)
    val dim = Color(0xFF8A8882)
    val faint = Color(0xFF4E4D49)
    val paper = Color(0xFFF1F0EB)
    val onPaper = Color(0xFF2A2A27)
    val ghost = Color(0xFF9A8F78)
    val live = Color(0xFFE9D9A6)
}

class Actions(
    val key: (String) -> Unit,
    val toggleCtrl: () -> Unit,
    val nextSession: () -> Unit,
    val stepComputer: (Boolean) -> Unit,
    val moveTo: (Computer) -> Unit,
    val nextKindle: () -> Unit,
    val toggleMic: () -> Unit,
    val toggleTextMode: () -> Unit,
    val focusKeys: () -> Unit,
)

@Composable
fun FocusScreen(state: FocusState, textMode: Boolean, actions: Actions, makeKeyView: (Context) -> KeyCaptureView) {
    Column(
        Modifier
            .fillMaxSize()
            .background(Ink.frame)
            .safeDrawingPadding()
            .imePadding()
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        Header(state, actions)
        Spacer(Modifier.height(14.dp))
        Computers(state, actions)
        Spacer(Modifier.height(14.dp))
        Panel(state, actions, makeKeyView, Modifier.weight(1f))
        Spacer(Modifier.height(12.dp))
        KeyRow(state, actions)
        Spacer(Modifier.height(10.dp))
        BottomRow(state, textMode, actions)
    }
}

@Composable
private fun Header(state: FocusState, actions: Actions) {
    val target = state.target
    val badge = when {
        target != null -> target.label.uppercase()
        state.searching || state.moving != null -> "KINDLE"
        else -> "NO KINDLE"
    }
    val others = state.kindles.map { it.label.uppercase() }.distinct().filter { it != badge }
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        Text(
            badge,
            color = Ink.text,
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.Bold,
            letterSpacing = 2.sp,
            fontSize = 15.sp,
            modifier = Modifier
                .border(BorderStroke(1.5.dp, Ink.rule), RoundedCornerShape(6.dp))
                .clickable(enabled = others.isNotEmpty()) { actions.nextKindle() }
                .padding(horizontal = 12.dp, vertical = 6.dp),
        )
        others.forEach {
            Spacer(Modifier.width(8.dp))
            Text(it, color = Ink.dim, fontFamily = FontFamily.Monospace, fontSize = 13.sp, letterSpacing = 1.5.sp)
        }
        Spacer(Modifier.weight(1f))
        val place = target?.computer?.label?.uppercase().orEmpty()
        Column(horizontalAlignment = Alignment.End) {
            if (place.isNotEmpty()) Text(place, color = Ink.dim, fontFamily = FontFamily.Monospace, fontSize = 12.sp, letterSpacing = 1.5.sp)
            if (target != null) Text(target.session, color = Ink.text, fontFamily = FontFamily.Monospace, fontSize = 15.sp)
        }
    }
}

@Composable
private fun Computers(state: FocusState, actions: Actions) {
    val here = state.target?.computer?.id
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        Text("‹", color = Ink.text, fontSize = 30.sp, modifier = Modifier.clickable { actions.stepComputer(false) }.padding(horizontal = 8.dp))
        Row(
            Modifier.weight(1f).horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(18.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            state.computers.forEach { c ->
                val online = state.online[c.id]
                val color = when {
                    c.id == here -> Ink.text
                    !c.ready -> Ink.faint
                    online == false -> Ink.faint
                    else -> Ink.dim
                }
                Text(
                    c.label,
                    color = color,
                    fontSize = 17.sp,
                    fontWeight = if (c.id == here) FontWeight.SemiBold else FontWeight.Normal,
                    modifier = Modifier
                        .clip(RoundedCornerShape(6.dp))
                        .clickable(enabled = c.ready && c.id != here) { actions.moveTo(c) }
                        .padding(horizontal = 4.dp, vertical = 4.dp),
                )
            }
        }
        Text("›", color = Ink.text, fontSize = 30.sp, modifier = Modifier.clickable { actions.stepComputer(true) }.padding(horizontal = 8.dp))
    }
    // With no Kindle found, say why each computer did not answer.
    if (state.target == null && state.errors.isNotEmpty()) {
        Column(Modifier.fillMaxWidth().padding(top = 8.dp, start = 8.dp, end = 8.dp)) {
            state.computers.forEach { c ->
                state.errors[c.id]?.let { why ->
                    Text("${c.label}: $why", color = Ink.dim, fontSize = 12.sp, fontFamily = FontFamily.Monospace, maxLines = 2)
                }
            }
        }
    }
}

@Composable
private fun Panel(state: FocusState, actions: Actions, makeKeyView: (Context) -> KeyCaptureView, modifier: Modifier) {
    Box(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(20.dp))
            .background(Ink.paper)
            .clickable { actions.focusKeys() },
        contentAlignment = Alignment.Center,
    ) {
        // Holds the soft keyboard. It draws nothing; the text below is the card.
        AndroidView(factory = makeKeyView, modifier = Modifier.fillMaxSize())
        val waiting = when {
            state.notice != null -> state.notice
            state.moving != null -> state.moving
            state.target == null && state.searching -> "Finding the Kindle."
            state.target == null -> "Open Terminal on the Kindle\nand pick a computer."
            else -> null
        }
        if (waiting != null) {
            Text(waiting, color = Ink.onPaper, fontSize = 20.sp, textAlign = TextAlign.Center, lineHeight = 28.sp, modifier = Modifier.padding(24.dp))
        } else {
            val shown = buildAnnotatedString {
                append(state.line.takeLast(400))
                if (state.ghost.isNotEmpty()) {
                    withStyle(SpanStyle(color = Ink.ghost)) {
                        if (state.line.isNotEmpty() && !state.line.endsWith(" ")) append(" ")
                        append(state.ghost)
                    }
                }
                append("▏")
            }
            Text(
                shown,
                color = Ink.onPaper,
                fontSize = 20.sp,
                fontFamily = FontFamily.Monospace,
                lineHeight = 28.sp,
                modifier = Modifier.fillMaxWidth().padding(22.dp),
            )
        }
    }
}

@Composable
private fun Keycap(label: String, modifier: Modifier = Modifier, lit: Boolean = false, onClick: () -> Unit) {
    Box(
        modifier
            .clip(RoundedCornerShape(9.dp))
            .background(if (lit) Ink.live else Color.Transparent)
            .border(BorderStroke(1.dp, Ink.rule), RoundedCornerShape(9.dp))
            // Keys must not take focus from the key view, or the soft keyboard closes.
            .focusProperties { canFocus = false }
            .clickable(onClick = onClick)
            .padding(vertical = 10.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            color = if (lit) Ink.frame else Ink.text,
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.Bold,
            fontSize = 15.sp,
        )
    }
}

@Composable
private fun KeyRow(state: FocusState, actions: Actions) {
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.fillMaxWidth()) {
        Keycap("esc", Modifier.weight(1.2f)) { actions.key("Escape") }
        Keycap("tab", Modifier.weight(1.2f)) { actions.key("Tab") }
        Keycap("ctrl", Modifier.weight(1.3f), lit = state.ctrl) { actions.toggleCtrl() }
        Keycap("←", Modifier.weight(1f)) { actions.key("Left") }
        Keycap("↑", Modifier.weight(1f)) { actions.key("Up") }
        Keycap("↓", Modifier.weight(1f)) { actions.key("Down") }
        Keycap("→", Modifier.weight(1f)) { actions.key("Right") }
        Keycap("⏎", Modifier.weight(1.2f)) { actions.key("Enter") }
    }
}

@Composable
private fun BottomRow(state: FocusState, textMode: Boolean, actions: Actions) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
        Keycap("^c", Modifier.weight(1f)) { actions.key("C-c") }
        Keycap("session ▸", Modifier.weight(2f)) { actions.nextSession() }
        // Lit: the phone keyboard's own voice typing, autocorrect and swipe are on.
        Keycap("text", Modifier.weight(1.3f), lit = textMode) { actions.toggleTextMode() }
        Keycap(if (state.listening) "● done" else "dictate", Modifier.weight(1.7f), lit = state.listening) { actions.toggleMic() }
    }
}

@Composable
fun SetupScreen(reason: String) {
    Box(
        Modifier.fillMaxSize().background(Ink.frame).safeDrawingPadding().padding(24.dp),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            Modifier.clip(RoundedCornerShape(20.dp)).background(Ink.paper).padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Eink Focus needs its key and host list.", color = Ink.onPaper, fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
            Text(reason, color = Ink.onPaper, fontSize = 16.sp)
            Text(
                "On the Mac, with this phone plugged in:\n\nandroid/provision.sh",
                color = Ink.onPaper,
                fontSize = 16.sp,
                fontFamily = FontFamily.Monospace,
            )
        }
    }
}

package dev.eterm.focus

import android.content.Context
import android.text.Editable
import android.text.InputType
import android.text.Selection
import android.util.Log
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import android.view.inputmethod.TextAttribute
import dev.eterm.focus.core.lineEdit

/** `adb shell setprop log.tag.EinkFocusIME DEBUG` logs every keyboard call in text mode. */
private const val IME_TAG = "EinkFocusIME"

/** Text mode starts a fresh line past this length, so the copy the keyboard edits stays small. */
private const val LINE_LIMIT = 1000

/** What the capture view hands to the engine. */
interface KeySink {
    /** False when the text was not typed: no Kindle, or sticky ctrl turned it into a key. */
    fun text(text: String): Boolean
    fun key(name: String)
    fun nextComputer()
}

/**
 * An invisible view that owns the soft keyboard. Hardware keyboards arrive through onKeyDown.
 *
 * Terminal mode tells the keyboard this is a visible-password field with no suggestions, the
 * way terminal apps do it, so it sends exact keystrokes. Keyboards turn voice typing off in
 * password fields, though.
 *
 * Text mode is a plain text field, so the keyboard's own voice typing, autocorrect and swipe
 * work. The keyboard edits [line], a copy of what this view typed on the current terminal
 * line, and each change goes to the terminal as backspaces and typing.
 */
class KeyCaptureView(context: Context, private val sink: KeySink) : View(context) {
    private val imm: InputMethodManager = context.getSystemService(InputMethodManager::class.java)

    /** Text mode: the field as the keyboard sees it. Holds only text that was really typed. */
    private val line: Editable = Editable.Factory.getInstance().newEditable("")

    /** Text mode: what the terminal line got from [line] since the last reset. */
    private var shown = ""
    private var batch = 0

    var textMode = false
        set(value) {
            if (field == value) return
            field = value
            clearLine()
            imm.restartInput(this)
        }

    init {
        isFocusable = true
        isFocusableInTouchMode = true
        Selection.setSelection(line, 0)
    }

    fun showKeyboard() {
        requestFocus()
        imm.showSoftInput(this, 0)
    }

    /** Text mode: start a fresh line. Call whenever anything else changes the terminal line. */
    fun forgetLine() {
        if (!textMode || (line.isEmpty() && shown.isEmpty())) return
        clearLine()
        post { imm.restartInput(this) }
    }

    private fun clearLine() {
        BaseInputConnection.removeComposingSpans(line)
        line.clear()
        Selection.setSelection(line, 0)
        shown = ""
    }

    override fun onCheckIsTextEditor(): Boolean = true

    /** A tap anywhere on the paper panel brings the keyboard back. */
    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_UP) {
            showKeyboard()
            performClick()
        }
        return true
    }

    override fun performClick(): Boolean = super.performClick()

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection {
        outAttrs.imeOptions = EditorInfo.IME_FLAG_NO_FULLSCREEN or
            EditorInfo.IME_FLAG_NO_EXTRACT_UI or
            EditorInfo.IME_FLAG_NO_ENTER_ACTION or
            EditorInfo.IME_ACTION_NONE
        if (textMode) {
            // Not multi-line: the keyboard's return key arrives as a key event, not as "\n".
            outAttrs.inputType = InputType.TYPE_CLASS_TEXT or
                InputType.TYPE_TEXT_FLAG_CAP_SENTENCES or
                InputType.TYPE_TEXT_FLAG_AUTO_CORRECT
            outAttrs.initialSelStart = Selection.getSelectionStart(line)
            outAttrs.initialSelEnd = Selection.getSelectionEnd(line)
            outAttrs.setInitialSurroundingText(line)
            batch = 0
            return TextConnection()
        }
        outAttrs.inputType = InputType.TYPE_CLASS_TEXT or
            InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD or
            InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        return TerminalConnection()
    }

    private fun emit(text: String) {
        if (text.isEmpty()) return
        val parts = text.split('\n')
        parts.forEachIndexed { i, part ->
            if (part.isNotEmpty()) sink.text(part)
            if (i < parts.size - 1) sink.key("Enter")
        }
    }

    private inner class TerminalConnection : BaseInputConnection(this@KeyCaptureView, false) {
        /** Some keyboards still compose. Send only the difference as it changes. */
        private var composing = ""

        private fun replaceComposing(next: String) {
            val edit = lineEdit(composing, next)
            repeat(edit.backspaces) { sink.key("BSpace") }
            emit(edit.typed)
            composing = next
        }

        override fun commitText(text: CharSequence, newCursorPosition: Int): Boolean {
            if (composing.isNotEmpty()) {
                replaceComposing(text.toString())
                composing = ""
            } else {
                emit(text.toString())
            }
            return true
        }

        override fun setComposingText(text: CharSequence, newCursorPosition: Int): Boolean {
            replaceComposing(text.toString())
            return true
        }

        override fun finishComposingText(): Boolean {
            composing = ""
            return true
        }

        override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
            repeat(beforeLength) { sink.key("BSpace") }
            repeat(afterLength) { sink.key("DC") }
            return true
        }

        override fun sendKeyEvent(event: KeyEvent): Boolean {
            if (event.action == KeyEvent.ACTION_DOWN) handleKey(event)
            return true
        }
    }

    /**
     * The framework applies every keyboard edit to [line]. When a batch of edits closes, the
     * terminal is brought level with it.
     */
    private inner class TextConnection : BaseInputConnection(this@KeyCaptureView, true) {
        override fun getEditable(): Editable = line

        override fun beginBatchEdit(): Boolean {
            batch++
            return true
        }

        override fun endBatchEdit(): Boolean {
            if (batch > 0) batch--
            if (batch == 0) sync()
            return batch > 0
        }

        private fun after(call: String, ok: Boolean): Boolean {
            trace(call)
            if (batch == 0) sync()
            return ok
        }

        override fun commitText(text: CharSequence, newCursorPosition: Int) =
            after("commitText(\"$text\", $newCursorPosition)", super.commitText(text, newCursorPosition))

        override fun setComposingText(text: CharSequence, newCursorPosition: Int) =
            after("setComposingText(\"$text\", $newCursorPosition)", super.setComposingText(text, newCursorPosition))

        override fun setComposingRegion(start: Int, end: Int) =
            after("setComposingRegion($start, $end)", super.setComposingRegion(start, end))

        override fun finishComposingText() =
            after("finishComposingText()", super.finishComposingText())

        override fun deleteSurroundingText(beforeLength: Int, afterLength: Int) =
            after("deleteSurroundingText($beforeLength, $afterLength)", super.deleteSurroundingText(beforeLength, afterLength))

        override fun deleteSurroundingTextInCodePoints(beforeLength: Int, afterLength: Int) =
            after(
                "deleteSurroundingTextInCodePoints($beforeLength, $afterLength)",
                super.deleteSurroundingTextInCodePoints(beforeLength, afterLength),
            )

        override fun setSelection(start: Int, end: Int) =
            after("setSelection($start, $end)", super.setSelection(start, end))

        override fun replaceText(start: Int, end: Int, text: CharSequence, newCursorPosition: Int, textAttribute: TextAttribute?) =
            after(
                "replaceText($start, $end, \"$text\", $newCursorPosition)",
                super.replaceText(start, end, text, newCursorPosition, textAttribute),
            )

        override fun sendKeyEvent(event: KeyEvent): Boolean {
            trace("sendKeyEvent(${KeyEvent.keyCodeToString(event.keyCode)}, action=${event.action})")
            if (event.action == KeyEvent.ACTION_DOWN) handleKey(event)
            return true
        }
    }

    /** Text mode: send the terminal what changed in [line] and tell the keyboard where the cursor is. */
    private fun sync() {
        // A spoken "new line" must not press Return and run a command.
        val now = line.toString().replace('\n', ' ')
        if (now != shown) {
            val edit = lineEdit(shown, now)
            repeat(edit.backspaces) { sink.key("BSpace") }
            if (edit.typed.isNotEmpty() && !sink.text(edit.typed)) {
                // It was not typed, so the copy no longer matches the terminal.
                forgetLine()
                return
            }
            shown = now
        }
        if (shown.length > LINE_LIMIT && BaseInputConnection.getComposingSpanStart(line) < 0) {
            forgetLine()
            return
        }
        imm.updateSelection(
            this,
            Selection.getSelectionStart(line),
            Selection.getSelectionEnd(line),
            BaseInputConnection.getComposingSpanStart(line),
            BaseInputConnection.getComposingSpanEnd(line),
        )
    }

    private fun trace(call: String) {
        if (Log.isLoggable(IME_TAG, Log.DEBUG)) {
            Log.d(IME_TAG, "$call -> \"$line\" sel=${Selection.getSelectionStart(line)}")
        }
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean =
        if (handleKey(event)) true else super.onKeyDown(keyCode, event)

    /** Text mode: plain typing and backspace edit [line]. True when it did. */
    private fun editLine(event: KeyEvent): Boolean {
        if (event.isCtrlPressed || event.isAltPressed) return false
        val start = Selection.getSelectionStart(line).coerceAtLeast(0)
        val end = Selection.getSelectionEnd(line).coerceAtLeast(0)
        val from = minOf(start, end)
        val to = maxOf(start, end)
        if (event.keyCode == KeyEvent.KEYCODE_DEL) {
            if (line.isEmpty()) return false
            if (from != to) line.delete(from, to) else if (from > 0) line.delete(Character.offsetByCodePoints(line, from, -1), from)
        } else {
            val code = event.unicodeChar
            if (code == 0 || Character.isISOControl(code)) return false
            line.replace(from, to, String(Character.toChars(code)))
        }
        if (batch == 0) sync()
        return true
    }

    /** tmux key names, matching what the Mac card sends for the same keys. */
    private fun handleKey(event: KeyEvent): Boolean {
        if (textMode) {
            if (editLine(event)) return true
            // Anything else changes the terminal line in ways the copy cannot follow.
            forgetLine()
        }
        val ctrl = event.isCtrlPressed
        val alt = event.isAltPressed
        val shift = event.isShiftPressed
        val named = when (event.keyCode) {
            KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> "Enter"
            KeyEvent.KEYCODE_DEL -> if (alt) "M-BSpace" else "BSpace"
            KeyEvent.KEYCODE_FORWARD_DEL -> "DC"
            KeyEvent.KEYCODE_ESCAPE -> "Escape"
            KeyEvent.KEYCODE_TAB -> if (shift) {
                sink.nextComputer()
                return true
            } else "Tab"
            KeyEvent.KEYCODE_DPAD_UP -> "Up"
            KeyEvent.KEYCODE_DPAD_DOWN -> "Down"
            KeyEvent.KEYCODE_DPAD_LEFT -> if (alt) "M-b" else "Left"
            KeyEvent.KEYCODE_DPAD_RIGHT -> if (alt) "M-f" else "Right"
            KeyEvent.KEYCODE_MOVE_HOME -> "Home"
            KeyEvent.KEYCODE_MOVE_END -> "End"
            KeyEvent.KEYCODE_PAGE_UP -> "PPage"
            KeyEvent.KEYCODE_PAGE_DOWN -> "NPage"
            else -> null
        }
        if (named != null) {
            sink.key(named)
            return true
        }
        val plain = event.getUnicodeChar(event.metaState and (KeyEvent.META_CTRL_MASK or KeyEvent.META_ALT_MASK).inv())
        if (plain == 0) return false
        val ch = plain.toChar()
        when {
            ctrl && ch.isLetter() -> sink.key("C-" + ch.lowercaseChar())
            alt -> sink.key("M-$ch")
            else -> sink.text(ch.toString())
        }
        return true
    }
}

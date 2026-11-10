package dev.eterm.focus.core

/** Terminal keys that turn [old] into the new line with the cursor at the end: backspaces, then text to type. */
data class LineEdit(val backspaces: Int, val typed: String)

fun lineEdit(old: String, new: String): LineEdit {
    var common = old.commonPrefixWith(new).length
    // A terminal backspace removes a whole code point, so never split a surrogate pair.
    if (common > 0 && Character.isHighSurrogate(old[common - 1])) common--
    return LineEdit(old.codePointCount(common, old.length), new.substring(common))
}

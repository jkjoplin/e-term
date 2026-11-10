package dev.eterm.focus.core

import org.junit.Assert.assertEquals
import org.junit.Test

class LineEditTest {
    @Test
    fun appendingOnlyTypes() {
        assertEquals(LineEdit(0, " world"), lineEdit("hello", "hello world"))
    }

    @Test
    fun voiceCorrectionBacksUpToTheChange() {
        // A voice keyboard swaps a misheard word and adds punctuation. Shared "I'm he":
        // back over "ar there", then type "re. ".
        assertEquals(LineEdit(8, "re. "), lineEdit("I'm hear there", "I'm here. "))
    }

    @Test
    fun deletingSendsBackspacesOnly() {
        assertEquals(LineEdit(3, ""), lineEdit("abcdef", "abc"))
    }

    @Test
    fun emojiCountsAsOneBackspace() {
        assertEquals(LineEdit(1, ""), lineEdit("ok 👍", "ok "))
        // Two emoji sharing a high surrogate: back up over the whole first one.
        assertEquals(LineEdit(1, "👎"), lineEdit("👍", "👎"))
    }

    @Test
    fun sameLineSendsNothing() {
        assertEquals(LineEdit(0, ""), lineEdit("same", "same"))
    }
}

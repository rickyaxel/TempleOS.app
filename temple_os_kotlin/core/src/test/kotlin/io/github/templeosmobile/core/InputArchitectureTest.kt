package io.github.templeosmobile.core

import io.github.templeosmobile.core.kernel.*
import io.github.templeosmobile.core.holyc.latin1
import io.github.templeosmobile.core.ui.*
import org.junit.Assert.*
import org.junit.Before
import org.junit.After
import org.junit.Test
import java.io.File

class InputArchitectureTest {
    private lateinit var dir: File
    private lateinit var sh: Shell
    private class Target(sh: Shell) : App(sh) {
        override val title = "input-probe"
        override val kind = "probe"
        override val wantsKeyboard = true
        override val rawKeys = true
        val events = ArrayList<Triple<Int, Long, Boolean>>()
        override fun draw(s: Surface, r: Rect) {}
        override fun key(ch: Int, sc: Long, down: Boolean): Boolean { events.add(Triple(ch, sc, down)); return true }
    }
    @Before fun setup() {
        dir = kotlin.io.path.createTempDirectory("input-architecture").toFile()
        sh = Shell(HeadlessEnv(dir)); sh.resize(390, 844, 47, 34)
    }
    @After fun cleanup() {
        sh.settings.language = "en-US"; sh.applyLanguage()
        sh.windows.toList().forEach { sh.close(it, true) }; dir.deleteRecursively()
    }
    @Test fun losslessCP437AndAtomicUnicodeRejection() {
        assertEquals(listOf(130,164,225).map(Int::toChar).joinToString(""), InputCharacterPolicy.encode("éñß"))
        assertEquals("\u0082\nx", InputCharacterPolicy.encode("e\u0301\r\nx"))
        for (s in listOf("ok🙂", "東京", "a\u0000b", "a\u001Bb", "ع")) assertNull(InputCharacterPolicy.encode(s))
        val large = "I64 x=1;\n".repeat(10_000)
        assertEquals(large, InputCharacterPolicy.encode(large))
        assertNull(InputCharacterPolicy.encode(large + "🙂"))
        assertNull(InputCharacterPolicy.encode("a\nb", true))
        for (b in 128..255) assertEquals("CP437 $b", b.toChar().toString(), InputCharacterPolicy.encode(Cp437.decode(b.toChar().toString())))
    }
    @Test fun pasteValidatesBeforeChangingEditor() {
        val ed = EditorApp(sh, null, "keep"); sh.open(ed)
        assertFalse(sh.insertUnicodeText("bad🙂")); assertEquals("keep", ed.text())
        ed.insert("bad東京"); assertEquals("keep", ed.text())
        assertTrue(sh.insertUnicodeText("é")); assertTrue(ed.text().contains('\u0082'))
        assertEquals(2, sh.rejectedInputCount)
    }
    @Test fun legacyUnicodeDraftNeverSilentlySavesOrRuns() {
        val draft = "東京🙂"; val ed = EditorApp(sh, "C:/Home/Legacy.HC", draft); sh.open(ed); sh.tick()
        assertEquals(draft, ed.text()); assertFalse(ed.save()); ed.run()
        assertFalse(sh.fs.exists("C:/Home/Legacy.HC")); assertEquals(1, sh.windows.size)
        assertEquals(draft, InputCharacterPolicy.display(draft))
    }
    @Test fun pasteIsDataWhileShortcutModifierIsLatched() {
        val ed = EditorApp(sh, null, "keep"); sh.open(ed); sh.toggleCtrl()
        assertTrue(sh.insertUnicodeText("abc"))
        assertTrue(ed.text().contains("abc")); assertTrue(ed.text().contains("keep"))
        assertFalse(sh.ctrlLatched)
    }
    @Test fun originalControlBytesAndBinaryTailRoundTrip() {
        val bytes = latin1("//\u001F\u0080\n\"OK\";") + byteArrayOf(0,22,33)
        sh.fs.writeFile("C:/Home/Bytes.HC", bytes)
        val ed = EditorApp(sh, "C:/Home/Bytes.HC"); sh.open(ed)
        assertTrue(ed.save()); assertArrayEquals(bytes, sh.fs.readFile("C:/Home/Bytes.HC"))
        assertFalse(sh.insertUnicodeText("bad\u001F"))
    }
    @Test fun staleLeaseAndClosedWindowCannotAcquireInput() {
        val a = EditorApp(sh, null, "a"); val aw = sh.open(a); val lease = sh.inputLease
        val b = EditorApp(sh, null, "b"); sh.open(b)
        assertFalse(sh.insertUnicodeText("x", lease)); assertEquals("b", b.text())
        sh.close(aw, true); sh.focus(aw); assertSame(b, sh.focused!!.app)
    }
    @Test fun heldKeysAndModifiersReleaseBeforeFocusAndIgnoreLateUp() {
        val a = Target(sh); sh.open(a); val (ch, sc) = Keys.forChar('a'.code)
        sh.hardwareKey(ch, sc, true); sh.hardwareKey(0, Keys.SC_CTRL.toLong() or Keys.SCF_CTRL, true)
        val b = Target(sh); sh.open(b)
        assertEquals(2, a.events.count { !it.third })
        sh.hardwareKey(ch, sc, false); sh.hardwareKey(0, Keys.SC_CTRL.toLong(), false)
        assertTrue(b.events.isEmpty())
    }
    @Test fun menuTransitionReleasesOldProgramBeforeIntercepting() {
        val a = Target(sh); sh.open(a); sh.hardwareKey(0, Keys.SC_CURSOR_UP.toLong(), true)
        sh.showStartMenu(); assertEquals(2, a.events.size); assertFalse(a.events.last().third)
        sh.hardwareKey(0, Keys.SC_CURSOR_UP.toLong(), false); assertEquals(2, a.events.size)
        sh.hardwareKey(0, Keys.SC_CTRL.toLong() or Keys.SCF_CTRL, true)
        sh.hardwareKey(0, Keys.SC_CTRL.toLong(), false); assertEquals(2, a.events.size)
    }
    @Test fun backgroundCancelsTouchRepeatAndRetainsIntent() {
        val ed = EditorApp(sh, null, ""); sh.open(ed); sh.tick()
        val key = sh.accessibilityNodes().first { it.label == "a" }; val x = key.rect.x+2; val y = key.rect.y+2
        sh.pointer(PointerEvent(Ptr.DOWN, x, y, 88, 100)); sh.onBackground(); sh.onForeground()
        sh.pointer(PointerEvent(Ptr.UP, x, y, 88, 200)); sh.tick()
        assertEquals("", ed.text()); assertTrue(sh.templeKeyboardShown)
        sh.hideKeyboard(); sh.onBackground(); sh.onForeground(); assertFalse(sh.templeKeyboardShown)
        sh.requestKeyboard(); assertTrue(sh.templeKeyboardShown)
    }
    @Test fun modalPasteCannotEscapeToUnderlyingWindow() {
        val ed = EditorApp(sh, null, "keep"); sh.open(ed); var answer: String? = null
        sh.showDialog(Dialog.input("Path", "") { answer = it })
        assertFalse(sh.insertUnicodeText("bad\ncommand")); assertEquals("keep", ed.text())
        assertTrue(sh.insertUnicodeText("é")); sh.text("\n"); assertEquals("\u0082", answer); assertEquals("keep", ed.text())
    }
    @Test fun popupRejectsReleaseFromKeyboardOrPreviousDialog() {
        sh.open(EditorApp(sh, null, "keep")); sh.tick()
        val key = sh.accessibilityNodes().first { it.label == "a" }.rect
        sh.pointer(PointerEvent(Ptr.DOWN, key.x+2, key.y+2, 88))
        var picked = 0
        val first = Dialog.choose("First", "", listOf("Pick once" to 1L), emptyList()) { if (it == 1L) picked++ }
        first.onCancel = {}
        sh.showDialog(first); sh.tick()
        var row = sh.accessibilityNodes().first { it.label == "Pick once" }.rect
        sh.pointer(PointerEvent(Ptr.UP, row.x+2, row.y+2, 88))
        assertEquals(0, picked); assertTrue(sh.dialogOpen)
        sh.pointer(PointerEvent(Ptr.DOWN, row.x+2, row.y+2, 89))
        sh.showDialog(Dialog.choose("Second", "", listOf("Pick once" to 1L), emptyList()) { if (it == 1L) picked++ })
        sh.tick(); row = sh.accessibilityNodes().first { it.label == "Pick once" }.rect
        sh.pointer(PointerEvent(Ptr.UP, row.x+2, row.y+2, 89))
        assertEquals(0, picked); assertTrue(sh.dialogOpen)
        sh.pointer(PointerEvent(Ptr.DOWN, row.x+2, row.y+2, 90))
        sh.pointer(PointerEvent(Ptr.DOWN, row.x+2, row.y+2, 91))
        sh.pointer(PointerEvent(Ptr.UP, row.x+2, row.y+2, 91))
        assertEquals(0, picked)
        sh.pointer(PointerEvent(Ptr.UP, row.x+2, row.y+2, 90))
        assertEquals(1, picked); assertFalse(sh.dialogOpen)
    }
    @Test fun popupRejectsReleaseAcrossBackgroundAndMenuChange() {
        var picked = 0
        sh.showDialog(Dialog.choose("Choice", "", listOf("Pick once" to 1L), emptyList()) { if (it == 1L) picked++ }); sh.tick()
        val row = sh.accessibilityNodes().first { it.label == "Pick once" }.rect
        sh.pointer(PointerEvent(Ptr.DOWN, row.x+2, row.y+2, 92))
        sh.onBackground(); sh.onForeground()
        sh.pointer(PointerEvent(Ptr.UP, row.x+2, row.y+2, 92))
        assertEquals(0, picked)
        sh.showMenu(listOf(MenuItem("Menu pick") { picked++ }), 10, 80); sh.back(); sh.tick()
        val menuRow = sh.accessibilityNodes().first { it.label == "Menu pick" }.rect
        sh.pointer(PointerEvent(Ptr.UP, menuRow.x+2, menuRow.y+2, 92))
        assertEquals(0, picked)
        sh.pointer(PointerEvent(Ptr.DOWN, menuRow.x+2, menuRow.y+2, 93))
        sh.pointer(PointerEvent(Ptr.UP, menuRow.x+2, menuRow.y+2, 93))
        assertEquals(1, picked)
    }
    @Test fun extendedPickerRestoresDialogTarget() {
        sh.open(EditorApp(sh, null, "keep")); var answer: String? = null
        sh.showDialog(Dialog.input("Path", "") { answer = it })
        sh.showCharacterPicker(); sh.text("\n"); sh.tick(); assertEquals("dialog", sh.inputTarget)
        sh.text("\n"); assertEquals("\u0080", answer)
    }
    @Test fun hundredTargetCloseCyclesAndRapidGeometryTransitions() {
        repeat(100) { i ->
            val ed = EditorApp(sh, null, ""); val win = sh.open(ed); val lease = sh.inputLease
            sh.text("x"); assertEquals("x", ed.text())
            sh.resize(if (i%2==0) 844 else 390, if (i%2==0) 390 else 844, 20, 20, 0, 0, 300)
            sh.hardwareKeyUsed(); assertTrue(sh.templeKeyboardShown); sh.close(win, true)
            assertFalse(sh.insertUnicodeText("late", lease)); assertEquals("none", sh.inputTarget); assertEquals(0, sh.keyboardHeight)
        }
    }
    @Test fun hundredRealTerminalLaunchTypeExecuteCloseCycles() {
        repeat(100) {
            Launch.terminal(sh)
            val window = sh.focused!!; val terminal = window.app as TerminalApp
            val ready = System.nanoTime() + 10_000_000_000L
            while (!terminal.kernel.console.plainText().contains(">") && System.nanoTime() < ready) Thread.sleep(2)
            Thread.sleep(2); sh.text("6*7;\n")
            val end = System.nanoTime() + 5_000_000_000L
            while (!terminal.kernel.console.plainText().contains("ans=0x0000002A=42") && System.nanoTime() < end) Thread.sleep(2)
            assertTrue(terminal.kernel.console.plainText().contains("ans=0x0000002A=42"))
            sh.close(window, true); sh.tick(); assertEquals("none", sh.inputTarget)
        }
    }
    @Test fun touchClockCannotCauseImmediateRepeat() {
        val ed = EditorApp(sh, null, ""); sh.open(ed); sh.tick()
        val n = sh.accessibilityNodes().first { it.label == "a" }
        sh.pointer(PointerEvent(Ptr.DOWN, n.rect.x+2, n.rect.y+2, 72, 1)); sh.tick(); assertEquals("", ed.text())
        sh.pointer(PointerEvent(Ptr.UP, n.rect.x+2, n.rect.y+2, 72, 2)); assertEquals("a", ed.text())
    }
    @Test fun heldTextKeyRetainsItsModifierSnapshot() {
        val ed = EditorApp(sh, null, "keep"); sh.open(ed); sh.tick(); sh.toggleCtrl()
        val n = sh.accessibilityNodes().first { it.label == "a" }; val time = sh.env.nowMs()
        sh.keyboard.pointer(PointerEvent(Ptr.DOWN, n.rect.x+2, n.rect.y+2, 73), time)
        sh.keyboard.tick(time+401); sh.keyboard.tick(time+470)
        sh.keyboard.pointer(PointerEvent(Ptr.UP, n.rect.x+2, n.rect.y+2, 73), time+480)
        assertEquals("keep", ed.text()); sh.text("x"); assertEquals("x", ed.text())
    }
    @Test fun originalDecodeTablesIncludeCapsDigitsAndControlCodes() {
        for (c in 'a'..'z') {
            val sc = Keys.char2ScanCode(c.code).toLong()
            assertEquals(c.code, Keys.scanCode2Char(sc))
            assertEquals(c.uppercaseChar().code, Keys.scanCode2Char(sc or Keys.SCF_SHIFT))
            assertEquals(c.code-96, Keys.scanCode2Char(sc or Keys.SCF_CTRL))
        }
        assertEquals('!'.code, Keys.scanCode2Char(2L or Keys.SCF_CAPS))
        assertEquals(Keys.CH_SHIFT_SPACE, Keys.scanCode2Char(Keys.SC_SPACE.toLong() or Keys.SCF_SHIFT))
        assertEquals(Keys.CH_SHIFT_ESC, Keys.scanCode2Char(Keys.SC_ESC.toLong() or Keys.SCF_SHIFT))
    }
    @Test fun localizationDoesNotChangeInputLayout() {
        sh.open(EditorApp(sh, null, "")); val keys = sh.keyboard.rows().flatten().mapNotNull { it.ch }
        for (language in listOf("en-US", "es-ES", "fr-FR", "de-DE", "ja-JP", "zh-CN", "ar-SA")) {
            sh.settings.language = language; sh.applyLanguage(); sh.tick()
            assertEquals(keys, sh.keyboard.rows().flatten().mapNotNull { it.ch })
            assertTrue(sh.insertUnicodeText("I64 x=1;")); assertTrue(sh.templeKeyboardShown)
        }
        assertEquals("日本語 العربية 🙂", InputCharacterPolicy.display("日本語 العربية 🙂"))
    }
}

package io.github.templeosmobile.core

import io.github.templeosmobile.core.holyc.latin1
import io.github.templeosmobile.core.kernel.*
import io.github.templeosmobile.core.ui.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

/**
 * The in-app TempleOS keyboard, driven the way a screen reader does it (activating the
 * accessibility nodes the shell publishes), so both are tested together.
 */
class KeyboardTest {
    private val dir = kotlin.io.path.createTempDirectory("kbd").toFile()
    private val env = HeadlessEnv(dir)
    private val sh = Shell(env).apply { resize(360, 780, 24, 16, 0, 0, 0); tick() }

    @After fun cleanup() { sh.windows.toList().forEach { sh.close(it, true) }; dir.deleteRecursively() }

    private fun node(label: String): A11yNode {
        sh.invalidate(); sh.tick()
        return sh.accessibilityNodes().firstOrNull { it.label == label }
            ?: error("no node '$label' in ${sh.accessibilityNodes().map { it.label }}")
    }
    private fun press(vararg labels: String) { for (l in labels) sh.accessibilityActivate(node(l)) }

    private fun editor(text: String): EditorApp {
        sh.fs.writeFile("C:/Home/Kbd.HC", latin1(text))
        Launch.editor(sh, "C:/Home/Kbd.HC"); sh.tick()
        return sh.focused!!.app as EditorApp
    }

    @Test fun textAppsGetTheTempleOsKeyboardNotTheDeviceKeyboard() {
        editor("x")
        assertTrue(sh.templeKeyboardShown)
        assertFalse("device keyboard stays hidden", env.systemKeyboard)
        val kr = sh.keyboardRect()
        assertTrue("keyboard is above the home indicator", kr.bottom <= 780 - 16)
        assertTrue("the window ends above the keyboard", sh.desktopRect().bottom <= kr.y)
        // every key is a real, labelled node inside the keyboard
        val keys = sh.accessibilityNodes().filter { kr.contains(it.rect.x + 1, it.rect.y + 1) }
        assertTrue(keys.size >= 50)
        assertTrue(keys.all { it.button && it.rect.h >= 30 })
    }

    @Test fun typingInsertsAtTheCaretWithShiftSymbolsAndBackspace() {
        val ed = editor("ab")
        ed.restoreCursor(0, 1)
        press("Shift", "X")                     // one-shot shift; keys now read as capitals
        assertEquals("aXb", ed.text())
        press("y")                               // shift released
        assertEquals("aXyb", ed.text())
        press("Backspace")
        assertEquals("aXb", ed.text())
        press("Symbols", "left brace", "Letters", "semicolon", "quote")
        assertEquals("aX{;\"b", ed.text())
        press("Function keys")
        assertEquals(KeyboardLayerName.FUNCTIONS, sh.keyboard.layer)
        press("Home")
        press("Function keys")                   // FN toggles back to letters
        assertEquals(KeyboardLayerName.LETTERS, sh.keyboard.layer)
        press("Shift", "Shift")                  // double tap: caps lock
        press("Q", "W")
        assertEquals("QWaX{;\"b", ed.text())
        assertEquals(2, sh.keyboard.shift)
    }

    @Test fun heldBackspaceRepeats() {
        val ed = editor("abcdefghijklmnopqrstuvwxyz")
        ed.restoreCursor(0, 26)
        val n = node("Backspace")
        val x = n.rect.x + n.rect.w / 2; val y = n.rect.y + n.rect.h / 2
        sh.pointer(PointerEvent(Ptr.DOWN, x, y, 5, env.nowMs()))
        val end = System.currentTimeMillis() + 900
        while (System.currentTimeMillis() < end) { sh.tick(); Thread.sleep(10) }
        sh.pointer(PointerEvent(Ptr.UP, x, y, 5, env.nowMs()))
        val left = ed.text().length
        assertTrue("held backspace deleted ${26 - left} characters", 26 - left >= 5)
    }

    @Test fun modifiersResetWhenFocusChanges() {
        editor("x")
        press("Control")
        assertTrue(sh.ctrlLatched)
        Launch.settings(sh); sh.tick()
        assertFalse("Ctrl must not leak into another window", sh.ctrlLatched)
        assertFalse(sh.templeKeyboardShown)
    }

    @Test fun legacyDeviceSettingCannotActivateAPlatformKeyboard() {
        editor("x")
        sh.settings = Settings.decode("k=1"); sh.setKeyboardMode(1)
        assertTrue(sh.templeKeyboardShown); assertFalse(env.systemKeyboard)
        assertEquals(0, sh.settings.keyboardMode)
        sh.saveSession(); assertTrue(env.session!!.contains("k=0"))
        assertFalse(sh.accessibilityNodes().any { it.label == "Use the device keyboard" })
    }

    @Test fun hardwareKeyboardKeepsSoftwareInputAvailable() {
        editor("x")
        sh.hardwareKeyUsed()
        assertTrue(sh.templeKeyboardShown)
        press("Hide keyboard")
        assertFalse(sh.templeKeyboardShown)
        press("Show or hide keyboard")
        assertTrue(sh.templeKeyboardShown)
    }

    @Test fun terminalRunsWhatIsTypedOnTheKeyboard() {
        Launch.terminal(sh, "C:/Home"); sh.tick()
        val term = sh.focused!!.app as TerminalApp
        assertTrue(sh.templeKeyboardShown)
        press("6", "Shift", "asterisk", "7", "semicolon", "Enter") // shift+8
        val end = System.currentTimeMillis() + 20_000
        while (System.currentTimeMillis() < end && !term.kernel.console.plainText().contains("ans=0x0000002A")) { sh.tick(); Thread.sleep(20) }
        assertTrue(term.kernel.console.plainText().takeLast(300), term.kernel.console.plainText().contains("ans=0x0000002A=42"))
    }

    @Test fun saveAsDialogTakesKeyboardInput() {
        val ed = editor("1;")
        ed.insert("2;")
        Launch.editor(sh, null); sh.tick() // an untitled editor: SAVE asks for a name
        val untitled = sh.focused!!.app as EditorApp
        untitled.save()
        assertTrue(sh.dialogOpen)
        assertTrue("the dialog's text field gets the TempleOS keyboard", sh.templeKeyboardShown)
        sh.invalidate(); sh.tick()
        val before = sh.accessibilityNodes().first { it.label.startsWith("Text field") }.label
        press("z")
        val after = sh.accessibilityNodes().first { it.label.startsWith("Text field") }.label
        assertEquals(before + "z", after)
    }

    @Test fun landscapeTempleKeyboardDoesNotShrinkFloatingWindows() {
        sh.resize(800, 360, 23, 16, 0, 0, 0); sh.tick()
        editor("x")
        val win = sh.focused!!
        assertTrue(sh.templeKeyboardShown && sh.typingCompact)
        val placed = listOf(win.x, win.y, win.w, win.h)
        assertTrue("window placed for the desktop, not the space above the keyboard: $placed", win.h >= 200)
        sh.hideKeyboard(); sh.tick()
        assertEquals(placed, listOf(win.x, win.y, win.w, win.h))
    }

    @Test fun keyPressCostIsSmall() {
        // one key press = dispatch to the editor + a full render of the shell surface (what the
        // UI thread does per key; the platform then uploads one bitmap)
        val ed = editor("")
        val keys = "abcdefghij".map { node(it.toString()) }
        repeat(50) { sh.accessibilityActivate(keys[it % 10]); sh.invalidate(); sh.tick() } // warm-up (JIT)
        val n = 200
        val t0 = System.nanoTime()
        repeat(n) { sh.accessibilityActivate(keys[it % 10]); sh.invalidate(); sh.tick() }
        val us = (System.nanoTime() - t0) / 1000 / n
        println("KEYPRESS-COST: ${us} us per key press (dispatch + editor + full 360x780 render)")
        assertEquals(250, ed.text().length)
        assertTrue("$us us per key", us < 20_000)
    }
}

/** Layer ids of [TempleKeyboard], named for the assertions above. */
object KeyboardLayerName { const val LETTERS = TempleKeyboard.LETTERS; const val FUNCTIONS = TempleKeyboard.FUNCTIONS }

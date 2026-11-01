package io.github.templeosmobile.core

import io.github.templeosmobile.core.kernel.*
import io.github.templeosmobile.core.ui.*
import io.github.templeosmobile.core.ui.SystemChrome.Owner
import org.junit.Assert.*
import org.junit.Test

/**
 * The system navigation region (Android navigation bar / gesture handle, iOS home indicator) shows
 * the TempleOS surface that owns the bottom edge ([SystemChrome]). Every check also reads the
 * rendered surface: the resolved color must be what the shell painted under the system region and
 * what it drew right above it, so the declared appearance and the pixels cannot drift apart.
 */
class SystemChromeTest {
    /** A plain app (no override): the shell's defaults apply. */
    private class PlainApp(shell: Shell, override val kind: String = "plain", private val edge: Int? = null, private val defer: Boolean = false) : App(shell) {
        override val title = "Plain"
        override fun draw(s: Surface, r: Rect) { s.fill(r, Palette.CYAN) }
        override val systemEdgeColor get() = edge
        override val defersEdgeGestures get() = defer
    }

    private fun <T> withShell(w: Int = 360, h: Int = 800, top: Int = 21, bottom: Int = 21, left: Int = 0, right: Int = 0, body: (Shell) -> T): T {
        val dir = kotlin.io.path.createTempDirectory("tosm-chrome").toFile()
        try {
            val sh = Shell(HeadlessEnv(dir))
            sh.resize(w, h, top, bottom, left, right, 0)
            sh.tick()
            return body(sh).also { sh.windows.toList().forEach { it.app.close() } }
        } finally { dir.deleteRecursively() }
    }

    private fun px(sh: Shell, x: Int, y: Int) = sh.surface.px[y * sh.surface.width + x].toInt() and 15

    /** The most common color of row [y] across the usable width. */
    private fun rowColor(sh: Shell, y: Int): Int {
        val n = IntArray(16)
        for (x in sh.insetLeft until sh.width - sh.insetRight) n[px(sh, x, y)]++
        return n.indices.maxByOrNull { n[it] }!!
    }

    /** The painted gutters equal the resolved chrome, and the row above the system region agrees. */
    private fun assertPainted(sh: Shell, label: String) {
        sh.tick()
        val c = sh.systemChrome
        val usableBottom = sh.height - maxOf(sh.insetBottom, sh.keyboardHeight)
        for (y in usableBottom until sh.height) for (x in 0 until sh.width)
            assertEquals("$label: bottom gutter ($x,$y)", c.bottom, px(sh, x, y))
        assertEquals("$label: the surface drawn above the system region", c.bottom, rowColor(sh, usableBottom - 1))
        if (sh.insetLeft > 0) assertEquals("$label: left gutter", c.side, px(sh, 0, sh.height / 2))
        if (sh.insetRight > 0) assertEquals("$label: right gutter", c.side, px(sh, sh.width - 1, sh.height / 2))
    }

    // 9. a screen with no explicit override gets the centralized default
    @Test fun emptyDesktopUsesTheDesktopColor() = withShell { sh ->
        assertEquals(Owner.DESKTOP, sh.systemChrome.owner)
        assertEquals(sh.settings.desktopColor, sh.systemChrome.bottom)
        assertPainted(sh, "desktop")
    }

    // 1. a declared background resolves the expected system background
    @Test fun portraitWindowOwnsTheBottomEdgeWithItsBackground() = withShell { sh ->
        Launch.doc(sh, "C:/Home/Welcome.DD"); sh.tick()
        assertEquals(Owner.WINDOW, sh.systemChrome.owner)
        assertEquals(Shell.WINDOW_BG, sh.systemChrome.bottom)
        assertPainted(sh, "doc window")
        assertTrue("dark icons on the white window", sh.systemChrome.darkIconsAt(SystemChrome.Edge.BOTTOM))
    }

    // 2 + 3. a screen change updates the appearance; going back restores it
    @Test fun screenChangesUpdateAndRestoreTheAppearance() = withShell { sh ->
        val before = sh.systemChrome
        Launch.doc(sh, "C:/Home/Welcome.DD"); sh.tick()
        val doc = sh.systemChrome
        assertNotEquals(before, doc)
        Launch.terminal(sh); sh.tick() // a text app: the TempleOS keyboard comes up
        assertEquals(Owner.KEYBOARD, sh.systemChrome.owner)
        assertEquals(Shell.BAR_BG, sh.systemChrome.bottom)
        assertFalse("light icons on the black keyboard", sh.systemChrome.darkIconsAt(SystemChrome.Edge.BOTTOM))
        assertPainted(sh, "terminal + TempleOS keyboard")
        sh.hideKeyboard(); sh.tick()
        assertEquals(Owner.KEY_ROW, sh.systemChrome.owner)
        assertPainted(sh, "terminal + key row")
        sh.close(sh.focused!!); sh.tick()
        assertEquals("back on the document", doc, sh.systemChrome)
        assertPainted(sh, "doc again")
        sh.close(sh.focused!!); sh.tick()
        assertEquals("back on the empty desktop", before, sh.systemChrome)
    }

    // 4. a modal that does not reach the bottom keeps the underlying appearance
    @Test fun menusAndDialogsDoNotTakeTheBottomEdge() = withShell { sh ->
        Launch.doc(sh, "C:/Home/Welcome.DD"); sh.tick()
        val doc = sh.systemChrome
        sh.showStartMenu(); sh.tick()
        assertTrue(sh.popupOpen)
        assertEquals("start menu", doc, sh.systemChrome)
        assertPainted(sh, "start menu")
        sh.back(); sh.tick()
        sh.showDialog(Dialog.confirm("Title", "A long message that wraps over a few lines.", "OK") {}); sh.tick()
        assertTrue(sh.dialogOpen)
        assertEquals("dialog", doc, sh.systemChrome)
        assertPainted(sh, "dialog")
        sh.back(); sh.tick()
        assertEquals(doc, sh.systemChrome)
    }

    // 5. a bottom-covering overlay takes ownership (resolver contract; no current popup is a full-width sheet)
    @Test fun aFullWidthSheetReachingTheBottomOwnsIt() {
        val window = SystemChrome.Layer(Rect(0, 40, 360, 739), Palette.WHITE, Owner.WINDOW)
        val dialog = SystemChrome.Layer(Rect(20, 200, 320, 200), Palette.WHITE, Owner.POPUP)
        val sheet = SystemChrome.Layer(Rect(0, 500, 360, 279), Palette.BLUE, Owner.POPUP)
        val shortSheet = SystemChrome.Layer(Rect(0, 500, 360, 270), Palette.BLUE, Owner.POPUP)
        fun r(vararg bars: SystemChrome.Layer) = SystemChrome.resolve(Palette.DKGRAY, listOf(window), 779, bars.toList(), 779, 0, 360)
        assertEquals(Owner.WINDOW, r(dialog).owner)
        assertEquals(Palette.WHITE, r(dialog).bottom)
        assertEquals(Owner.POPUP, r(dialog, sheet).owner)
        assertEquals(Palette.BLUE, r(dialog, sheet).bottom)
        assertEquals("the side gutters still follow the content", Palette.WHITE, r(sheet).side)
        assertEquals("a sheet that stops short of the edge does not own it", Owner.WINDOW, r(shortSheet).owner)
        val narrow = SystemChrome.Layer(Rect(4, 500, 352, 279), Palette.BLUE, Owner.POPUP)
        assertEquals("nor does one narrower than the screen", Owner.WINDOW, r(narrow).owner)
    }

    // 6. the device keyboard: flagged, so the platform leaves the region under it to the system
    @Test fun nativeKeyboardGeometryCannotChangeTheApp() = withShell { sh ->
        sh.setKeyboardMode(Settings.KEYBOARD_SYSTEM)
        Launch.editor(sh, "C:/Home/Examples/Hello.HC"); sh.tick()
        assertFalse(sh.systemChrome.deviceKeyboard)
        assertEquals(Owner.KEYBOARD, sh.systemChrome.owner)
        sh.resize(360, 800, 21, 21, 0, 0, 300); sh.tick() // keyboard up
        assertFalse(sh.systemChrome.deviceKeyboard)
        assertEquals("the key row sits on the keyboard", Owner.KEYBOARD, sh.systemChrome.owner)
        assertPainted(sh, "device keyboard")
        sh.resize(360, 800, 21, 21, 0, 0, 0); sh.tick() // keyboard down
        assertFalse(sh.systemChrome.deviceKeyboard)
        assertPainted(sh, "device keyboard closed")
    }

    // 7. an unchanged state never reaches the platform twice
    @Test fun unchangedAppearanceIsAppliedOnce() = withShell { sh ->
        Launch.doc(sh, "C:/Home/Welcome.DD"); sh.tick()
        val applied = ArrayList<SystemChrome>()
        val gate = ChangeGate<SystemChrome> { applied.add(it) }
        repeat(5) { sh.invalidate(); sh.tick(); gate.offer(sh.systemChrome) }
        assertEquals("five renders of the same screen", 1, applied.size)
        sh.showStartMenu(); sh.tick(); gate.offer(sh.systemChrome)
        assertEquals("a menu does not change it", 1, applied.size)
        sh.back(); Launch.terminal(sh); sh.tick(); gate.offer(sh.systemChrome)
        assertEquals(2, applied.size)
        gate.reset(); gate.offer(sh.systemChrome)
        assertEquals("reset (window recreated) applies again", 3, applied.size)
    }

    // 8. icon contrast for every palette color
    @Test fun iconContrastIsReadableOnEveryPaletteColor() {
        fun contrast(a: Double, b: Double) = (maxOf(a, b) + 0.05) / (minOf(a, b) + 0.05)
        for (c in 0 until 16) {
            val l = SystemChrome.luminance(Palette.STD[c])
            val icon = if (SystemChrome.prefersDarkIcons(c)) 0.0 else 1.0
            assertTrue("color $c: ${contrast(l, icon)}", contrast(l, icon) >= 4.5)
        }
        assertTrue(SystemChrome.prefersDarkIcons(Palette.WHITE))
        assertTrue(SystemChrome.prefersDarkIcons(Palette.LTGRAY))
        assertFalse(SystemChrome.prefersDarkIcons(Palette.BLACK))
        assertFalse(SystemChrome.prefersDarkIcons(Palette.BLUE))
        assertFalse(SystemChrome.prefersDarkIcons(Palette.DKGRAY))
    }

    // 9 (cont.) an app inherits the window default unless it overrides
    @Test fun appsInheritTheWindowDefaultAndMayOverride() = withShell { sh ->
        sh.open(PlainApp(sh)); sh.tick()
        assertEquals(Shell.WINDOW_BG, sh.systemChrome.bottom)
        assertFalse(sh.systemChrome.defersEdgeGestures)
        sh.open(PlainApp(sh, "override", edge = Palette.BLACK, defer = true)); sh.tick()
        assertEquals(Owner.APP_OVERRIDE, sh.systemChrome.owner)
        assertEquals(Palette.BLACK, sh.systemChrome.bottom)
        assertTrue(sh.systemChrome.defersEdgeGestures)
        for (x in 0 until sh.width) assertEquals(Palette.BLACK, px(sh, x, sh.height - 1))
    }

    @Test fun desktopColorChangeWithoutNavigationIsFollowed() = withShell { sh ->
        sh.settings.desktopColor = Palette.BLUE; sh.invalidate(); sh.tick()
        assertEquals(Palette.BLUE, sh.systemChrome.bottom)
        assertPainted(sh, "blue desktop")
    }

    @Test fun landscapeFloatingWindowsLeaveTheDesktopAndMaximizedWindowsTakeIt() =
        withShell(w = 800, h = 360, top = 0, bottom = 16, left = 40, right = 42) { sh ->
            Launch.doc(sh, "C:/Home/Welcome.DD"); sh.tick()
            assertEquals("floating window", Owner.DESKTOP, sh.systemChrome.owner)
            assertPainted(sh, "landscape floating")
            sh.focused!!.maximized = true; sh.relayout(); sh.tick()
            assertEquals("maximized window", Owner.WINDOW, sh.systemChrome.owner)
            assertEquals(Shell.WINDOW_BG, sh.systemChrome.side)
            assertPainted(sh, "landscape maximized")
            // a three-button bar on the right side takes the side color
            assertEquals(Shell.WINDOW_BG, sh.systemChrome.colorAt(SystemChrome.Edge.RIGHT))
        }

    @Test fun rotationKeepsTheGuttersPainted() = withShell { sh ->
        Launch.doc(sh, "C:/Home/Welcome.DD"); sh.tick()
        sh.resize(800, 360, 0, 16, 40, 42, 0); sh.tick()
        assertPainted(sh, "landscape")
        sh.resize(360, 800, 21, 42, 0, 0, 0); sh.tick() // back to portrait, three-button bar height
        assertEquals(Owner.WINDOW, sh.systemChrome.owner)
        assertPainted(sh, "portrait again")
    }
}

package io.github.templeosmobile.core

import io.github.templeosmobile.core.kernel.Keys
import io.github.templeosmobile.core.ui.*
import org.junit.Assert.*
import org.junit.Test

/**
 * The responsive menu layer (MenuMetrics, docs/ui-normalization/TEMPLEOS_RESPONSIVE_MENU_UI.md): the sizing
 * policy's invariants over real and edge viewports, and the menus driven through the shell as a user does
 * (touch, drag, keys, submenus, rotation). Same cases as Swift MenuMetricsTests.
 */
class MenuMetricsTest {
    /** (name, usable w, usable h, dp per logical px, touch dp) */
    private val viewports = listOf(
        listOf("iphone17pro-portrait", 402, 778, 1.0, 44.0), listOf("iphone17pro-landscape", 750, 381, 1.0, 44.0),
        listOf("iphonese-portrait", 375, 647, 1.0, 44.0), listOf("iphonese-landscape", 667, 375, 1.0, 44.0),
        listOf("android-portrait", 360, 763, 3 / 2.625, 48.0), listOf("android-landscape", 784, 339, 3 / 2.625, 48.0),
        listOf("oppo-portrait", 360, 760, 1.0, 48.0), listOf("ipad-portrait", 417, 575, 2.0, 44.0), listOf("ipad-landscape", 597, 395, 2.0, 44.0),
        listOf("tablet-landscape", 640, 376, 2.0, 48.0), listOf("split-300", 300, 723, 1.0, 48.0), listOf("tiny", 160, 160, 1.0, 48.0),
        listOf("display-scale-1", 1080, 2300, 1 / 2.625, 48.0), listOf("display-scale-6", 180, 380, 6 / 2.625, 48.0),
    )

    private fun mm(v: List<Any>, large: Boolean = false, typing: Boolean = false) =
        MenuMetrics.compute(v[1] as Int, v[2] as Int, v[3] as Double, v[4] as Double, large, typing)

    @Test fun invariantsOverViewports() {
        for (v in viewports) for (large in listOf(false, true)) for (typing in listOf(false, true)) {
            val m = mm(v, large, typing); val dp = v[3] as Double; val w = v[1] as Int
            val tag = "${v[0]} large=$large typing=$typing $m"
            assertTrue("scale 1..4 $tag", m.textScale in 1..MenuMetrics.MAX_SCALE)
            assertTrue("a row holds its text and padding $tag", m.rowH >= m.glyphH + 8)
            assertTrue("bar and chrome hold their text $tag", m.barH >= m.glyphH + 6 && m.chromeH >= m.glyphH + 4)
            assertTrue("all sizes positive $tag", m.rowH > 0 && m.barH > 0 && m.chromeH > 0 && m.chromeBtnW > 0)
            if (m.textScale > 1) assertTrue("a menu row holds ${MenuMetrics.MIN_ROW_CHARS} characters $tag", (w - 16) / m.charW >= MenuMetrics.MIN_ROW_CHARS)
            if (!m.compact) assertTrue("touch-sized rows outside compact layouts $tag", m.rowH * dp >= (v[4] as Double) - 0.5)
            else assertTrue("compact rows stay usable (>= 34 dp) $tag", m.rowH * dp >= MenuMetrics.COMPACT_ROW_DP - 0.5 || m.rowH >= m.glyphH + 8)
        }
    }

    @Test fun phonesGetTwiceTheGlyphTabletsKeepTheirs() {
        for (n in listOf("iphone17pro-portrait", "iphone17pro-landscape", "iphonese-portrait", "android-portrait", "android-landscape", "oppo-portrait", "split-300"))
            assertEquals(n, 2, mm(viewports.first { it[0] == n }).textScale)
        // the AUTO display scale already draws tablets' 8x8 glyphs 16 dp tall: no further magnification
        for (n in listOf("ipad-portrait", "ipad-landscape", "tablet-landscape")) assertEquals(n, 1, mm(viewports.first { it[0] == n }).textScale)
        // the user's Display scale: a 1x display scale is compensated, a 6x one needs none
        assertEquals(4, mm(viewports.first { it[0] == "display-scale-1" }).textScale)
        assertEquals(1, mm(viewports.first { it[0] == "display-scale-6" }).textScale)
        // glyphs are 16 dp on every phone and tablet (within a dp)
        for (v in viewports.filter { it[0] != "tiny" && !(it[0] as String).startsWith("display") }) {
            val m = mm(v); assertEquals("${v[0]}", 16.0, m.glyphH * (v[3] as Double), 2.3)
        }
    }

    @Test fun landscapePhonesAreCompactPortraitIsNot() {
        assertTrue(mm(viewports.first { it[0] == "iphone17pro-landscape" }).compact)
        assertTrue(mm(viewports.first { it[0] == "android-landscape" }).compact)
        assertFalse(mm(viewports.first { it[0] == "iphone17pro-portrait" }).compact)
        assertFalse("a tablet in landscape has room", mm(viewports.first { it[0] == "ipad-landscape" }).compact)
        // LARGE keeps touch-sized rows in landscape, except while typing (V-31)
        val l = viewports.first { it[0] == "iphone17pro-landscape" }
        assertTrue(mm(l, large = true).rowH >= 44)
        assertTrue(mm(l, large = true, typing = true).rowH < 44)
    }

    @Test fun noJumpsBetweenNeighbouringSizes() {
        // widths around the MIN_ROW_CHARS threshold, heights around SHORT_DP: sizes change by at most one scale step
        var prev: MenuMetrics? = null
        for (w in 230..440 step 2) {
            val m = MenuMetrics.compute(w, 760, 1.0, 48.0, false, false)
            prev?.let { assertTrue("w=$w $it -> $m", Math.abs(it.textScale - m.textScale) <= 1 && Math.abs(it.rowH - m.rowH) <= 16) }
            prev = m
        }
        for (h in 480..560) assertEquals(2, MenuMetrics.compute(800, h, 1.0, 48.0, false, false).textScale)
    }

    // ------------------------------------------------------------ driven through the shell

    private fun shell(w: Int, h: Int, top: Int, bottom: Int, dp: Double, body: (Shell) -> Unit) {
        val dir = kotlin.io.path.createTempDirectory("tosm-mm").toFile()
        try {
            val sh = Shell(HeadlessEnv(dir)); sh.resize(w, h, top, bottom, 0, 0, 0, dp); sh.tick()
            Launch.doc(sh, "C:/Home/Welcome.DD"); sh.tick()
            body(sh)
            sh.windows.toList().forEach { it.app.close() }
        } finally { dir.deleteRecursively() }
    }

    private var t = 1000L
    private fun tap(sh: Shell, x: Int, y: Int) { sh.pointer(PointerEvent(Ptr.DOWN, x, y, 1, t)); t += 50; sh.pointer(PointerEvent(Ptr.UP, x, y, 1, t)); t += 50; sh.tick() }
    private fun node(sh: Shell, label: String): Rect { sh.tick(); return sh.accessibilityNodes().firstOrNull { it.label == label }?.rect ?: error("no '$label' in ${sh.accessibilityNodes().map { it.label }}") }
    private fun tapNode(sh: Shell, label: String) { val r = node(sh, label); tap(sh, r.x + r.w / 2, r.y + r.h / 2) }
    private fun key(sh: Shell, sc: Int, ch: Int = 0) { sh.key(ch, sc.toLong(), true); sh.key(ch, sc.toLong() or Keys.SCF_KEY_UP, false); sh.tick() }

    @Test fun drawnMenusMatchTheMetricsAndStayOnScreen() {
        for ((w, h, dp) in listOf(Triple(402, 874, 1.0), Triple(874, 402, 1.0), Triple(360, 800, 3 / 2.625), Triple(300, 760, 1.0), Triple(597, 417, 2.0))) shell(w, h, 20, 20, dp) { sh ->
            val m = sh.metrics
            sh.showStartMenu(); sh.tick()
            val menu = sh.openMenu!!
            val b = menu.bounds
            assertTrue("$w x $h: menu on screen $b", b.x >= 0 && b.y >= 20 && b.right <= w && b.bottom <= h - 20)
            val rows = sh.accessibilityNodes().filter { it.button && b.contains(it.rect.x + 1, it.rect.y + 1) }
            assertEquals(14, menu.items.size)
            assertTrue(rows.isNotEmpty() && rows.size <= menu.items.size + 2)
            for (r in rows) {
                assertTrue("$w x $h row ${r.label} ${r.rect} is ${m.rowH} tall", r.rect.h >= m.rowH)
                assertTrue("touch target", r.rect.h * dp >= (if (m.compact) MenuMetrics.COMPACT_ROW_DP else 44.0) - 0.5)
            }
            // rows tile without overlapping: a tap anywhere in a row selects that row only
            for (a in rows) for (c in rows) if (a !== c) assertFalse("${a.label} overlaps ${c.label}", a.rect.intersect(c.rect).w > 0 && a.rect.intersect(c.rect).h > 0)
            // the Games submenu stays under the top bar and inside the screen, whatever its length
            tapNode(sh, tr("menu.start.examples"))
            val sub = sh.openMenu!!
            assertTrue("submenu", sub.parent === menu)
            assertTrue("$w x $h: submenu below the bar ${sub.bounds}", sub.bounds.y >= 20 && sub.bounds.bottom <= h - 20)
            sh.back(); assertSame("back goes to the start menu", menu, sh.openMenu)
            sh.back(); assertNull(sh.openMenu)
        }
    }

    @Test fun touchKeysScrollAndSubmenus() = shell(402, 874, 62, 34, 1.0) { sh ->
        // open by tapping MENU; a row tap anywhere in its height runs it once
        tapNode(sh, tr("topbar.menu")); assertTrue(sh.popupOpen)
        val files = node(sh, tr("menu.start.files"))
        tap(sh, files.x + 2, files.bottom - 2)
        assertEquals("files", sh.focused?.app?.kind)
        assertEquals(2, sh.windows.size)
        // a tap outside closes the menu and reaches nothing under it
        tapNode(sh, tr("topbar.menu")); tap(sh, 395, 860)
        assertFalse(sh.popupOpen); assertEquals(2, sh.windows.size); assertEquals("files", sh.focused?.app?.kind)
        // keyboard: arrows select (TempleOS hover colors), Enter runs, Esc closes
        tapNode(sh, tr("topbar.menu"))
        key(sh, Keys.SC_CURSOR_DOWN); assertEquals(0, sh.openMenu!!.selected)
        key(sh, Keys.SC_CURSOR_DOWN); key(sh, Keys.SC_CURSOR_UP); assertEquals(0, sh.openMenu!!.selected)
        key(sh, Keys.SC_END); assertEquals(sh.openMenu!!.items.size - 1, sh.openMenu!!.selected)
        key(sh, Keys.SC_ESC, Keys.CH_ESC); assertFalse(sh.popupOpen)
        // Games: a long submenu scrolls (drag, arrow rows, End) and never loses its last item
        tapNode(sh, tr("topbar.menu")); tapNode(sh, tr("menu.start.examples"))
        // A deliberately long fixture exercises overflow independently of catalog size.
        val bounce = sh.catalog.byId("demo.bounce")!!
        sh.showMenu(listOf(MenuItem("Overflow") {
            sh.showMenu((0 until 30).map { i -> MenuItem("Entry $i") { Launch.program(sh, bounce.path, bounce) } }, 4, sh.insetTop + sh.barH, "Overflow fixture")
        }), 4, sh.insetTop + sh.barH, "Fixture parent")
        sh.tick();tapNode(sh,"Overflow")
        val games = sh.openMenu!!
        assertTrue(games.parent != null)
        val last = games.items.last().label
        key(sh, Keys.SC_END); assertEquals(games.items.size - 1, games.selected)
        node(sh, last) // on screen
        val firstShown = games.scroll
        val b = games.bounds
        sh.pointer(PointerEvent(Ptr.DOWN, b.x + 40, b.y + b.h / 2, 1, t)); t += 20
        sh.pointer(PointerEvent(Ptr.MOVE, b.x + 40, b.y + b.h / 2 + 3 * sh.metrics.rowH, 1, t)); t += 20
        sh.pointer(PointerEvent(Ptr.UP, b.x + 40, b.y + b.h / 2 + 3 * sh.metrics.rowH, 1, t)); t += 20; sh.tick()
        assertTrue("a drag scrolls ($firstShown -> ${games.scroll})", games.scroll < firstShown)
        assertSame("a drag runs nothing", games, sh.openMenu)
        tapNode(sh, tr("a11y.scroll_menu_up")); assertTrue(games.scroll < firstShown)
        // Left goes back to the start menu; Backspace too; a program from the list opens once
        key(sh, Keys.SC_CURSOR_LEFT); assertSame(games.parent, sh.openMenu)
        key(sh, Keys.SC_ESC, Keys.CH_ESC)
        sh.showStartMenu(); tapNode(sh, tr("menu.start.demos"))
        assertEquals("programs", sh.focused?.app?.kind)
        assertTrue(sh.accessibilityNodes().any { it.button && it.label == "Games: Beginner" })
        sh.showMenu(listOf(MenuItem("Bounce") { Launch.program(sh, bounce.path, bounce) }), 4, sh.insetTop + sh.barH, "Launch fixture")
        tapNode(sh, "Bounce")
        assertFalse(sh.popupOpen)
        assertEquals("program", sh.focused?.app?.kind)
        assertEquals(4, sh.windows.size)
    }

    @Test fun rotationRecomputesOpenMenus() = shell(402, 874, 62, 34, 1.0) { sh ->
        sh.showStartMenu(); sh.tick()
        val portrait = sh.openMenu!!.bounds
        assertEquals(1, sh.openMenu!!.cols)
        sh.resize(874, 402, 0, 21, 62, 62, 0); sh.tick()
        val m = sh.metrics
        assertTrue("landscape is compact", m.compact)
        val land = sh.openMenu!!.bounds
        assertTrue("the open menu was laid out again for landscape: $portrait -> $land", land != portrait && land.bottom <= 402 - 21 && land.x >= 62)
        val rows = sh.accessibilityNodes().filter { it.button && land.contains(it.rect.x + 1, it.rect.y + 1) }
        assertTrue(rows.all { it.rect.h == m.rowH })
        sh.resize(402, 874, 62, 34, 0, 0, 0); sh.tick()
        assertEquals("back in portrait: the same layout as before", portrait, sh.openMenu!!.bounds)
        sh.back()
        // a menu opened after the rotation has the new sizes at once
        sh.resize(874, 402, 0, 21, 62, 62, 0); sh.tick()
        sh.showStartMenu(); sh.tick()
        assertEquals(2, sh.openMenu!!.cols)
    }

    @Test fun legacyAndResponsiveScaleRatio() {
        // the measured enlargement of the report (docs/ui-normalization/TEMPLEOS_RESPONSIVE_MENU_UI.md): portrait phone
        val m = MenuMetrics.compute(402, 778, 1.0, 44.0, false, false)
        val l = MenuMetrics.LEGACY_STANDARD
        assertEquals(2.0, m.glyphH.toDouble() / l.glyphH, 0.0)
        assertTrue(m.rowH.toDouble() / l.rowH >= 2.0)
        assertEquals(2.0, m.barH.toDouble() / l.barH, 0.0)
    }
}

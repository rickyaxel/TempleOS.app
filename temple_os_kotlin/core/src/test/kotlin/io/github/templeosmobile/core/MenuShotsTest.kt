package io.github.templeosmobile.core

import io.github.templeosmobile.core.ui.*
import io.github.templeosmobile.core.kernel.Keys
import io.github.templeosmobile.core.kernel.Palette
import java.awt.image.BufferedImage
import java.io.File
import javax.imageio.ImageIO
import org.junit.Test

/**
 * Menu-layer screenshots and measurements at real device viewports (opt-in: -Dtempleos.menushots=<dir>).
 * The headless shell is sized as each device's TempleView sizes it (AUTO scale = shorter side / 360 device
 * px, insets in logical px), then the start menu, a submenu (scrolled to its end with the keyboard), a window
 * menu, a dialog and the window list are drawn. Every PNG is scaled by the device's integer factor, as on
 * the screen. Sizes are measured from what was drawn (accessibility nodes: the rects a tap hits), so the
 * same harness measures the code before the responsive menus (docs/ui-normalization/evidence/menu-sizing).
 */
class MenuShotsTest {
    class Device(val name: String, val w: Int, val h: Int, val top: Int, val bottom: Int, val left: Int, val right: Int,
                 val scale: Int, val dpPerPx: Double)

    companion object {
        // logical px = device px / AUTO scale; insets from the devices (status bar, home indicator, notch)
        val DEVICES = listOf(
            Device("iphone17pro-portrait", 402, 874, 62, 34, 0, 0, 3, 1.0),
            Device("iphone17pro-landscape", 874, 402, 0, 21, 62, 62, 3, 1.0),
            Device("iphonese-portrait", 375, 667, 20, 0, 0, 0, 2, 1.0),
            Device("iphonese-landscape", 667, 375, 0, 0, 0, 0, 2, 1.0),
            Device("android-emulator-portrait", 360, 800, 21, 16, 0, 0, 3, 3 / 2.625),
            Device("android-emulator-landscape", 800, 360, 21, 0, 0, 16, 3, 3 / 2.625),
            Device("ipadpro11-portrait", 417, 597, 12, 10, 0, 0, 4, 2.0),
            Device("ipadpro11-landscape", 597, 417, 12, 10, 0, 0, 4, 2.0),
            Device("pixeltablet-landscape", 640, 400, 12, 12, 0, 0, 4, 2.0),
            Device("split-narrow-portrait", 300, 760, 21, 16, 0, 0, 3, 1.0),
        )
    }

    @Test
    fun shots() {
        val out = System.getProperty("templeos.menushots")?.let { File(it) } ?: return
        out.mkdirs()
        val report = StringBuilder("[\n")
        for (d in DEVICES) {
            val dir = kotlin.io.path.createTempDirectory("tosm-menu").toFile()
            try {
                val env = object : ShellEnv by HeadlessEnv(dir) { override val touchTargetDp = if (d.name.startsWith("android") || d.name.startsWith("pixel") || d.name.startsWith("split")) 48.0 else 44.0 }
                val sh = Shell(env)
                sh.resize(d.w, d.h, d.top, d.bottom, d.left, d.right, 0, d.dpPerPx)
                Launch.doc(sh, "C:/Home/Welcome.DD"); sh.tick()
                fun nodes() = sh.accessibilityNodes()
                fun measure(tag: String): String {
                    sh.tick()
                    val ns = nodes()
                    val m = sh.openMenu?.bounds
                    val rows = ns.filter { it.button && m != null && m.contains(it.rect.x + 1, it.rect.y + 1) }.map { it.rect }
                    val menuChip = ns.firstOrNull { it.label == tr("topbar.menu") }?.rect
                    val chrome = sh.focused?.let { f -> ns.firstOrNull { it.label == tr("a11y.window_menu", "title" to f.app.title) }?.rect }
                    fun dp(v: Int) = "%.1f".format(java.util.Locale.ROOT, v * d.dpPerPx)
                    val mm = sh.metrics
                    return "  {\"device\": \"${d.name}\", \"view\": \"$tag\", \"logicalW\": ${d.w}, \"logicalH\": ${d.h}, \"dpPerPx\": ${"%.4f".format(java.util.Locale.ROOT, d.dpPerPx)}, " +
                        "\"textScale\": ${mm.textScale}, \"glyphDp\": ${dp(mm.glyphH)}, \"rowDp\": ${dp(mm.rowH)}, \"barDp\": ${dp(mm.barH)}, \"chromeDp\": ${dp(mm.chromeH)}, \"compact\": ${mm.compact}, " +
                        "\"menuChip\": ${menuChip?.let { "[${dp(it.w)}, ${dp(it.h)}]" } ?: "null"}, \"windowMenuButton\": ${chrome?.let { "[${dp(it.w)}, ${dp(it.h)}]" } ?: "null"}, " +
                        "\"dropdown\": ${m?.let { "[${dp(it.w)}, ${dp(it.h)}]" } ?: "null"}, \"columns\": ${sh.openMenu?.cols ?: 0}, " +
                        "\"rowsMinHDp\": ${rows.minOfOrNull { it.h }?.let { dp(it) } ?: "null"}, \"rowsMinWDp\": ${rows.minOfOrNull { it.w }?.let { dp(it) } ?: "null"}, \"rowsShown\": ${rows.size}}"
                }
                fun shot(tag: String) { report.append(measure(tag)).append(",\n"); save(sh, d, File(out, "${d.name}-$tag.png")) }
                shot("desktop")
                sh.showStartMenu(); shot("start-menu")
                // Games...: a long submenu; End selects its last item (keyboard), which scrolls it into view
                sh.tick()
                val g = nodes().first { it.label == tr("menu.start.games") }.rect
                sh.pointer(PointerEvent(Ptr.DOWN, g.x + g.w / 2, g.y + g.h / 2, 1, 900)); sh.pointer(PointerEvent(Ptr.UP, g.x + g.w / 2, g.y + g.h / 2, 1, 950)); shot("games-submenu")
                sh.key(0, Keys.SC_CURSOR_DOWN.toLong(), true); sh.key(0, Keys.SC_CURSOR_DOWN.toLong(), true); shot("games-submenu-keyboard")
                sh.key(0, Keys.SC_END.toLong(), true); shot("games-submenu-end")
                sh.back(); shot("back-to-start-menu")
                sh.back(); sh.tick()
                // a window menu (Welcome document) and a dialog
                val wm = nodes().first { it.label == tr("a11y.window_menu", "title" to sh.focused!!.app.title) }.rect
                sh.pointer(PointerEvent(Ptr.DOWN, wm.x + wm.w / 2, wm.y + wm.h / 2, 1, 1000)); sh.pointer(PointerEvent(Ptr.UP, wm.x + wm.w / 2, wm.y + wm.h / 2, 1, 1050)); shot("window-menu")
                sh.back()
                sh.showDialog(Dialog.choose(tr("dialog.choose"), "", listOf("EASY" to 0L, "MEDIUM" to 1L, "HARD" to 2L, "Return to the menu" to 3L), listOf(-1, -1, -1, -1)) {}); shot("dialog")
                sh.back()
                // several windows: the top bar's +N chip and the window list
                Launch.terminal(sh); Launch.editor(sh, null); Launch.files(sh, "C:/Home"); sh.tick()
                shot("three-more-windows")
                sh.showWindowList(); shot("window-list")
                sh.back()
                sh.windows.toList().forEach { it.app.close() }
            } finally { dir.deleteRecursively() }
        }
        if (report.endsWith(",\n")) report.setLength(report.length - 2)
        report.append("\n]\n")
        File(out, "menu-measurements.json").writeText(report.toString())
        println("menu shots: ${out.absolutePath}")
    }

    /** The surface scaled by the device's integer factor (nearest neighbour), program frames composited. */
    private fun save(sh: Shell, d: Device, f: File) {
        sh.tick()
        val s = sh.surface
        val k = d.scale
        val img = BufferedImage(s.width * k, s.height * k, BufferedImage.TYPE_INT_RGB)
        for (y in 0 until s.height * k) for (x in 0 until s.width * k) img.setRGB(x, y, Palette.STD[s.px[(y / k) * s.width + x / k].toInt() and 15])
        ImageIO.write(img, "png", f)
    }
}

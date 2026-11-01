package io.github.templeosmobile.core

import io.github.templeosmobile.core.ui.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File

/**
 * The shared half of TempleOS Mobile's typography (docs/typography/TEMPLEOS_TYPOGRAPHY.md): which text keeps the
 * TempleOS 8x8 font and which becomes a platform text run, the run geometry the platforms draw in, and the toast.
 * The platform half (rasterization at the display's resolution, ink fitting) is checked by the iOS UI test
 * testTypographyMatrix and tools/ui-audit/typography_matrix_android.py. Port: TypographyTests.swift.
 */
class TypographyTest {
    private val font = File(SHARED, "runtime/font8x8.bin").readBytes()
    private fun surface() = Surface(320, 480, font).also { it.measureNative = { s -> s.length * 10 } }

    @Test fun englishTextIsTheOriginalGlyphsMagnifiedByWholePixels() {
        // the TempleOS font, pixel for pixel: each font bit becomes a scale x scale block, nothing in between
        for (scale in 1..3) {
            val s = surface()
            s.uiText(4, 4, "TempleOS gyp", 14, scale = scale)
            assertTrue(s.runs.isEmpty())
            for ((i, ch) in "TempleOS gyp".withIndex()) for (row in 0 until 8) {
                val bits = font[ch.code * 8 + row].toInt() and 0xFF
                for (col in 0 until 8) {
                    val on = (bits ushr col) and 1 != 0 // bit c is column c (Kernel/FontStd.HC layout)
                    val px = s.px[(4 + row * scale) * s.width + 4 + (i * 8 + col) * scale].toInt()
                    for (dy in 0 until scale) for (dx in 0 until scale)
                        assertEquals("'$ch' row $row col $col scale $scale", px, s.px[(4 + row * scale + dy) * s.width + 4 + (i * 8 + col) * scale + dx].toInt())
                    assertEquals("'$ch' row $row col $col", if (on) 14 else 0, px)
                }
            }
        }
    }

    @Test fun everyCatalogsLabelsAreGlyphsOrOneUnsplitRun() {
        val dir = File(SHARED, "runtime/l10n")
        val keys = listOf("topbar.menu", "menu.start.god_words", "menu.start.settings", "menu.start.about", "god.button.ten_words")
        var runs = 0
        for (f in dir.listFiles()!!.filter { it.name.endsWith(".json") && it.name != "locales.json" }) {
            @Suppress("UNCHECKED_CAST") val cat = Json.parse(f.readText()) as Map<String, Any?>
            for (k in keys) {
                val text = cat[k] as? String ?: continue
                val s = surface()
                s.uiText(10, 40, text, 1, scale = 2)
                if (Cp437.representable(text)) assertTrue("${f.name} $k", s.runs.isEmpty())
                else {
                    runs++
                    assertEquals("${f.name} $k: one run", 1, s.runs.size)
                    val r = s.runs[0]
                    assertEquals("${f.name} $k: the whole string, in logical order (shaping and bidi are the platform's)", text, r.text)
                    assertEquals("12 rows at scale 2", Rect(10, 36, r.w, 24).let { listOf(it.y, it.h) }, listOf(r.clip.y, r.clip.h))
                }
            }
        }
        assertTrue("most catalogs need runs: $runs", runs > 150)
    }

    @Test fun aRunsInkBoxEndsWhereSomethingDrawnAboveItBegins() {
        val s = surface()
        s.uiText(10, 40, "日本語", 1)           // row 40..48, box 38..50
        val r = s.runs.single()
        assertEquals(38 to 50, Surface.runInkBox(r, emptyList()))
        s.layer(Rect(0, 48, 320, 20))           // a bar from y 48 across the run, drawn later
        assertEquals(38 to 48, Surface.runInkBox(r, s.occluders))
        s.layer(Rect(0, 0, 320, 39))            // and one above, ending at 39
        assertEquals(39 to 48, Surface.runInkBox(r, s.occluders))
        // what is drawn before the run, or beside it, does not count
        assertEquals(38 to 50, Surface.runInkBox(r, listOf(Surface.Occluder(Rect(0, 48, 320, 20), 0), Surface.Occluder(Rect(200, 30, 50, 50), 9))))
    }

    @Test fun aBorderTitleIsFittedToItsBand() {
        val s = surface()
        s.border(Rect(8, 100, 200, 80), 1, 15, true, " 神の言葉 ")
        val r = s.runs.single()
        assertEquals("the 8-row band, not 2 rows into the window's chrome bar", listOf(100, 108), listOf(r.clip.y, r.clip.bottom))
        val e = surface()
        e.border(Rect(8, 100, 200, 80), 1, 15, true, " Sound ")
        assertTrue(e.runs.isEmpty())
    }

    @Test fun aLocalizedToastIsDrawnAsLocalizedText() {
        val dir = kotlin.io.path.createTempDirectory("tosm-typo").toFile()
        try {
            val sh = Shell(HeadlessEnv(dir))
            sh.resize(640, 640); sh.restoreSession(); sh.tick()
            val msg = "Guardado: año, łódź, 保存しました"
            sh.showToast(msg); sh.tick()
            assertTrue("the toast is one run with the whole message: ${sh.surface.runs.map { it.text }}", sh.surface.runs.any { it.text == msg })
            sh.resize(240, 640); sh.showToast(msg); sh.tick()
            val toast = sh.accessibilityNodes().first { it.label == msg }.rect
            assertTrue("full message remains accessible", toast.x >= 0 && toast.right <= sh.width)
            assertTrue(sh.surface.runs.any { it.text.contains("łódź") })
            assertTrue(sh.surface.runs.any { it.text.contains("保存しました") })
            assertTrue("wrapped native lines stay inside the toast", sh.surface.runs.all { it.clip.y >= toast.y && it.clip.bottom <= toast.bottom })
            sh.showToast("Saved."); sh.tick()
            assertFalse(sh.surface.runs.any { it.text == "Saved." }) // the TempleOS font
        } finally { dir.deleteRecursively() }
    }
}

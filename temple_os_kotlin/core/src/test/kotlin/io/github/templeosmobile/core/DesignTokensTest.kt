package io.github.templeosmobile.core

import io.github.templeosmobile.core.kernel.Palette
import io.github.templeosmobile.core.ui.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File

/**
 * The code must match shared/specifications/templeos-ui/tokens.json, the one visual
 * specification both apps follow (DesignTokensTests.swift checks the Swift side).
 */
class DesignTokensTest {
    @Suppress("UNCHECKED_CAST")
    private val tokens = Json.parse(File(SHARED, "specifications/templeos-ui/tokens.json").readText()) as Map<String, Any?>
    @Suppress("UNCHECKED_CAST")
    private fun obj(m: Any?, k: String) = (m as Map<String, Any?>)[k]
    private fun int(v: Any?) = (v as Number).toInt()
    private val names = listOf("BLACK", "BLUE", "GREEN", "CYAN", "RED", "PURPLE", "BROWN", "LTGRAY",
        "DKGRAY", "LTBLUE", "LTGREEN", "LTCYAN", "LTRED", "LTPURPLE", "YELLOW", "WHITE")

    @Test fun paletteMatchesTokensAndTempleOs() {
        @Suppress("UNCHECKED_CAST")
        val colors = obj(obj(tokens, "palette"), "colors") as List<Map<String, Any?>>
        assertEquals(16, colors.size)
        for (c in colors) {
            val i = int(c["index"])
            assertEquals(names[i], c["name"])
            assertEquals("palette $i", (c["rgb"] as String).substring(1).toInt(16), Palette.STD[i] and 0xFFFFFF)
        }
        // and the original: Adam/Gr/GrPalette.HC gr_palette_std (CBGR48: r<<32 | g<<16 | b)
        val src = File(REFERENCE, "original-templeos/Adam/Gr/GrPalette.HC")
        if (src.exists()) {
            val block = src.readText().substringAfter("gr_palette_std[COLORS_NUM]={").substringBefore("};")
            val vals = Regex("0x([0-9A-Fa-f]{12})").findAll(block).map { it.groupValues[1].toLong(16) }.toList()
            assertEquals(16, vals.size)
            for ((i, v) in vals.withIndex()) {
                val rgb = (((v shr 32) and 0xFFFF) shr 8 shl 16) or (((v shr 16) and 0xFFFF) shr 8 shl 8) or ((v and 0xFFFF) shr 8)
                assertEquals("GrPalette.HC entry $i", rgb.toInt(), Palette.STD[i] and 0xFFFFFF)
            }
        }
    }

    @Test fun buttonFacesFollowTheTokens() {
        val faces = obj(obj(tokens, "button"), "faces")
        fun face(k: String) = names.indexOf(obj(faces, k) as String)
        assertEquals(face("normal"), ButtonFace.NORMAL)
        assertEquals(face("action"), ButtonFace.ACTION)
        assertEquals(face("selected"), ButtonFace.SELECTED)
        assertEquals(face("pressed"), ButtonFace.PRESSED)
        assertEquals(face("character"), ButtonFace.CHARACTER)
        assertEquals(face("locked"), ButtonFace.LOCKED)
        assertEquals(face("destructive"), ButtonFace.DESTRUCTIVE)
        assertEquals(2, int(obj(obj(tokens, "button"), "inset")))
    }

    @Test fun metricsFollowTheTokensInBothSizes() {
        val metrics = obj(tokens, "metrics")
        try {
            for ((mode, large) in listOf("standard" to false, "large" to true)) {
                Touch.large = large
                val m = obj(metrics, mode)
                val actual = mapOf("rowH" to Touch.rowH, "topBar" to Touch.topBar, "chrome" to Touch.chrome, "chromeBtn" to Touch.chromeBtn,
                    "keyRow" to Touch.keyRow, "header" to Touch.header, "editorHeader" to Touch.editorHeader, "button" to Touch.button,
                    "toolRow" to Touch.toolRow, "kbdRow" to Touch.kbdRow)
                for ((k, v) in actual) assertEquals("$mode.$k", int(obj(m, k)), v)
            }
        } finally { Touch.large = false }
        val kb = obj(metrics, "keyboard")
        assertEquals(int(obj(kb, "repeatDelayMs")).toLong(), TempleKeyboard.REPEAT_DELAY_MS)
        assertEquals(int(obj(kb, "repeatMs")).toLong(), TempleKeyboard.REPEAT_MS)
        assertEquals(int(obj(metrics, "longPressMs")).toLong(), Shell.LONG_PRESS_MS)
    }
}

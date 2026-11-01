package io.github.templeosmobile.core

import io.github.templeosmobile.core.holyc.latin1
import io.github.templeosmobile.core.kernel.*
import org.junit.Assert.*
import org.junit.Test

/**
 * The TempleOS screen and program end (docs/fidelity-audit, FA-11..FA-16). References:
 * Adam/Gr/GrScrn.HC (GrUpdateTextBG/FG: text.font, pan_text, blink), Demo/Games/ElephantWalk.HC
 * and Demo/Graphics/MouseDemo.HC (drawing only on gr.dc), Demo/Graphics/CharAnimation.HC (a task
 * that outlives the program's code), Demo/Graphics/Extents.HC (output printed just before the end).
 */
class ScreenFidelityTest {
    /** Run in virtual time until [vtMs] or the end; returns the kernel. */
    private fun run(src: String, vtMs: Long = 3000, setup: (Kernel) -> Unit = {}): Kernel {
        val k = Kernel(TestEnv(), "test")
        k.virtualTime = true
        k.boot()
        setup(k)
        k.runProgram("C:/Home/Test.HC", latin1(src))
        val deadline = System.nanoTime() + 20_000_000_000L
        k.virtualStopAt = vtMs * 1_000_000
        while (System.nanoTime() < deadline && k.now() < k.virtualStopAt) if (k.step(50_000_000) < 0) break
        return k
    }

    private fun px(k: Kernel, x: Int, y: Int) = k.published[y * Kernel.W + x].toInt()

    @Test fun drawingOnlyOnGrDcIsGraphics() {
        val k = run("GrPlot(gr.dc,10,10);while (TRUE) Refresh;", 500)
        assertTrue("a program that only draws on gr.dc (ElephantWalk, MouseDemo, SunMoon) is shown as graphics", k.graphicsUsed)
    }

    @Test fun paletteChangeShowsTheScreen() {
        val k = run("\"colors\\n\";GrPaletteColorSet(WHITE,0);while (TRUE) Refresh;", 500)
        assertTrue("Demo/Graphics/Palette.HC changes what the whole screen looks like", k.graphicsUsed)
    }

    /** CharAnimation edits the glyphs through text.font; the text layer must draw with it. */
    @Test fun textLayerUsesTextFont() {
        val k = run("U64 *f=MAlloc(256*8);MemCpy(f,text.font,256*8);f['A']=-1;text.font=f;" +
            "WinBorder;WinMax;DocClear;\"A\";GrPlot(gr.dc,600,400);while (TRUE) Refresh;", 600)
        // 'A' at text cell (0,1) of the borderless window: screen (0,8); every pixel of the glyph is set
        for (y in 8 until 16) for (x in 0 until 8) assertEquals("pixel $x,$y of the replaced glyph", Palette.BLUE, px(k, x, y))
    }

    /** gr.pan_text_x/y move the whole text layer by pixels (CharDemo's smooth scrolling, PanText). */
    @Test fun panTextMovesTheTextLayer() {
        val k = run("WinBorder;WinMax;DocClear;\"\$BG,RED\$ \";gr.pan_text_x=3;gr.pan_text_y=2;GrPlot(gr.dc,600,400);while (TRUE) Refresh;", 600)
        // the red cell at (0,8) moves to (3,10); the 3-px left strip is blanked (BLACK)
        assertEquals(Palette.RED, px(k, 3, 10))
        assertEquals(Palette.RED, px(k, 10, 17))
        assertEquals(Palette.BLACK, px(k, 1, 12))
    }

    /** Blink swaps a cell's colors (it does not hide the glyph), at 2.5 Hz (Kernel/KMisc.HC Blink). */
    @Test fun blinkSwapsColors() {
        val src = "WinBorder;WinMax;DocClear;\"\$BK,1\$\$BG,RED\$\$FG,YELLOW\$ \";GrPlot(gr.dc,600,400);while (TRUE) Refresh;"
        val seen = HashSet<Int>()
        for (t in listOf(300L, 500L, 700L, 900L)) seen.add(px(run(src, t), 4, 12))
        assertEquals("the cell alternates between its background and its foreground color", setOf(Palette.RED, Palette.YELLOW), seen)
    }

    @Test fun spawnedTasksOutliveTheProgramsCode() {
        val k = run("U0 Child(U8 *) {Sleep(500);\"child done\\n\";}\nSpawn(&Child,NULL,\"Child\",,Fs);\"main done\\n\";", 2000)
        val out = k.console.plainText()
        assertTrue(out, out.contains("main done") && out.contains("child done"))
        assertTrue("ended once the last task ended", k.finished)
    }

    @Test fun stopEndsEverySpawnedTask() {
        val k = run("U0 Child(U8 *) {while (TRUE) Sleep(10);}\nSpawn(&Child,NULL,\"Child\",,Fs);while (TRUE) Sleep(10);", 300)
        k.post(KInput.Break)
        k.virtualStopAt = 2_000_000_000
        val deadline = System.nanoTime() + 10_000_000_000L
        while (System.nanoTime() < deadline && !k.finished) k.step(50_000_000)
        assertTrue("Stop ended the program and its Child task", k.finished)
    }

    /** Text printed just before the end is on the last frame (Extents prints its result and returns). */
    @Test fun lastOutputIsOnTheFinalFrame() {
        val k = run("WinBorder;WinMax;DocClear;GrPlot(gr.dc,600,400);Refresh;\"\$BG,RED\$ \";", 1000)
        assertTrue(k.finished)
        assertEquals(Palette.RED, px(k, 4, 12))
    }
}

package io.github.templeosmobile.core

import io.github.templeosmobile.core.holyc.latin1
import io.github.templeosmobile.core.kernel.*
import org.junit.Assert.*
import org.junit.Test

/**
 * Programs see TempleOS's window coordinates (docs/fidelity-audit, FA-01). The values below follow
 * from the original arithmetic: Kernel/Display.HC WinDerivedValsUpdate (pix = FONT_WIDTH * text
 * cell) and Adam/Win.HC WinMax (text columns 1..TEXT_COLS-2 and rows 2..TEXT_ROWS-2 with a border,
 * 0..TEXT_COLS-1 and 1..TEXT_ROWS-1 without one). The VM reference (QEMU, official ISO) draws
 * TicTacToe's grid 8 px right and 16 px down of where a 640x480 client put it.
 */
class WindowGeometryTest {
    private fun geom(setup: String): String {
        val k = runHolyC(latin1(setup + "\"%d %d %d %d\\n\",Fs->pix_left,Fs->pix_top,Fs->pix_width,Fs->pix_height;\n"))
        return k.console.plainText().trim().lines().last()
    }

    @Test fun initialWindowIsAMaximizedTerminalWithBorder() = assertEquals("8 16 624 456", geom(""))

    @Test fun borderlessMaximizedGameWindow() = assertEquals("0 8 640 472", geom("WinBorder;WinMax;"))

    @Test fun borderedMaximizedWindow() = assertEquals("8 16 624 456", geom("WinBorder(ON);WinMax;"))

    /** Demo/Games/FlapBat.HC: WinBorder(ON); WinHorz(1,TEXT_COLS/2); WinVert(2,TEXT_ROWS/2); */
    @Test fun flapBatHalfWindow() =
        assertEquals("8 16 320 232", geom("WinBorder(ON);WinHorz(1,TEXT_COLS/2);WinVert(2,TEXT_ROWS/2);"))

    @Test fun windowRestoredBySettingsPop() =
        assertEquals("8 16 624 456", geom("SettingsPush;WinBorder;WinMax;SettingsPop;"))

    /** SettingsPop restores the palette ("SettingsPop() restores original palette", Demo/Graphics/Palette.HC). */
    @Test fun settingsPopRestoresPalette() {
        val k = runHolyC(latin1("SettingsPush;GrPaletteColorSet(WHITE,0);SettingsPop;\"%X\\n\",GrPaletteColorGet(WHITE);\n"))
        assertEquals("FFFFFFFFFFFF", k.console.plainText().trim().lines().last())
    }

    @Test fun drawingAndPublishedWindowFollowTheWindow() {
        val k = runHolyC(latin1("WinBorder;WinMax;CDC *dc=DCAlias;dc->color=RED;GrPlot(dc,0,0);DCDel(dc);Refresh;Refresh;\n"))
        // client (0,0) is screen (0,8): the borderless maximized window starts below the system bar row
        assertEquals(Palette.RED, k.published[8 * Kernel.W].toInt())
        assertArrayEquals(intArrayOf(0, 8, 640, 472), k.publishedWindow)
    }

    /** Adam/WinMgr.HC WinQueIPMsgs: msg args are ms.pos minus the window's pix_left/pix_top; ms.pos is the screen. */
    @Test fun mouseMessagesAreWindowRelative() {
        val k = runHolyC(latin1("WinBorder(ON);WinMax;I64 a1,a2,c;do c=GetMsg(&a1,&a2,1<<MSG_MS_L_DOWN); while (!c);" +
            "\"%d %d %d %d\\n\",a1,a2,ms.pos.x,ms.pos.y;\n")) { kk ->
            kk.post(KInput.Mouse(100, 116, true, false))
        }
        assertEquals("92 100 100 116", k.console.plainText().trim().lines().last())
    }
}

package io.github.templeosmobile.core

import io.github.templeosmobile.core.holyc.latin1
import io.github.templeosmobile.core.kernel.*
import org.junit.Assert.*
import org.junit.Test

/**
 * TempleOS input semantics (docs/fidelity-audit, FA-04..FA-10). Expected values come from the
 * original sources: Kernel/SerialDev/Keyboard.HC (KbdBuildSC, ScanCode2Char, KbdHndlr),
 * Kernel/SerialDev/Mouse.HC (MsSet, MsUpdate, MsHardSpeedSet), Adam/Win.HC (ms.speed) and
 * Adam/WinMgr.HC (WinQueIPMsgs, grab scroll, double click = ESC).
 */
class InputFidelityTest {
    private fun last(k: Kernel) = k.console.plainText().trim().lines().last().trim()

    /** WinQueIPMsgs runs once per window manager frame: many pointer moves become one MSG_MS_MOVE. */
    @Test fun pointerMovesAreOneMessagePerFrame() {
        val k = runHolyC(latin1("I64 n=0,a,b;F64 t0=tS;while (tS-t0<0.3) {while (ScanMsg(&a,&b,1<<MSG_MS_MOVE)) n++;Sleep(1);}\"%d\\n\",n;\n")) { kk ->
            for (i in 1..100) kk.post(KInput.Mouse(10 + i, 20 + i, false, false))
        }
        assertEquals("1", last(k))
    }

    @Test fun msSetMovesThePointerAndTheWheel() {
        val k = runHolyC(latin1("MsSet(100,200,25);Refresh;\"%d %d %d\\n\",ms.pos.x,ms.pos.y,ms.pos.z;\n"))
        assertEquals("100 200 25", last(k))
    }

    /** ms.speed: pixels per second of the last motion (Speedline and Life draw thicker lines with it). */
    @Test fun msSpeedFollowsTheMotion() {
        val k = runHolyC(latin1("MsSet(0,0);Sleep(100);MsSet(300,400);Refresh;\"%d\\n\",ToI64(ms.speed);\n"))
        val v = last(k).toLong()
        assertTrue("500 px in ~0.1 s gives ~5000 px/s, got $v", v in 3500..6000)
    }

    @Test fun heldShiftAndCtrlChangeCharAndFlags() {
        val (_, a) = Keys.forChar('a'.code)
        val k = runHolyC(latin1("I64 sc,c1,c2;c1=GetKey(&sc);c2=GetKey;\"%d %d %d %d\\n\",c1,!!(sc&SCF_SHIFT),Bt(kbd.down_bitmap,SC_SHIFT),c2;\n")) { kk ->
            kk.post(KInput.Key(0, Keys.SC_SHIFT.toLong(), true))
            kk.post(KInput.Key('a'.code, a, true))
            kk.post(KInput.Key(0, Keys.SC_SHIFT.toLong() or Keys.SCF_KEY_UP, false))
            kk.post(KInput.Key(0, Keys.SC_CTRL.toLong(), true))
            kk.post(KInput.Key('a'.code, a, true))
        }
        // GetKey also returns the SHIFT and CTRL key-downs themselves (ASCII 0) and skips nothing:
        // the first GetKey is SHIFT (0); TempleOS programs use GetChar to skip them
        val k2 = runHolyC(latin1("I64 c1=GetChar(,FALSE),c2=GetChar(,FALSE);\"%d %d %d\\n\",c1,c2,Bt(kbd.down_bitmap,SC_CTRL);\n")) { kk ->
            kk.post(KInput.Key(0, Keys.SC_SHIFT.toLong(), true))
            kk.post(KInput.Key('a'.code, a, true))
            kk.post(KInput.Key(0, Keys.SC_SHIFT.toLong() or Keys.SCF_KEY_UP, false))
            kk.post(KInput.Key(0, Keys.SC_CTRL.toLong(), true))
            kk.post(KInput.Key('a'.code, a, true))
        }
        assertEquals("0 1 1 65", last(k))
        assertEquals("65 1 1", last(k2))
    }

    /** kbd.down_bitmap2 is indexed with the distinct scan code: E0 keys have bit 7 set. */
    @Test fun downBitmap2UsesTheE0Bit() {
        val (cu, su) = Keys.special(Keys.SC_CURSOR_UP)
        val k = runHolyC(latin1("GetKey;\"%d %d %d\\n\",Bt(kbd.down_bitmap,SC_CURSOR_UP),Bt(kbd.down_bitmap2,SC_CURSOR_UP|0x80),Bt(kbd.down_bitmap2,SC_CURSOR_UP);\n")) { kk ->
            kk.post(KInput.Key(cu, su, true))
        }
        assertEquals("1 1 0", last(k))
    }

    /** CTRL-ALT-letter never reaches the program (KbdBuildSC clears SCF_NEW_KEY). */
    @Test fun ctrlAltLettersAreTheSystems() {
        val (_, x) = Keys.forChar('x'.code)
        val (_, b) = Keys.forChar('b'.code)
        val k = runHolyC(latin1("I64 c=GetChar(,FALSE);\"%d\\n\",c;\n")) { kk ->
            kk.post(KInput.Key('x'.code, x or Keys.SCF_CTRL or Keys.SCF_ALT, true))
            kk.post(KInput.Key('b'.code, b, true))
        }
        assertEquals("98", last(k))
    }

    private val clicker = "U0 Clicker(U8 *) {Sleep(100);MsSet(100,100,,1);Sleep(60);MsSet(,,,0);Sleep(60);MsSet(,,,1);Sleep(60);MsSet(,,,0);}\n"

    /**
     * A double left click in the window of a task that keeps double clicks (the user terminal's
     * WIG_USER_TASK_DFT) is the ESC key, sent with scan code 0 (Adam/WinMgr.HC).
     */
    @Test fun doubleClickIsEsc() {
        val k = runHolyC(latin1(clicker + "Spawn(&Clicker);I64 sc,ch=GetKey(&sc);\"%d %d\\n\",ch,sc;\n"))
        assertEquals("27 0", last(k))
    }

    /** With WIG_DBL_CLICK in win_inhibit (games' WIG_TASK_DFT) the same clicks are two plain clicks. */
    @Test fun dblClickInhibitGivesPlainClicks() {
        val k = runHolyC(latin1(clicker + "Fs->win_inhibit=WIG_TASK_DFT;Spawn(&Clicker);I64 n=0,a,b,c,keys=0;F64 t0=tS;" +
            "while (tS-t0<1.0) {while (c=ScanMsg(&a,&b,1<<MSG_MS_L_DOWN|1<<MSG_MS_L_D_DOWN|1<<MSG_KEY_DOWN)) {if (c==MSG_MS_L_DOWN) n++; else keys++;} Sleep(1);}" +
            "\"%d %d\\n\",n,keys;\n"))
        assertEquals("2 0", last(k))
    }

    /** Without the inhibit a single click is reported ms.dbl_time (0.35 s) late, at the press position. */
    @Test fun singleClickWaitsForTheDoubleClickTime() {
        val one = "U0 Clicker(U8 *) {Sleep(100);MsSet(100,100,,1);Sleep(60);MsSet(,,,0);}\n"
        val k = runHolyC(latin1(one + "Spawn(&Clicker);F64 t0=tS;I64 a,b;GetMsg(&a,&b,1<<MSG_MS_L_DOWN);\"%d\\n\",ToI64((tS-t0)*1000);\n"))
        val ms = last(k).toLong()
        assertTrue("left down after $ms ms (press at 100 ms + 350 ms)", ms in 440..520)
        val k2 = runHolyC(latin1(one + "Fs->win_inhibit=WIG_TASK_DFT;Spawn(&Clicker);F64 t0=tS;I64 a,b;GetMsg(&a,&b,1<<MSG_MS_L_DOWN);\"%d\\n\",ToI64((tS-t0)*1000);\n"))
        val ms2 = last(k2).toLong()
        assertTrue("left down after $ms2 ms (press at 100 ms)", ms2 in 95..160)
    }

    /** CTRL + left drag scrolls the window by whole characters and sends no mouse messages (grab scroll). */
    @Test fun ctrlDragScrollsTheWindow() {
        val drag = "U0 Drag(U8 *) {Sleep(50);MsSet(100,100,,1);Sleep(50);MsSet(140,120);Sleep(50);MsSet(,,,0);}\n"
        val k = runHolyC(latin1(drag + "Spawn(&Drag);I64 n=0,a,b;F64 t0=tS;" +
            "while (tS-t0<0.5) {while (ScanMsg(&a,&b,1<<MSG_MS_L_DOWN|1<<MSG_MS_MOVE)) n++; Sleep(1);}" +
            "\"%d %d %d\\n\",Fs->scroll_x,Fs->scroll_y,n;\n")) { kk ->
            kk.post(KInput.Key(0, Keys.SC_CTRL.toLong(), true))
        }
        assertEquals("40 16 0", last(k))
    }
}

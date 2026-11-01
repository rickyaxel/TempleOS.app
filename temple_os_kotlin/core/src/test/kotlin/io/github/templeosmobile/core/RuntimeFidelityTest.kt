package io.github.templeosmobile.core

import io.github.templeosmobile.core.holyc.latin1
import io.github.templeosmobile.core.kernel.*
import org.junit.Assert.*
import org.junit.Test

/**
 * Smaller runtime fidelity fixes (docs/fidelity-audit FA-23..FA-28): the console's newline fill
 * (Adam/DolDoc/DocRecalc.HC:724), no artificial task cap (TempleOS spawns until memory runs out),
 * a paused program not seeing the paused time pass (TempleOS has no pause), the original line
 * input (GetStr, GetI64, View) and the terminal's scroll bars.
 */
class RuntimeFidelityTest {
    @Test fun newlineFillsTheRestOfTheRowWithTheCurrentColors() {
        val c = Console()
        c.write("\$BG,RED\$x\n\$BG\$y")
        val cols = 10
        val dst = IntArray(cols * 2)
        c.renderCells(dst, cols, 2, (Console.DFT_BG shl 4) or Console.DFT_FG)
        for (x in 1 until cols) assertEquals("row 0 col $x takes RED from the newline", Palette.RED, (dst[x] shr 12) and 15)
        assertEquals("row 1 after 'y' keeps the window color", Console.DFT_BG, (dst[cols + 3] shr 12) and 15)
    }

    @Test fun manyTasksAreAllowed() {
        // BomberGolf: one 3 s Noise task per bomb, about 90 at once while SPACE repeats
        val env = object : TestEnv() { override val memoryLimit: Int get() = 64 shl 20 }
        val k = runHolyC(latin1("U0 T(U8 *) {Sleep(1000);}\nI64 i;for (i=0;i<100;i++) Spawn(&T,NULL,\"T\");\"spawned %d\\n\",i;\n"), env = env)
        assertFalse(k.console.plainText(), k.console.plainText().contains("TooMany"))
        assertTrue(k.console.plainText(), k.console.plainText().contains("spawned 100"))
    }

    private fun last(k: Kernel) = k.console.plainText().trim().lines().last().trim()
    private fun runRealTime(src: ByteArray): Kernel {
        val k = Kernel(TestEnv(), "test")
        k.boot()
        k.runProgram("C:/Home/Test.HC", src)
        val deadline = System.nanoTime() + 20_000_000_000L
        while (System.nanoTime() < deadline) {
            val r = k.step(50_000_000)
            if (r < 0) break
            if (r > 0) Thread.sleep(r / 1_000_000, (r % 1_000_000).toInt())
        }
        return k
    }
    private fun key(ch: Int) = Keys.forChar(ch).let { (c, sc) -> KInput.Key(c, sc, true) }
    private val shiftEsc = KInput.Key(Keys.CH_SHIFT_ESC, Keys.SC_ESC.toLong() or Keys.SCF_SHIFT, true)
    private fun type(k: Kernel, s: String) { for (c in s) k.post(key(c.code)) }

    /** Adam/DolDoc/DocEd.HC View: only ESC (TRUE) and SHIFT-ESC (FALSE) end it; ENTER and SPACE do not. */
    @Test fun viewEndsOnlyOnEscOrShiftEsc() {
        val k = runHolyC(latin1("\"%d\\n\",View;\n")) { kk -> type(kk, "\n x"); kk.post(key(Keys.CH_ESC)) }
        assertEquals("x1", last(k)) // View edits the document before returning ESC
        val k2 = runHolyC(latin1("\"%d\\n\",View;\n")) { kk -> type(kk, "\n"); kk.post(shiftEsc) }
        assertEquals("0", last(k2))
    }

    /** Adam/DolDoc/DocGet.HC DocGetStr2: ESC does not end or clear a prompt; SHIFT-ESC returns "" (so the default). */
    @Test fun getStrIgnoresEscAndShiftEscGivesTheDefault() {
        val k = runHolyC(latin1("U8 *s=GetStr(\"?\");\"[%s]\\n\",s;\n")) { kk -> type(kk, "ab"); kk.post(key(Keys.CH_ESC)); type(kk, "c\n") }
        assertEquals("[abc]", last(k))
        val k2 = runHolyC(latin1("U8 *s=GetStr(,\"dft\");\"[%s]\\n\",s;\n")) { kk -> type(kk, "ab"); kk.post(shiftEsc) }
        assertEquals("the typed text stays on the line", "ab[dft]", last(k2))
        // GSF_SHIFT_ESC_EXIT ends the task instead
        val k3 = runHolyC(latin1("GetStr(,,GSF_SHIFT_ESC_EXIT);\"after\\n\";\n")) { kk -> kk.post(shiftEsc) }
        assertFalse(k3.console.plainText(), k3.console.plainText().contains("after"))
        // GSF_WITH_NEW_LINE: ENTER starts a new line, ESC ends the text
        val k4 = runHolyC(latin1("U8 *s=GetStr(,,GSF_WITH_NEW_LINE);\"\\n%d %d\\n\",StrLen(s),s[1];\n")) { kk -> type(kk, "a\nb"); kk.post(key(Keys.CH_ESC)) }
        assertEquals("3 10", last(k4))
    }

    /** Adam/DolDoc/DocGet.HC GetI64: the answer is an expression; a bad one or one out of range asks again. */
    @Test fun getI64EvaluatesAndAsksAgain() {
        val k = runHolyC(latin1("\"=%d\\n\",GetI64(\"n:\",7,0,100);\n")) { kk -> type(kk, "nonsense\n500\n6*7\n") }
        assertEquals("=42", last(k))
        val k2 = runHolyC(latin1("\"=%d\\n\",GetI64(\"n:\",7,0,100);\n")) { kk -> type(kk, "\n") }
        assertEquals("=7", last(k2))
        val k3 = runHolyC(latin1("\"=%.2f\\n\",GetF64(\"x:\",1.0);\n")) { kk -> type(kk, "1/4.0\n") }
        assertEquals("=0.25", last(k3))
        // Compiler/OptPass012.HC: ToF64 of an F64 and ToI64 of an I64 leave the value as it is
        val k4 = runHolyC(latin1("F64 z=0.5;\"%.3f %d %.3f %.3f\\n\",ToF64(1/4.0),ToI64(2.75),ToF64(z),ToF64(3);\n"))
        assertEquals("0.250 2 0.500 3.000", last(k4))
    }

    /**
     * A program runs in the user's terminal task, which has the window's two scroll bars
     * (Adam/DolDoc/DocTerm.HC:49 WinScrollsInit); the wheel moves the vertical one
     * (Adam/WinMgr.HC wheel_chg). They do not make a text program a graphics one.
     */
    @Test fun programsHaveTheTerminalScrollBars() {
        val k = runHolyC(latin1("CCtrl *h=CtrlFindUnique(Fs,CTRLT_WIN_HSCROLL),*v=CtrlFindUnique(Fs,CTRLT_WIN_VSCROLL);" +
            "Refresh(2);\"%d %d\\n\",h!=NULL,v!=NULL;\n"))
        assertEquals("1 1", last(k))
        assertFalse("scroll bars alone keep the console", k.graphicsUsed)
        // Demo/Graphics/ScrollBars.HC: a drawing program sets the range and reads the position
        val k2 = runHolyC(latin1("U0 D(CTask *,CDC *) {}\nFs->draw_it=&D;Fs->vert_scroll.max=100;Refresh(2);MsSet(,,3);Refresh(2);" +
            "\"%d\\n\",Fs->vert_scroll.pos;\n"))
        assertEquals("3", last(k2))
    }

    /**
     * Kernel/KMisc.HC Snd programs the PIT with SYS_TIMER_FREQ (18333*65536/1000) but the PIT counts at
     * 1193182 Hz: the reference VM's speaker plays 437.1 Hz for ona 60 and 218.43 Hz for ona 48
     * (docs/fidelity-audit/data/vm-observations.json). A negative ona plays the slowest tone.
     */
    @Test fun speakerPitchIsTheTempleOsPit() {
        val env = TestEnv()
        runHolyC(latin1("Snd(60);Sleep(10);Snd(48);Sleep(10);Snd(-12);Sleep(10);Snd;\n"), env = env)
        val f = env.sounds.filter { it > 0 }
        assertEquals(3, f.size)
        assertEquals(437.06, f[0], 0.01)
        assertEquals(218.49, f[1], 0.01)
        assertEquals(18.21, f[2], 0.01)
        // Freq2Ona truncates: 12*Log2(32/440*120)=37.5 -> 37
        assertEquals("37 60 0", last(runHolyC(latin1("\"%d %d %d\\n\",Freq2Ona(120),Freq2Ona(440),Freq2Ona(0);\n"))))
    }

    /** Kernel/KMathB.HC Seed returns the seed, a new timer-based one for 0. */
    @Test fun seedReturnsTheSeed() {
        assertEquals("5 1", last(runHolyC(latin1("\"%d %d\\n\",Seed(5),Seed(0)!=0;\n"))))
    }

    /** Kernel/SerialDev/Message.HC ScanChar: a key-down returns only once its key-up has come. */
    @Test fun scanCharWaitsForTheKeyUp() {
        val k = runHolyC(latin1("U0 P(CTask *parent) {Sleep(200);PostMsg(parent,MSG_KEY_UP,'a',0x1E);}\n" +
            "Msg(MSG_KEY_DOWN,'a',0x1E);Spawn(&P,Fs);F64 t0=tS;I64 c=ScanChar;\"%d %d\\n\",c,tS-t0>0.15;\n"))
        assertEquals("97 1", last(k))
        // no key: 0 at once; a key-down with no ASCII (SHIFT) is consumed and gives 0
        assertEquals("0 0", last(runHolyC(latin1("Msg(MSG_KEY_DOWN,0,SC_SHIFT);I64 a=ScanChar,b=ScanChar;\"%d %d\\n\",a,b;\n"))))
    }

    /** Panning the text layer or replacing its font shows the TempleOS screen (PanText, CharAnimation). */
    @Test fun textLayerProgramsShowTheScreen() {
        assertTrue(runHolyC(latin1("gr.pan_text_x=3;Refresh(2);gr.pan_text_x=0;\n")).graphicsUsed)
        assertTrue(runHolyC(latin1("U64 *f=MAlloc(256*8);MemCpy(f,text.font,256*8);f[' ']=0x0011AA440011AA44;text.font=f;Refresh(2);\n")).graphicsUsed)
        assertFalse(runHolyC(latin1("\"text\\n\";Refresh(2);\n")).graphicsUsed)
    }

    /**
     * Adam/Gr/GrScrn.HC GrUpdateTasks sums each frame's ODE time into winmgr.last_ode_time, which with
     * Gs->idle_factor budgets the next frame's ODEs (Adam/AMathODE.HC ODEsUpdate).
     */
    @Test fun odeTimeBudgetIsKept() {
        // on the real clock: in virtual time a frame's work takes no time
        val k = runRealTime(latin1("U0 D(CMathODE *,F64,F64 *,F64 *d) {d[0]=1.0;}\nU0 Dr(CTask *,CDC *) {}\n" +
            "Fs->draw_it=&Dr;CMathODE *o=ODENew(1,1e-4);o->derive=&D;QueIns(o,Fs->last_ode);Sleep(500);" +
            "\"%d %d %d\\n\",winmgr.last_ode_time>0,0.0<=Gs->idle_factor<=1.0,o->state[0]>0.3;QueRem(o);\n"))
        assertEquals("1 1 1", last(k))
    }

    /** Span's file choosers (Adam/DolDoc/DocPopUp.HC) as native lists: the default name, the directory's files. */
    @Test fun fileChoosersOfferTheDefaultAndTheFiles() {
        val dir = kotlin.io.path.createTempDirectory("pick").toFile()
        try {
            val fs = LayeredFs(DirBundle(java.io.File(SHARED, "bundled-fs"), java.io.File(SHARED, "bundled-fs.index")), dir)
            val k = runHolyC(latin1("DirMk(\"~/Span\");FileWrite(\"~/Span/B.DATA\",\"x\",1);FileWrite(\"~/Span/A.DATA\",\"y\",1);" +
                "U8 *n=PopUpFileName(\"~/Span/Game.DATA\"),*p=PopUpPickFile(\"~/Span\");\"%s %s\\n\",n,p;\n"), env = TestEnv(fs))
            // headless popups take the first entry: the default name, and the first file in name order
            assertEquals("~/Span/Game.DATA ~/Span/A.DATA", last(k))
        } finally { dir.deleteRecursively() }
    }

    @Test fun pausedTimeIsNotProgramTime() {
        var clock = 1_000_000_000L
        val env = object : io.github.templeosmobile.core.kernel.KernelEnv by TestEnv() {
            override fun nanoTime(): Long = clock
        }
        val k = Kernel(env, "t")
        k.boot()
        val t0 = k.now()
        clock += 2_000_000_000L
        k.clockPaused(true)
        clock += 30_000_000_000L // half a minute in the background
        k.clockPaused(false)
        clock += 1_000_000_000L
        assertEquals("only the 3 s the program ran are program time", 3_000_000_000L, k.now() - t0)
    }
}

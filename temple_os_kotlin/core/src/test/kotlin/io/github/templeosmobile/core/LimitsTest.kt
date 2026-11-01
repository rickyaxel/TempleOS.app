package io.github.templeosmobile.core

import io.github.templeosmobile.core.holyc.latin1
import io.github.templeosmobile.core.kernel.*
import io.github.templeosmobile.core.ui.KernelRunner
import org.junit.Assert.*
import org.junit.Assume.assumeFalse
import org.junit.Test
import java.io.File

/**
 * Resource-limit / sandbox tests (independent verification). Every test runs
 * on a watchdog thread with a bounded wall clock, in real time (not virtual
 * time), against the same APIs the UI uses (Kernel.step, Kernel.post(Break),
 * KernelRunner.stop). Same cases as Swift LimitsTests.
 */
class LimitsTest {
    private class LimitEnv(override val memoryLimit: Int = 32 shl 20) : KernelEnv {
        override val fs: VirtualFs? = null
        override fun runtimeFile(name: String): ByteArray? = File(SHARED, "runtime/$name").let { if (it.exists()) it.readBytes() else null }
        override fun entropy(): Long = 1
        override fun popupRequested(kernel: Kernel, req: PopupRequest) { req.result = -1 }
    }

    /** Runs [block] on its own thread; fails if it does not finish within [ms] (e.g. step() never returns). */
    private fun bounded(ms: Long, block: () -> Unit) {
        var err: Throwable? = null
        val th = Thread(null, { try { block() } catch (t: Throwable) { err = t } }, "limits", 64L shl 20)
        th.isDaemon = true
        th.start()
        th.join(ms)
        if (th.isAlive) {
            val st = th.stackTrace.take(8).joinToString("\n") { "  at $it" }
            fail("did not complete within $ms ms (host thread still busy):\n$st")
        }
        err?.let { throw it }
    }

    private fun boot(memoryLimit: Int = 32 shl 20, shell: Boolean = false): Kernel {
        val k = Kernel(LimitEnv(memoryLimit), if (shell) "Terminal" else "Limits", shellMode = shell)
        k.boot()
        return k
    }

    private fun start(src: String, memoryLimit: Int = 32 shl 20): Kernel {
        val k = boot(memoryLimit)
        k.runProgram("C:/Home/Limits.HC", latin1(src))
        return k
    }

    /** Steps until the program ends or [wallMs] passes; true if it ended. */
    private fun runToEnd(k: Kernel, wallMs: Long): Boolean {
        val deadline = System.nanoTime() + wallMs * 1_000_000
        while (System.nanoTime() < deadline) {
            if (k.step(20_000_000) < 0) return true
        }
        return k.finished
    }

    private fun stepUntil(k: Kernel, wallMs: Long, cond: () -> Boolean): Boolean {
        val deadline = System.nanoTime() + wallMs * 1_000_000
        while (System.nanoTime() < deadline) {
            if (cond()) return true
            k.step(5_000_000)
        }
        return cond()
    }

    private fun assertNoHostError(out: String) {
        assertFalse("host-level error leaked into the program:\n$out", out.contains("internal error", ignoreCase = true))
        assertFalse("host stack overflow:\n$out", out.contains("host stack overflow"))
    }

    /** Max wall time of one step(budget) call while [k] runs a busy program. */
    private fun worstStepNs(k: Kernel, calls: Int, budgetNs: Long): Long {
        var worst = 0L
        repeat(calls) {
            val t0 = System.nanoTime()
            assertTrue("busy program must not finish", k.step(budgetNs) >= 0)
            worst = maxOf(worst, System.nanoTime() - t0)
        }
        return worst
    }

    // ------------------------------------------------------------ 1. infinite loops

    @Test fun infiniteLoopHonoursStepBudgetAndBreakStopsIt() = bounded(10_000) {
        val k = start("\"spin\\n\";\nwhile (TRUE) {}\n\"never\\n\";\n")
        k.step(5_000_000) // warm-up (JIT)
        val worst = worstStepNs(k, 40, 5_000_000)
        assertFalse(k.finished)
        assertTrue("step(5 ms) took ${worst / 1_000_000} ms", worst < 100_000_000)
        // UI soft stop (KernelRunner.stop(hard=false) posts KInput.Break)
        k.post(KInput.Break)
        assertTrue("Break must end the program", runToEnd(k, 2000))
        val out = k.console.plainText()
        assertTrue(out, out.contains("spin"))
        assertFalse(out, out.contains("never"))
        assertTrue(out, out.contains("Break"))
        assertTrue(k.tasks.isEmpty())
        assertEquals(-1L, k.step(5_000_000))
    }

    /** Posts Break from another thread after [delayMs] (the kernel thread is stuck inside the callback). */
    private fun breakLater(k: Kernel, delayMs: Long) {
        val th = Thread { Thread.sleep(delayMs); k.post(KInput.Break) }
        th.isDaemon = true
        th.start()
    }

    @Test fun breakStopsInfiniteLoopInsideNativeCallback() = bounded(10_000) {
        val k = start("I64 Cmp(I64 a,I64 b) {while (TRUE) {} return a-b;}\nI64 arr[2]={2,1};\n\"sorting\\n\";\nQSortI64(arr,2,&Cmp);\n\"never\\n\";\n")
        breakLater(k, 100)
        val t0 = System.nanoTime()
        assertTrue("Break must end the program", runToEnd(k, 5000))
        val ms = (System.nanoTime() - t0) / 1_000_000
        val out = k.console.plainText()
        assertNoHostError(out)
        assertTrue(out, out.contains("sorting"))
        assertFalse(out, out.contains("never"))
        assertTrue(out, out.contains("Break"))
        assertFalse("ended by the instruction guard, not Break:\n$out", out.contains("too long"))
        assertTrue("Break inside a callback took $ms ms", ms < 1000)
    }

    @Test fun breakInsideNativeCallbackReachesTheCallbacksHandler() = bounded(10_000) {
        val k = start("I64 Cmp(I64 a,I64 b) {\n  try { while (TRUE) {} } catch { \"caught\\n\"; Fs->catch_except=TRUE; }\n  return a-b;\n}\n" +
            "I64 arr[2]={2,1};\nQSortI64(arr,2,&Cmp);\n\"sorted %d %d\\n\",arr[0],arr[1];\n")
        breakLater(k, 100)
        assertTrue(runToEnd(k, 5000))
        val out = k.console.plainText()
        assertNoHostError(out)
        assertTrue(out, out.contains("caught"))
        assertTrue(out, out.contains("sorted 1 2"))
    }

    @Test fun otherTasksAndFramesRunWhileANativeCallbackSpins() = bounded(10_000) {
        // V-17: the comparator never returns; the spawned ticker and the frame clock must keep going
        val k = start("I64 ticks=0;\nU0 Ticker(U8 *) { while (TRUE) { ticks++; if (ticks%10==0) \"tick %d\\n\",ticks; Sleep(1); } }\n" +
            "Spawn(&Ticker);\nI64 Cmp(I64 a,I64 b) {while (TRUE) {} return a-b;}\nI64 arr[2]={2,1};\n\"sorting\\n\";\n" +
            "QSortI64(arr,2,&Cmp);\n\"never\\n\";\n")
        breakLater(k, 700)
        val f0 = k.frameCount
        assertTrue("Break must end the program", runToEnd(k, 5000))
        val out = k.console.plainText()
        assertNoHostError(out)
        assertTrue(out, out.contains("sorting") && !out.contains("never") && out.contains("Break"))
        val ticks = Regex("tick (\\d+)").findAll(out).map { it.groupValues[1].toInt() }.maxOrNull() ?: 0
        assertTrue("the spawned task ran only $ticks ticks while the comparator spun:\n$out", ticks >= 20)
        assertTrue("only ${k.frameCount - f0} frames in ~0.7 s", k.frameCount - f0 >= 8)
    }

    @Test fun uiRunnerHardStopKillsProgramThatSwallowsBreak() = bounded(10_000) {
        val k = Kernel(LimitEnv(), "Swallow")
        val runner = KernelRunner(k)
        runner.start { it.runProgram("C:/Home/Swallow.HC", latin1(
            "I64 breaks=0;\nwhile (TRUE) {\n  try { while (TRUE) {} } catch { breaks++; Fs->catch_except=TRUE; }\n}\n")) }
        val bootDeadline = System.nanoTime() + 5_000_000_000L
        while (!runner.booted && System.nanoTime() < bootDeadline) Thread.sleep(10)
        assertTrue(runner.booted)
        Thread.sleep(300)
        runner.stop(hard = false)
        Thread.sleep(500)
        // TempleOS semantics: Break is throw('Break'), which this catch{} swallows
        assumeFalse("runtime made Break uncatchable; hard-stop path not exercised", k.finished)
        runner.stop(hard = true) // what ProgramApp.stop() escalates to, and close()
        assertFalse(runner.alive)
        val n1 = k.vm.instructionsExecuted
        Thread.sleep(300)
        val n2 = k.vm.instructionsExecuted
        assertEquals("VM must stop executing after hard stop", n1, n2)
    }

    @Test fun shellKernelRunsAnotherCommandAfterBreak() = bounded(10_000) {
        val k = boot(shell = true)
        assertTrue(k.execLine("while (TRUE) {}"))
        repeat(10) { k.step(5_000_000) }
        assertTrue(k.busy)
        assertFalse("a running command must block a new one", k.execLine("\"x\\n\";"))
        k.post(KInput.Break)
        assertTrue("Break must end the command", stepUntil(k, 3000) { !k.busy })
        assertTrue(k.execLine("\"after %d\\n\",6*7;"))
        assertTrue(stepUntil(k, 3000) { !k.busy })
        val out = k.console.plainText()
        assertTrue(out, out.contains("after 42"))
        assertNoHostError(out)
    }

    // ------------------------------------------------------------ 2. recursion

    @Test fun unboundedRecursionIsStkOver() = bounded(10_000) {
        val k = start("""
            I64 R(I64 n) {return R(n+1)+1;}
            try { R(0); } catch { "caught %c\n",Fs->except_ch; Fs->catch_except=TRUE; }
            U0 Big() {U8 buf[100000]; buf[0]=1; Big;}
            try { Big; } catch { "caught2 %c\n",Fs->except_ch; Fs->catch_except=TRUE; }
            "alive\n";
            R(0);
            "never\n";
            """.trimIndent())
        assertTrue(runToEnd(k, 8000))
        val out = k.console.plainText()
        assertNoHostError(out)
        assertTrue(out, out.contains("caught StkOver"))
        assertTrue(out, out.contains("caught2 StkOver"))
        assertTrue(out, out.contains("alive"))
        assertFalse(out, out.contains("never"))
        assertTrue("uncaught StkOver ends the program: ${k.exitMessage}", k.exitMessage?.contains("StkOver") == true)
    }

    @Test fun recursionThroughNativeCallbackIsStkOver() = bounded(10_000) {
        // QSortI64 -> comparator -> QSortI64 -> ...: nests host calls (Vm.callFunction)
        val k = start("""
            I64 depth=0;
            I64 Cmp(I64 a,I64 b) {I64 x[2]; x[0]=2; x[1]=1; depth++; QSortI64(x,2,&Cmp); return a-b;}
            I64 arr[2]={2,1};
            try { QSortI64(arr,2,&Cmp); } catch { "caught %c\n",Fs->except_ch; Fs->catch_except=TRUE; }
            "alive %d\n",depth>100;
            """.trimIndent())
        assertTrue(runToEnd(k, 8000))
        val out = k.console.plainText()
        assertNoHostError(out)
        assertTrue(out, out.contains("StkOver"))
    }

    // ------------------------------------------------------------ 3. memory limit

    @Test fun allocationBeyondLimitIsOutMemAndProgramContinues() = bounded(10_000) {
        val limit = 16 shl 20
        val k = start("""
            I64 n=0;
            try { while (TRUE) { MAlloc(1<<20); n++; } } catch { "loop %c %d\n",Fs->except_ch,n; Fs->catch_except=TRUE; }
            try { MAlloc(1<<40); "huge-ok\n"; } catch { "huge %c\n",Fs->except_ch; Fs->catch_except=TRUE; }
            try { CAlloc(1<<40); "chuge-ok\n"; } catch { "chuge %c\n",Fs->except_ch; Fs->catch_except=TRUE; }
            try { MAlloc(-1); "neg-ok\n"; } catch { "neg %c\n",Fs->except_ch; Fs->catch_except=TRUE; }
            try { StrNew(NULL); I64 *big=MAlloc(I64_MAX); "max-ok\n"; } catch { "max %c\n",Fs->except_ch; Fs->catch_except=TRUE; }
            U8 *p=MAlloc(100);
            p[99]=7;
            "still %d\n",p[99];
            """.trimIndent(), memoryLimit = limit)
        assertTrue(runToEnd(k, 8000))
        val out = k.console.plainText()
        assertNoHostError(out)
        val m = Regex("loop OutMem (\\d+)").find(out)
        assertNotNull("MAlloc loop must end with OutMem:\n$out", m)
        assertTrue(out, m!!.groupValues[1].toInt() in 1..16)
        assertTrue(out, out.contains("huge OutMem"))
        assertTrue(out, out.contains("chuge OutMem"))
        assertTrue(out, out.contains("neg OutMem"))
        assertTrue(out, out.contains("max OutMem"))
        assertTrue(out, out.contains("still 7"))
        assertTrue("arena (${k.mem.size}) must stay within the limit ($limit)", k.mem.size <= limit)
    }

    // ------------------------------------------------------------ 4. output volume

    @Test fun millionsOfLinesKeepScrollbackBounded() = bounded(10_000) {
        val k = start("I64 i;\nfor (i=0;i<1000000;i++) \"line %d\\n\",i;\n\"last\\n\";\n")
        assertTrue("printing 1M lines must finish in time", runToEnd(k, 9000))
        val lines = k.console.lineCount()
        assertTrue("scrollback has $lines lines", lines <= 2001)
        val out = k.console.plainText()
        assertTrue(out.endsWith("last\n") || out.endsWith("last"))
        assertTrue(out.contains("line 999999"))
        assertTrue("console holds ${out.length} chars", out.length < 100_000)
    }

    @Test fun oneHugeLineIsBounded() = bounded(10_000) {
        // 8M characters without a newline: the line cap (not the line-count cap) must apply
        val k = start("U8 *s=MAlloc(1001);\nMemSet(s,'x',1000);\ns[1000]=0;\nI64 i;\nfor (i=0;i<8000;i++) \"%s\",s;\n\"END\";\n")
        assertTrue(runToEnd(k, 9000))
        val len = k.console.plainText().length
        // bound: long lines wrap at Console.MAX_COLS, scrollback keeps 2000 lines
        val bound = Console.MAX_COLS * 2000 + 2000
        assertTrue("console holds $len chars after an 8M-char line (bound $bound)", len <= bound)
    }

    // ------------------------------------------------------------ 5. invalid memory

    /** Runs [snippet] in try/catch in a fresh program; returns a problem description or null. */
    private fun faultCase(snippet: String, expect: String?, pre: String = ""): String? {
        val src = "$pre\n\"start\\n\";\ntry {\n$snippet\n\"noexc\\n\";\n} catch {\n\"exc %c\\n\",Fs->except_ch;\nFs->catch_except=TRUE;\n}\n\"done\\n\";\n"
        val k = try { start(src) } catch (e: Throwable) { return "$snippet: host exception at load: $e" }
        val ended = try { runToEnd(k, 5000) } catch (e: Throwable) { return "$snippet: host exception escaped Kernel.step: $e" }
        val out = k.console.plainText().trim().replace("\n", " | ")
        if (!ended) return "$snippet: did not end"
        if (out.contains("internal error", ignoreCase = true) || out.contains("host stack overflow")) return "$snippet: host error: $out"
        if (!out.contains("done")) return "$snippet: program died: $out"
        if (expect != null && !out.contains("exc $expect")) return "$snippet: expected $expect, got: $out"
        return null
    }

    private fun checkCases(vararg r: String?) {
        val bad = r.filterNotNull()
        if (bad.isNotEmpty()) fail(bad.joinToString("\n"))
    }

    @Test fun nullAndWildPointers() = bounded(10_000) {
        checkCases(
            faultCase("*(0x7FFFFFFFFFFF)(I64*)=1;", "BadMem"),
            faultCase("I64 v=*(0x7FFFFFFFFFF0)(I64*); \"%d\\n\",v;", "BadMem"),
            faultCase("*(-8)(I64*)=1;", "BadMem"),
            faultCase("I64 *q=MAlloc(16); q[-1000000]=1;", "BadMem"),
            faultCase("I64 *q=MAlloc(16); q[1<<40]=1;", "BadMem"),
            faultCase("\"%s\\n\",0x7FFFFFFF0000;", "BadMem"),
            faultCase("U0 (*fp)()=0x123456; fp();", null)
        )
    }

    @Test fun badFrees() = bounded(10_000) {
        checkCases(
            faultCase("Free(0x12345);", "BadFree"),
            faultCase("FreeLocal;", "BadFree", pre = "U0 FreeLocal() {I64 loc; Free(&loc);}"),
            faultCase("U8 *d=MAlloc(8); Free(d); Free(d);", "BadFree"),
            faultCase("U8 *d=MAlloc(64); Free(d+8);", "BadFree")
        )
    }

    @Test fun hugeAndNegativeMemOps() = bounded(10_000) {
        checkCases(
            faultCase("U8 b[16]; MemCpy(b,b,1<<40);", "BadMem"),
            faultCase("U8 *m=MAlloc(16); MemSet(m,0,1<<40);", "BadMem"),
            faultCase("U8 *m=MAlloc(16); MemSet(m,0,0x7FFFFFFF);", "BadMem"),
            faultCase("U8 b[16]; MemCpy(b,0x7FFFFFFFFFF0,4);", "BadMem"),
            faultCase("U8 b[16]; MemCpy(b,\"abc\",-1);", null),
            faultCase("U8 *m=MAlloc(16); MemSet(m,0,-5);", null),
            faultCase("I64 *m=MAlloc(16); MemSetI64(m,0,1<<61);", "BadMem"),
            faultCase("I64 *m=MAlloc(16); MemSetI64(m,0,1<<29);", "BadMem"),
            faultCase("U32 *m=MAlloc(16); MemSetU32(m,0,1<<30);", "BadMem"),
            faultCase("U8 b[16]; MemCpy(b,\"abcdefghijklmnopqrstuvwxyz\",(1<<32)+20);", "BadMem")
        )
    }

    @Test fun overflowsInsideOwnHeapAndStack() = bounded(10_000) {
        // Writes stay inside the program's own arena; they may corrupt its own heap
        // (as in TempleOS) but must surface as HolyC exceptions, never host errors.
        checkCases(
            faultCase("U8 *s=MAlloc(4); StrCpy(s,\"0123456789012345678901234567890123456789\"); Free(s);", null),
            faultCase("U8 *a=MAlloc(16),*b=MAlloc(16); MemSet(a,0xFF,64); U8 *c=MAlloc(16); Free(b); Free(a); Free(c);", null),
            faultCase("U8 *big=MAlloc(1<<20); MemSet(big,'y',(1<<20)-1); big[(1<<20)-1]=0; F(big);", null,
                pre = "U0 F(U8 *src) {U8 b[4]; StrCpy(b,src);}"),
            faultCase("I64 *q=MAlloc(16); q[-1]=0x7FFFFFFFFFFFFFFF; q[-2]=-1; Free(q); MAlloc(16);", null)
        )
    }

    @Test fun wildWritesDoNotTouchAnotherLoadedProgram() = bounded(10_000) {
        val b = start("""
            U8 *buf=MAlloc(4096);
            MemSet(buf,0x5A,4096);
            "B addr %d\n",buf;
            I64 spin,i,bad=0;
            for (spin=0;spin<2000000;spin++) {}
            for (i=0;i<4096;i++) if (buf[i]!=0x5A) bad++;
            "B bad %d\n",bad;
            """.trimIndent())
        assertTrue(stepUntil(b, 3000) { b.console.plainText().contains("B addr") })
        val addr = Regex("B addr (\\d+)").find(b.console.plainText())!!.groupValues[1]
        val a = start("""
            try { MemSet($addr,0,4096); } catch { Fs->catch_except=TRUE; }
            try { Free($addr); } catch { Fs->catch_except=TRUE; }
            I64 a;
            for (a=0x10000;;a+=8) *a(I64*)=-1;
            """.trimIndent())
        // interleave the two kernels as the UI threads would
        val deadline = System.nanoTime() + 8_000_000_000L
        while ((!a.finished || !b.finished) && System.nanoTime() < deadline) {
            if (!a.finished) a.step(2_000_000)
            if (!b.finished) b.step(2_000_000)
        }
        assertTrue(a.finished && b.finished)
        val outA = a.console.plainText()
        val outB = b.console.plainText()
        assertNoHostError(outA); assertNoHostError(outB)
        assertTrue("A must die on its own arena boundary:\n$outA", outA.contains("BadMem") || outA.contains("BadFree"))
        assertTrue("B's memory must be untouched:\n$outB", outB.contains("B bad 0"))
    }

    @Test fun corruptedTaskCallbackPointerStaysInsideTheProgram() = bounded(10_000) {
        // A program may scribble over its own CTask (it lives in the arena; the 1 MiB
        // StrCpy above does exactly that). The window manager then calls Fs->draw_it.
        val k = start("Fs->draw_it=0x7979797979797979;\nI64 i;\nfor (i=0;i<20;i++) Sleep(20);\n\"end\\n\";\n")
        val err = try { runToEnd(k, 5000); null } catch (e: Throwable) { e }
        assertNull("host exception escaped Kernel.step: $err", err)
        assertNoHostError(k.console.plainText())
    }

    @Test fun hardStopInterruptsOneHugeGraphicsPrimitive() = bounded(10_000) {
        // one GrRect over a 4096x4096 DC runs entirely inside a native
        val k = start("CDC *dc=DCNew(4096,4096);\ndc->color=RED;\n\"go\\n\";\nwhile (TRUE) GrRect(dc,0,0,4096,4096);\n")
        stepUntil(k, 3000) { k.console.plainText().contains("go") }
        // what KernelRunner.stop(hard=true) does from the UI thread
        val stopper = Thread { Thread.sleep(300); k.stopRequested = true; k.vm.interrupt = true }
        stopper.start()
        val t0 = System.nanoTime()
        var r = 0L
        while (r >= 0 && System.nanoTime() - t0 < 4_000_000_000L) r = k.step(5_000_000)
        val ms = (System.nanoTime() - t0) / 1_000_000
        assertEquals("hard stop must end the program (took $ms ms)", -1L, r)
        assertTrue("hard stop took $ms ms", ms < 1500)
        assertTrue(k.finished)
    }

    // ------------------------------------------------------------ 6. graphics loop

    /**
     * Frame fairness (docs/performance/TEMPLEOS_RUNTIME_OPTIMIZATIONS.md section 2): a draw_it slower than the
     * frame interval while every task sleeps must not keep step() composing frames forever. It once did, so the
     * kernel thread never got back to input, and Stop never reached the program.
     */
    @Test fun slowFramesWithSleepingTasksStillReturnFromStep() = bounded(10_000) {
        val k = start("""
            I64 n=0;
            U0 DrawIt(CTask *,CDC *dc) { F64 t=tS; while (tS-t<0.05) n++; dc->color=n&15; GrRect(dc,0,0,64,64); } //50 ms frames
            Fs->draw_it=&DrawIt;
            Sleep(100000);
        """.trimIndent())
        k.step(20_000_000)
        // drive it as KernelRunner does, over 0.7 s of real time
        var worst = 0L
        val end = System.nanoTime() + 700_000_000L
        while (System.nanoTime() < end) {
            val t0 = System.nanoTime()
            val w = k.step(5_000_000)
            worst = maxOf(worst, System.nanoTime() - t0)
            if (w > 0) Thread.sleep(maxOf(1L, minOf(w / 1_000_000, 10L)))
        }
        println("LimitsTest: worst step(5 ms) with slow frames and sleeping tasks: ${worst / 1_000_000} ms, frames=${k.frameCount}")
        assertTrue("step(5 ms) took ${worst / 1_000_000} ms", worst < 1_000_000_000L)
        assertTrue("frames still composed", k.frameCount >= 3)
        k.post(KInput.Break)
        assertTrue("Break stops it", runToEnd(k, 3000))
    }

    @Test fun tightGraphicsLoopHonoursBudgetAndStops() = bounded(10_000) {
        val k = start("""
            CDC *dc=DCAlias;
            CDC *off=DCNew(640,480);
            I64 i=0;
            while (TRUE) {
              dc->color=i&15; off->color=(i+1)&15;
              GrRect(dc,0,0,320,240); GrLine(dc,0,0,639,479);
              GrRect(off,10,10,600,400); GrLine(off,639,0,0,479);
              i++;
            }
            """.trimIndent())
        k.step(20_000_000)
        val worst = worstStepNs(k, 5, 5_000_000)
        // Natives such as GrRect run nested HolyC per pixel and are not preempted, so a
        // step overshoots its budget by one primitive; it must still return promptly.
        println("LimitsTest: worst step(5 ms) in a 640x480 graphics loop: ${worst / 1_000_000} ms")
        assertTrue("step(5 ms) took ${worst / 1_000_000} ms in a graphics loop", worst < 1_000_000_000)
        k.post(KInput.Break)
        assertTrue("Break must stop a graphics loop", runToEnd(k, 3000))
        assertNoHostError(k.console.plainText())
    }

    @Test fun tightGraphicsLoopStopsViaUiRunner() = bounded(10_000) {
        val k = Kernel(LimitEnv(), "Gfx")
        val runner = KernelRunner(k)
        runner.start { it.runProgram("C:/Home/Gfx.HC", latin1(
            "CDC *dc=DCAlias;\nI64 i=0;\nwhile (TRUE) {\n  dc->color=i&15;\n  GrRect(dc,0,0,640,480);\n  GrLine(dc,0,0,639,479);\n  i++;\n}\n")) }
        val bootDeadline = System.nanoTime() + 5_000_000_000L
        while (!runner.booted && System.nanoTime() < bootDeadline) Thread.sleep(10)
        Thread.sleep(300)
        runner.stop(hard = false)
        val deadline = System.nanoTime() + 2_000_000_000L
        while (!k.finished && System.nanoTime() < deadline) Thread.sleep(10)
        assertTrue("Break (soft stop) must end the graphics loop", k.finished)
        runner.stop(hard = true)
        assertFalse(runner.alive)
    }
}

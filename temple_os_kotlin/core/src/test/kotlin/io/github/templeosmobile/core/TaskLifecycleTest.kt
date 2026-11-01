package io.github.templeosmobile.core

import io.github.templeosmobile.core.holyc.latin1
import io.github.templeosmobile.core.kernel.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File

/**
 * A task that has ended must never have frames pushed on its stack: the kernel frees the stack and a new task
 * may get it. Whap showed it as "Unhandled exception 'BadMem' in SoundEffectTask (GrLib.HC:6674): invalid memory
 * access at 0x3fb99999999999a0": each frame the window manager's MobileOdeFrameEnd ran on the task that had run
 * last — a Noise task that had just ended — and its LowPass1(0.1,...) argument landed on the argument slot of a
 * Noise task Whap's ODE had just spawned on the reused stack; 0.1's bits + 6 (CSoundEffectFrame.duration) is the
 * address. Port: TaskLifecycleTests.swift. docs/audio/TEMPLEOS_AUDIO_FIDELITY.md §15 (A-7).
 */
class TaskLifecycleTest {
    @Test fun tasksSpawnedDuringAFrameKeepTheirArguments() {
        // draw_it (frame composition) spawns a short task each frame while earlier ones end and their stacks are reused
        val k = runHolyC(latin1("""
            I64 bad=0,ok=0;
            U0 Child(I64 *p) { if (*p==12345) ok++; else bad++; Free(p); }
            U0 DrawIt(CTask *,CDC *) { I64 *p=MAlloc(8); *p=12345; Spawn(&Child,p,"Child"); }
            Fs->draw_it=&DrawIt;
            Sleep(3000);
            Fs->draw_it=NULL;
            Sleep(100);
            "OK:%d BAD:%d\n",ok,bad;
        """.trimIndent() + "\n"))
        val text = k.console.plainText()
        val ok = Regex("OK:(\\d+) BAD:(\\d+)").find(text)
        assertNotNull(text, ok)
        assertEquals(text, "0", ok!!.groupValues[2])
        assertTrue("children ran: $text", ok.groupValues[1].toInt() > 50)
        assertFalse(text, text.contains("Unhandled exception"))
    }

    @Test fun whapsCollisionNoiseRunsWithoutBadMem() {
        // Demo/Games/Whap.HC unmodified: the pointer sweeps through the balls so they collide (Noise(50,102,105) from
        // the ODE's MyDerivative) for 30 s; every noise task must start with its own frame
        val fs = LayeredFs(DirBundle(File(SHARED, "bundled-fs"), File(SHARED, "bundled-fs.index")), kotlin.io.path.createTempDirectory("whap").toFile())
        val env = TestEnv(fs)
        val k = Kernel(env, "whap")
        k.virtualTime = true
        k.boot()
        k.runProgram("C:/Demo/Games/Whap.HC", fs.readFile("C:/Demo/Games/Whap.HC")!!)
        var step = 0
        while (k.now() < 30_000_000_000L && !k.finished) {
            val a = step * 0.07
            k.post(KInput.Mouse((320 + 200 * Math.cos(a)).toInt(), (240 + 150 * Math.sin(a)).toInt(), false, false))
            k.virtualStopAt = k.now() + 20_000_000
            k.step(50_000_000); step++
        }
        val text = k.console.plainText()
        assertFalse(text.takeLast(600), text.contains("Unhandled exception"))
        assertTrue("Whap keeps running", !k.finished)
        // the collision noise: onas 102..104 (RandU16%(105-102)+102), many retunes
        val noise = (102..104).map { Natives.PIT_FREQ / ((18333 * 65536 / 1000) / (440.0 / 32 * Math.pow(2.0, it / 12.0))).toLong() }.toSet()
        assertTrue("collisions sounded: ${env.sounds.count { it in noise }}", env.sounds.count { it in noise } > 500)
    }
}

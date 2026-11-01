package io.github.templeosmobile.core

import io.github.templeosmobile.core.kernel.*
import org.junit.Test
import java.io.File

/** Diagnostic (enable with -Dtempleos.flap=true): FlapBat bat height around SPACE presses. */
class FlapProbeTest {
    @Test fun probe() {
        if (System.getProperty("templeos.flap") != "true") return
        val fs = HostDirFs(File(SHARED, "bundled-fs"))
        val k = Kernel(TestEnv(fs), "flap")
        k.virtualTime = true
        k.boot()
        k.runProgram("C:/Demo/Games/FlapBat.HC", File(SHARED, "bundled-fs/Demo/Games/FlapBat.HC").readBytes())
        fun run(ms: Long) { k.virtualStopAt = k.now() + ms * 1_000_000; while (k.now() < k.virtualStopAt) if (k.step(1_000_000_000) < 0) break }
        fun batY() = Double.fromBits(k.mem.ld8((k.prog.globals["bat_y"] as io.github.templeosmobile.core.holyc.GlobalSym).addr))
        run(1500)
        val (ch, sc) = Keys.forChar(' '.code)
        for (i in 0 until 6) {
            val before = batY()
            k.post(KInput.Key(ch, sc, true)); run(300)
            k.post(KInput.Key(ch, sc or Keys.SCF_KEY_UP, false)); run(400)
            println("flap $i: bat_y $before -> ${batY()}  t=${k.now() / 1_000_000}ms")
        }
        k.terminate("done")
    }
}

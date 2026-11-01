package io.github.templeosmobile.purekotlin

import io.github.templeosmobile.core.bench.*
import io.github.templeosmobile.core.holyc.GlobalSym
import org.junit.Test
import java.io.File

/**
 * Why X-Caliber's 4 s scenario costs 7 billion budget ticks (docs/native-validation): traces its ODE
 * (`ode`, a CMathODE) every frame — the adaptive tolerance, the step size and the budget ticks spent.
 *
 * ODEsUpdate (Adam/AMathODE.HC, copied unchanged into GrLib.HC) gives the ODE a real-time budget and
 * steers `tolerance_internal` so that integration fills 75% of it: `d=(tS-start_time)/(timeout_time-
 * start_time)-0.75`, then `tolerance_internal*=2.0`d` (d<0). In virtual time a frame's work costs no
 * time, so tS does not move during ODEsUpdate: d is always -0.75 and the tolerance halves every
 * 1/0.75 frames until it reaches X-Caliber's min_tolerance (1e-9), where RK5 takes its smallest steps.
 *
 *   -Dtempleos.odeprobe=native|terry  (results: build/xcaliber-ode-probe.csv)
 */
class XCaliberOdeProbeTest {
    @Test
    fun probe() {
        val which = System.getProperty("templeos.odeprobe") ?: return
        val engine = if (which == "terry") Engine.TERRY else Engine.NATIVE
        val path = "C:/Apps/X-Caliber/Run.HC"
        val env = ParityEnv(bundledFs())
        val (k, _) = bootProgram(path, engine, env.fs, env)
        // X-Caliber's globals exist once its chunks have loaded: looked up at each frame
        fun off(m: String) = k.prog.classes["CMathODE"]?.members?.get(m)?.offset ?: error("no CMathODE.$m")
        val out = StringBuilder("ms,frame,ticks,ticks_this_frame,ode_t,tolerance_internal,min_tolerance,max_tolerance,h,h_min,h_max,n_internal\n")
        val script = ScenarioScript.sweep(4000)
        val evs = script.events.sortedBy { it.ms }
        var i = 0; var ms = 0L; var lastTicks = 0L; var lastFrame = -1L
        while (ms <= 4000) {
            while (i < evs.size && evs[i].ms <= ms) {
                when (val e = evs[i]) {
                    is ScenarioEvent.Key -> k.post(io.github.templeosmobile.core.kernel.KInput.Key(e.ch, e.sc, e.down))
                    is ScenarioEvent.Mouse -> k.post(io.github.templeosmobile.core.kernel.KInput.Mouse(e.x, e.y, e.lb, e.rb))
                    else -> {}
                }
                i++
            }
            if (!ScenarioRunner.advanceTo(k, ms)) break
            if (k.frameCount != lastFrame) {
                val odeSym = k.prog.globals["ode"] as? GlobalSym
                val ode = if (odeSym == null) 0L else k.mem.ld8(k.mem.check(odeSym.addr.toLong(), 8))
                fun f(m: String) = if (ode == 0L) Double.NaN else java.lang.Double.longBitsToDouble(k.mem.ld8(k.mem.check(ode + off(m), 8)))
                val n = if (ode == 0L) 0 else k.mem.ld8(k.mem.check(ode + off("n_internal"), 8))
                val ticks = k.vm.ticksExecuted
                out.append("$ms,${k.frameCount},$ticks,${ticks - lastTicks},${f("t")},${f("tolerance_internal")},${f("min_tolerance")},${f("max_tolerance")},${f("h")},${f("h_min")},${f("h_max")},$n\n")
                lastTicks = ticks; lastFrame = k.frameCount
            }
            ms += 20
        }
        k.terminate("done")
        File("build").mkdirs()
        File("build/xcaliber-ode-probe-$which.csv").writeText(out.toString())
        println(out.lines().filterIndexed { j, _ -> j == 0 || j % 10 == 1 }.joinToString("\n"))
    }
}

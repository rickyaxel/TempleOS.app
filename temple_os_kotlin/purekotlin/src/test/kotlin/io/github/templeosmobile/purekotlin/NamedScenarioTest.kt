package io.github.templeosmobile.purekotlin

import io.github.templeosmobile.core.bench.*
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.File

/**
 * Named scenarios of the device bench mode (ScenarioScript.named), run on the host on both engines: they must agree,
 * and their checkpoints (build/parity/named-<name>-<program>.<engine>.json) are the reference for the phones' runs.
 *
 *   default: Cartesian with typed formulas.  -Dtempleos.named=<name>:<path>[,...]
 */
class NamedScenarioTest {
    @Test
    fun namedScenarios() {
        val which = System.getProperty("templeos.named") ?: "cartesian:C:/Demo/Graphics/Cartesian.HC"
        File("build/parity").mkdirs()
        for (item in which.split(',')) {
            val (name, path) = item.split(':', limit = 2)
            val script = ScenarioScript.named(name, 4000)
            val o = ScenarioRunner.Options(memMb = 128, env = { ParityEnv(it) })
            val a = runner.run(path, ScenarioEngine.TERRY, script, o)
            val b = runner.run(path, ScenarioEngine.NATIVE, script, o)
            val prog = path.substringAfterLast('/').substringBefore('.')
            File("build/parity/named-$name-$prog.terry.json").writeText(ScenarioRunner.checkpointsJson(a.checkpoints))
            File("build/parity/named-$name-$prog.native.json").writeText(ScenarioRunner.checkpointsJson(b.checkpoints))
            val d = compareRuns(Run(a.kernel, a.env, a.checkpoints, a.frames, a), Run(b.kernel, b.env, b.checkpoints, b.frames, b))
            println("$name $path: terry ${a.kernel.exitCategory} / native ${b.kernel.exitCategory}, native dynexpr evaluations ${b.kernel.dynExprEvaluations}, bytecode ${b.kernel.vm.instructionsExecuted}")
            a.kernel.terminate("done"); b.kernel.terminate("done")
            assertEquals(0L, b.kernel.vm.instructionsExecuted)
            assertNull(d, d)
        }
    }
}

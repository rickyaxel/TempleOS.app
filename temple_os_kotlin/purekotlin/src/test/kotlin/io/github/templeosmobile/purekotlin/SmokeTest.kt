package io.github.templeosmobile.purekotlin

import io.github.templeosmobile.core.kernel.*
import org.junit.Assert.*
import org.junit.Test

class SmokeTest {
    @Test
    fun bomberGolfRunsNatively() {
        val (k, env) = bootProgram("C:/Demo/Games/BomberGolf.HC", Engine.NATIVE)
        for (ms in 20L..3000L step 20) {
            if (ms % 700 == 0L) { val (ch, sc) = Keys.forChar(' '.code); k.post(KInput.Key(ch, sc, true)); k.post(KInput.Key(ch, sc or Keys.SCF_KEY_UP, false)) }
            if (!advanceTo(k, ms)) break
        }
        println("frames=${k.frameCount} finished=${k.finished} exit=${k.exitMessage} ticks=${k.vm.ticksExecuted} instr=${k.vm.instructionsExecuted} sounds=${env.sound.size}")
        println(k.console.plainText().take(2000))
        assertEquals("native kernel must not interpret bytecode", 0L, k.vm.instructionsExecuted)
        assertTrue(k.frameCount > 50)
        k.terminate("done")
    }
}

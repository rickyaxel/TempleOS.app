package io.github.templeosmobile.core

import io.github.templeosmobile.core.kernel.*
import org.junit.Assert.*
import org.junit.Test

/**
 * The command line prints each command's answer like TempleOS's CmdLinePmt
 * (Compiler/CMisc.HC): "%8.6fs ans=0x%08X=%d", "ansf=%15.7g" for F64, and just
 * the time for U0 results and non-expression statements.
 */
class TerminalAnswerTest {
    @Test
    fun compileErrorDoesNotScheduleAStaleReturn() {
        val k = Kernel(TestEnv(), "Terminal", shellMode = true)
        k.virtualTime = true
        k.boot()
        assertTrue(run(k, "LocalizationAuditMissingSymbol;").contains("undefined identifier"))
        // The UI scheduler keeps stepping even when the terminal is waiting for input.
        repeat(3) { k.step(50_000_000) }
        assertFalse(k.console.plainText(), k.console.plainText().contains("return with no active call"))
        assertTrue(run(k, "9+9;").contains("ans=0x00000012=18"))
    }

    private fun run(k: Kernel, line: String): String {
        val before = k.console.plainText().length
        k.execLine(line)
        val deadline = System.nanoTime() + 20_000_000_000L
        while (k.busy && System.nanoTime() < deadline) k.step(50_000_000)
        assertFalse("command finished: $line", k.busy)
        return k.console.plainText().substring(before)
    }

    @Test
    fun answers() {
        val k = Kernel(TestEnv(), "Terminal", shellMode = true)
        k.virtualTime = true
        k.boot()
        val time = Regex("""\d+\.\d{6}s""")
        assertTrue(run(k, "2+3*4;").contains(Regex("""${time.pattern} ans=0x0000000E=14""")))
        // HolyC precedence: << binds tighter than * (Doc/HolyC.DD)
        assertTrue(run(k, "I64 x=6*7;").contains(time))
        val shifted = run(k, "x<<2;")
        assertTrue(shifted, shifted.contains("ans=0x000000A8=168"))
        val neg = run(k, "-1;")
        assertTrue(neg, neg.contains("ans=0xFFFFFFFFFFFFFFFF=-1"))
        val f = run(k, "1.5*3;")
        assertTrue(f, f.contains(" ansf=") && f.contains("4.5"))
        val v = run(k, "U0 Nothing(){}\nNothing;")
        assertTrue(v, v.contains(time) && !v.contains("ans"))
        // only the last statement's answer is shown
        val two = run(k, "1;2;")
        assertTrue(two, two.contains("=2\n") && !two.contains("=1\n"))
        // no answer after an exception or a compile error
        val ex = run(k, "I64 *p=0x7FFFFFFFFFF0; *p;")
        assertFalse(ex, ex.contains("ans="))
        assertFalse(run(k, "Bogus();").contains("ans="))
        // output printed by the command comes before the answer
        val p = run(k, "\"hi\\n\"; 7;")
        assertTrue(p, p.indexOf("hi") in 0 until p.indexOf("ans=0x00000007=7"))
    }
}

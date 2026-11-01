package io.github.templeosmobile.purekotlin

import io.github.templeosmobile.core.holyc.*
import io.github.templeosmobile.core.kernel.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File

/**
 * Function-level differential test: every prelude function (the TempleOS libraries every program uses)
 * whose parameters are all scalars is called on the interpreter and on its translation with the same
 * arguments — boundary values (0, ±1, MIN, MAX, NaN, ±Inf, subnormals...) and seeded random ones —
 * and must return the same word, raise the same exception, and leave every global the same.
 * Functions that need the screen, input or time are called too: both kernels see the same state.
 */
class FunctionDiffTest {
    private val ints = longArrayOf(0, 1, -1, 2, -2, 7, 8, 63, 64, 255, 256, -256, 1000, -1000, 65535, 1L shl 31, -(1L shl 31),
        Int.MAX_VALUE.toLong(), Int.MIN_VALUE.toLong(), Long.MAX_VALUE, Long.MIN_VALUE, 640, 480, 0x7F, 0x80)
    private val floats = doubleArrayOf(0.0, -0.0, 1.0, -1.0, 0.5, -0.5, 2.0, 3.141592653589793, -3.141592653589793, 1e-300, 4.9e-324,
        1e300, Double.MAX_VALUE, Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY, 123.456, -0.001, 1e10, 0.1)

    private fun scalar(t: Type) = Types.isInt(t) || t is F64Type

    @Test
    fun preludeFunctionsAgree() {
        val (a, _) = bootProgram("C:/Home/Examples/Hello.HC", Engine.TERRY)
        val (b, _) = bootProgram("C:/Home/Examples/Hello.HC", Engine.NATIVE)
        advanceTo(a, 500); advanceTo(b, 500)
        val rnd = java.util.SplittableRandom(20261020)
        val report = StringBuilder()
        var calls = 0; var fns = 0; var mismatches = 0; var skipped = 0
        // functions that wait for the user, the clock or never return on their own: not callable in isolation
        val skip = setOf("GetChar", "GetKey", "GetStr", "GetI64", "GetF64", "PressAKey", "Beep", "Play", "Sleep", "SleepUntil",
            "Refresh", "Yield", "Msg", "ScanMsg", "GetMsg", "PopUpOk", "PopUp1", "PopUp2", "PopUpNoYes", "PopUpCancelOk",
            "PopUpRangeI64", "PopUpGetI64", "PopUpGetF64", "PopUpColor", "PopUpPickLst", "PopUpGetStr", "PopUpPickFile", "PopUpFileName",
            "SongTask", "SoundEffectTask", "Noise", "Sweep", "Exit", "Kill", "Spawn", "throw", "Break", "MobileGetStr", "View", "Ed")
        val split = io.github.templeosmobile.purekotlin.gen.NativeCatalog.prelude.split
        for (f in a.prog.funcs) {
            if (f.index !in 0 until split || f.isNative || !f.defined || f.name.startsWith("$")) continue
            if (f.name in skip || f.name.startsWith("PopUp") || f.name.startsWith("Snd")) { skipped++; continue }
            val ft = f.ftype
            if (ft.varargs || !ft.params.all { scalar(it.type) }) { skipped++; continue }
            val fb = b.prog.funcs.getOrNull(f.index)
            assertNotNull("native function #${f.index} ${f.name}", fb)
            fns++
            val cases = ArrayList<LongArray>()
            if (ft.params.isEmpty()) cases.add(LongArray(0))
            else {
                for (i in 0 until 24) cases.add(LongArray(ft.params.size) { p ->
                    if (ft.params[p].type is F64Type) (if (i < floats.size) floats[(i + p) % floats.size] else rnd.nextDouble() * 2e6 - 1e6).toRawBits()
                    else if (i < ints.size) ints[(i + p * 3) % ints.size] else rnd.nextLong(-100000, 100000)
                })
            }
            for (args in cases) {
                calls++
                // an F64 NaN result is compared as "NaN": when both operands of an F64 add/multiply are NaNs, which one
                // propagates (and so the sign: Cosh(NaN) adds Exp(NaN) and Exp(-NaN)) follows the operand order HotSpot's
                // JIT happens to choose, not the program (TempleOS's x87 has its own rule; docs/native-validation)
                val f64 = ft.ret is F64Type
                val ra = nanClass(call(a, f, args), f64); val rb = nanClass(call(b, f, args), f64)
                val ga = globalsHash(a, HOST_GLOBALS); val gb = globalsHash(b, HOST_GLOBALS)
                if (ra != rb || ga != gb) {
                    mismatches++
                    report.append("${f.name}(${args.joinToString(",") { "0x" + java.lang.Long.toHexString(it) }}): terry=$ra native=$rb" +
                        (if (ga != gb) " globals: ${globalDiff(a, b)}" else "") + "\n")
                    // continue from a common state: the remaining calls compare like with like only if the states agree
                    if (ga != gb) break
                }
            }
        }
        a.terminate("done"); b.terminate("done")
        val summary = "functions compared: $fns, calls: $calls, mismatches: $mismatches, not callable in isolation: $skipped"
        File("build").mkdirs(); File("build/function-diff.txt").writeText(summary + "\n" + report)
        println(summary); print(report.toString().take(4000))
        assertEquals(report.toString().take(2000), 0, mismatches)
    }

    private fun nanClass(r: String, f64: Boolean): String =
        if (f64 && r.startsWith("=") && java.lang.Double.isNaN(java.lang.Double.longBitsToDouble(java.lang.Long.parseUnsignedLong(r.substring(1), 16)))) "=NaN" else r

    /** The call's word result, or the exception it raised (the VM's VmUncaught/VmKill), as text. */
    private fun call(k: Kernel, f: FuncSym, args: LongArray): String = try {
        val t = k.adamTask!!
        "=" + java.lang.Long.toHexString(k.vm.callFunction(t, k.prog.funcPtr(f), *args))
    } catch (u: VmUncaught) { "raise " + k.vm.chStr(u.ch) } catch (e: VmKill) { "kill" } catch (e: VmFault) { "fault " + k.vm.chStr(e.ch) }
}

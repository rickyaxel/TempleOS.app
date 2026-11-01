package io.github.templeosmobile.core

import io.github.templeosmobile.core.dynexpr.*
import io.github.templeosmobile.core.holyc.*
import io.github.templeosmobile.core.kernel.Kernel
import org.junit.Assert.*
import org.junit.Test

/**
 * Unit tests of the native dynamic expression engine (core/dynexpr): lexer, parser (precedence,
 * associativity, typing), errors and their messages, sandbox limits and the cache. Pure tests use a
 * small fake environment; the semantic tests at the end compare the engine with the interpreter's own
 * ExePrint (NativesSys.runNested) on the same interpreted kernel.
 */
class DynExprUnitTest {
    // ------------------------------------------------------------ a fake environment (no kernel)

    private class Fake {
        val mem = ByteArray(4096)
        val globals = HashMap<String, Sym>()
        val calls = ArrayList<String>()
        private var nextAddr = 64
        fun global(name: String, t: Type): GlobalSym = GlobalSym(name, t, nextAddr).also { globals[name] = it; nextAddr += 8 }
        fun func(name: String, ret: Type, vararg params: Pair<String, Type>, native: Boolean = true) =
            FuncSym(name, FuncType(ret, params.map { Param(it.first, it.second, null) }, false)).also {
                if (native) it.nativeIndex = globals.size else it.index = globals.size
                globals[name] = it
            }
        init {
            global("x", Types.F64); global("y", Types.F64); global("y_last", Types.F64)
            global("b", Types.U8); global("c", Types.I8); global("i32", Types.I32); global("u", Types.U64); global("flag", Types.Bool)
            global("p", PtrType(Types.U8))
            func("ToF64", Types.F64, "i" to Types.I64); func("ToI64", Types.I64, "d" to Types.F64)
            func("Sin", Types.F64, "d" to Types.F64); func("Min", Types.F64, "n1" to Types.F64, "n2" to Types.F64, native = false)
            func("Sqr", Types.F64, "d" to Types.F64, native = false); func("Print", Types.U0, "fmt" to Types.U8Ptr)
        }
        val scope = object : DynScope {
            override fun symbol(name: String) = globals[name]
            override fun isClassName(name: String) = name == "CTask"
            override fun isKnownMacro(name: String) = name == "RED"
        }
        val host = object : DynHost {
            override fun ld(addr: Int, size: Int): Long { var v = 0L; for (i in size - 1 downTo 0) v = (v shl 8) or (mem[addr + i].toLong() and 0xFF); return v }
            override fun st(addr: Int, size: Int, v: Long) { for (i in 0 until size) mem[addr + i] = (v ushr (8 * i)).toByte() }
            override fun frameStore(off: Int, v: Long) {}
            override fun poll() {}
            override fun call(fn: FuncSym, args: LongArray): Long {
                calls.add(fn.name)
                return when (fn.name) {
                    "ToF64" -> args[0].toDouble().toRawBits()
                    "ToI64" -> f2i(d(args[0]))
                    "Sin" -> StrictMath.sin(d(args[0])).toRawBits()
                    "Sqr" -> (d(args[0]) * d(args[0])).toRawBits()
                    "Min" -> (if (d(args[0]) < d(args[1])) d(args[0]) else d(args[1])).toRawBits()
                    else -> throw IllegalStateException(fn.name)
                }
            }
        }
        fun setF(name: String, v: Double) = host.st((globals[name] as GlobalSym).addr, 8, v.toRawBits())
        fun getF(name: String) = d(host.ld((globals[name] as GlobalSym).addr, 8))
        fun getRaw(name: String, size: Int) = host.ld((globals[name] as GlobalSym).addr, size)

        fun compile(text: String) = DynExpr.compile(latin1(text), scope, { true })
        /** Runs [text] as ExePrint would; returns the result or throws the first compile error. */
        fun run(text: String): Long {
            var r = 0L
            val ev = DynEval(host)
            for (c in compile(text)) when (c) {
                is DError -> throw c.error
                is DEmpty -> r = 0
                is DStmt -> r = ev.run(c)
            }
            return r
        }
        fun f(expr: String) = d(run("ToF64($expr);"))
        fun i(expr: String) = run("$expr;")
        fun error(text: String): CompileError = try { run(text); throw AssertionError("no error for $text") } catch (e: CompileError) { e }
    }

    private fun d(v: Long) = java.lang.Double.longBitsToDouble(v)

    // ------------------------------------------------------------ lexer

    private fun tokens(s: String): List<DToken> {
        val lx = DynLexer(latin1(s), emptyMap(), DynExpr.FILE)
        val out = ArrayList<DToken>()
        var i = 0
        while (lx[i].kind != DTok.EOF) out.add(lx[i++])
        return out
    }

    @Test
    fun lexesNumbersCharsAndPunctuation() {
        val t = tokens("0x1F 0b101 12 1.5e-1 1. .25 1e400 'AB' '' <<= ^^ ` 12345678901234567890 0xFFFFFFFFFFFFFFFFF")
        assertEquals(listOf(DTok.INT, DTok.INT, DTok.INT, DTok.FLOAT, DTok.FLOAT, DTok.FLOAT, DTok.FLOAT, DTok.CHAR, DTok.CHAR,
            DTok.PUNCT, DTok.PUNCT, DTok.PUNCT, DTok.INT, DTok.INT), t.map { it.kind })
        assertEquals(31L, t[0].ival); assertEquals(5L, t[1].ival); assertEquals(0.15, t[3].fval, 0.0)
        assertEquals(1.0, t[4].fval, 0.0); assertEquals(0.25, t[5].fval, 0.0); assertEquals(Double.POSITIVE_INFINITY, t[6].fval, 0.0)
        assertEquals(0x4241L, t[7].ival); assertEquals(0, t[8].charLen)
        assertEquals(-6101065172474983726L, t[12].ival) // parsed unsigned
        assertEquals(-1L, t[13].ival) // hex wraps silently, as the compiler's lexer
    }

    @Test
    fun skipsCommentsAndDolDocAndExpandsConstants() {
        val t = tokens("/* a /* nested */ */ 1 // x\n \$FG,RED\$+\$\$ pi \$ 2")
        assertEquals(listOf("1", "+", "(", "4614256656552045848", "(", "F64", ")", ")", "2"), t.map { it.toString() })
        assertEquals(2, t.last().line)
    }

    @Test
    fun lexerErrorsAreTheCompilers() {
        val f = Fake()
        assertEquals("C:/Home/ExePrint.HC:1: integer constant too large: 99999999999999999999", f.error("99999999999999999999;").message)
        assertEquals("C:/Home/ExePrint.HC:1: char constant longer than 8 chars", f.error("'ABCDEFGHI';").message)
        assertEquals("C:/Home/ExePrint.HC:1: unterminated literal", f.error("'A").message)
        assertEquals("C:/Home/ExePrint.HC:1: unknown directive #x", f.error("ToF64(#x);").message)
        assertTrue(f.error("#define A 1\nA;").message!!.contains("outside the native expression subset"))
        // a lexer error after a parse error is never reached (the lexers are lazy)
        assertEquals("C:/Home/ExePrint.HC:1: expected ',' but found 'y'", f.error("ToF64(x y 'ABCDEFGHI');").message)
    }

    // ------------------------------------------------------------ precedence, associativity, typing

    @Test
    fun holycPrecedence() {
        val f = Fake()
        assertEquals(5L, f.i("1<<2+1"))       // << binds tighter than +
        assertEquals(3L, f.i("6&3+1"))        // & binds tighter than +
        assertEquals(3L, f.i("1+6&3"))
        assertEquals(9L, f.i("5&3|8"))
        assertEquals(7L, f.i("1+2*3"))
        assertEquals(3L, f.i("10-4-3"))       // left associative
        assertEquals(5L, f.i("100/10/2"))
        assertEquals(512.0, f.f("2`3`2"), 0.0) // right associative
        assertEquals(-4.0, f.f("-2`2"), 0.0)   // -x`y is -(x`y)
        assertEquals(18.0, f.f("2*3`2"), 0.0)
        assertEquals(1L, f.i("1<2<3"))         // chained
        assertEquals(1L, f.i("3>2>1"))
        assertEquals(0L, f.i("1<3<2"))
        assertEquals(0L, f.i("2<3==1"))        // any comparison after another chains: 2<3 && 3==1
        assertEquals(1L, f.i("1==2<3"))        // < binds tighter than ==: 1==(2<3), not a chain
    }

    @Test
    fun chainsAndLogic() {
        val f = Fake()
        f.setF("x", 5.0)
        assertEquals(1.0, f.f("0<x<10"), 0.0)
        assertEquals(0.0, f.f("0<x<3"), 0.0)
        assertEquals(1.0, f.f("x>0 ^^ x>25"), 0.0)
        assertEquals(0.0, f.f("x>0 ^^ x<25"), 0.0)
        assertEquals(1.0, f.f("x<-50 || x>0"), 0.0)
        assertEquals(0.0, f.f("!x"), 0.0)
        assertEquals(1.0, f.f("!!x"), 0.0)
        // short circuit: the assignment does not run
        f.setF("y", 0.0)
        assertEquals(0.0, f.f("x<0 && (y=1)"), 0.0)
        assertEquals(0.0, f.getF("y"), 0.0)
    }

    @Test
    fun integerAndFloatSemantics() {
        val f = Fake()
        assertEquals(3L, f.i("7/2")); assertEquals(-3L, f.i("-7/2")); assertEquals(-1L, f.i("-7%3"))
        assertEquals(3.5, f.f("7/2.0"), 0.0); assertEquals(3.5, f.f("7.0/2"), 0.0)
        assertEquals(Long.MIN_VALUE, f.i("0x7FFFFFFFFFFFFFFF+1"))     // wraps
        assertEquals(0x7FFFFFFFFFFFFFFFL, f.i("0xFFFFFFFFFFFFFFFF/2")) // U64 literal: unsigned division
        assertEquals(1L, f.i("-0xFFFFFFFFFFFFFFFF"))                  // a negated literal folds to an I64 literal
        assertEquals(-32L, f.i("-256>>3"))                            // arithmetic shift
        assertEquals(0x1FFFFFFFFFFFFFFFL, f.i("0xFFFFFFFFFFFFFFFF>>3")) // logical for U64
        assertEquals(2L, f.i("1<<65"))                                // count masked to 6 bits
        assertEquals(-6L, f.i("~5"))
        assertEquals(255L, f.i("(-1)(U8)")); assertEquals(44L, f.i("300(U8)"))
        assertEquals(0x4000000000000000L, f.i("2.0(I64)"))            // bits, not value
        assertEquals(2.0, d(f.i("0x4000000000000000(F64)")), 0.0)
        assertEquals(Long.MIN_VALUE, f.i("ToI64(1e300)"))             // x86 truncation of out-of-range
        assertEquals(1024.0, f.f("2`10"), 0.0); assertEquals(1.0, f.f("0`0"), 0.0)
        assertEquals(0x4241L, f.i("'AB'+0"))
        assertEquals(8L, f.i("sizeof(F64)")); assertEquals(1L, f.i("sizeof(Bool)")); assertEquals(8L, f.i("sizeof(x)")); assertEquals(8L, f.i("sizeof(U8*)"))
        // unsigned comparison when either side is unsigned (any width)
        f.host.st((f.globals["b"] as GlobalSym).addr, 1, 200)
        assertEquals(1L, f.i("b<-1")); assertEquals(0L, f.i("b>-1"))
    }

    @Test
    fun divisionByZeroIsTheVmsFault() {
        val f = Fake()
        for (e in listOf("1/0", "1%0", "x(I64)/0", "0x8000000000000000(I64)/-1")) {
            try { f.i(e); fail(e) } catch (v: VmFault) { assertEquals(Vm.DIV_ZERO, v.ch) }
        }
        assertTrue(f.f("1.0/0").isInfinite()); assertTrue(f.f("0.0/0").isNaN())
    }

    @Test
    fun assignmentsAndIncrements() {
        val f = Fake()
        f.setF("x", 2.0)
        assertEquals(4.0, f.f("y=2*x"), 0.0); assertEquals(4.0, f.getF("y"), 0.0)
        assertEquals(300L, f.i("b=300")); assertEquals(44L, f.getRaw("b", 1)) // stores truncated, yields the converted value
        assertEquals(2.0, f.f("x++"), 0.0); assertEquals(3.0, f.getF("x"), 0.0)
        assertEquals(4.0, f.f("++x"), 0.0)
        assertEquals(8.0, f.f("x*=2"), 0.0)
        f.host.st((f.globals["c"] as GlobalSym).addr, 1, 127)
        assertEquals(-128L, f.i("++c"))
        assertEquals(3L, f.i("i32=3.7")) // F64 -> integer truncates
        assertEquals(5L, f.i("x(I64)=5")); assertEquals(5L, f.getRaw("x", 8)) // a cast is an lvalue at the cast's width
        f.setF("x", 1.0)
        assertEquals(3.0, d(f.run("ToF64(1);y=3;ToF64(y);")), 0.0)
        assertEquals(0L, f.run("ToF64(1);;")) // a trailing empty statement is a chunk that returns 0
    }

    @Test
    fun callsAreBoundLikeTheCodeGenerator() {
        val f = Fake()
        f.setF("x", 0.5)
        assertEquals(StrictMath.sin(0.5), f.f("Sin(x)"), 0.0)
        f.calls.clear()
        assertEquals(0.5, f.f("x"), 0.0)
        assertEquals(emptyList<String>(), f.calls) // ToF64 of an F64: the call is dropped
        assertEquals(3.0, f.f("ToF64(3)"), 0.0)
        assertEquals(listOf("ToF64"), f.calls)
        assertEquals(0.25, f.f("Sqr(x)"), 0.0)
        assertEquals(0.5, f.f("Min(x,1)"), 0.0)
        assertEquals("C:/Home/ExePrint.HC:1: too many arguments to Sin", f.error("ToF64(Sin(x,1));").message)
        assertEquals("C:/Home/ExePrint.HC:1: missing argument 'd' to Sin", f.error("ToF64(Sin());").message)
        assertEquals("C:/Home/ExePrint.HC:1: missing argument 'n1' to Min", f.error("ToF64(Min(,2));").message)
        assertEquals("C:/Home/ExePrint.HC:1: missing argument 'i' to ToF64", f.error("ToF64(\$);").message) // a lone $ is skipped as DolDoc
    }

    // ------------------------------------------------------------ errors

    @Test
    fun syntaxErrorsCarryTheCompilersMessages() {
        val f = Fake()
        assertEquals("C:/Home/ExePrint.HC:1: unexpected ')'", f.error("ToF64(2*);").message)
        assertEquals("C:/Home/ExePrint.HC:0: unexpected end of file", f.error("ToF64(x+").message)
        assertEquals("C:/Home/ExePrint.HC:0: expected ',' but found 'end of file'", f.error("ToF64(x").message)
        assertEquals("C:/Home/ExePrint.HC:1: undefined identifier 'foo'", f.error("ToF64(foo(x));").message)
        assertEquals("C:/Home/ExePrint.HC:1: expression is not assignable", f.error("ToF64(1++);").message)
        assertEquals("C:/Home/ExePrint.HC:1: called object is not a function", f.error("ToF64(x(2));").message)
        assertEquals("C:/Home/ExePrint.HC:1: expected identifier but found '.2'", f.error("ToF64(1..2);").message)
        assertEquals("C:/Home/ExePrint.HC:1: unexpected character '\u0001' (0x1)", f.error("ToF64(x\u0001);").message)
        assertEquals("C:/Home/ExePrint.HC:1: cannot index F64", f.error("ToF64(x[0]);").message)
        assertEquals("C:/Home/ExePrint.HC:1: unknown type 'class'", f.error("ToF64(x(class));").message)
    }

    @Test
    fun constructsOutsideTheSubsetAreRejectedPredictably() {
        val f = Fake()
        for ((text, what) in listOf(
            "ToF64(\"str\");" to "a string literal",
            "Print(\"hi\");" to "the function 'Print'",
            "ToF64(p);" to "the variable 'p'",
            "ToF64(*p);" to "a pointer dereference",
            "ToF64(&x);" to "the address operator",
            "ToF64(RED);" to "the TempleOS macro 'RED'",
            "ToF64(x(CTask));" to "a cast to CTask",
            "ToF64(x(U8*));" to "a cast to U8*",
            "I64 z=1;" to "a declaration",
            "if (x) y=1;" to "the statement 'if'",
            "\"hi\";" to "a string statement",
            "ToF64(x.u8[0]);" to "indexing",
        )) {
            val c = f.compile(text).last()
            assertTrue("$text: $c", c is DError && c.outsideSubset)
            val m = (c as DError).error.message!!
            assertTrue("$text: $m", m.startsWith("C:/Home/ExePrint.HC:1: outside the native expression subset: $what"))
            assertTrue(m, m.endsWith("Pure Terry compiles it"))
        }
        // statements before the rejected one still run (TempleOS runs each statement as it is compiled)
        val chunks = f.compile("ToF64(1);y=2;Print(\"x\");")
        assertEquals(3, chunks.size); assertTrue(chunks[0] is DStmt && chunks[1] is DStmt && chunks[2] is DError)
    }

    // ------------------------------------------------------------ limits

    @Test
    fun sandboxLimits() {
        val f = Fake()
        fun limited(text: String) = f.compile(text).last().let { it is DError && it.error.message!!.contains("outside the native expression engine's limits") }
        assertTrue(limited("ToF64(" + "1+".repeat(5000) + "1);"))                    // > MAX_SOURCE_BYTES
        assertTrue(limited("ToF64(" + "x+".repeat(2100) + "x);"))                    // > MAX_TOKENS (4200 tokens)
        assertFalse(limited("ToF64(" + "x+".repeat(1000) + "x);"))                   // long operator sequences are folds, not deep trees
        assertTrue(limited("ToF64(" + "(".repeat(600) + "x" + ")".repeat(600) + ");")) // parser nesting
        assertFalse(limited("ToF64(" + "(".repeat(150) + "x" + ")".repeat(150) + ");"))
        assertTrue(limited("ToF64(x" + "(I64)".repeat(300) + ");"))                  // AST height
        assertTrue(limited("ToF64(" + "Sin(".repeat(300) + "x" + ")".repeat(300) + ");"))
        assertFalse(limited("ToF64(" + "Sin(".repeat(40) + "x" + ")".repeat(40) + ");"))
        assertEquals(1001.0, f.f("1" + "+1".repeat(1000)), 0.0)
    }

    // ------------------------------------------------------------ the engine on a kernel, against the interpreter

    /** An interpreted kernel with Cartesian's globals (and a few others) and its main task finished. */
    private fun kernel(): Kernel = runHolyC(latin1("F64 x,y,y_last; U8 b; I8 c; I32 i32; U64 u; Bool flag;\n"))

    private val testGlobals = listOf("x", "y", "y_last", "b", "c", "i32", "u", "flag")

    /** x = [x], every other test global 0 (each run starts from the same state). */
    private fun setGlobals(k: Kernel, x: Double) {
        for (n in testGlobals) k.mem.st8((k.prog.globals[n] as GlobalSym).addr, 0)
        k.mem.st8((k.prog.globals["x"] as GlobalSym).addr, x.toRawBits())
    }

    private fun outcome(k: Kernel, run: () -> Long): String {
        k.console.clear()
        val r = try { "=" + java.lang.Long.toHexString(run()) } catch (u: VmUncaught) { "raise ${k.vm.chStr(u.ch)}: ${u.message}" } catch (f: VmFault) { "raise ${k.vm.chStr(f.ch)}: ${f.message}" }
        val g = testGlobals.joinToString(",") { n ->
            val s = k.prog.globals[n] as GlobalSym; java.lang.Long.toHexString(k.mem.ld8(s.addr) and DynEval.mask(s.type.size))
        }
        return "$r [$g] ${k.console.plainText().trim()}"
    }

    @Test
    fun engineAgreesWithTheInterpreterOnTheSameKernel() {
        val k = kernel()
        val t = k.adamTask!!
        val exprs = listOf("2*x", "x/3", "x%7", "-x%7", "x(I64)&15", "x(I64)<<1", "x`0.5", "-x`2", "0<x<10", "x>0 ^^ x>25",
            "Sin(x/20)*100", "Sqrt(Abs(x))*Sign(x)*10", "FloorI64(17,5)", "CeilI64(-17,5)", "ClampI64(x,-5,5)", "ASin(0.5)", "ACos(-2)",
            "y=2*x", "x++", "--x", "x*=2", "b=x", "c=x", "i32=x*1000000000", "u=x", "flag=x", "b+=200", "c-=x", "u/=3", "u>>=1",
            "(x/3)(I64)", "x(U8)", "(x*1000000000)(I32)", "300(U8)", "1/0", "x%0", "FloorI64(17,0)", "I64_MIN/-1", "1e308*10",
            "0x8000000000000000", "-I64_MIN", "pi*x", "eps*1e16", "1);y=3;ToF64(y", "1);;ToF64(2", "x);", "u=-1,u<1", "b=200,b<c",
            "flag=2,flag", "Pow(x,2)/100", "Arg(x,10)*50", "Log2(x)", "x>=10", "sizeof(x)+sizeof(I32)", "(y=x,y)+1", "(x,y)=7")
        var compared = 0
        for (e in exprs) for (x in doubleArrayOf(-7.0, -0.5, 0.0, 1.0, 45.0)) {
            setGlobals(k, x)
            val src = latin1("ToF64($e);")
            val a = outcome(k) { k.sys.runNested(t, DynExpr.FILE, src, "C:/Home") }
            setGlobals(k, x)
            val b = outcome(k) { k.dynExpr.exePrint(t, src, false) }
            assertEquals("ToF64($e); at x=$x", a, b)
            compared++
        }
        assertEquals(exprs.size * 5, compared)
        k.terminate("done")
    }

    @Test
    fun parsedTextIsCachedPerKernel() {
        val k = kernel()
        val t = k.adamTask!!
        val before = k.dynExpr.stats.compiles
        for (i in 0 until 640) { setGlobals(k, i - 320.0); k.dynExpr.exePrint(t, latin1("ToF64(2*x);"), false) }
        assertEquals(before + 1, k.dynExpr.stats.compiles)
        assertEquals(639L, k.dynExpr.stats.cacheHits)
        assertEquals(640L, k.dynExpr.stats.evaluations)
        // more distinct texts than the cache holds: the oldest is compiled again
        for (i in 0..DynLimits.CACHE_ENTRIES) k.dynExpr.exePrint(t, latin1("ToF64($i);"), false)
        val c = k.dynExpr.stats.compiles
        k.dynExpr.exePrint(t, latin1("ToF64(2*x);"), false)
        assertEquals(c + 1, k.dynExpr.stats.compiles)
        k.terminate("done")
    }

    @Test
    fun builtInConstantsAreTheHeadersMacros() {
        val k = kernel()
        for ((name, text) in DynMacros.TEXT) {
            val body = k.defines[name] ?: error("$name is not defined by the prelude")
            val mine = DynMacros.body(name)!!
            assertEquals(name, body.map { it.toString() }, mine.map { it.toString() })
            assertEquals(name, body.map { it.kind.name }, mine.map { if (it.kind == DTok.BIN) "INS_BIN" else it.kind.name })
            assertTrue(text.isNotEmpty())
        }
        k.terminate("done")
    }

    @Test
    fun whitelistedFunctionsHaveThePreludesParameters() {
        val k = kernel()
        for ((name, params) in DynFunctions.PARAMS) {
            val f = k.prog.globals[name] as? FuncSym ?: error("$name is not a prelude function")
            assertEquals(name, params, f.ftype.params.map { it.name })
            assertFalse(name, f.ftype.varargs)
        }
        k.terminate("done")
    }
}

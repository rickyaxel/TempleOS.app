package io.github.templeosmobile.core.kernel

import io.github.templeosmobile.core.Brand
import io.github.templeosmobile.core.holyc.*

/** TempleOS exception code for compiler errors raised inside natives. */
internal val COMPILER = chCode("Compiler")

/**
 * Host functions bound to the prelude's `native` declarations. This file is
 * the complete list of things HolyC code can ask the host to do.
 */
class Natives(private val k: Kernel) {
    private val mem get() = k.mem
    private val vm get() = k.vm

    val SCF_SHIFT = 1L shl 9
    val SCF_CTRL = 1L shl 10
    val SCF_ALT = 1L shl 11
    val SCF_KEY_UP = 1L shl 8

    private fun d(v: Long) = java.lang.Double.longBitsToDouble(v)
    private fun f(x: Double) = x.toRawBits()
    private fun b(v: Boolean) = if (v) 1L else 0L

    private lateinit var table: NativeTable
    /** A primitive Double -> Double operation (a `fun interface`: no boxing per call, see [NativeFn]). */
    fun interface DoubleOp { fun apply(x: Double): Double }

    private fun reg(name: String, fn: NativeFn) {
        table.add(object : Native(name) {
            // natives that tokenize text (DefinePrint, MenuNew...) raise a HolyC 'Compiler' exception
            override fun call(t: Task, base: Int, argc: Int): Long =
                try { fn.call(t, base, argc) } catch (e: CompileError) { throw VmFault(COMPILER, e.message ?: "compile error") }
        })
    }

    fun register(nt: NativeTable) {
        table = nt
        console(); memory(); strings(); math(); time(); exceptions(); input(); tasks(); sound(); files(); graphics()
    }

    // ================================================================ console

    /** Kernel/KMisc.HC Silent(): console output is dropped while set (TempleOS: per-task DISPLAYf_SILENT). */
    private var silent = false

    private fun out(bytes: ByteArray) { if (!silent) { k.documents.output(bytes);k.console.write(bytes) } }

    private fun format(t: Task, fmtAddr: Long, base: Int, argc: Int): ByteArray {
        if (fmtAddr == 0L) throw VmFault(chCode("StrPrint"), "NULL format string")
        return k.fmt.format(mem.readStrBytes(fmtAddr), t.st, base, argc)
    }

    private fun newStr(b: ByteArray): Long {
        val a = mem.malloc(b.size + 1L)
        mem.writeBytes(a, b); mem.st1(a + b.size, 0)
        return a.toLong()
    }

    private fun console() {
        reg("PutChars") { t, a, _ ->
            val v = t.st[a]
            val bytes = ArrayList<Byte>()
            for (i in 0 until 8) { val c = (v ushr (8 * i)) and 0xFF; if (c == 0L) break; bytes.add(c.toByte()) }
            out(bytes.toByteArray()); 0
        }
        reg("PutS") { t, a, _ -> out(mem.readStrBytes(t.st[a])); 0 }
        reg("Print") { t, a, n -> out(format(t, t.st[a], a + 1, n - 1)); 0 }
        reg("StrPrintJoin") { t, a, _ ->
            val dst = t.st[a]; val fmt = t.st[a + 1]; val argcL = t.st[a + 2]; val argv = t.st[a + 3]
            if (argcL < 0 || argcL > 4096) throw VmFault(chCode("StrPrint"), "bad argument count $argcL")
            val argc = argcL.toInt()
            val args = LongArray(argc)
            if (argc > 0) { val p = mem.check(argv, argc * 8); for (i in 0 until argc) args[i] = mem.ld8(p + i * 8) }
            val r = k.fmt.format(mem.readStrBytes(fmt), args, 0, argc)
            if (dst == 0L) newStr(r) else { val p = mem.check(dst, r.size + 1); mem.writeBytes(p, r); mem.st1(p + r.size, 0); dst }
        }
        reg("StrPrint") { t, a, n ->
            val dst = t.st[a]
            val r = format(t, t.st[a + 1], a + 2, n - 2)
            if (dst == 0L) newStr(r) else { val p = mem.check(dst, r.size + 1); mem.writeBytes(p, r); mem.st1(p + r.size, 0); dst }
        }
        reg("CatPrint") { t, a, n ->
            val dst = t.st[a]
            val r = format(t, t.st[a + 1], a + 2, n - 2)
            val p0 = mem.check(dst, 1)
            val p = p0 + mem.strLen(p0)
            mem.check(p.toLong(), r.size + 1)
            mem.writeBytes(p, r); mem.st1(p + r.size, 0)
            dst
        }
        reg("MStrPrint") { t, a, n -> newStr(format(t, t.st[a], a + 1, n - 1)) }
        reg("Sprite") { t, a, _ ->
            val elems = t.st[a]
            val bounds = mem.malloc(32)
            var dc = 0L
            try {
                k.callHolyC("SpriteExtents", elems, bounds.toLong(), bounds + 8L, bounds + 16L, bounds + 24L)
                val minX = mem.ld8(bounds); val minY = mem.ld8(bounds + 16)
                if (minX > mem.ld8(bounds + 8) || minY > mem.ld8(bounds + 24)) return@reg 0
                if (minX !in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong() || minY !in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong()) return@reg 0
                val width = mem.ld8(bounds + 8) - mem.ld8(bounds) + 1
                val height = mem.ld8(bounds + 24) - mem.ld8(bounds + 16) + 1
                if (width !in 1..4096 || height !in 1..4096 || width * height > 4L * 1024 * 1024) throw VmKill("document sprite size")
                dc = k.callHolyC("DCNew", width, height, 0, 0)
                val blank = dc.toInt()
                mem.fill(mem.ld8(blank + k.o.dc("body")).toInt(), 255,
                    mem.ld4(blank + k.o.dc("width_internal")).toInt() * height.toInt())
                k.callHolyC("Sprite3", dc, -mem.ld8(bounds), -mem.ld8(bounds + 16), 0, elems, 0)
                val d = dc.toInt()
                val w = mem.ld4(d + k.o.dc("width")).toInt()
                val h = mem.ld4(d + k.o.dc("height")).toInt()
                val stride = mem.ld4(d + k.o.dc("width_internal")).toInt()
                if (w <= 0 || h <= 0 || w.toLong() * h > 4L * 1024 * 1024) throw VmKill("document sprite size")
                val body = mem.check(mem.ld8(d + k.o.dc("body")), stride * h)
                val pixels = ByteArray(w * h)
                for (y in 0 until h) for (x in 0 until w) pixels[y * w + x] = mem.ld1(body + y * stride + x).toByte()
                val spec=if(t.st[a+1]!=0L) mem.readStr(t.st[a+1]) else ""
                if(spec.length>4096) throw VmKill("document sprite format limit")
                if(spec.isNotEmpty()) k.console.write(spec)
                val slot=k.console.insertSprite(pixels, w, h, mem.ld8(bounds).toInt(), mem.ld8(bounds + 16).toInt(),spec)
                k.documents.trackSprite(elems,slot,mem.ld8(bounds),mem.ld8(bounds+8),mem.ld8(bounds+16),mem.ld8(bounds+24))
                k.graphicsUsed = true
            } finally {
                if (dc != 0L) k.callHolyC("DCDel", dc)
                mem.free(bounds.toLong())
            }
            k.callHolyC("MobileDocSprite",elems,t.st[a+1])
        }
        reg("DocClear") { t,a,_ -> k.callHolyC("MobileDocClear",t.st[a]);k.console.clear(); 0 }
        reg("DocBottom") { _, _, _ -> 0 }
        reg("DocTop") { _, _, _ -> 0 }
        reg("DocScroll") { _, _, _ -> 0 }
        reg("DocCursor") { t, a, _ -> k.console.cursorVisible = t.st[a] != 0L; 0 }
        reg("PutExceptMsg") { _, _, _ ->
            val m = vm.lastFault
            if (!m.isNullOrEmpty()) out(latin1(m))
            vm.lastFault = null
            0
        }
        reg("Silent") { t, a, n -> val old = silent; silent = if (n > 0) t.st[a] != 0L else true; if (old) 1 else 0 }
        reg("IsSilent") { _, _, _ -> if (silent) 1 else 0 }
        reg("SysPlatformName") { _, _, _ -> k.prog.stringAddr(latin1(Brand.APP_NAME)).toLong() }
        reg("Raw") { _, _, _ -> 0 }
        reg("Spaces") { t, a, _ -> out(ByteArray(t.st[a].toInt().coerceIn(0, 4096)) { ' '.code.toByte() }); 0 }
    }

    // ================================================================ memory

    private fun memory() {
        reg("MAlloc") { t, a, _ -> mem.malloc(t.st[a]).toLong() }
        reg("CAlloc") { t, a, _ -> mem.calloc(t.st[a]).toLong() }
        reg("Free") { t, a, _ -> mem.free(t.st[a]); 0 }
        reg("MSize") { t, a, _ -> mem.msize(t.st[a]) }
        reg("MSize2") { t, a, _ -> if (t.st[a] == 0L) 0 else mem.msize(t.st[a]) + Arena.HDR }
        // As Kernel/KUtils.HC: counts are 64-bit (a negative count is a huge REP count and
        // faults), the results are dst+cnt, MemCpy copies forward (REP_MOVSB) and MemCmp
        // returns -1/0/1.
        reg("MemCpy") { t, a, _ ->
            val dst = t.st[a]; val src = t.st[a + 1]; val n = t.st[a + 2]
            if (n != 0L) {
                val d = span(dst, n, 1); val s = span(src, n, 1); val nn = n.toInt()
                if (d > s && d < s + nn) for (i in 0 until nn) mem.st1(d + i, mem.ld1(s + i)) // overlapping forward copy
                else mem.copy(d, s, nn)
            }
            dst + n
        }
        reg("MemSet") { t, a, _ ->
            val dst = t.st[a]; val n = t.st[a + 2]
            if (n != 0L) mem.fill(span(dst, n, 1), t.st[a + 1].toInt() and 0xFF, n.toInt())
            dst + n
        }
        reg("MemSetU16") { t, a, _ ->
            val dst = t.st[a]; val v = t.st[a + 1]; val n = t.st[a + 2]
            if (n != 0L) { val p = span(dst, n, 2); for (i in 0 until n.toInt()) mem.st2(p + i * 2, v) }
            dst + n * 2
        }
        reg("MemSetU32") { t, a, _ ->
            val dst = t.st[a]; val v = t.st[a + 1]; val n = t.st[a + 2]
            if (n != 0L) { val p = span(dst, n, 4); for (i in 0 until n.toInt()) mem.st4(p + i * 4, v) }
            dst + n * 4
        }
        reg("MemSetI64") { t, a, _ ->
            val dst = t.st[a]; val v = t.st[a + 1]; val n = t.st[a + 2]
            if (n != 0L) { val p = span(dst, n, 8); for (i in 0 until n.toInt()) mem.st8(p + i * 8, v) }
            dst + n * 8
        }
        reg("MemCmp") { t, a, _ ->
            val n = t.st[a + 2]
            if (n == 0L) 0 else {
                val p1 = span(t.st[a], n, 1); val p2 = span(t.st[a + 1], n, 1)
                var r = 0L
                for (i in 0 until n.toInt()) { val x = mem.ld1(p1 + i) - mem.ld1(p2 + i); if (x != 0L) { r = if (x > 0) 1 else -1; break } }
                r
            }
        }
        reg("StrLen") { t, a, _ -> if (t.st[a] == 0L) 0 else mem.strLen(mem.check(t.st[a], 1)).toLong() }
        reg("MemUsed") { _, _, _ -> mem.allocated }
    }

    // ================================================================ strings

    /** Checks [n] elements of [size] bytes at [addr]; a negative or oversized count faults. */
    private fun span(addr: Long, n: Long, size: Int): Int {
        if (n < 0 || n > Int.MAX_VALUE / size) mem.fault(addr)
        return mem.check(addr, (n * size).toInt())
    }

    /** -1/0/1 like Kernel/StrA.HC _STRCMP and friends. */
    private fun cmp(a: ByteArray, b: ByteArray, n: Int, ci: Boolean): Long {
        var i = 0
        while (i < n) {
            var x = if (i < a.size) a[i].toInt() and 0xFF else 0
            var y = if (i < b.size) b[i].toInt() and 0xFF else 0
            if (ci) { if (x in 97..122) x -= 32; if (y in 97..122) y -= 32 }
            if (x != y) return if (x > y) 1 else -1
            if (x == 0) return 0
            i++
        }
        return 0
    }

    private fun strings() {
        reg("StrCmp") { t, a, _ -> cmp(mem.readStrBytes(t.st[a]), mem.readStrBytes(t.st[a + 1]), Int.MAX_VALUE, false) }
        reg("StrICmp") { t, a, _ -> cmp(mem.readStrBytes(t.st[a]), mem.readStrBytes(t.st[a + 1]), Int.MAX_VALUE, true) }
        reg("StrNCmp") { t, a, _ -> cmp(mem.readStrBytes(t.st[a]), mem.readStrBytes(t.st[a + 1]), t.st[a + 2].toInt(), false) }
        reg("StrNICmp") { t, a, _ -> cmp(mem.readStrBytes(t.st[a]), mem.readStrBytes(t.st[a + 1]), t.st[a + 2].toInt(), true) }
        fun find(needle: Long, hay: Long, ci: Boolean): Long {
            if (needle == 0L || hay == 0L) return 0
            val n = mem.readStr(needle); val h = mem.readStr(hay)
            val i = h.indexOf(n, ignoreCase = ci)
            return if (i < 0) 0 else hay + i
        }
        reg("StrFind") { t, a, _ -> find(t.st[a], t.st[a + 1], (t.st[a + 2] and 1L) != 0L) }
        reg("StrIMatch") { t, a, _ -> find(t.st[a], t.st[a + 1], true) }
        reg("StrMatch") { t, a, _ -> find(t.st[a], t.st[a + 1], false) }
        reg("Str2I64") { t, a, _ ->
            // Port of Kernel/StrScan.HC Str2I64: signs toggle, "0b" "0d" "0x" change the
            // radix only when they cannot be digits of it, *_end_ptr is the first non-digit.
            val s = t.st[a]; val radix0 = t.st[a + 1]; val endp = t.st[a + 2]
            if (s == 0L || radix0 !in 2..36) { if (endp != 0L) mem.st8(mem.check(endp, 8), s); 0L } else {
                var radix = radix0.toInt()
                var p = mem.check(s, 1)
                fun up(c: Int) = if (c in 'a'.code..'z'.code) c - 0x20 else c
                fun white(c: Int) = c == 9 || c == 10 || c == 13 || c == 0x1F || c == 0x20
                while (white(mem.ld1(p).toInt())) p++
                var neg = false
                prefix@ while (true) {
                    when (mem.ld1(p).toInt()) {
                        '-'.code -> { p++; neg = !neg }
                        '+'.code -> p++
                        '0'.code -> {
                            p++
                            val ch = up(mem.ld1(p).toInt())
                            if (ch >= 'B'.code && (radix <= 10 || ch > 'A'.code + radix - 11)) when (ch) {
                                'B'.code -> { radix = 2; p++ }
                                'D'.code -> { radix = 10; p++ }
                                'X'.code -> { radix = 16; p++ }
                            }
                            break@prefix
                        }
                        else -> break@prefix
                    }
                }
                var v = 0L
                while (true) {
                    val ch = up(mem.ld1(p).toInt())
                    val dg = when {
                        radix > 10 && ch in '0'.code..'9'.code -> ch - '0'.code
                        radix > 10 && ch in 'A'.code..('A'.code + radix - 11) -> ch - 'A'.code + 10
                        radix <= 10 && ch in '0'.code..('0'.code + radix - 1) -> ch - '0'.code
                        else -> -1
                    }
                    if (dg < 0) break
                    v = v * radix + dg; p++
                }
                if (endp != 0L) mem.st8(mem.check(endp, 8), p.toLong())
                if (neg) -v else v
            }
        }
        reg("Str2F64") { t, a, _ ->
            val s = t.st[a]; val endp = t.st[a + 1]
            if (s == 0L) f(0.0) else {
                val str = mem.readStr(s)
                val m = Regex("^\\s*[-+]?(\\d+\\.?\\d*|\\.\\d+)([eE][-+]?\\d+)?").find(str)
                val v = m?.value?.trim()?.toDoubleOrNull() ?: 0.0
                if (endp != 0L) mem.st8(mem.check(endp, 8), s + (m?.value?.length ?: 0))
                f(v)
            }
        }
    }

    // ================================================================ math

    private fun math() {
        fun m1(name: String, op: DoubleOp) = reg(name) { t, a, _ -> f(op.apply(d(t.st[a]))) }
        m1("Sin") { StrictMath.sin(it) }; m1("Cos") { StrictMath.cos(it) }; m1("Tan") { StrictMath.tan(it) }
        m1("ATan") { StrictMath.atan(it) }; m1("ASin") { StrictMath.asin(it) }; m1("ACos") { StrictMath.acos(it) }
        m1("Sinh") { StrictMath.sinh(it) }; m1("Cosh") { StrictMath.cosh(it) }; m1("Tanh") { StrictMath.tanh(it) }
        m1("Sqrt") { Math.sqrt(it) }; m1("Exp") { StrictMath.exp(it) }; m1("Ln") { StrictMath.log(it) }
        m1("Log2") { StrictMath.log(it) / StrictMath.log(2.0) }; m1("Log10") { StrictMath.log10(it) }
        m1("Pow10") { StrictMath.pow(10.0, it) }; m1("Floor") { Math.floor(it) }; m1("Ceil") { Math.ceil(it) }
        m1("Round") { Math.rint(it) }; m1("Trunc") { if (it < 0) Math.ceil(it) else Math.floor(it) }
        m1("Abs") { Math.abs(it) }
        reg("Arg") { t, a, _ -> f(StrictMath.atan2(d(t.st[a + 1]), d(t.st[a]))) }
        reg("Pow") { t, a, _ -> f(templePow(d(t.st[a]), d(t.st[a + 1]))) }
        reg("ToI64") { t, a, _ -> f2i(d(t.st[a])) }
        reg("ToF64") { t, a, _ -> f(t.st[a].toDouble()) }
        reg("ToBool") { t, a, _ -> b(t.st[a] != 0L) }
        // Kernel/KMathB.HC: each task's own seed (Kernel.nextRand); Rand is (res&0x3FFFFFFFFFFFFFFF)/ToF64(1<<62)
        reg("Rand") { t, _, _ -> f((k.nextRand(t) and 0x3FFFFFFFFFFFFFFFL).toDouble() / 4611686018427387904.0) }
        reg("RandI16") { t, _, _ -> k.nextRand(t).toShort().toLong() }
        reg("RandU16") { t, _, _ -> k.nextRand(t) and 0xFFFF }
        reg("RandI32") { t, _, _ -> k.nextRand(t).toInt().toLong() }
        reg("RandU32") { t, _, _ -> k.nextRand(t) and 0xFFFFFFFFL }
        reg("RandI64") { t, _, _ -> k.nextRand(t) }
        reg("RandU64") { t, _, _ -> k.nextRand(t) }
        // Kernel/KMathB.HC Seed(seed=0, task=NULL): returns the new seed (timer-based for 0)
        reg("Seed") { t, a, n -> k.seed(t, t.st[a], if (n > 1) t.st[a + 1] else 0L) }
        // the checked byte address shifted left 3, or'ed with the bit number (no Pair allocated per call)
        fun bitAddr(t: Task, a: Int): Long {
            val bit = t.st[a + 1]
            val addr = t.st[a] + (bit shr 3)
            return (mem.check(addr, 1).toLong() shl 3) or (bit and 7)
        }
        reg("Bt") { t, a, _ -> val pb = bitAddr(t, a); val p = (pb ushr 3).toInt(); val bi = (pb and 7).toInt(); (mem.ld1(p) ushr bi) and 1 }
        reg("Bts") { t, a, _ -> val pb = bitAddr(t, a); val p = (pb ushr 3).toInt(); val bi = (pb and 7).toInt(); val o = mem.ld1(p); mem.st1(p, o or (1L shl bi)); (o ushr bi) and 1 }
        reg("Btr") { t, a, _ -> val pb = bitAddr(t, a); val p = (pb ushr 3).toInt(); val bi = (pb and 7).toInt(); val o = mem.ld1(p); mem.st1(p, o and (1L shl bi).inv()); (o ushr bi) and 1 }
        reg("Btc") { t, a, _ -> val pb = bitAddr(t, a); val p = (pb ushr 3).toInt(); val bi = (pb and 7).toInt(); val o = mem.ld1(p); mem.st1(p, o xor (1L shl bi)); (o ushr bi) and 1 }
        reg("Bsf") { t, a, _ -> val v = t.st[a]; if (v == 0L) -1 else java.lang.Long.numberOfTrailingZeros(v).toLong() }
        reg("Bsr") { t, a, _ -> val v = t.st[a]; if (v == 0L) -1 else (63 - java.lang.Long.numberOfLeadingZeros(v)).toLong() }
        reg("BFieldExtU32") { t, a, _ ->
            val bit = t.st[a + 1]; val size = t.st[a + 2].toInt()
            val p = mem.check(t.st[a] + (bit shr 3), 8)
            var v = 0L
            for (i in 0 until 5) v = v or (mem.ld1(p + i) shl (8 * i))
            (v ushr (bit and 7).toInt()) and (if (size >= 32) 0xFFFFFFFFL else (1L shl size) - 1)
        }
        reg("BFieldOrU32") { t, a, _ ->
            val bit = t.st[a + 1]; val pat = t.st[a + 2] and 0xFFFFFFFFL
            val p = mem.check(t.st[a] + (bit shr 3), 5)
            val v = pat shl (bit and 7).toInt()
            for (i in 0 until 5) mem.st1(p + i, mem.ld1(p + i) or ((v ushr (8 * i)) and 0xFF))
            0
        }
        reg("BCnt") { t, a, _ -> java.lang.Long.bitCount(t.st[a]).toLong() }
        reg("QSortI64") { t, a, _ ->
            val base = t.st[a]; val nL = t.st[a + 1]; val fp = t.st[a + 2]
            if (nL > 1) {
                val p = span(base, nL, 8); val n = nL.toInt()
                val arr = Array(n) { mem.ld8(p + it * 8) }
                // an inconsistent comparator makes TimSort throw: leave the array as it was
                val ok = try { arr.sortWith { x, y -> vm.callFunction(t, fp, x, y).let { r -> if (r < 0) -1 else if (r > 0) 1 else 0 } }; true }
                    catch (e: IllegalArgumentException) { false }
                if (ok) for (i in 0 until n) mem.st8(p + i * 8, arr[i])
            }
            0
        }
        reg("QSort") { t, a, _ ->
            val base = t.st[a]; val nL = t.st[a + 1]; val wL = t.st[a + 2]; val fp = t.st[a + 3]
            if (nL > 1 && wL > 0) {
                if (wL > Int.MAX_VALUE || nL > Int.MAX_VALUE / wL) mem.fault(base)
                val n = nL.toInt(); val w = wL.toInt()
                val p = mem.check(base, n * w)
                val tmp1 = mem.malloc(w.toLong()); val tmp2 = mem.malloc(w.toLong())
                val items = Array(n) { mem.readBytes(p + it * w, w) }
                var ok = true
                try {
                    items.sortWith { x, y ->
                        mem.writeBytes(tmp1, x); mem.writeBytes(tmp2, y)
                        vm.callFunction(t, fp, tmp1.toLong(), tmp2.toLong()).let { r -> if (r < 0) -1 else if (r > 0) 1 else 0 }
                    }
                } catch (e: IllegalArgumentException) { ok = false } // inconsistent comparator
                finally { mem.free(tmp1.toLong()); mem.free(tmp2.toLong()) }
                if (ok) for (i in 0 until n) mem.writeBytes(p + i * w, items[i])
            }
            0
        }
    }

    // ================================================================ time

    private fun time() {
        reg("Sleep") { t, a, _ ->
            val ms = t.st[a]
            if (t.nestLevel > 0) 0
            else if (t.resumed) { t.resumed = false; 0 }
            else if (ms <= 0 && t.speakerTask) {
                // TempleOS's SoundEffectTask (Adam/ASnd.HC) compares its pause t, in ms, with tS, in seconds,
                // so for its last second (all of a short Noise) it calls Sleep(0) = Yield and retunes the
                // speaker as fast as its CPU runs. How that sounded depended on the machine (each retune
                // restarts the PIT; docs/audio/TEMPLEOS_AUDIO_FIDELITY.md §7); here the loop waits for the next
                // jiffy instead of spinning: it still ends at its timeout and retunes about 1000 times a second,
                // without a core at 100%.
                t.wakeAt = TempleClock.jiffyStartNs(TempleClock.jiffyAt(k.taskNow(t)) + 1); k.block(t, Kernel.SLEEP); 0
            }
            else if (ms <= 0) { t.yieldReq = true; t.lateNs = 0; 0 }
            // Kernel/KMisc.HC: SleepUntil(cnts.jiffies+mS*JIFFY_FREQ/1000), so a Sleep ends on a jiffy: a loop
            // that sleeps after some work keeps its period (the work done within the jiffy costs no time)
            else { t.wakeAt = TempleClock.jiffyStartNs(TempleClock.jiffyAt(k.taskNow(t)) + ms * TempleClock.JIFFY_FREQ / 1000); k.block(t, Kernel.SLEEP); 0 }
        }
        reg("Yield") { t, _, _ -> if (t.nestLevel == 0) { t.yieldReq = true; t.lateNs = 0 }; 0 }
        reg("Refresh") { t, a, _ ->
            if (t.nestLevel > 0) 0
            else if (t.resumed) { t.resumed = false; 0 }
            else {
                t.blockToken = k.frameCount + maxOf(t.st[a], 1) - 1
                k.block(t, Kernel.WAIT_FRAME); 0
            }
        }
        reg("tS") { t, _, _ -> f(k.taskNow(t) / 1e9) }
        reg("GetTSC") { t, _, _ -> k.taskNow(t) }
        reg("SysTimerRead") { t, _, _ -> k.taskNow(t) / 838 }
        reg("Now") { _, _, _ -> Dates.fromEpochMillis(k.env.epochMillis(), k.env.utcOffsetMillis()) }
        reg("Busy") {t,a,_->
            k.vga.sync()
            if(t.nestLevel>0 || t.resumed) {t.resumed=false;0}
            else {t.wakeAt=k.taskNow(t)+t.st[a].coerceIn(0,60_000_000)*1000;k.block(t,Kernel.SLEEP);0}
        }
    }

    // ================================================================ exceptions

    private fun exceptions() {
        reg("throw") { t, a, _ ->
            vm.lastFault = null
            t.faultPc = t.pc
            throw VmFault(t.st[a], "")
        }
        reg("Break") { t, _, _ -> throw VmFault(chCode("Break"), "") }
        reg("BreakLock") { _, _, _ -> 1 }
        reg("BreakUnlock") { _, _, _ -> 1 }
    }

    // ================================================================ input

    /** Removes and returns the first message matching [mask], discarding others before it. */
    private fun takeMsg(mask:Long):Kernel.Msg? = k.takeMessage(mask)

    private fun waitMsg(t: Task) { t.resumed = false; k.block(t, Kernel.WAIT_MSG) }

    private fun keyDownOnly(ch:Boolean):Kernel.Msg? {
        while(true) {val m=k.takeMessage(1L shl 2) ?: return null;if(!ch || m.a1!=0L) return m}
    }

    private fun input() {
        reg("GetChar") { t, a, _ ->
            val m = keyDownOnly(true)
            if (m == null) { if (t.nestLevel == 0) waitMsg(t); 0 }
            else {
                if (t.st[a] != 0L) mem.st8(mem.check(t.st[a], 8), m.a2)
                if (t.st[a + 1] != 0L && m.a1 in 32..255) out(byteArrayOf(m.a1.toByte()))
                m.a1
            }
        }
        reg("GetKey") { t, a, _ ->
            val m = keyDownOnly(false)
            if (m == null) { if (t.nestLevel == 0) waitMsg(t); 0 }
            else {
                if (t.st[a] != 0L) mem.st8(mem.check(t.st[a], 8), m.a2)
                if (t.st[a + 1] != 0L && m.a1 in 32..255) out(byteArrayOf(m.a1.toByte()))
                m.a1
            }
        }
        reg("ScanKey") { t, a, _ ->
            val m = keyDownOnly(false)
            if (m == null) {
                // Kernel/SerialDev/Message.HC: no key sets *_ch and *_scan_code to 0
                if (t.st[a] != 0L) mem.st8(mem.check(t.st[a], 8), 0)
                if (t.st[a + 1] != 0L) mem.st8(mem.check(t.st[a + 1], 8), 0)
                0
            } else {
                if (t.st[a] != 0L) mem.st8(mem.check(t.st[a], 8), m.a1)
                if (t.st[a + 1] != 0L) mem.st8(mem.check(t.st[a + 1], 8), m.a2)
                1
            }
        }
        reg("GetMsg") { t, a, _ ->
            val mask = t.st[a + 2]
            val m = takeMsg(mask)
            if (m == null) { if (t.nestLevel == 0) waitMsg(t); 0 }
            else {
                if (t.st[a] != 0L) mem.st8(mem.check(t.st[a], 8), m.a1)
                if (t.st[a + 1] != 0L) mem.st8(mem.check(t.st[a + 1], 8), m.a2)
                m.code.toLong()
            }
        }
        reg("ScanMsg") { t, a, _ ->
            val m = takeMsg(t.st[a + 2])
            if (m == null) {
                // no message: *_arg1 and *_arg2 are set to 0 (Kernel/SerialDev/Message.HC)
                if (t.st[a] != 0L) mem.st8(mem.check(t.st[a], 8), 0)
                if (t.st[a + 1] != 0L) mem.st8(mem.check(t.st[a + 1], 8), 0)
                0
            } else {
                if (t.st[a] != 0L) mem.st8(mem.check(t.st[a], 8), m.a1)
                if (t.st[a + 1] != 0L) mem.st8(mem.check(t.st[a + 1], 8), m.a2)
                m.code.toLong()
            }
        }
        reg("FlushMsgs") { _, _, _ -> k.messageQueue().clear(); 0 }
        // the same 256-message bound as posted input (Kernel.enqueue): `while (1) Msg(0,0,0);` grew host memory without limit
        reg("Msg") {t,a,_->k.enqueueTo(t,Kernel.Msg(t.st[a].toInt(),t.st[a+1],t.st[a+2]));0}
        // Kernel/SerialDev/Mouse.HC MsSet: moves the pointer (and wheel and buttons); like the hardware,
        // the window manager then queues a move message (Zing aims the bow with it, BattleLines sets the
        // wheel to 25 for its command force)
        reg("MsSet") { t, a, _ ->
            val ms = k.o.msAddr
            var x = t.st[a]; var y = t.st[a + 1]; var z = t.st[a + 2]; val l = t.st[a + 3]; val r = t.st[a + 4]
            if (x !in 0 until Kernel.W) x = mem.ld8(ms + k.o.msPos)
            if (y !in 0 until Kernel.H) y = mem.ld8(ms + k.o.msPos + 8)
            if (z == Long.MAX_VALUE) z = mem.ld8(ms + k.o.msPos + 16)
            val lb = if (l in 0L..1L) l != 0L else mem.ld1(ms + k.o.msLb) != 0L
            val rb = if (r in 0L..1L) r != 0L else mem.ld1(ms + k.o.msRb) != 0L
            k.msUpdate(x, y, z, lb, rb)
            0
        }
        reg("Char2ScanCode") { t, a, _ -> Keys.char2ScanCode(t.st[a].toInt()).toLong() }
        reg("ScanCode2Char") { t, a, _ -> Keys.scanCode2Char(t.st[a]).toLong() }
        // GetStr, GetS, GetI64 and GetF64 are the original HolyC (Prelude.HC) over this reader
        reg("MobileGetStr2") { t, a, _ -> lineInput(t, t.st[a].toInt())?.let { newStr(it) } ?: 0 }
    }

    // line editing state for MobileGetStr2 (per kernel; one reader at a time)
    private val lineBuf = StringBuilder()
    private val lineDone = StringBuilder()
    private var lineActive = false

    /**
     * Collects a line from key messages like Adam/DolDoc/DocGet.HC DocGetStr2: ENTER ends it, ESC is
     * ignored (it would run the document entry under the cursor; a prompt has none), SHIFT-ESC
     * returns "" or ends the task with GSF_SHIFT_ESC_EXIT, and with GSF_WITH_NEW_LINE ENTER starts a
     * new line and ESC ends the text. Blocks until done; returns null while waiting.
     */
    private fun lineInput(t: Task, flags: Int): ByteArray? {
        if (t.nestLevel > 0) return ByteArray(0)
        if (!lineActive) { lineActive = true; lineBuf.setLength(0); lineDone.setLength(0); k.console.setInput("", 0) }
        val multi = flags and GSF_WITH_NEW_LINE != 0
        while (true) {
            val m = keyDownOnly(false) ?: break
            val ch = m.a1.toInt()
            when {
                ch == Keys.CH_SHIFT_ESC -> {
                    // the typed text stays on the screen, as in the TempleOS document
                    lineActive = false
                    k.console.setInput(null, 0)
                    out(latin1(lineBuf.toString()))
                    if (flags and GSF_SHIFT_ESC_EXIT != 0) {
                        t.state = Kernel.DEAD; t.blocked = true; k.taskEnded(t, null)
                    }
                    return ByteArray(0)
                }
                ch == Keys.CH_ESC -> if (multi) {
                    lineActive = false
                    k.console.setInput(null, 0)
                    out(latin1(lineBuf.toString()))
                    lineDone.append(lineBuf)
                    return latin1(lineDone.toString())
                }
                ch == '\n'.code || ch == '\r'.code -> {
                    out(latin1(lineBuf.toString() + "\n"))
                    if (multi) {
                        lineDone.append(lineBuf).append('\n'); lineBuf.setLength(0)
                    } else {
                        lineActive = false
                        k.console.setInput(null, 0)
                        return latin1(lineBuf.toString())
                    }
                }
                ch == 8 -> if (lineBuf.isNotEmpty()) lineBuf.setLength(lineBuf.length - 1)
                ch in 32..255 -> lineBuf.append(ch.toChar())
            }
            k.console.setInput(lineBuf.toString(), lineBuf.length)
        }
        waitMsg(t)
        return null
    }

    // ================================================================ tasks & windows

    private fun tasks() {
        reg("Spawn") { t, a, _ ->
            val fp = t.st[a]; val data = t.st[a + 1]; val nameP = t.st[a + 2]
            val name = if (nameP != 0L) mem.readStr(nameP) else "Task"
            val parentFs = t.st[a + 4]
            val parent = if (parentFs != 0L) k.taskByFs(parentFs) ?: t else t
            // TempleOS has no task cap (memory is the limit; each task gets a 256 KiB stack, MEM_DFT_STK).
            // BomberGolf spawns a 3 s Noise task per bomb, about 90 at once while SPACE repeats; the
            // program's memory limit bounds them here too, this cap only bounds host memory
            if (k.tasks.size >= MAX_TASKS) throw VmFault(chCode("TooMany"), "too many tasks")
            val nt = k.newTask(name, parent)
            // an invalid function pointer must not leave a runnable task without a frame
            try { vm.pushCall(nt, fp, longArrayOf(data)) } catch (e: VmFault) { k.taskEnded(nt, null); throw e }
            nt.speakerTask = fp != 0L && fp == k.soundEffectFp
            nt.fsAddr.toLong()
        }
        reg("Kill") { t, a, _ ->
            val target = k.taskByFs(t.st[a])
            if (target != null) {
                if (target === t) { k.block(t, Kernel.DEAD); t.blocked = true; k.taskEnded(t, null) }
                else k.taskEnded(target, null)
            }
            0
        }
        reg("Exit") { t, _, _ -> t.state = Kernel.DEAD; t.blocked = true; k.taskEnded(t, null); 0 }
        reg("TaskValidate") { t, a, _ -> b(k.taskByFs(t.st[a])?.let { it.state != Kernel.DEAD } ?: false) }
        reg("Suspend") { t, a, _ ->
            val target = if (t.st[a] == 0L) t else k.taskByFs(t.st[a])
            if (target != null) {
                if (t.st[a + 1] != 0L) { target.state = Kernel.SUSPENDED; if (target === t) t.blocked = true }
                else if (target.state == Kernel.SUSPENDED) target.state = Kernel.READY
            }
            0
        }
        // one window per kernel: nothing to raise or focus. WinMax/WinBorder/WinHorz/WinVert and
        // SettingsPush/SettingsPop are the original TempleOS HolyC (Prelude.HC).
        for (n in listOf("WinToTop", "MenuPop"))
            reg(n) { _, _, _ -> 0 }
        reg("WinFocus") {t,a,_->k.focus(if(t.st[a]==0L) t else k.taskByFs(t.st[a]));0}
        reg("AutoComplete") { _, _, _ -> 0 }
        reg("MenuPush") { _, _, _ -> 0 }
        reg("MenuEntryFind") { _, _, _ -> 0 }
        reg("JobQue") { t, a, _ ->
            // run synchronously: TempleOS queues to another core
            val fp = t.st[a]; val data = t.st[a + 1]
            val result=vm.callFunction(t, fp, data)
            val job=mem.calloc(k.prog.classes["CJob"]!!.size.toLong());mem.st8(job+k.o.member("CJob","res"),result);job.toLong()
        }
        reg("JobResGet") { t,a,_ -> if(t.st[a]==0L) 0 else {val job=mem.check(t.st[a],k.prog.classes["CJob"]!!.size);val result=mem.ld8(job+k.o.member("CJob","res"));mem.free(t.st[a]);result} }
        reg("mp_cnt") { _, _, _ -> 1 }
    }


    companion object {
        const val MAX_TASKS = 256
        /** Kernel/KernelA.HH SYS_TIMER_FREQ and the PC's PIT input clock. */
        const val SYS_TIMER_FREQ = (18333L * 65536 / 1000).toDouble()
        const val PIT_FREQ = TempleClock.PIT_HZ.toDouble()
        // GetStr flags (Kernel/KernelA.HH)
        const val GSF_SHIFT_ESC_EXIT = 1
        const val GSF_WITH_NEW_LINE = 2
    }


    // ================================================================ sound

    private var muted = false
    /** CTRL-ALT-M (Kernel/KeyDev.HC CtrlAltM: Mute(!IsMute)). */
    fun toggleMute() { mute(null, !muted) }
    /** The ona the PIT was last set for (Kernel/KMisc.HC scrncast.ona); Int.MIN_VALUE after SndFreq. */
    private var lastOna = 0

    /** Kernel/KMisc.HC Mute: muting turns the speaker off (Snd) and then sets the flag; unmuting only clears it. */
    private fun mute(t: Task?, v: Boolean): Boolean {
        val o = muted
        if (v && !muted) speakerOff(t)
        muted = v
        return o
    }

    private fun speakerOff(t: Task?) { setOna(0); k.speakerChanges++; k.speaker(t, 0.0) }

    /** scrncast.ona in the arena (Kernel/KGlbls.HC CScrnCastGlbls scrncast), resolved once the prelude is compiled. */
    private val scrncastOna by lazy { k.o.global("scrncast") + k.o.member("CScrnCastGlbls", "ona") }

    /** Kernel/KMisc.HC Snd keeps the ona in scrncast.ona, which programs read (ToTheFront: while (scrncast.ona) Yield;). */
    private fun setOna(ona: Int) { lastOna = ona; mem.st1(scrncastOna, ona.toLong()) }

    /** The tone the PIT makes for [fr] Hz: the nearest count of its 1193182 Hz clock (1..65535). */
    fun pitFreq(fr: Double): Double = PIT_FREQ / Math.round(PIT_FREQ / fr).coerceIn(1L, 65535L)
    fun ona2freq(ona: Int): Double = if (ona == 0) 0.0 else 440.0 / 32 * StrictMath.pow(2.0, ona / 12.0)

    /**
     * The tone the PC speaker makes for [ona] (Kernel/KMisc.HC Snd): TempleOS programs PIT channel 2
     * with period=ClampI64(SYS_TIMER_FREQ/Ona2Freq(ona),1,U16_MAX), where SYS_TIMER_FREQ is
     * 18333*65536/1000, but the PIT counts at 1193182 Hz, so every note is about 0.7% flat (A4 is
     * 437.06 Hz; measured on the reference VM). A negative ona is a valid I8 and plays ~18.2 Hz.
     */
    fun speakerFreq(ona: Int): Double {
        if (ona == 0) return 0.0
        val period = (SYS_TIMER_FREQ / ona2freq(ona)).toLong().coerceIn(1L, 65535L)
        return PIT_FREQ / period
    }

    private fun sound() {
        // Kernel/KMisc.HC: a muted speaker ignores Snd (scrncast.ona keeps its value), and the ona already
        // playing leaves the PIT alone; anything else reprograms it until the next Snd
        reg("Snd") { t, a, _ ->
            val ona = t.st[a].toByte().toInt()
            if (!muted && ona != lastOna) {
                setOna(ona)
                k.speakerChanges++
                k.speaker(t, speakerFreq(ona))
            }
            0
        }
        // Not in TempleOS V5.03 (a TempleOS Mobile addition, used by no bundled program): sets the PIT to
        // the count nearest [freq] Hz, as Snd does for an ona; 0 or less turns the speaker off
        reg("SndFreq") { t, a, _ ->
            val fr = d(t.st[a])
            if (!muted) {
                if (fr.isFinite() && fr > 0) { lastOna = Int.MIN_VALUE; k.speakerChanges++; k.speaker(t, pitFreq(fr)) }
                else if (lastOna != 0) speakerOff(t)
            }
            0
        }
        reg("Mute") { t, a, _ -> b(mute(t, t.st[a] != 0L)) }
        reg("IsMute") { _, _, _ -> b(muted) }
        // Kernel/KMisc.HC: "Fix stuck sound": frees the sound semaphore and turns the speaker off (Snd)
        reg("SndRst") { t, _, _ -> if (!muted) speakerOff(t); 0 }
        reg("Ona2Freq") { t, a, _ -> f(ona2freq(t.st[a].toByte().toInt())) }
        // Kernel/KMisc.HC: ClampI64(12*Log2(32.0/440.0*freq),1,I8_MAX); the F64 argument is truncated
        // toward zero (Compiler/BackFA.HC FISTTP)
        reg("Freq2Ona") { t, a, _ ->
            val fr = d(t.st[a])
            if (fr > 0) (12 * StrictMath.log(32.0 / 440.0 * fr) / StrictMath.log(2.0)).toLong().coerceIn(1, 127) else 0
        }
    }

    // ================================================================ files

    private fun fsOrFail() = k.env.fs ?: throw VmFault(chCode("NoFS"), "no filesystem")

    private fun abs(t: Task, p: Long): String? {
        val s = mem.readStr(p)
        return Paths.normalize(k.curDir(t), s)
    }

    private fun files() {
        reg("FileRead") { t, a, _ ->
            val path = abs(t, t.st[a]) ?: return@reg 0
            val data = k.env.fs?.readFile(path) ?: k.env.fs?.readFile("$path.Z")
            if (data == null) 0 else {
                val p = mem.malloc(data.size + 1L)
                mem.writeBytes(p, data); mem.st1(p + data.size, 0)
                if (t.st[a + 1] != 0L) mem.st8(mem.check(t.st[a + 1], 8), data.size.toLong())
                p.toLong()
            }
        }
        reg("FileWrite") { t, a, _ ->
            val path = abs(t, t.st[a]) ?: throw VmFault(chCode("BadPath"), "invalid path")
            val n = t.st[a + 2].toInt()
            val data = if (n > 0) mem.readBytes(mem.check(t.st[a + 1], n), n) else ByteArray(0)
            try { fsOrFail().writeFile(path, data); n.toLong() } catch (e: FsError) {
                out(latin1("\$RED\$${e.message}\$FG\$\n")); 0
            }
        }
        reg("FileFind") { t, a, _ -> val p = abs(t, t.st[a]); b(p != null && ((k.env.fs?.exists(p) ?: false) || p in listOf("C:/Adam/AutoComplete/ACDefs.DATA","C:/Adam/AutoComplete/ACWords.DATA.Z") && "dictionary" in k.prog.requiredServices)) }
        // the files of a directory as a TempleOS list ("a\0b\0\0"), for PopUpPickFile (Prelude.HC)
        reg("MobileDirLst") { t, a, _ ->
            val p = abs(t, t.st[a]) ?: return@reg 0
            val names = k.env.fs?.list(p)?.filter { !it.isDir }?.map { it.name }?.sorted() ?: return@reg 0
            newStr(latin1(names.joinToString("") { it + "\u0000" }))
        }
        reg("Dir") { t, a, _ -> FsCommands(k, t).dir(mem.readStr(t.st[a]).ifEmpty { "*" }, t.st[a + 1] != 0L) }
        reg("Cd") { t, a, _ ->
            val target = if (t.st[a] == 0L) "C:/Home" else mem.readStr(t.st[a])
            b(FsCommands(k, t).cd(target, t.st[a + 1] != 0L))
        }
        reg("DirCur") { t, _, _ -> newStr(latin1(k.curDir(t))) }
        reg("DirMk") { t, a, _ -> b(FsCommands(k, t).mkdir(mem.readStr(t.st[a]))) }
        reg("Del") { t, a, _ -> FsCommands(k, t).del(mem.readStr(t.st[a]), t.st[a + 2] != 0L, t.st[a + 3] != 0L) }
        reg("DelTree") { t, a, _ -> FsCommands(k, t).delTree(mem.readStr(t.st[a])) }
        reg("Copy") { t, a, _ -> b(FsCommands(k, t).copy(mem.readStr(t.st[a]), mem.readStr(t.st[a + 1]))) }
        reg("Move") { t, a, _ -> b(FsCommands(k, t).move(mem.readStr(t.st[a]), mem.readStr(t.st[a + 1]))) }
        reg("Type") { t, a, _ -> FsCommands(k, t).type(mem.readStr(t.st[a])); 0 }
        reg("Ed") { t, a, _ -> abs(t, t.st[a])?.let { k.env.openEditor(k, it) }; 0 }
        reg("Man") { t, a, _ -> k.env.openDocument(k, "man:" + mem.readStr(t.st[a])); 0 }
        reg("Help") { _, _, _ -> k.env.openDocument(k, "C:/Doc/HelpIndex.DD"); 0 }
        reg("DocLink") { t, a, _ -> abs(t, t.st[a])?.let { k.env.openDocument(k, it) }; 0 }
        reg("FileNameAbs") { t, a, _ -> newStr(latin1(abs(t, t.st[a]) ?: "")) }
    }

    // ================================================================ graphics

    private fun graphics() {
        reg("GrUsed") { _, _, _ -> k.graphicsUsed = true; 0 }
        reg("GrPlot0") { t, a, _ -> k.gfx.plot0(t.st[a], t.st[a + 1], t.st[a + 2]); 1 }
        reg("GrPlot") { t, a, _ -> k.raster.plot(t.st[a], t.st[a + 1], t.st[a + 2]) }
        reg("GrPlot1") { t, a, _ -> k.raster.plot1(t.st[a], t.st[a + 1], t.st[a + 2]) }
        reg("GrPeek") { t, a, _ -> k.raster.peek(t.st[a], t.st[a + 1], t.st[a + 2]) }
        reg("GrRect") { t, a, _ -> k.raster.rect(t.st[a], t.st[a + 1], t.st[a + 2], t.st[a + 3], t.st[a + 4]) }
        reg("GrHLine") { t, a, _ -> k.raster.hline(t.st[a], t.st[a + 1], t.st[a + 2], t.st[a + 3], t.st[a + 4], t.st[a + 5]) }
        reg("GrVLine") { t, a, _ -> k.raster.vline(t.st[a], t.st[a + 1], t.st[a + 2], t.st[a + 3], t.st[a + 4], t.st[a + 5]) }
        reg("GrFillTri0") { t, a, _ -> k.raster.fillTri0(t.st[a], t.st[a + 1], t.st[a + 2], t.st[a + 3]) }
        reg("GrBlot3") { t, a, _ -> k.raster.blot3(t.st[a], t.st[a + 1], t.st[a + 2], t.st[a + 3], t.st[a + 4]) }
        val v3 = LongArray(3)
        fun xyz(t: Task, a: Int, f: (LongArray) -> Unit) {
            val px = mem.check(t.st[a], 8); val py = mem.check(t.st[a + 1], 8); val pz = mem.check(t.st[a + 2], 8)
            v3[0] = mem.ld8(px); v3[1] = mem.ld8(py); v3[2] = mem.ld8(pz)
            f(v3)
            mem.st8(px, v3[0]); mem.st8(py, v3[1]); mem.st8(pz, v3[2])
        }
        reg("GrPutChar") { t, a, _ -> k.raster.putChar(t.st[a], t.st[a + 1], t.st[a + 2], t.st[a + 3]) }
        reg("Circle") { t, a, _ -> k.raster.circle(t, t.st[a], t.st[a + 1], t.st[a + 2], t.st[a + 3], t.st[a + 4], t.st[a + 5], t.st[a + 6], d(t.st[a + 7]), d(t.st[a + 8])) }
        reg("DCLighting") { t, a, _ -> k.raster.lighting(t.st[a], t.st[a + 1], t.st[a + 2], t.st[a + 3], t.st[a + 4]); 0 }
        reg("Mat4x4MulMat4x4Equ") { t, a, _ -> k.raster.mulMat4x4(t.st[a], t.st[a + 1], t.st[a + 2]) }
        reg("Mat4x4MulXYZ") { t, a, _ -> val r = mem.check(t.st[a], 128); xyz(t, a + 1) { k.raster.mulXYZ(r, it) }; 0 }
        reg("DCTransform") { t, a, _ -> val dc = mem.check(t.st[a], 8); xyz(t, a + 1) { k.raster.dcTransform(dc, it) }; 0 }
        reg("DCReflect") { t, a, _ -> val dc = mem.check(t.st[a], 8); xyz(t, a + 1) { k.raster.dcReflect(dc, it) }; 0 }
        reg("GrFillCircle") { t, a, _ -> k.raster.fillCircle(t.st[a], t.st[a + 1], t.st[a + 2], t.st[a + 3], t.st[a + 4]) }
        reg("GrFillSemiCircle") { t, a, _ -> k.raster.fillSemiCircle(t.st[a], t.st[a + 1], t.st[a + 2], t.st[a + 3], t.st[a + 4], t.st[a + 5]) }
        reg("GrLineFat3") { t, a, _ -> k.raster.lineFat3(t.st[a], t.st[a + 1], t.st[a + 2], t.st[a + 3], t.st[a + 4], t.st[a + 5], t.st[a + 6], t.st[a + 7], t.st[a + 8]) }
        reg("SpriteElemSize") { t, a, _ -> k.raster.spriteElemSize(t.st[a]) }
        reg("SpriteSize") { t, a, _ -> k.raster.spriteSize(t.st[a]) }
        reg("Line") { t, a, _ -> k.raster.line(t, t.st[a], t.st[a + 1], t.st[a + 2], t.st[a + 3], t.st[a + 4], t.st[a + 5], t.st[a + 6], t.st[a + 7], t.st[a + 8], t.st[a + 9]) }
        reg("GrBlot") { t, a, _ -> k.raster.blot(t.st[a], t.st[a + 1], t.st[a + 2], t.st[a + 3]) }
        reg("GrFloodFillRay") { t, a, _ -> k.gfx.floodFillRay(t.st[a], t.st[a + 1], t.st[a + 2], t.st[a + 3]) }
        reg("DefinePrint") { t, a, n ->
            val name = mem.readStr(t.st[a])
            val text = format(t, t.st[a + 1], a + 2, n - 2)
            k.defines[name] = Lexer(null, k.defines).tokenizeFragment(latin1(text), "DefinePrint", 0)
            val p = newStr(text)
            k.defineStrs[name] = Kernel.DefStr(p.toInt(), -1, 0)
            p
        }
        // Kernel/KDefine.HC: DEFINE strings and lists
        reg("DefineLoad") { t, a, _ ->
            val name = mem.readStr(t.st[a])
            val text = mem.readStrBytes(t.st[a + 1])
            k.defines[name] = Lexer(null, k.defines).tokenizeFragment(latin1(text), "DefineLoad", 0)
            val p = newStr(text)
            k.defineStrs[name] = Kernel.DefStr(p.toInt(), -1, 0)
            p
        }
        reg("DefineLstLoad") { t, a, _ ->
            val name = mem.readStr(t.st[a])
            val lst = mem.check(t.st[a + 1], 1)
            // entries are NUL-terminated; the list ends with an empty entry. '@' entries are skipped.
            var q = lst; var cnt = 0
            while (mem.ld1(mem.check(q.toLong(), 1)) != 0L) {
                if (mem.ld1(q) != '@'.code.toLong()) cnt++
                q += mem.strLen(q) + 1
            }
            val len = q + 1 - lst
            val data = mem.malloc(len.toLong())
            mem.copy(data, lst, len)
            val subs = mem.malloc(maxOf(cnt, 1) * 8L)
            var p = data; var i = 0
            while (mem.ld1(p) != 0L) {
                if (mem.ld1(p) != '@'.code.toLong()) { mem.st8(subs + i * 8, p.toLong()); i++ }
                p += mem.strLen(p) + 1
            }
            k.defineStrs[name] = Kernel.DefStr(data, cnt, subs)
            data.toLong()
        }
        fun undefinedDefine(name: String): Nothing = throw VmFault(chCode("UndefDef"), "Undefined Define: '$name'.")
        reg("Define") { t, a, _ ->
            if (t.st[a] == 0L) 0L else {
                val name = mem.readStr(t.st[a])
                (k.defineStrs[name] ?: undefinedDefine(name)).data.toLong()
            }
        }
        reg("DefineSub") { t, a, _ ->
            if (t.st[a + 1] == 0L) 0L else {
                val name = mem.readStr(t.st[a + 1])
                val r = k.defineSub(t.st[a], name)
                if (r < 0) undefinedDefine(name) else r.toLong()
            }
        }
        reg("DefineCnt") { t, a, _ ->
            if (t.st[a] == 0L) -1L else {
                val name = mem.readStr(t.st[a])
                (k.defineStrs[name] ?: undefinedDefine(name)).cnt.toLong()
            }
        }
        reg("GrPeek0") { t, a, _ -> k.gfx.peek0(t.st[a], t.st[a + 1], t.st[a + 2]) }
        reg("IsPixCovered0") { _, _, _ -> 0 }
        reg("GrPaletteColorSet") { t, a, _ -> k.gfx.paletteSet(t.st[a].toInt(), t.st[a + 1]); 0 }
        reg("GrPaletteColorGet") { t, a, _ -> k.gfx.paletteGet(t.st[a].toInt()) }
        reg("TextChar") { t, a, _ ->
            k.graphicsUsed = true
            b(k.gfx.textChar(t.st[a], t.st[a + 1] != 0L, t.st[a + 2], t.st[a + 3], t.st[a + 4]))
        }
        reg("TextLenStr") { t, a, _ ->
            k.graphicsUsed = true
            val task = t.st[a]; val x = t.st[a + 1]; val y = t.st[a + 2]; val len = t.st[a + 3].toInt(); val attr = t.st[a + 4]
            val sp = t.st[a + 5]
            var any = false
            if (len > 0 && sp != 0L) {
                val p = mem.check(sp, len)
                for (i in 0 until len) any = k.gfx.textChar(task, false, x + i, y, attr or mem.ld1(p + i)) or any
            }
            b(any)
        }
        reg("TextLenAttrStr") { t, a, _ ->
            k.graphicsUsed = true
            val task = t.st[a]; val x = t.st[a + 1]; val y = t.st[a + 2]; val len = t.st[a + 3].toInt(); val ap = t.st[a + 4]
            var any = false
            if (len > 0 && ap != 0L) {
                val p = mem.check(ap, len * 4)
                for (i in 0 until len) any = k.gfx.textChar(task, false, x + i, y, mem.ld4(p + i * 4)) or any
            }
            b(any)
        }
        reg("TextLenAttr") { t, a, _ ->
            k.graphicsUsed = true
            val task = t.st[a]; val x = t.st[a + 1]; val y = t.st[a + 2]; val len = t.st[a + 3].toInt(); val attr = t.st[a + 4]
            var any = false
            for (i in 0 until maxOf(len, 0)) any = k.gfx.textAttr(task, x + i, y, attr) or any
            b(any)
        }
        reg("Option") { _, _, _ -> 0 }
        reg("SysFont") { _, _, _ -> k.gfx.fontAddr.toLong() }
    }
}

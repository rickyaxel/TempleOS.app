@file:Suppress("NOTHING_TO_INLINE")

package io.github.templeosmobile.core.purenative

import io.github.templeosmobile.core.holyc.*

/**
 * Base class of the Kotlin modules the translator generates from TempleOS HolyC (Pure Kotlin mode).
 *
 * Generated functions are ordinary compiled Kotlin: native locals, native control flow, native
 * arithmetic. They share with the interpreter only what HolyC programs observe: the program's arena
 * (pointers are arena addresses, so data layouts and pointer arithmetic are TempleOS's), the host
 * functions (natives: graphics, sound, files, input, scheduling) and the kernel. The helpers here
 * implement the VM's semantics for operations Kotlin does not have directly; each is a few lines of
 * Kotlin with the same behaviour as the corresponding bytecode (see holyc/Vm.kt).
 */
abstract class NativeModule(@JvmField val rt: NativeRuntime) {
    @JvmField val m: Arena = rt.mem
    @JvmField val vm: Vm = rt.vm

    /** Calls generated function [index] of this module with word arguments t.st[base until base+n]. */
    abstract fun dispatch(t: Task, index: Int, base: Int, n: Int): Long
    /** True when this module defines function [index]. */
    abstract fun defines(index: Int): Boolean
    /** Sets the address fields of the globals, strings and binary literals of data-segment unit [unit]. */
    abstract fun bind(unit: Int, seg: Segment)
    /** The HolyC name of function [index] (messages). */
    abstract fun nameOf(index: Int): String?

    // ------------------------------------------------------------ memory (checked, as the VM's LDn/STn)
    //
    // Each accessor first tries a fused fast path: an in-bounds access at its natural alignment reads or
    // writes the arena's word array directly, exactly as Arena's aligned case does. Anything else
    // (unaligned, out of bounds) takes the original Arena.check + Arena access calls, with the same faults.
    // The 8-byte accessors (pointers, F64: most accesses) are expanded inline; the sub-word ones are single
    // calls (inline everywhere, they made GrFillTri0 exceed the JVM's 64 KB method limit).
    // Without it every access was two out-of-line calls that ART does not inline into the large generated
    // methods: 45% of X-Caliber's time on the OPPO (simpleperf, docs/native-validation).

    fun ld1u(a: Long): Long { val mm = m; return if (a >= 0L && a < mm.size) (mm.words[(a ushr 3).toInt()] ushr ((a.toInt() and 7) shl 3)) and 0xFF else mm.ld1(mm.check(a, 1)) }
    inline fun ld1s(a: Long): Long = ld1u(a).toByte().toLong()
    fun ld2u(a: Long): Long { val mm = m; return if ((a and 1L) == 0L && a >= 0L && a <= mm.size - 2L) (mm.words[(a ushr 3).toInt()] ushr ((a.toInt() and 7) shl 3)) and 0xFFFF else mm.ld2(mm.check(a, 2)) }
    inline fun ld2s(a: Long): Long = ld2u(a).toShort().toLong()
    fun ld4u(a: Long): Long { val mm = m; return if ((a and 3L) == 0L && a >= 0L && a <= mm.size - 4L) (mm.words[(a ushr 3).toInt()] ushr ((a.toInt() and 7) shl 3)) and 0xFFFFFFFFL else mm.ld4(mm.check(a, 4)) }
    inline fun ld4s(a: Long): Long = ld4u(a).toInt().toLong()
    inline fun ld8(a: Long): Long { val mm = m; return if ((a and 7L) == 0L && a >= 0L && a <= mm.size - 8L) mm.words[(a ushr 3).toInt()] else mm.ld8(mm.check(a, 8)) }
    inline fun ldf(a: Long): Double = java.lang.Double.longBitsToDouble(ld8(a))
    fun st1(a: Long, v: Long) {
        val mm = m
        if (a >= 0L && a < mm.size) { val w = mm.words; val i = (a ushr 3).toInt(); val sh = (a.toInt() and 7) shl 3; w[i] = (w[i] and (0xFFL shl sh).inv()) or ((v and 0xFF) shl sh) }
        else mm.st1(mm.check(a, 1), v)
    }
    fun st2(a: Long, v: Long) {
        val mm = m
        if ((a and 1L) == 0L && a >= 0L && a <= mm.size - 2L) { val w = mm.words; val i = (a ushr 3).toInt(); val sh = (a.toInt() and 7) shl 3; w[i] = (w[i] and (0xFFFFL shl sh).inv()) or ((v and 0xFFFF) shl sh) }
        else mm.st2(mm.check(a, 2), v)
    }
    fun st4(a: Long, v: Long) {
        val mm = m
        if ((a and 3L) == 0L && a >= 0L && a <= mm.size - 4L) { val w = mm.words; val i = (a ushr 3).toInt(); val sh = (a.toInt() and 7) shl 3; w[i] = (w[i] and (0xFFFFFFFFL shl sh).inv()) or ((v and 0xFFFFFFFFL) shl sh) }
        else mm.st4(mm.check(a, 4), v)
    }
    inline fun st8(a: Long, v: Long) { val mm = m; if ((a and 7L) == 0L && a >= 0L && a <= mm.size - 8L) mm.words[(a ushr 3).toInt()] = v else mm.st8(mm.check(a, 8), v) }
    /** MEMCPY: destination checked before the source, as the VM pops them. */
    fun copy(dst: Long, src: Long, n: Int) { val d = m.check(dst, n); val s = m.check(src, n); m.copy(d, s, n) }

    // ------------------------------------------------------------ arithmetic

    inline fun f(bits: Long): Double = java.lang.Double.longBitsToDouble(bits)
    inline fun bits(x: Double): Long = x.toRawBits()
    inline fun b2i(b: Boolean): Long = if (b) 1L else 0L
    inline fun ltu(a: Long, b: Long): Boolean = (a xor Long.MIN_VALUE) < (b xor Long.MIN_VALUE)
    inline fun leu(a: Long, b: Long): Boolean = (a xor Long.MIN_VALUE) <= (b xor Long.MIN_VALUE)
    inline fun gtu(a: Long, b: Long): Boolean = (a xor Long.MIN_VALUE) > (b xor Long.MIN_VALUE)
    inline fun geu(a: Long, b: Long): Boolean = (a xor Long.MIN_VALUE) >= (b xor Long.MIN_VALUE)
    inline fun eval(x: Long) {}
    inline fun eval(x: Double) {}
    inline fun eval(x: Boolean) {}
    inline fun sx1(x: Long): Long = x.toByte().toLong()
    inline fun sx2(x: Long): Long = x.toShort().toLong()
    inline fun sx4(x: Long): Long = x.toInt().toLong()
    inline fun u2f(x: Long): Double = io.github.templeosmobile.core.holyc.u2f(x)
    inline fun f2i(x: Double): Long = io.github.templeosmobile.core.holyc.f2i(x)
    inline fun ipow(b: Long, e: Long): Long = io.github.templeosmobile.core.holyc.ipow(b, e)
    inline fun fpow(a: Double, b: Double): Double = templePow(a, b)

    fun divs(a: Long, d: Long): Long {
        if (d == 0L || (d == -1L && a == Long.MIN_VALUE)) throw VmFault(Vm.DIV_ZERO, "division by zero")
        return if (d == -1L) -a else a / d
    }
    fun mods(a: Long, d: Long): Long {
        if (d == 0L || (d == -1L && a == Long.MIN_VALUE)) throw VmFault(Vm.DIV_ZERO, "division by zero")
        return if (d == -1L) 0L else a % d
    }
    fun divu(a: Long, d: Long): Long { if (d == 0L) throw VmFault(Vm.DIV_ZERO, "division by zero"); return java.lang.Long.divideUnsigned(a, d) }
    fun modu(a: Long, d: Long): Long { if (d == 0L) throw VmFault(Vm.DIV_ZERO, "division by zero"); return java.lang.Long.remainderUnsigned(a, d) }

    // ------------------------------------------------------------ frames, depth, budget

    /** Function entry: call depth as the VM counts it (StkOver at MAX_DEPTH). */
    inline fun enter(t: Task) { if (++t.depth > Task.MAX_DEPTH) { t.depth--; throw VmFault(Vm.STK_OVER, "stack overflow (call depth)") } }

    /** An arena frame of [size] bytes at the 8-aligned top of the task's stack (VM enter). */
    fun frame(t: Task, size: Int): Long {
        val fp = (t.msp + 7) and 7.inv()
        if (fp + size > t.mspLimit) { t.depth--; throw VmFault(Vm.STK_OVER, "stack overflow") }
        t.msp = fp + size
        return fp.toLong()
    }

    /** One budget tick (a backward branch or a HolyC call): the slice ends when the budget runs out. */
    inline fun tick(t: Task) { if (--t.budget <= 0) rt.sliceEnd(t) }

    // ------------------------------------------------------------ calls

    /** Writes word arguments at the top of the task's stack (natives and pointer calls read them there). */
    fun push(t: Task, vararg a: Long): Int { val b = t.sp; val st = t.st; for (i in a.indices) st[b + i] = a[i]; t.sp = b + a.size; return b }
    fun push0(t: Task): Int = t.sp
    fun push1(t: Task, a0: Long): Int { val b = t.sp; t.st[b] = a0; t.sp = b + 1; return b }
    fun push2(t: Task, a0: Long, a1: Long): Int { val b = t.sp; val st = t.st; st[b] = a0; st[b + 1] = a1; t.sp = b + 2; return b }
    fun push3(t: Task, a0: Long, a1: Long, a2: Long): Int { val b = t.sp; val st = t.st; st[b] = a0; st[b + 1] = a1; st[b + 2] = a2; t.sp = b + 3; return b }
    fun push4(t: Task, a0: Long, a1: Long, a2: Long, a3: Long): Int { val b = t.sp; val st = t.st; st[b] = a0; st[b + 1] = a1; st[b + 2] = a2; st[b + 3] = a3; t.sp = b + 4; return b }

    /** Calls host function [index] with the words pushed at [base] (VM CALLN: blocking natives suspend the task). */
    fun nat(t: Task, index: Int, base: Int): Long { val r = rt.callNative(t, index, base, t.sp - base); t.sp = base; return r }

    /** Calls through a HolyC function pointer with the words pushed at [base] (VM CALLP). */
    fun ptr(t: Task, fp: Long, base: Int): Long { val r = rt.callPointer(t, fp, base, t.sp - base); t.sp = base; return r }

    /** A function that was declared but never defined (VM: 'BadCall' when called). */
    fun undefined(name: String): Long = throw VmFault(Vm.BAD_CALL, "call of undefined function '$name'")

    /** Varargs callee: copies the [n] extra words at [base] to the frame at [dst] (where argv points). */
    fun vaCopy(t: Task, dst: Long, base: Int, n: Int) { val st = t.st; for (i in 0 until n) m.st8(dst.toInt() + i * 8, st[base + i]) }

    // ------------------------------------------------------------ exceptions (VM raise / ENDCATCH)

    /** Source files of this module's code (generated); [locate] decodes `fileIndex shl 20 or line`. */
    protected open val files: Array<String> get() = emptyArray()

    /**
     * A fault leaving generated function [name]: records where it happened, as the VM's message gives it
     * ("Function (file:line)"), unless a function it called already did.
     */
    fun locate(f: VmFault, name: String, ln: Int): VmFault {
        if (f.where == null) f.where = "$name (${files.getOrElse(ln ushr 20) { "?" }}:${ln and 0xFFFFF})"
        return f
    }

    /** In a catch: records the exception as the VM's raise does; rethrows what HolyC cannot catch. */
    fun caught(t: Task, e: RuntimeException) = rt.caught(t, e)
    fun endCatch(t: Task) = rt.endCatch(t)
}

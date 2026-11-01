package io.github.templeosmobile.core.holyc

/** Exception that escaped a nested callback (propagated to the caller's context). */
class VmUncaught(val ch: Long, message: String) : RuntimeException(message, null, false, false)

/** A cooperative HolyC task: operand stack, call frames and exception handlers. */
class Task(val vm: Vm, val id: Int, val name: String) {
    companion object {
        const val STACK_WORDS = 8192
        const val MAX_DEPTH = 2048
        const val MAX_HANDLERS = 256
        const val MEM_STACK = 256 * 1024
    }

    val st = LongArray(STACK_WORDS)
    var sp = 0
    var pc = 0
    var fp = 0
    var msp = 0
    val mspBase: Int = vm.mem.allocStack(MEM_STACK.toLong())
    val mspLimit: Int = mspBase + MEM_STACK

    val fRet = IntArray(MAX_DEPTH)
    val fFp = IntArray(MAX_DEPTH)
    val fMsp = IntArray(MAX_DEPTH)
    var depth = 0

    val hPc = IntArray(MAX_HANDLERS)
    val hSp = IntArray(MAX_HANDLERS)
    val hFp = IntArray(MAX_HANDLERS)
    val hMsp = IntArray(MAX_HANDLERS)
    val hDepth = IntArray(MAX_HANDLERS)
    var hCount = 0
    var handlerBase = 0

    /** Set by a native to suspend the task; the native is re-executed on resume. */
    var blocked = false
    /** Set by the scheduler when a blocked task is woken (the native re-runs). */
    var resumed = false
    /** Set by a native to end the current time slice after it returns. */
    var yieldReq = false
    /** True when the last [Vm.run] ended because the task yielded (not because its slice ran out). */
    var yielded = false
    var result = 0L
    var faultPc = 0
    var deathMessage: String? = null
    /** The exception code that ended the task (with [deathMessage]); 0 if unknown. */
    var deathCode = 0L
    var nestLevel = 0

    /** Arena address of this task's CTask struct (the HolyC `Fs`). */
    var fsAddr = 0

    /** Scheduler/kernel owned state. */
    var state = 0
    var wakeAt = 0L
    /** How late the scheduler woke this task from its last timed sleep (0 for other wake-ups), in ns. */
    var lateNs = 0L
    var blockToken = 0L
    /** Started on TempleOS's SoundEffectTask (Noise/Sweep): its Sleep(0) is paced (Natives Sleep). */
    var speakerTask = false
    var userData: Any? = null

    // ---- native execution (purenative.NativeRuntime): unused by the bytecode interpreter
    /** Budget ticks left in this slice (the VM keeps its budget in a local). */
    @JvmField var budget = 0
    /** Slices a nested callback has run (the VM's callFunction guard). */
    @JvmField var nestGuard = 0
    /** Exception injected while suspended (Break), raised when the task resumes. */
    @JvmField var pendingFault: Long? = null
    /** The engine's per-task state (its thread). */
    @JvmField var engineData: Any? = null

    init { msp = mspBase; fp = mspBase }
}

/**
 * Executes compiled HolyC without the bytecode interpreter (purenative.NativeRuntime runs
 * ahead-of-time translated Kotlin). When [Vm.engine] is set, the VM's entry points delegate to it
 * and the interpreter loop refuses to run, so a kernel is either interpreted or native, never both.
 */
interface ExecEngine {
    fun pushCall(t: Task, fnPtrOrIndex: Long, args: LongArray)
    fun run(t: Task, budget: Int): Int
    fun callFunction(t: Task, fnPtr: Long, args: LongArray): Long
    fun inject(t: Task, ch: Long): Boolean
    /** [t] ended or was killed; its execution context can be discarded. */
    fun taskGone(t: Task)
    /** The kernel ended: every task's execution context is discarded. */
    fun shutdown()
}

/**
 * The bytecode interpreter. One Vm instance owns one arena and one program; it is
 * driven by a single thread (the program's kernel thread).
 */
class Vm(arenaInitial: Int = 1 shl 20, arenaMax: Int = 32 shl 20) {
    val mem = Arena(arenaInitial, arenaMax)
    val natives = NativeTable()
    val prog = Program(this)

    @Volatile var interrupt = false

    /**
     * Native engine only: at the end of a task's slice, the kernel's answer to "may this task simply go on?"
     * (Kernel.continueSlice): the next slice's budget, or 0 to hand the CPU back to the scheduler.
     */
    var sliceContinuation: ((Task) -> Int)? = null

    /** Native execution engine (Pure Kotlin mode); null for the interpreter (Pure Terry mode). */
    var engine: ExecEngine? = null

    /** Budget ticks consumed (backward branches and HolyC calls), counted by both engines. */
    var ticksExecuted = 0L

    /** Polled between slices of a nested callback; true raises 'Break' in it (set by the kernel). */
    var callbackBreak: ((Task) -> Boolean)? = null

    /** Called between slices of a nested callback so the kernel can run frames and other tasks (V-17). */
    var callbackYield: ((Task) -> Unit)? = null

    /** Offsets of CTask.except_ch / catch_except in the arena (set by the kernel). */
    var exceptChOff = -1
    var catchExceptOff = -1

    var instructionsExecuted = 0L

    /** Optional sampling profiler: function name -> samples (debug builds/tests only). */
    var profile: HashMap<String, Int>? = null
    private var profileTick = 0
    private fun sample(pc: Int) {
        val p = profile ?: return
        if (++profileTick and 63 != 0) return
        val n = prog.funcAt(pc)
        p[n] = (p[n] ?: 0) + 1
    }

    companion object {
        const val R_SLICE = 0
        const val R_BLOCKED = 1
        const val R_DONE = 2
        const val R_DEAD = 3
        val DIV_ZERO = chCode("DivZero")
        val STK_OVER = chCode("StkOver")
        val BAD_CALL = chCode("BadCall")
        val BREAK = chCode("Break")
    }

    // ------------------------------------------------------------ entry points

    /** Prepares [t] to call user function [fi] with [args]; the frame returns to the caller (-1). */
    fun pushCall(t: Task, fnPtrOrIndex: Long, args: LongArray) {
        engine?.let { return it.pushCall(t, fnPtrOrIndex, args) }
        for (a in args) t.st[t.sp++] = a
        val fi = decodeUserFn(fnPtrOrIndex)
        enter(t, fi, args.size, -1)
    }

    private fun decodeUserFn(v: Long): Int {
        if ((v and -0x100000000L) == Program.FPTR_TAG) return (v and 0xFFFFFFFFL).toInt()
        if (v in 0 until prog.funcs.size) return v.toInt()
        throw VmFault(BAD_CALL, "call of invalid function pointer 0x${java.lang.Long.toHexString(v)}")
    }

    /**
     * Calls a function pointer synchronously on task [t] (used for callbacks such
     * as draw_it and QSort comparators). Blocking natives return immediately.
     */
    fun callFunction(t: Task, fnPtr: Long, vararg args: Long): Long {
        engine?.let { return it.callFunction(t, fnPtr, args) }
        if ((fnPtr and -0x100000000L) == Program.FPTR_NATIVE) {
            val n = natives.list[(fnPtr and 0xFFFFFFFFL).toInt()]
            val base = t.sp
            for (a in args) t.st[t.sp++] = a
            val r = n.call(t, base, args.size)
            t.sp = base
            t.blocked = false
            return r
        }
        val savedSp = t.sp; val savedPc = t.pc; val savedFp = t.fp; val savedMsp = t.msp
        val savedDepth = t.depth; val savedHBase = t.handlerBase
        t.handlerBase = t.hCount
        t.nestLevel++
        try {
            for (a in args) t.st[t.sp++] = a
            enter(t, decodeUserFn(fnPtr), args.size, -1)
            var guard = 0
            while (true) {
                val r = run(t, 200_000, savedDepth)
                if (r == R_DONE) return t.result
                if (r == R_DEAD) throw VmUncaught(0, t.deathMessage ?: "callback failed")
                if (interrupt) throw VmKill("stopped")
                if (callbackBreak?.invoke(t) == true) {
                    // into the callback's own handlers, else VmUncaught to the native's caller
                    t.faultPc = t.pc
                    raise(t, BREAK, "", savedDepth)
                }
                if (++guard > 500) throw VmKill("callback ran too long (instruction budget exceeded)")
                t.blocked = false
                callbackYield?.invoke(t)
            }
        } finally {
            t.nestLevel--
            t.sp = savedSp; t.pc = savedPc; t.fp = savedFp; t.msp = savedMsp
            t.depth = savedDepth; t.hCount = t.handlerBase; t.handlerBase = savedHBase
            t.blocked = false
        }
    }

    private fun enter(t: Task, fi: Int, n: Int, retPc: Int) {
        val p = prog
        if (p.fnEntry[fi] < 0) throw VmFault(BAD_CALL, "call of undefined function '${p.funcs[fi].name}'")
        if (t.depth >= Task.MAX_DEPTH) throw VmFault(STK_OVER, "stack overflow (call depth)")
        val d = t.depth
        t.fRet[d] = retPc; t.fFp[d] = t.fp; t.fMsp[d] = t.msp
        t.depth = d + 1
        val np = p.fnNParams[fi]
        val extra = if (n > np) n - np else 0
        val newFp = (t.msp + 7) and 7.inv()
        val frame = p.fnFrame[fi]
        if (newFp + frame + extra * 8 > t.mspLimit) { t.depth = d; throw VmFault(STK_OVER, "stack overflow") }
        val base = t.sp - n
        val offs = p.fnParamOff[fi]!!
        val m = mem
        val cnt = if (n < np) n else np
        for (i in 0 until cnt) m.st8(newFp + offs[i], t.st[base + i])
        val ac = p.fnArgc[fi]
        if (ac >= 0) {
            val va = newFp + frame
            for (i in 0 until extra) m.st8(va + i * 8, t.st[base + np + i])
            m.st8(newFp + ac, extra.toLong())
            m.st8(newFp + p.fnArgv[fi], va.toLong())
        }
        t.sp = base
        t.fp = newFp
        t.msp = newFp + frame + extra * 8
        t.pc = p.fnEntry[fi]
    }

    // ------------------------------------------------------------ exceptions

    /** Transfers control to the innermost handler. Returns false if there is none. */
    private fun raise(t: Task, ch: Long, msg: String?, stopDepth: Int): Boolean {
        if (t.fsAddr != 0 && exceptChOff >= 0) {
            mem.st8(t.fsAddr + exceptChOff, ch)
            mem.st1(t.fsAddr + catchExceptOff, 0)
        }
        if (t.hCount > t.handlerBase) {
            val h = --t.hCount
            t.sp = t.hSp[h]; t.fp = t.hFp[h]; t.msp = t.hMsp[h]; t.depth = t.hDepth[h]; t.pc = t.hPc[h]
            lastFault = msg
            return true
        }
        val where = prog.where(t.faultPc)
        val fn = prog.funcAt(t.faultPc)
        val m = "Unhandled exception '${chStr(ch)}' in $fn ($where)" + (if (msg.isNullOrEmpty()) "" else ": $msg")
        if (stopDepth > 0 || t.nestLevel > 0) throw VmUncaught(ch, m)
        t.deathMessage = m
        t.deathCode = ch
        return false
    }

    /** Raises exception [ch] in a suspended task (Break). Returns false if unhandled. */
    fun inject(t: Task, ch: Long): Boolean {
        engine?.let { return it.inject(t, ch) }
        t.blocked = false; t.resumed = false
        t.faultPc = t.pc
        return try { raise(t, ch, "", 0) } catch (u: VmUncaught) { t.deathMessage = u.message; t.deathCode = u.ch; false }
    }

    /** Message of the last runtime fault that was caught by a handler (for PutExcept). */
    var lastFault: String? = null

    fun chStr(ch: Long): String {
        val sb = StringBuilder()
        var v = ch
        while (v != 0L) { sb.append((v and 0xFF).toInt().toChar()); v = v ushr 8 }
        return sb.toString()
    }

    // ------------------------------------------------------------ interpreter

    /** Runs [t] for about [budget] backward branches/calls. */
    fun run(t: Task, budget: Int, stopDepth: Int = 0): Int {
        engine?.let { return it.run(t, budget) }
        while (true) {
            try {
                return exec(t, budget, stopDepth)
            } catch (f: VmFault) {
                if (!raise(t, f.ch, f.message, stopDepth)) return R_DEAD
            } catch (u: VmUncaught) {
                if (t.nestLevel > 0 && stopDepth > 0) throw u
                // an exception escaped a callback invoked by a native: rethrow in this context
                if (!raise(t, u.ch, u.message, stopDepth)) return R_DEAD
            }
        }
    }

    private fun exec(t: Task, budget0: Int, stopDepth: Int): Int {
        // purity guard: a native kernel never interprets bytecode
        check(engine == null) { "bytecode execution in a native kernel" }
        var code = prog.code.data
        var k = prog.konstArr
        val st = t.st
        val m = mem
        val p = prog
        val nat = natives.list
        var pc = t.pc
        var sp = t.sp
        var fp = t.fp
        var budget = budget0
        var opPc = pc
        var count = 0L
        try {
            while (true) {
                opPc = pc
                count++
                when (code[pc++]) {
                    Op.NOP -> {}
                    Op.PUSHI -> st[sp++] = code[pc++].toLong()
                    Op.PUSHK -> st[sp++] = k[code[pc++]]
                    Op.POP -> sp--
                    Op.DUP -> { st[sp] = st[sp - 1]; sp++ }
                    Op.SWAP -> { val a = st[sp - 1]; st[sp - 1] = st[sp - 2]; st[sp - 2] = a }
                    Op.REV -> { var i = sp - code[pc++].toInt(); var j = sp - 1; while (i < j) { val a = st[i]; st[i] = st[j]; st[j] = a; i++; j-- } }
                    Op.LADDR -> st[sp++] = (fp + code[pc++]).toLong()

                    Op.LD1S -> st[sp - 1] = m.ld1(m.check(st[sp - 1], 1)).toByte().toLong()
                    Op.LD1U -> st[sp - 1] = m.ld1(m.check(st[sp - 1], 1))
                    Op.LD2S -> st[sp - 1] = m.ld2(m.check(st[sp - 1], 2)).toShort().toLong()
                    Op.LD2U -> st[sp - 1] = m.ld2(m.check(st[sp - 1], 2))
                    Op.LD4S -> st[sp - 1] = m.ld4(m.check(st[sp - 1], 4)).toInt().toLong()
                    Op.LD4U -> st[sp - 1] = m.ld4(m.check(st[sp - 1], 4))
                    Op.LD8 -> st[sp - 1] = m.ld8c(st[sp - 1])

                    Op.LLD1S -> st[sp++] = m.ld1(fp + code[pc++]).toByte().toLong()
                    Op.LLD1U -> st[sp++] = m.ld1(fp + code[pc++])
                    Op.LLD2S -> st[sp++] = m.ld2(fp + code[pc++]).toShort().toLong()
                    Op.LLD2U -> st[sp++] = m.ld2(fp + code[pc++])
                    Op.LLD4S -> st[sp++] = m.ld4(fp + code[pc++]).toInt().toLong()
                    Op.LLD4U -> st[sp++] = m.ld4(fp + code[pc++])
                    Op.LLD8 -> st[sp++] = m.ld8(fp + code[pc++])

                    Op.GLD1S -> st[sp++] = m.ld1(code[pc++]).toByte().toLong()
                    Op.GLD1U -> st[sp++] = m.ld1(code[pc++])
                    Op.GLD2S -> st[sp++] = m.ld2(code[pc++]).toShort().toLong()
                    Op.GLD2U -> st[sp++] = m.ld2(code[pc++])
                    Op.GLD4S -> st[sp++] = m.ld4(code[pc++]).toInt().toLong()
                    Op.GLD4U -> st[sp++] = m.ld4(code[pc++])
                    Op.GLD8 -> st[sp++] = m.ld8(code[pc++])

                    Op.ST1 -> { val v = st[--sp]; m.st1(m.check(st[--sp], 1), v) }
                    Op.ST2 -> { val v = st[--sp]; m.st2(m.check(st[--sp], 2), v) }
                    Op.ST4 -> { val v = st[--sp]; m.st4(m.check(st[--sp], 4), v) }
                    Op.ST8 -> { val v = st[--sp]; m.st8c(st[--sp], v) }
                    Op.STK1 -> { val v = st[--sp]; m.st1(m.check(st[sp - 1], 1), v); st[sp - 1] = v }
                    Op.STK2 -> { val v = st[--sp]; m.st2(m.check(st[sp - 1], 2), v); st[sp - 1] = v }
                    Op.STK4 -> { val v = st[--sp]; m.st4(m.check(st[sp - 1], 4), v); st[sp - 1] = v }
                    Op.STK8 -> { val v = st[--sp]; m.st8c(st[sp - 1], v); st[sp - 1] = v }
                    Op.LST8 -> m.st8(fp + code[pc++], st[--sp])
                    Op.LSTK8 -> m.st8(fp + code[pc++], st[sp - 1])
                    Op.GST8 -> m.st8(code[pc++], st[--sp])

                    Op.ADD -> { sp--; st[sp - 1] += st[sp] }
                    Op.SUB -> { sp--; st[sp - 1] -= st[sp] }
                    Op.MUL -> { sp--; st[sp - 1] *= st[sp] }
                    Op.DIVS -> { sp--; val d = st[sp]; if (d == 0L || (d == -1L && st[sp - 1] == Long.MIN_VALUE)) throw VmFault(DIV_ZERO, "division by zero"); st[sp - 1] = if (d == -1L) -st[sp - 1] else st[sp - 1] / d }
                    Op.DIVU -> { sp--; val d = st[sp]; if (d == 0L) throw VmFault(DIV_ZERO, "division by zero"); st[sp - 1] = java.lang.Long.divideUnsigned(st[sp - 1], d) }
                    Op.MODS -> { sp--; val d = st[sp]; if (d == 0L || (d == -1L && st[sp - 1] == Long.MIN_VALUE)) throw VmFault(DIV_ZERO, "division by zero"); st[sp - 1] = if (d == -1L) 0L else st[sp - 1] % d }
                    Op.MODU -> { sp--; val d = st[sp]; if (d == 0L) throw VmFault(DIV_ZERO, "division by zero"); st[sp - 1] = java.lang.Long.remainderUnsigned(st[sp - 1], d) }
                    Op.AND -> { sp--; st[sp - 1] = st[sp - 1] and st[sp] }
                    Op.OR -> { sp--; st[sp - 1] = st[sp - 1] or st[sp] }
                    Op.XOR -> { sp--; st[sp - 1] = st[sp - 1] xor st[sp] }
                    Op.SHL -> { sp--; st[sp - 1] = st[sp - 1] shl st[sp].toInt() }
                    Op.SHRS -> { sp--; st[sp - 1] = st[sp - 1] shr st[sp].toInt() }
                    Op.SHRU -> { sp--; st[sp - 1] = st[sp - 1] ushr st[sp].toInt() }
                    Op.POWI -> { sp--; st[sp - 1] = ipow(st[sp - 1], st[sp]) }
                    Op.NEG -> st[sp - 1] = -st[sp - 1]
                    Op.COM -> st[sp - 1] = st[sp - 1].inv()
                    Op.LNOT -> st[sp - 1] = if (st[sp - 1] == 0L) 1L else 0L
                    Op.TOBOOL -> st[sp - 1] = if (st[sp - 1] != 0L) 1L else 0L
                    Op.LXOR -> { sp--; st[sp - 1] = if ((st[sp - 1] != 0L) != (st[sp] != 0L)) 1L else 0L }
                    Op.EQ -> { sp--; st[sp - 1] = if (st[sp - 1] == st[sp]) 1L else 0L }
                    Op.NE -> { sp--; st[sp - 1] = if (st[sp - 1] != st[sp]) 1L else 0L }
                    Op.LTS -> { sp--; st[sp - 1] = if (st[sp - 1] < st[sp]) 1L else 0L }
                    Op.LES -> { sp--; st[sp - 1] = if (st[sp - 1] <= st[sp]) 1L else 0L }
                    Op.GTS -> { sp--; st[sp - 1] = if (st[sp - 1] > st[sp]) 1L else 0L }
                    Op.GES -> { sp--; st[sp - 1] = if (st[sp - 1] >= st[sp]) 1L else 0L }
                    Op.LTU -> { sp--; st[sp - 1] = if (java.lang.Long.compareUnsigned(st[sp - 1], st[sp]) < 0) 1L else 0L }
                    Op.LEU -> { sp--; st[sp - 1] = if (java.lang.Long.compareUnsigned(st[sp - 1], st[sp]) <= 0) 1L else 0L }
                    Op.GTU -> { sp--; st[sp - 1] = if (java.lang.Long.compareUnsigned(st[sp - 1], st[sp]) > 0) 1L else 0L }
                    Op.GEU -> { sp--; st[sp - 1] = if (java.lang.Long.compareUnsigned(st[sp - 1], st[sp]) >= 0) 1L else 0L }

                    Op.FADD -> { sp--; st[sp - 1] = (d(st[sp - 1]) + d(st[sp])).toRawBits() }
                    Op.FSUB -> { sp--; st[sp - 1] = (d(st[sp - 1]) - d(st[sp])).toRawBits() }
                    Op.FMUL -> { sp--; st[sp - 1] = (d(st[sp - 1]) * d(st[sp])).toRawBits() }
                    Op.FDIV -> { sp--; st[sp - 1] = (d(st[sp - 1]) / d(st[sp])).toRawBits() }
                    Op.FMOD -> { sp--; st[sp - 1] = (d(st[sp - 1]) % d(st[sp])).toRawBits() }
                    Op.FPOW -> { sp--; st[sp - 1] = templePow(d(st[sp - 1]), d(st[sp])).toRawBits() }
                    Op.FNEG -> st[sp - 1] = st[sp - 1] xor Long.MIN_VALUE
                    Op.FEQ -> { sp--; st[sp - 1] = if (d(st[sp - 1]) == d(st[sp])) 1L else 0L }
                    Op.FNE -> { sp--; st[sp - 1] = if (d(st[sp - 1]) != d(st[sp])) 1L else 0L }
                    Op.FLT -> { sp--; st[sp - 1] = if (d(st[sp - 1]) < d(st[sp])) 1L else 0L }
                    Op.FLE -> { sp--; st[sp - 1] = if (d(st[sp - 1]) <= d(st[sp])) 1L else 0L }
                    Op.FGT -> { sp--; st[sp - 1] = if (d(st[sp - 1]) > d(st[sp])) 1L else 0L }
                    Op.FGE -> { sp--; st[sp - 1] = if (d(st[sp - 1]) >= d(st[sp])) 1L else 0L }
                    Op.I2F -> st[sp - 1] = st[sp - 1].toDouble().toRawBits()
                    Op.U2F -> st[sp - 1] = u2f(st[sp - 1]).toRawBits()
                    Op.F2I -> st[sp - 1] = f2i(d(st[sp - 1]))
                    Op.SX1 -> st[sp - 1] = st[sp - 1].toByte().toLong()
                    Op.SX2 -> st[sp - 1] = st[sp - 1].toShort().toLong()
                    Op.SX4 -> st[sp - 1] = st[sp - 1].toInt().toLong()
                    Op.ZX1 -> st[sp - 1] = st[sp - 1] and 0xFF
                    Op.ZX2 -> st[sp - 1] = st[sp - 1] and 0xFFFF
                    Op.ZX4 -> st[sp - 1] = st[sp - 1] and 0xFFFFFFFFL
                    Op.ADDI -> st[sp - 1] += code[pc++]
                    Op.MULI -> st[sp - 1] *= code[pc++]

                    // ---- quickened superinstructions (see Quicken.kt); pc is just past the first opcode
                    Quick.FLD8 -> { st[sp++] = m.ld8c(m.ld8(fp + code[pc]) + code[pc + 2]); pc += 4 }
                    Quick.FLD4S -> { st[sp++] = m.ld4(m.check(m.ld8(fp + code[pc]) + code[pc + 2], 4)).toInt().toLong(); pc += 4 }
                    Quick.FLD4U -> { st[sp++] = m.ld4(m.check(m.ld8(fp + code[pc]) + code[pc + 2], 4)); pc += 4 }
                    Quick.FLD2S -> { st[sp++] = m.ld2(m.check(m.ld8(fp + code[pc]) + code[pc + 2], 2)).toShort().toLong(); pc += 4 }
                    Quick.FLD2U -> { st[sp++] = m.ld2(m.check(m.ld8(fp + code[pc]) + code[pc + 2], 2)); pc += 4 }
                    Quick.FLD1S -> { st[sp++] = m.ld1(m.check(m.ld8(fp + code[pc]) + code[pc + 2], 1)).toByte().toLong(); pc += 4 }
                    Quick.FLD1U -> { st[sp++] = m.ld1(m.check(m.ld8(fp + code[pc]) + code[pc + 2], 1)); pc += 4 }
                    Quick.ALD8 -> { st[sp - 1] = m.ld8c(st[sp - 1] + code[pc]); pc += 2 }
                    Quick.ALD4S -> { st[sp - 1] = m.ld4(m.check(st[sp - 1] + code[pc], 4)).toInt().toLong(); pc += 2 }
                    Quick.ALD4U -> { st[sp - 1] = m.ld4(m.check(st[sp - 1] + code[pc], 4)); pc += 2 }
                    Quick.ALD2S -> { st[sp - 1] = m.ld2(m.check(st[sp - 1] + code[pc], 2)).toShort().toLong(); pc += 2 }
                    Quick.ALD2U -> { st[sp - 1] = m.ld2(m.check(st[sp - 1] + code[pc], 2)); pc += 2 }
                    Quick.ALD1S -> { st[sp - 1] = m.ld1(m.check(st[sp - 1] + code[pc], 1)).toByte().toLong(); pc += 2 }
                    Quick.ALD1U -> { st[sp - 1] = m.ld1(m.check(st[sp - 1] + code[pc], 1)); pc += 2 }
                    Quick.XLD8 -> { sp--; st[sp - 1] = m.ld8c(st[sp - 1] + st[sp]); pc += 1 }
                    Quick.XLD4S -> { sp--; st[sp - 1] = m.ld4(m.check(st[sp - 1] + st[sp], 4)).toInt().toLong(); pc += 1 }
                    Quick.XLD4U -> { sp--; st[sp - 1] = m.ld4(m.check(st[sp - 1] + st[sp], 4)); pc += 1 }
                    Quick.XLD1U -> { sp--; st[sp - 1] = m.ld1(m.check(st[sp - 1] + st[sp], 1)); pc += 1 }
                    Quick.LLD8_ADDI -> { st[sp++] = m.ld8(fp + code[pc]) + code[pc + 2]; pc += 3 }
                    Quick.LLD8_LLD8 -> { st[sp++] = m.ld8(fp + code[pc]); st[sp++] = m.ld8(fp + code[pc + 2]); pc += 3 }
                    Quick.LLD8_MULI -> { st[sp++] = m.ld8(fp + code[pc]) * code[pc + 2]; pc += 3 }
                    Quick.LLD8_LD8 -> { st[sp++] = m.ld8c(m.ld8(fp + code[pc])); pc += 2 }
                    Quick.LLD8_PUSHI -> { st[sp++] = m.ld8(fp + code[pc]); st[sp++] = code[pc + 2].toLong(); pc += 3 }
                    Quick.MULI_ADD -> { sp--; st[sp - 1] += st[sp] * code[pc]; pc += 2 }
                    Quick.LADDR_ADDI -> { st[sp++] = (fp + code[pc]).toLong() + code[pc + 2]; pc += 3 }
                    Quick.ADDI_ADDI -> { st[sp - 1] += code[pc].toLong() + code[pc + 2]; pc += 3 }
                    Quick.PUSHI_AND -> { st[sp - 1] = st[sp - 1] and code[pc].toLong(); pc += 2 }
                    Quick.PUSHI_SUB -> { st[sp - 1] -= code[pc]; pc += 2 }
                    Quick.PUSHI_SHL -> { st[sp - 1] = st[sp - 1] shl code[pc]; pc += 2 }
                    Quick.PUSHI_SHRS -> { st[sp - 1] = st[sp - 1] shr code[pc]; pc += 2 }
                    Quick.PUSHI_EQ -> { st[sp - 1] = if (st[sp - 1] == code[pc].toLong()) 1L else 0L; pc += 2 }
                    Quick.PUSHI_NE -> { st[sp - 1] = if (st[sp - 1] != code[pc].toLong()) 1L else 0L; pc += 2 }
                    Quick.PUSHI_JLTS -> { if (st[--sp] >= code[pc]) pc = code[pc + 2] else pc += 3 }
                    Quick.LNOT_TOBOOL -> { st[sp - 1] = if (st[sp - 1] == 0L) 1L else 0L; pc += 1 }
                    Quick.ST8_LLD8 -> { val v = st[--sp]; m.st8c(st[--sp], v); st[sp++] = m.ld8(fp + code[pc + 1]); pc += 2 }
                    Quick.LST8_LLD8 -> { m.st8(fp + code[pc], st[--sp]); st[sp++] = m.ld8(fp + code[pc + 2]); pc += 3 }
                    Quick.FMUL_FADD -> { sp -= 2; st[sp - 1] = (d(st[sp - 1]) + d(st[sp]) * d(st[sp + 1])).toRawBits(); pc += 1 }
                    Quick.TOBOOL_JZ, Quick.TOBOOL_JNZ, Quick.LNOT_JZ, Quick.LNOT_JNZ -> {
                        val o = code[opPc]
                        val tg = code[pc + 1]
                        val v = st[--sp] != 0L
                        if (v == (o == Quick.TOBOOL_JNZ || o == Quick.LNOT_JZ)) {
                            if (tg <= opPc && (--budget <= 0 || interrupt)) { pc = tg; t.pc = pc; t.sp = sp; t.fp = fp; instructionsExecuted += count; ticksExecuted += budget0 - budget; return R_SLICE }
                            pc = tg
                        } else pc += 2
                    }
                    Op.JMP -> {
                        val tg = code[pc]
                        if (tg <= opPc) {
                            if (profile != null) sample(opPc)
                            if (--budget <= 0 || interrupt) { pc = tg; t.pc = pc; t.sp = sp; t.fp = fp; instructionsExecuted += count; ticksExecuted += budget0 - budget; return R_SLICE }
                        }
                        pc = tg
                    }
                    Op.JZ -> {
                        val tg = code[pc++]
                        if (st[--sp] == 0L) {
                            if (tg <= opPc && (--budget <= 0 || interrupt)) { pc = tg; t.pc = pc; t.sp = sp; t.fp = fp; instructionsExecuted += count; ticksExecuted += budget0 - budget; return R_SLICE }
                            pc = tg
                        }
                    }
                    Op.JNZ -> {
                        val tg = code[pc++]
                        if (st[--sp] != 0L) {
                            if (tg <= opPc && (--budget <= 0 || interrupt)) { pc = tg; t.pc = pc; t.sp = sp; t.fp = fp; instructionsExecuted += count; ticksExecuted += budget0 - budget; return R_SLICE }
                            pc = tg
                        }
                    }
                    Op.JLTS -> { val tg = code[pc++]; sp -= 2; if (st[sp] >= st[sp + 1]) pc = tg }
                    Op.JLES -> { val tg = code[pc++]; sp -= 2; if (st[sp] > st[sp + 1]) pc = tg }
                    Op.JGTS -> { val tg = code[pc++]; sp -= 2; if (st[sp] <= st[sp + 1]) pc = tg }
                    Op.JGES -> { val tg = code[pc++]; sp -= 2; if (st[sp] < st[sp + 1]) pc = tg }
                    Op.JEQ -> { val tg = code[pc++]; sp -= 2; if (st[sp] != st[sp + 1]) pc = tg }
                    Op.JNE -> { val tg = code[pc++]; sp -= 2; if (st[sp] == st[sp + 1]) pc = tg }
                    Op.SWITCH -> {
                        val tb = p.switchTables[code[pc]]
                        val i = st[--sp] - tb.lo
                        pc = if (i >= 0 && i < tb.targets.size) tb.targets[i.toInt()] else tb.dflt
                    }

                    Op.CALL -> {
                        val fi = code[pc]; val n = code[pc + 1]; pc += 2
                        if (profile != null) sample(opPc)
                        t.sp = sp; t.fp = fp
                        enter(t, fi, n, pc)
                        sp = t.sp; fp = t.fp; pc = t.pc
                        if (--budget <= 0 || interrupt) { t.pc = pc; instructionsExecuted += count; ticksExecuted += budget0 - budget; return R_SLICE }
                    }
                    Op.CALLP -> {
                        val n = code[pc++]
                        val f = st[--sp]
                        if ((f and -0x100000000L) == Program.FPTR_NATIVE) {
                            val nf = nat[(f and 0xFFFFFFFFL).toInt()]
                            t.sp = sp; t.fp = fp; t.pc = opPc
                            val r = nf.call(t, sp - n, n)
                            code=prog.code.data;k=prog.konstArr
                            t.blocked = false
                            sp -= n
                            st[sp++] = r
                        } else {
                            if ((f and -0x100000000L) != Program.FPTR_TAG) throw VmFault(BAD_CALL, "call of invalid function pointer 0x${java.lang.Long.toHexString(f)}")
                            t.sp = sp; t.fp = fp
                            enter(t, (f and 0xFFFFFFFFL).toInt(), n, pc)
                            sp = t.sp; fp = t.fp; pc = t.pc
                            if (--budget <= 0 || interrupt) { t.pc = pc; instructionsExecuted += count; ticksExecuted += budget0 - budget; return R_SLICE }
                        }
                    }
                    Op.CALLN -> {
                        val ni = code[pc]; val n = code[pc + 1]; pc += 2
                        t.sp = sp; t.fp = fp; t.pc = opPc; t.faultPc = opPc
                        t.blocked = false
                        val r = nat[ni].call(t, sp - n, n)
                        // Runtime source loading can grow/reallocate these buffers.
                        code=prog.code.data;k=prog.konstArr
                        if (t.blocked) {
                            t.pc = opPc; t.sp = sp; t.fp = fp
                            instructionsExecuted += count; ticksExecuted += budget0 - budget
                            return R_BLOCKED
                        }
                        // the wake-up token belongs to this (re-executed) call: a later Sleep/SleepUntil/
                        // Refresh must wait again (Play's note gaps were skipped: SleepUntil left it set)
                        t.resumed = false
                        sp -= n
                        st[sp++] = r
                        if (t.yieldReq) {
                            t.yieldReq = false
                            t.yielded = true
                            t.pc = pc; t.sp = sp; t.fp = fp
                            instructionsExecuted += count; ticksExecuted += budget0 - budget
                            return R_SLICE
                        }
                    }
                    Op.RET -> {
                        val v = st[--sp]
                        val d = t.depth - 1
                        if (d < 0) throw VmKill("internal error: return with no active call")
                        t.depth = d
                        while (t.hCount > t.handlerBase && t.hDepth[t.hCount - 1] > d) t.hCount--
                        val rp = t.fRet[d]
                        fp = t.fFp[d]
                        t.msp = t.fMsp[d]
                        if (d <= stopDepth || rp < 0) {
                            t.result = v; t.sp = sp; t.fp = fp; t.pc = rp
                            instructionsExecuted += count; ticksExecuted += budget0 - budget
                            return R_DONE
                        }
                        pc = rp
                        st[sp++] = v
                    }
                    Op.TRY -> {
                        val h = t.hCount
                        if (h >= Task.MAX_HANDLERS) throw VmFault(STK_OVER, "too many nested try blocks")
                        t.hPc[h] = code[pc++]; t.hSp[h] = sp; t.hFp[h] = fp; t.hMsp[h] = t.msp; t.hDepth[h] = t.depth
                        t.hCount = h + 1
                    }
                    Op.UNTRY -> if (t.hCount > t.handlerBase) t.hCount--
                    Op.THROW -> { t.faultPc = opPc; lastFault = null; throw VmFault(st[--sp], "") }
                    Op.ENDCATCH -> {
                        if (t.fsAddr != 0 && m.ld1(t.fsAddr + catchExceptOff) == 0L) {
                            val ch = m.ld8(t.fsAddr + exceptChOff)
                            throw VmFault(ch, lastFault ?: "")
                        }
                    }
                    Op.MEMCPY -> {
                        val n = code[pc++]
                        val src = st[--sp]; val dst = st[--sp]
                        m.copy(m.check(dst, n), m.check(src, n), n)
                    }
                    Op.MEMZERO -> { val n = code[pc++]; val a = st[--sp]; m.fill(m.check(a, n), 0, n) }
                    Op.INC -> {
                        val kind = code[pc]; val delta = code[pc + 1]; val post = code[pc + 2]; pc += 3
                        st[sp - 1] = incAt(st[sp - 1], kind, delta, post != 0)
                    }
                    Op.LINC8 -> {
                        val a = fp + code[pc]; val delta = code[pc + 1]; val post = code[pc + 2]; pc += 3
                        val old = m.ld8(a)
                        val nv = old + delta
                        m.st8(a, nv)
                        st[sp++] = if (post != 0) old else nv
                    }
                    Op.HALT -> { t.pc = opPc; t.sp = sp; t.fp = fp; instructionsExecuted += count; return R_DONE }
                    else -> throw IllegalStateException("bad opcode ${code[opPc]} at $opPc")
                }
            }
        } catch (f: VmFault) {
            t.pc = opPc; t.sp = sp; t.fp = fp; t.faultPc = opPc
            instructionsExecuted += count; ticksExecuted += budget0 - budget
            throw f
        } catch (u: VmUncaught) {
            // an exception that escaped a callback a native made: its ticks still count (virtual time)
            instructionsExecuted += count; ticksExecuted += budget0 - budget
            throw u
        } catch (e: ArrayIndexOutOfBoundsException) {
            // operand stack overflow from runaway recursion of expressions
            t.pc = opPc; t.sp = 0; t.fp = fp; t.faultPc = opPc
            throw VmFault(STK_OVER, "operand stack overflow")
        }
    }

    private fun incAt(av: Long, kind: Int, delta: Int, post: Boolean): Long {
        val m = mem
        when (kind) {
            Op.KF64 -> {
                val a = m.check(av, 8); val old = d(m.ld8(a)); val nv = old + delta
                m.st8(a, nv.toRawBits()); return (if (post) old else nv).toRawBits()
            }
            Op.K8 -> { val a = m.check(av, 8); val old = m.ld8(a); m.st8(a, old + delta); return if (post) old else old + delta }
            Op.K4S, Op.K4U -> {
                val a = m.check(av, 4); val raw = m.ld4(a)
                val old = if (kind == Op.K4S) raw.toInt().toLong() else raw
                m.st4(a, old + delta)
                val nv = if (kind == Op.K4S) (old + delta).toInt().toLong() else (old + delta) and 0xFFFFFFFFL
                return if (post) old else nv
            }
            Op.K2S, Op.K2U -> {
                val a = m.check(av, 2); val raw = m.ld2(a)
                val old = if (kind == Op.K2S) raw.toShort().toLong() else raw
                m.st2(a, old + delta)
                val nv = if (kind == Op.K2S) (old + delta).toShort().toLong() else (old + delta) and 0xFFFF
                return if (post) old else nv
            }
            else -> {
                val a = m.check(av, 1); val raw = m.ld1(a)
                val old = if (kind == Op.K1S) raw.toByte().toLong() else raw
                m.st1(a, old + delta)
                val nv = if (kind == Op.K1S) (old + delta).toByte().toLong() else (old + delta) and 0xFF
                return if (post) old else nv
            }
        }
    }
}

@Suppress("NOTHING_TO_INLINE")
inline fun d(v: Long): Double = java.lang.Double.longBitsToDouble(v)

fun u2f(v: Long): Double = if (v >= 0) v.toDouble() else ((v ushr 1) or (v and 1)).toDouble() * 2.0

/** x86 CVTTSD2SI semantics: truncate; NaN/out-of-range -> 0x8000000000000000. */
/**
 * HolyC's power (the ` operator and Pow), as Kernel/KMathA.HC SYS_POW computes it on TempleOS: an exponent of +0.0
 * gives 1, a base of +0.0 gives 0 (also for negative exponents), otherwise |base|^exp, negated when the base is
 * negative and the exponent truncated to an integer (FISTTP) is odd: (-320)`0.5 is 17.888..., not NaN. The x87
 * computes |base|^exp as 2^(exp*log2|base|) rounding toward zero; that last-bit rounding is not reproduced
 * (fdlibm pow here). Verified against the original: shared/test-vectors/dynexpr/cartesian-vm-results.json.
 */
fun templePow(x: Double, y: Double): Double {
    if (y.toRawBits() == 0L) return 1.0
    val xb = x.toRawBits()
    if (xb == 0L) return 0.0
    val r = StrictMath.pow(Math.abs(x), y)
    return if (xb < 0 && (f2i(y) and 1L) != 0L) -r else r
}

fun f2i(x: Double): Long =
    if (x.isNaN() || x >= 9.223372036854775807E18 || x < -9.223372036854775808E18) Long.MIN_VALUE else x.toLong()

fun ipow(b0: Long, e0: Long): Long {
    if (e0 < 0) return if (b0 == 1L) 1 else if (b0 == -1L) (if (e0 and 1L == 0L) 1 else -1) else 0
    var r = 1L; var b = b0; var e = e0
    while (e != 0L) {
        if (e and 1L != 0L) r *= b
        b *= b; e = e ushr 1
    }
    return r
}

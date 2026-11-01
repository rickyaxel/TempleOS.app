package io.github.templeosmobile.core.purenative

import io.github.templeosmobile.core.holyc.*
import java.util.concurrent.locks.LockSupport

/** Unwinds a task thread whose task the kernel has discarded (never caught by HolyC try/catch). */
class TaskKilled : RuntimeException(null, null, false, false)

/**
 * Executes a kernel's HolyC as translated, compiled Kotlin (Pure Kotlin mode): the [ExecEngine]
 * behind [Vm.engine].
 *
 * TempleOS tasks are cooperative: a task runs until it sleeps, waits, yields or uses up its slice.
 * Translated code has no interpreter loop to return from, so each task runs on its own thread, and
 * exactly one thread runs at a time: [run] hands the CPU to the task's thread and waits until the
 * task gives it back (slice over, blocked in a native, finished, died). The kernel's scheduler is
 * unchanged and sees the same results as from the interpreter. Slices end at the same points (a
 * budget tick at every backward branch and every call of a HolyC function, and in the natives that
 * block or yield), so with the same input the native program is scheduled as the interpreted one.
 *
 * Callbacks the kernel or a native makes ([callFunction]: draw_it, ODEs, controls, QSort
 * comparators) run synchronously on the calling thread, like the VM's nested runs.
 */
class NativeRuntime(@JvmField val vm: Vm) : ExecEngine {
    @JvmField val mem: Arena = vm.mem
    private val natives = vm.natives.list

    /** Generated modules; functions below [split] belong to [prelude]. */
    lateinit var prelude: NativeModule
    var program: NativeModule? = null
    var split = Int.MAX_VALUE

    private fun module(index: Int): NativeModule {
        if (index < split) {
            if (prelude.defines(index)) return prelude
            program?.let { if (it.defines(index)) return it }
            return prelude
        }
        return program ?: prelude
    }

    fun nameOf(index: Int): String = module(index).nameOf(index) ?: "function #$index"

    /** Runs generated function [index] on [t] with word arguments t.st[base until base+n]. */
    fun dispatch(t: Task, index: Int, base: Int, n: Int): Long {
        val m = module(index)
        if (!m.defines(index)) throw VmFault(Vm.BAD_CALL, "call of undefined function '${nameOf(index)}'")
        return m.dispatch(t, index, base, n)
    }

    // ------------------------------------------------------------ calls from generated code

    /** VM CALLN: a native; a blocking one suspends the task and runs again when it is woken. */
    fun callNative(t: Task, index: Int, base: Int, n: Int): Long {
        val nf = natives[index]
        while (true) {
            t.blocked = false
            val r = nf.call(t, base, n)
            if (t.blocked) {
                // in a callback the VM's loop takes the slice (yield to the kernel, guard) and runs the native again
                if (t.nestLevel > 0) nestedSlice(t) else suspend(t, Vm.R_BLOCKED)
                continue
            }
            // the wake-up token belongs to this call (see Vm CALLN)
            t.resumed = false
            if (t.yieldReq) {
                t.yieldReq = false
                t.yielded = true
                sliceOver(t)
            }
            return r
        }
    }

    /** VM CALLP: through a function pointer; a native runs without blocking, a HolyC function costs a tick. */
    fun callPointer(t: Task, fp: Long, base: Int, n: Int): Long {
        if ((fp and -0x100000000L) == Program.FPTR_NATIVE) {
            val nf = natives[(fp and 0xFFFFFFFFL).toInt()]
            val r = nf.call(t, base, n)
            t.blocked = false
            return r
        }
        if ((fp and -0x100000000L) != Program.FPTR_TAG) throw VmFault(Vm.BAD_CALL, "call of invalid function pointer 0x${java.lang.Long.toHexString(fp)}")
        if (--t.budget <= 0) sliceEnd(t)
        return dispatch(t, (fp and 0xFFFFFFFFL).toInt(), base, n)
    }

    /** The budget ran out at a tick. */
    fun sliceEnd(t: Task) { sliceOver(t) }

    private fun sliceOver(t: Task) {
        if (t.nestLevel > 0) { nestedSlice(t); return }
        suspend(t, Vm.R_SLICE)
    }

    /** Between slices of a nested callback (Vm.callFunction's loop). */
    private fun nestedSlice(t: Task) {
        vm.ticksExecuted += CALLBACK_BUDGET - maxOf(t.budget, 0)
        t.budget = CALLBACK_BUDGET
        if (vm.interrupt) throw VmKill("stopped")
        if (vm.callbackBreak?.invoke(t) == true) throw VmFault(Vm.BREAK, "")
        if (++t.nestGuard > 500) throw VmKill("callback ran too long (instruction budget exceeded)")
        t.blocked = false
        vm.callbackYield?.invoke(t)
    }

    // ------------------------------------------------------------ exceptions

    fun caught(t: Task, e: RuntimeException) {
        val ch: Long
        val msg: String?
        when (e) {
            is VmFault -> { ch = e.ch; msg = e.message }
            is VmUncaught -> { ch = e.ch; msg = e.message }
            // the VM turns an operand stack overflow into StkOver
            is ArrayIndexOutOfBoundsException -> { ch = Vm.STK_OVER; msg = "operand stack overflow" }
            else -> throw e
        }
        if (t.fsAddr != 0 && vm.exceptChOff >= 0) {
            mem.st8(t.fsAddr + vm.exceptChOff, ch)
            mem.st1(t.fsAddr + vm.catchExceptOff, 0)
        }
        vm.lastFault = msg
    }

    fun endCatch(t: Task) {
        if (t.fsAddr != 0 && mem.ld1(t.fsAddr + vm.catchExceptOff) == 0L) {
            val ch = mem.ld8(t.fsAddr + vm.exceptChOff)
            throw VmFault(ch, vm.lastFault ?: "")
        }
    }

    private fun unhandled(ch: Long, where: String, msg: String?): String =
        "Unhandled exception '${vm.chStr(ch)}' in $where" + (if (msg.isNullOrEmpty()) "" else ": $msg")

    // ------------------------------------------------------------ task threads

    /** A task's thread and the handoff state shared with the thread that runs it. */
    private inner class TaskThread(val t: Task, val entry: Int, val args: LongArray) : Runnable {
        @Volatile var turn = KERNEL
        @Volatile var waiter: Thread? = null
        @Volatile var code = 0
        @Volatile var exited = false
        @Volatile var killed = false
        var failure: Throwable? = null
        /** The budget [run] gave the current slice (ticks consumed = this - what is left). */
        var sliceBudget = 0
        /** The last slice ended while the scheduling thread was still waiting awake for it. */
        var shortSlices = true
        val thread = Thread(null, this, "HolyC-native:${t.name}", STACK_BYTES).also { it.isDaemon = true }

        override fun run() {
            live.incrementAndGet()
            try { body() } finally { live.decrementAndGet() }
        }

        private fun body() {
            awaitTurn()
            var c = Vm.R_DONE
            try {
                if (killed) throw TaskKilled()
                t.depth = 0; t.sp = 0; t.hCount = 0; t.handlerBase = 0
                t.msp = t.mspBase; t.fp = t.mspBase
                for ((i, a) in args.withIndex()) t.st[i] = a
                t.sp = args.size
                t.result = dispatch(t, entry, 0, args.size)
                t.depth = 0
            } catch (k: TaskKilled) {
                exited = true
                waiter?.let { LockSupport.unpark(it) }
                return
            } catch (f: VmFault) {
                t.deathMessage = unhandled(f.ch, f.where ?: "${nameOf(entry)} (native)", f.message)
                t.deathCode = f.ch
                c = Vm.R_DEAD
            } catch (u: VmUncaught) {
                t.deathMessage = u.message
                t.deathCode = u.ch
                c = Vm.R_DEAD
            } catch (e: Throwable) {
                failure = e
            }
            exited = true
            t.engineData = null
            handBack(c)
        }

        /** Gives the CPU back to the thread waiting in [run]. */
        fun handBack(c: Int) {
            code = c
            val w = waiter
            turn = KERNEL
            if (w != null) LockSupport.unpark(w)
        }

        fun awaitTurn() {
            var spins = 0
            while (turn != TASK) {
                if (spins < SPINS) spins++ else LockSupport.park(this)
            }
        }
    }

    private val live = java.util.concurrent.atomic.AtomicInteger()

    private fun threadOf(t: Task): TaskThread? = t.engineData as? TaskThread

    /** Suspends the calling task thread until the scheduler resumes it. */
    private fun suspend(t: Task, code: Int) {
        val th = threadOf(t) ?: throw IllegalStateException("task ${t.name} suspended outside its thread")
        vm.ticksExecuted += th.sliceBudget - maxOf(t.budget, 0)
        if (code == Vm.R_SLICE) {
            // the scheduler would run this task again at once: continue without a thread switch
            val next = vm.sliceContinuation?.invoke(t) ?: 0
            if (next > 0) { t.budget = next; th.sliceBudget = next; return }
        }
        th.handBack(code)
        th.awaitTurn()
        if (th.killed) throw TaskKilled()
        t.pendingFault?.let { ch -> t.pendingFault = null; throw VmFault(ch, "") }
    }

    private val gone = ArrayList<TaskThread>()

    override fun pushCall(t: Task, fnPtrOrIndex: Long, args: LongArray) {
        val idx = decode(fnPtrOrIndex)
        if (!module(idx).defines(idx)) throw VmFault(Vm.BAD_CALL, "call of undefined function '${nameOf(idx)}'")
        threadOf(t)?.let { if (!it.exited) error("task ${t.name} already has a running entry") }
        t.engineData = TaskThread(t, idx, args)
    }

    private fun decode(v: Long): Int {
        if ((v and -0x100000000L) == Program.FPTR_TAG) return (v and 0xFFFFFFFFL).toInt()
        if (v in 0 until vm.prog.funcs.size) return v.toInt()
        throw VmFault(Vm.BAD_CALL, "call of invalid function pointer 0x${java.lang.Long.toHexString(v)}")
    }

    override fun run(t: Task, budget: Int): Int {
        reap()
        val th = threadOf(t) ?: return Vm.R_DONE
        if (th.exited) return Vm.R_DONE
        t.budget = budget
        th.sliceBudget = budget
        th.waiter = Thread.currentThread()
        th.turn = TASK
        if (th.thread.state == Thread.State.NEW) th.thread.start() else LockSupport.unpark(th.thread)
        // most slices are short (a few steps, then Sleep/Refresh): wait for them awake, and park only
        // for long ones, so a short slice costs one thread wake instead of two. A task whose last slice
        // outlasted the wait is waited for asleep at once (no CPU burnt on long slices).
        val spinUntil = System.nanoTime() + (if (th.shortSlices) KERNEL_SPIN_NS else 0L)
        var parked = false
        while (th.turn != KERNEL) {
            if (System.nanoTime() < spinUntil) Thread.onSpinWait() else { parked = true; LockSupport.park(this) }
        }
        th.shortSlices = !parked
        th.failure?.let { th.failure = null; throw it }
        if (th.code == Vm.R_DONE || th.code == Vm.R_DEAD) {
            vm.ticksExecuted += budget - maxOf(t.budget, 0)
            t.engineData = null
        }
        return th.code
    }

    override fun callFunction(t: Task, fnPtr: Long, args: LongArray): Long {
        if ((fnPtr and -0x100000000L) == Program.FPTR_NATIVE) {
            val nf = natives[(fnPtr and 0xFFFFFFFFL).toInt()]
            val base = t.sp
            for (a in args) t.st[t.sp++] = a
            val r = nf.call(t, base, args.size)
            t.sp = base
            t.blocked = false
            return r
        }
        val idx = decode(fnPtr)
        val savedSp = t.sp; val savedMsp = t.msp; val savedDepth = t.depth
        val savedBudget = t.budget; val savedGuard = t.nestGuard; val savedH = t.hCount
        t.nestLevel++
        try {
            val base = t.sp
            for (a in args) t.st[t.sp++] = a
            t.budget = CALLBACK_BUDGET
            t.nestGuard = 0
            return try { dispatch(t, idx, base, args.size) } catch (f: VmFault) {
                throw VmUncaught(f.ch, unhandled(f.ch, f.where ?: "${nameOf(idx)} (native)", f.message))
            }
        } finally {
            vm.ticksExecuted += CALLBACK_BUDGET - maxOf(t.budget, 0)
            t.nestLevel--
            t.sp = savedSp; t.msp = savedMsp; t.depth = savedDepth
            t.budget = savedBudget; t.nestGuard = savedGuard; t.hCount = savedH
            t.blocked = false
        }
    }

    override fun inject(t: Task, ch: Long): Boolean {
        t.blocked = false; t.resumed = false
        val th = threadOf(t)
        if (th == null || th.exited || t.hCount <= 0) {
            t.deathMessage = unhandled(ch, if (th != null) "${nameOf(th.entry)} (native)" else t.name, "")
            t.deathCode = ch
            return false
        }
        t.pendingFault = ch
        return true
    }

    override fun taskGone(t: Task) {
        val th = threadOf(t) ?: return
        t.engineData = null
        if (!th.exited) synchronized(gone) { gone.add(th) }
    }

    /** Ends the threads of discarded tasks, one at a time, from the scheduling thread (no task runs meanwhile). */
    private fun reap() {
        val me = Thread.currentThread()
        val list = synchronized(gone) { if (gone.isEmpty()) return; gone.toList() }
        for (th in list) {
            // a task that ended itself (Exit, Kill(Fs)) is still on this thread's stack: reaped later
            if (th.thread === me) continue
            synchronized(gone) { gone.remove(th) }
            if (th.exited) continue
            if (th.thread.state == Thread.State.NEW) { th.exited = true; continue }
            th.killed = true
            th.waiter = me
            th.turn = TASK
            LockSupport.unpark(th.thread)
            val deadline = System.nanoTime() + 2_000_000_000L
            while (!th.exited && System.nanoTime() < deadline) LockSupport.parkNanos(this, 1_000_000)
        }
    }

    override fun shutdown() { reap() }

    /** Task threads that have started and not yet ended (leak checks). */
    val liveThreads: Int get() = live.get()

    companion object {
        const val KERNEL = 0
        const val TASK = 1
        const val CALLBACK_BUDGET = 200_000
        /** Spins before parking on a handoff (a few microseconds: most handoffs are answered sooner). */
        const val SPINS = 2000
        /** How long the scheduling thread waits awake for a task's slice before parking. */
        const val KERNEL_SPIN_NS = 50_000L
        /** HolyC recursion runs on the task thread's stack (MAX_DEPTH frames of generated code). */
        const val STACK_BYTES = 32L shl 20
    }
}

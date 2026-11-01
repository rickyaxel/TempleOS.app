import Foundation
import CTempleAtomics

// Port of purenative/NativeRuntime.kt.

/** Unwinds a task thread whose task the kernel has discarded (never caught by HolyC try/catch). */
public struct TaskKilled: Error {}

/**
 * Executes a kernel's HolyC as translated, compiled Swift (Pure Swift mode): the [ExecEngine]
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
public final class NativeRuntime: ExecEngine {
    public unowned let vm: Vm
    public let mem: Arena
    /** The host functions (registered before the engine is created; a stored copy avoids array traffic per call). */
    private let natives: [Native]

    /** Generated modules; functions below [split] belong to [prelude]. */
    public var prelude: NativeModule!
    public var program: NativeModule?
    public var split = Int.max

    public init(_ vm: Vm) { self.vm = vm; mem = vm.mem; natives = vm.natives.list }

    private func module(_ index: Int) -> NativeModule {
        if index < split {
            if prelude.defines(index) { return prelude }
            if let p = program, p.defines(index) { return p }
            return prelude
        }
        return program ?? prelude
    }

    public func nameOf(_ index: Int) -> String { module(index).nameOf(index) ?? "function #\(index)" }

    /** Runs generated function [index] on [t] with word arguments t.st[base ..< base+n]. */
    public func dispatch(_ t: HTask, _ index: Int, _ base: Int, _ n: Int) throws -> Int64 {
        let m = module(index)
        if !m.defines(index) { throw VmFault(Vm.BAD_CALL, "call of undefined function '\(nameOf(index))'") }
        return try m.dispatch(t, index, base, n)
    }

    // MARK: calls from generated code

    /** VM CALLN: a native; a blocking one suspends the task and runs again when it is woken. */
    public func callNative(_ t: HTask, _ index: Int, _ base: Int, _ n: Int) throws -> Int64 {
        let nf = natives[index]
        while true {
            t.blocked = false
            let r = try nf.call(t, base, n)
            if t.blocked {
                // in a callback the VM's loop takes the slice (yield to the kernel, guard) and runs the native again
                if t.nestLevel > 0 { try nestedSlice(t) } else { try suspend(t, Vm.R_BLOCKED) }
                continue
            }
            // the wake-up token belongs to this call (see Vm CALLN)
            t.resumed = false
            if t.yieldReq {
                t.yieldReq = false
                t.yielded = true
                try sliceOver(t)
            }
            return r
        }
    }

    private static let HI_MASK: Int64 = -0x1_0000_0000

    /** VM CALLP: through a function pointer; a native runs without blocking, a HolyC function costs a tick. */
    public func callPointer(_ t: HTask, _ fp: Int64, _ base: Int, _ n: Int) throws -> Int64 {
        if (fp & NativeRuntime.HI_MASK) == Program.FPTR_NATIVE {
            let ni = Int(Int32(truncatingIfNeeded: fp & 0xFFFF_FFFF))
            if ni < 0 || ni >= natives.count { throw VmIndexOutOfBounds() }
            let r = try natives[ni].call(t, base, n)
            t.blocked = false
            return r
        }
        if (fp & NativeRuntime.HI_MASK) != Program.FPTR_TAG { throw VmFault(Vm.BAD_CALL, "call of invalid function pointer 0x\(hex(fp))") }
        t.budget -= 1
        if t.budget <= 0 { try sliceEnd(t) }
        return try dispatch(t, Int(fp & 0xFFFF_FFFF), base, n)
    }

    /** The budget ran out at a tick. */
    public func sliceEnd(_ t: HTask) throws { try sliceOver(t) }

    private func sliceOver(_ t: HTask) throws {
        if t.nestLevel > 0 { try nestedSlice(t); return }
        try suspend(t, Vm.R_SLICE)
    }

    /** Between slices of a nested callback (Vm.callFunction's loop). */
    private func nestedSlice(_ t: HTask) throws {
        vm.ticksExecuted &+= Int64(NativeRuntime.CALLBACK_BUDGET - max(t.budget, 0))
        t.budget = NativeRuntime.CALLBACK_BUDGET
        if vm.interrupt { throw VmKill("stopped") }
        if vm.callbackBreak?(t) == true { throw VmFault(Vm.BREAK, "") }
        t.nestGuard += 1
        if t.nestGuard > 500 { throw VmKill("callback ran too long (instruction budget exceeded)") }
        t.blocked = false
        try vm.callbackYield?(t)
    }

    // MARK: exceptions

    public func caught(_ t: HTask, _ e: Error) throws {
        let ch: Int64
        let msg: String?
        if let f = e as? VmFault { ch = f.ch; msg = f.message }
        else if let u = e as? VmUncaught { ch = u.ch; msg = u.message }
        else if e is VmIndexOutOfBounds { ch = Vm.STK_OVER; msg = "operand stack overflow" }
        else { throw e }
        if t.fsAddr != 0 && vm.exceptChOff >= 0 {
            mem.st8(t.fsAddr + vm.exceptChOff, ch)
            mem.st1(t.fsAddr + vm.catchExceptOff, 0)
        }
        vm.lastFault = msg
    }

    public func endCatch(_ t: HTask) throws {
        if t.fsAddr != 0 && mem.ld1(t.fsAddr + vm.catchExceptOff) == 0 {
            let ch = mem.ld8(t.fsAddr + vm.exceptChOff)
            throw VmFault(ch, vm.lastFault ?? "")
        }
    }

    func unhandled(_ ch: Int64, _ whr: String, _ msg: String?) -> String {
        "Unhandled exception '\(vm.chStr(ch))' in \(whr)" + ((msg ?? "").isEmpty ? "" : ": \(msg!)")
    }

    // MARK: task threads

    static let KERNEL = 0
    static let TASK = 1
    public static let CALLBACK_BUDGET = 200_000
    /** HolyC recursion runs on the task thread's stack (MAX_DEPTH frames of generated code). */
    static let STACK_BYTES = 32 << 20
    /** Spin iterations before a handoff waiter sleeps (a few microseconds). */
    static let SPINS = 4000
    /** How long the scheduling thread waits awake for a task's slice before sleeping. */
    static let KERNEL_SPIN_NS: Int64 = 50_000

    private static let liveLock = NSLock()
    private static var liveCount = 0
    /** Task threads that have started and not yet ended, in all kernels (leak checks). */
    public static var liveThreads: Int { liveLock.lock(); defer { liveLock.unlock() }; return liveCount }

    /** A task's thread and the handoff state shared with the thread that runs it. */
    final class TaskThread {
        unowned let rt: NativeRuntime
        let t: HTask
        let entry: Int
        let args: [Int64]
        private var mutex = pthread_mutex_t()
        private var cond = pthread_cond_t()
        /** Whose turn it is (KERNEL / TASK); read spinning, without the lock. */
        private let turn = UnsafeMutablePointer<ct_atomic_long>.allocate(capacity: 1)
        /** Threads blocked in the condition variable (the giver only signals when there are some). */
        private let sleepers = UnsafeMutablePointer<ct_atomic_long>.allocate(capacity: 1)
        var code = 0
        var exited = false
        var killed = false
        var started = false
        var failure: Error?
        var sliceBudget = 0
        /** The last slice ended while the scheduling thread was still waiting awake for it. */
        var shortSlices = true
        var thread: Thread?

        init(_ rt: NativeRuntime, _ t: HTask, _ entry: Int, _ args: [Int64]) {
            self.rt = rt; self.t = t; self.entry = entry; self.args = args
            pthread_mutex_init(&mutex, nil)
            pthread_cond_init(&cond, nil)
            ct_init(turn, NativeRuntime.KERNEL)
            ct_init(sleepers, 0)
        }

        deinit {
            pthread_mutex_destroy(&mutex); pthread_cond_destroy(&cond)
            turn.deallocate(); sleepers.deallocate()
        }

        /** Hands the CPU to [to]: most handoffs are seen by a spinning waiter; a sleeping one is signalled. */
        func give(_ to: Int) {
            ct_store_sc(turn, to)
            if ct_load_sc(sleepers) > 0 {
                pthread_mutex_lock(&mutex)
                pthread_cond_broadcast(&cond)
                pthread_mutex_unlock(&mutex)
            }
        }

        /** Waits for [who]'s turn: spinning [SPINS] times, then up to [spinNs] more, then asleep. True when it slept. */
        @discardableResult
        func waitFor(_ who: Int, spinNs: Int64 = 0) -> Bool {
            // a few microseconds of spinning answers almost every handoff (one runs while the other waits)
            for _ in 0..<NativeRuntime.SPINS {
                if ct_load(turn) == who { return false }
                ct_pause()
            }
            if spinNs > 0 {
                let until = monoNanos() + spinNs
                while monoNanos() < until {
                    for _ in 0..<64 { if ct_load(turn) == who { return false }; ct_pause() }
                }
            }
            pthread_mutex_lock(&mutex)
            _ = ct_add_sc(sleepers, 1)
            while ct_load_sc(turn) != who { pthread_cond_wait(&cond, &mutex) }
            _ = ct_add_sc(sleepers, -1)
            pthread_mutex_unlock(&mutex)
            return true
        }

        func awaitExit(seconds: Double) {
            let deadline = Date().addingTimeInterval(seconds)
            pthread_mutex_lock(&mutex)
            while !exited && Date() < deadline {
                var ts = timespec(); clock_gettime(CLOCK_REALTIME, &ts)
                ts.tv_nsec += 1_000_000
                if ts.tv_nsec >= 1_000_000_000 { ts.tv_sec += 1; ts.tv_nsec -= 1_000_000_000 }
                pthread_cond_timedwait(&cond, &mutex, &ts)
            }
            pthread_mutex_unlock(&mutex)
        }

        func markExited() {
            pthread_mutex_lock(&mutex)
            exited = true
            pthread_cond_broadcast(&cond)
            pthread_mutex_unlock(&mutex)
        }

        func start() {
            started = true
            let th = Thread { [self] in
                NativeRuntime.liveLock.lock(); NativeRuntime.liveCount += 1; NativeRuntime.liveLock.unlock()
                self.body()
                NativeRuntime.liveLock.lock(); NativeRuntime.liveCount -= 1; NativeRuntime.liveLock.unlock()
            }
            th.stackSize = NativeRuntime.STACK_BYTES
            th.name = "HolyC-native:\(t.name)"
            thread = th
            th.start()
        }

        private func body() {
            waitFor(NativeRuntime.TASK)
            var c = Vm.R_DONE
            do {
                if killed { throw TaskKilled() }
                t.depth = 0; t.sp = 0; t.hCount = 0; t.handlerBase = 0
                t.msp = t.mspBase; t.fp = t.mspBase
                for (i, a) in args.enumerated() { t.st[i] = a }
                t.sp = args.count
                t.result = try rt.dispatch(t, entry, 0, args.count)
                t.depth = 0
            } catch is TaskKilled {
                markExited()
                return
            } catch let f as VmFault {
                t.deathMessage = rt.unhandled(f.ch, f.whereText ?? "\(rt.nameOf(entry)) (native)", f.message)
                t.deathCode = f.ch
                c = Vm.R_DEAD
            } catch let u as VmUncaught {
                t.deathMessage = u.message
                t.deathCode = u.ch
                c = Vm.R_DEAD
            } catch {
                failure = error
            }
            if t.engineData === self { t.engineData = nil }
            code = c
            markExited()
            give(NativeRuntime.KERNEL)
        }
    }

    private func threadOf(_ t: HTask) -> TaskThread? { t.engineData as? TaskThread }

    /** Suspends the calling task thread until the scheduler resumes it. */
    private func suspend(_ t: HTask, _ code: Int) throws {
        guard let th = threadOf(t) else { throw VmKill("task \(t.name) suspended outside its thread") }
        vm.ticksExecuted &+= Int64(th.sliceBudget - max(t.budget, 0))
        if code == Vm.R_SLICE {
            // the scheduler would run this task again at once: continue without a thread switch
            let next = vm.sliceContinuation?(t) ?? 0
            if next > 0 { t.budget = next; th.sliceBudget = next; return }
        }
        th.code = code
        th.give(NativeRuntime.KERNEL)
        th.waitFor(NativeRuntime.TASK)
        if th.killed { throw TaskKilled() }
        if let ch = t.pendingFault { t.pendingFault = nil; throw VmFault(ch, "") }
    }

    private let goneLock = NSLock()
    private var gone: [TaskThread] = []

    public func pushCall(_ t: HTask, _ fnPtrOrIndex: Int64, _ args: [Int64]) throws {
        let idx = try decode(fnPtrOrIndex)
        if !module(idx).defines(idx) { throw VmFault(Vm.BAD_CALL, "call of undefined function '\(nameOf(idx))'") }
        if let old = threadOf(t), !old.exited { throw VmKill("task \(t.name) already has a running entry") }
        t.engineData = TaskThread(self, t, idx, args)
    }

    private func decode(_ v: Int64) throws -> Int {
        if (v & NativeRuntime.HI_MASK) == Program.FPTR_TAG { return Int(v & 0xFFFF_FFFF) }
        if v >= 0 && v < Int64(vm.prog.funcs.count) { return Int(v) }
        throw VmFault(Vm.BAD_CALL, "call of invalid function pointer 0x\(hex(v))")
    }

    public func run(_ t: HTask, _ budget: Int) throws -> Int {
        reap()
        guard let th = threadOf(t), !th.exited else { return Vm.R_DONE }
        t.budget = budget
        th.sliceBudget = budget
        if !th.started { th.start() }
        th.give(NativeRuntime.TASK)
        // most slices are short (a few steps, then Sleep/Refresh): wait for them awake, and sleep only for
        // long ones, so a short slice costs one thread wake instead of two. A task whose last slice outlasted
        // the wait is waited for asleep sooner (no CPU burnt on long slices).
        th.shortSlices = !th.waitFor(NativeRuntime.KERNEL, spinNs: th.shortSlices ? NativeRuntime.KERNEL_SPIN_NS : 0)
        if let f = th.failure { th.failure = nil; throw f }
        if th.code == Vm.R_DONE || th.code == Vm.R_DEAD {
            vm.ticksExecuted &+= Int64(budget - max(t.budget, 0))
            if t.engineData === th { t.engineData = nil }
        }
        return th.code
    }

    public func callFunction(_ t: HTask, _ fnPtr: Int64, _ args: [Int64]) throws -> Int64 {
        if (fnPtr & NativeRuntime.HI_MASK) == Program.FPTR_NATIVE {
            let ni = Int(Int32(truncatingIfNeeded: fnPtr & 0xFFFF_FFFF))
            if ni < 0 || ni >= natives.count { throw VmIndexOutOfBounds() }
            let base = t.sp
            if base + args.count > HTask.STACK_WORDS { throw VmIndexOutOfBounds() }
            for a in args { t.st[t.sp] = a; t.sp += 1 }
            let r = try natives[ni].call(t, base, args.count)
            t.sp = base
            t.blocked = false
            return r
        }
        let idx = try decode(fnPtr)
        let savedSp = t.sp, savedMsp = t.msp, savedDepth = t.depth
        let savedBudget = t.budget, savedGuard = t.nestGuard, savedH = t.hCount
        t.nestLevel += 1
        defer {
            vm.ticksExecuted &+= Int64(NativeRuntime.CALLBACK_BUDGET - max(t.budget, 0))
            t.nestLevel -= 1
            t.sp = savedSp; t.msp = savedMsp; t.depth = savedDepth
            t.budget = savedBudget; t.nestGuard = savedGuard; t.hCount = savedH
            t.blocked = false
        }
        let base = t.sp
        if base + args.count > HTask.STACK_WORDS { throw VmIndexOutOfBounds() }
        for a in args { t.st[t.sp] = a; t.sp += 1 }
        t.budget = NativeRuntime.CALLBACK_BUDGET
        t.nestGuard = 0
        do {
            return try dispatch(t, idx, base, args.count)
        } catch let f as VmFault {
            throw VmUncaught(f.ch, unhandled(f.ch, f.whereText ?? "\(nameOf(idx)) (native)", f.message))
        }
    }

    public func inject(_ t: HTask, _ ch: Int64) -> Bool {
        t.blocked = false; t.resumed = false
        let th = threadOf(t)
        if th == nil || th!.exited || t.hCount <= 0 {
            t.deathMessage = unhandled(ch, th != nil ? "\(nameOf(th!.entry)) (native)" : t.name, "")
            t.deathCode = ch
            return false
        }
        t.pendingFault = ch
        return true
    }

    public func taskGone(_ t: HTask) {
        guard let th = threadOf(t) else { return }
        t.engineData = nil
        if !th.exited { goneLock.lock(); gone.append(th); goneLock.unlock() }
    }

    /** Ends the threads of discarded tasks, one at a time, from the scheduling thread (no task runs meanwhile). */
    private func reap() {
        goneLock.lock()
        if gone.isEmpty { goneLock.unlock(); return }
        let list = gone
        goneLock.unlock()
        let me = Thread.current
        for th in list {
            // a task that ended itself (Exit, Kill(Fs)) is still on this thread's stack: reaped later
            if th.thread === me { continue }
            goneLock.lock(); gone.removeAll { $0 === th }; goneLock.unlock()
            if th.exited { continue }
            if !th.started { th.exited = true; continue }
            th.killed = true
            th.give(NativeRuntime.TASK)
            th.awaitExit(seconds: 2)
        }
    }

    public func shutdown() { reap() }

    /**
     * Kernel.deinit: the runtime and its generated modules refer to each other (NativeModule.rt is a strong
     * reference, used on every call from generated code), and the runtime holds the arena. Without breaking that
     * cycle every closed native program kept its arena: on iOS each arena reserves its whole program-memory limit,
     * and the iPhone ran out of address space after about a hundred programs (docs/native-validation).
     */
    public func dispose() { reap(); prelude = nil; program = nil }
}

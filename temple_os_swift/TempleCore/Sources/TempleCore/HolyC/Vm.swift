import Foundation

// Port of holyc/Vm.kt (class Vm). `Task` is HTask (HTask.swift); VmUncaught,
// d(), u2f, f2i and ipow live in Basics.swift.

/**
 * Stand-in for the JVM's ArrayIndexOutOfBoundsException: the Kotlin interpreter
 * catches it around exec (operand stack overflow, bad function/native index)
 * and turns it into a 'StkOver' fault. Swift unsafe pointers do not check, so
 * the places that can overflow check explicitly and throw this.
 */
public struct VmIndexOutOfBounds: Error, CustomStringConvertible {
    public init() {}
    public var description: String { "index out of bounds" }
}

/**
 * Executes compiled HolyC without the bytecode interpreter (purenative NativeRuntime runs
 * ahead-of-time translated Swift). When [Vm.engine] is set, the VM's entry points delegate to it
 * and the interpreter loop refuses to run, so a kernel is either interpreted or native, never both.
 */
public protocol ExecEngine: AnyObject {
    func pushCall(_ t: HTask, _ fnPtrOrIndex: Int64, _ args: [Int64]) throws
    func run(_ t: HTask, _ budget: Int) throws -> Int
    func callFunction(_ t: HTask, _ fnPtr: Int64, _ args: [Int64]) throws -> Int64
    func inject(_ t: HTask, _ ch: Int64) -> Bool
    /** [t] ended or was killed; its execution context can be discarded. */
    func taskGone(_ t: HTask)
    /** The kernel ended: every task's execution context is discarded. */
    func shutdown()
    /**
     * The kernel is being destroyed: release everything (Swift reference counting does not collect cycles, and a
     * native engine and its generated modules refer to each other).
     */
    func dispose()
}

/**
 * HolyC's power (the ` operator and Pow) as Kernel/KMathA.HC SYS_POW computes it (Vm.kt templePow): +0.0 exponent
 * gives 1, +0.0 base gives 0, otherwise |base|^exp, negated when the base is negative and trunc(exp) is odd.
 */
@inlinable @inline(__always) public func templePow(_ x: Double, _ y: Double) -> Double {
    if y.bitPattern == 0 { return 1.0 }
    let xb = Int64(bitPattern: x.bitPattern)
    if xb == 0 { return 0.0 }
    let r = FdLibm.pow(Swift.abs(x), y)
    return (xb < 0 && (f2i(y) & 1) != 0) ? -r : r
}

/** Java Math.pow special cases (fdlibm) that differ from C pow. */
@inlinable @inline(__always) public func vmJavaPow(_ x: Double, _ y: Double) -> Double {
    // fdlibm, bit-identical to the Kotlin VM's StrictMath.pow on every platform (Java's special cases included)
    FdLibm.pow(x, y)
}

/**
 * The bytecode interpreter. One Vm instance owns one arena and one program; it is
 * driven by a single thread (the program's kernel thread).
 */
public final class Vm {
    public let mem: Arena
    public let natives = NativeTable()
    public private(set) var prog: Program!

    /** Kotlin `@Volatile var interrupt` (set by the UI thread; plain var in Swift). */
    public var interrupt = false

    /** Polled between slices of a nested callback; true raises 'Break' in it (set by the kernel). */
    public var callbackBreak: ((HTask) -> Bool)?

    /** Called between slices of a nested callback so the kernel can run frames and other tasks (V-17). */
    public var callbackYield: ((HTask) throws -> Void)?

    /** Offsets of CTask.except_ch / catch_except in the arena (set by the kernel). */
    public var exceptChOff = -1
    public var catchExceptOff = -1

    public var instructionsExecuted: Int64 = 0

    /**
     * Native engine only: at the end of a task's slice, the kernel's answer to "may this task simply go on?"
     * (Kernel.continueSlice): the next slice's budget, or 0 to hand the CPU back to the scheduler.
     */
    public var sliceContinuation: ((HTask) -> Int)?

    /** Native execution engine (Pure Swift mode); nil for the interpreter (Pure Terry mode). */
    public var engine: ExecEngine?

    /** Budget ticks consumed (backward branches and HolyC calls), counted by both engines. */
    public var ticksExecuted: Int64 = 0

    /** Optional sampling profiler: function name -> samples (debug builds/tests only). */
    public var profile: [String: Int]?
    private var profileTick = 0
    private func sample(_ pc: Int) {
        if profile == nil { return }
        profileTick += 1
        if profileTick & 63 != 0 { return }
        let n = prog.funcAt(pc)
        profile![n] = (profile![n] ?? 0) + 1
    }

    public static let R_SLICE = 0
    public static let R_BLOCKED = 1
    public static let R_DONE = 2
    public static let R_DEAD = 3
    public static let DIV_ZERO = chCode("DivZero")
    public static let STK_OVER = chCode("StkOver")
    public static let BAD_CALL = chCode("BadCall")
    public static let BREAK = chCode("Break")

    /** Kotlin `-0x100000000L`: the tag half of a function pointer. */
    private static let HI_MASK: Int64 = -0x1_0000_0000
    /**
     * Operand-stack headroom required at every call. The Kotlin VM detects
     * overflow on the exact push (ArrayIndexOutOfBounds); the Swift stack is an
     * unchecked pointer, so calls refuse to start within this many words of the end.
     */
    private static let ST_SLACK = 512

    public init(_ arenaInitial: Int = 1 << 20, _ arenaMax: Int = 32 << 20) {
        mem = Arena(arenaInitial, arenaMax)
        prog = Program(self)
    }

    // ------------------------------------------------------------ entry points

    /** Prepares [t] to call user function [fi] with [args]; the frame returns to the caller (-1). */
    public func pushCall(_ t: HTask, _ fnPtrOrIndex: Int64, _ args: [Int64]) throws {
        if let e = engine { return try e.pushCall(t, fnPtrOrIndex, args) }
        if t.sp + args.count > HTask.STACK_WORDS { throw VmIndexOutOfBounds() }
        for a in args { t.st[t.sp] = a; t.sp += 1 }
        let fi = try decodeUserFn(fnPtrOrIndex)
        try enter(t, fi, args.count, -1)
    }

    private func decodeUserFn(_ v: Int64) throws -> Int {
        if (v & Vm.HI_MASK) == Program.FPTR_TAG { return Int(Int32(truncatingIfNeeded: v & 0xFFFF_FFFF)) }
        if v >= 0 && v < Int64(prog.funcs.count) { return Int(v) }
        throw VmFault(Vm.BAD_CALL, "call of invalid function pointer 0x\(hex(v))")
    }

    /**
     * Calls a function pointer synchronously on task [t] (used for callbacks such
     * as draw_it and QSort comparators). Blocking natives return immediately.
     */
    @discardableResult
    public func callFunction(_ t: HTask, _ fnPtr: Int64, _ args: Int64...) throws -> Int64 {
        return try callFunction(t, fnPtr, args)
    }

    @discardableResult
    public func callFunction(_ t: HTask, _ fnPtr: Int64, _ args: [Int64]) throws -> Int64 {
        if let e = engine { return try e.callFunction(t, fnPtr, args) }
        if (fnPtr & Vm.HI_MASK) == Program.FPTR_NATIVE {
            let ni = Int(Int32(truncatingIfNeeded: fnPtr & 0xFFFF_FFFF))
            if ni < 0 || ni >= natives.list.count { throw VmIndexOutOfBounds() }
            let n = natives.list[ni]
            let base = t.sp
            if base + args.count > HTask.STACK_WORDS { throw VmIndexOutOfBounds() }
            for a in args { t.st[t.sp] = a; t.sp += 1 }
            let r = try n.call(t, base, args.count)
            t.sp = base
            t.blocked = false
            return r
        }
        let savedSp = t.sp, savedPc = t.pc, savedFp = t.fp, savedMsp = t.msp
        let savedDepth = t.depth, savedHBase = t.handlerBase
        t.handlerBase = t.hCount
        t.nestLevel += 1
        defer {
            t.nestLevel -= 1
            t.sp = savedSp; t.pc = savedPc; t.fp = savedFp; t.msp = savedMsp
            t.depth = savedDepth; t.hCount = t.handlerBase; t.handlerBase = savedHBase
            t.blocked = false
        }
        if t.sp + args.count > HTask.STACK_WORDS { throw VmIndexOutOfBounds() }
        for a in args { t.st[t.sp] = a; t.sp += 1 }
        try enter(t, try decodeUserFn(fnPtr), args.count, -1)
        var guardN = 0
        while true {
            let r = try run(t, 200_000, savedDepth)
            if r == Vm.R_DONE { return t.result }
            if r == Vm.R_DEAD { throw VmUncaught(0, t.deathMessage ?? "callback failed") }
            if interrupt { throw VmKill("stopped") }
            if callbackBreak?(t) == true {
                // into the callback's own handlers, else VmUncaught to the native's caller
                t.faultPc = t.pc
                _ = try raise(t, Vm.BREAK, "", savedDepth)
            }
            guardN += 1
            if guardN > 500 { throw VmKill("callback ran too long (instruction budget exceeded)") }
            t.blocked = false
            try callbackYield?(t)
        }
    }

    @inline(__always) private func offsOf(_ a: [Int]?) throws -> [Int] {
        guard let a = a else { throw VmKill("internal error: missing parameter offsets") }
        return a
    }
    @inline(__always) private func offsOf(_ a: [Int]) -> [Int] { a }

    private func enter(_ t: HTask, _ fi: Int, _ n: Int, _ retPc: Int) throws {
        let p: Program = prog
        if fi < 0 || fi >= p.fnEntry.count { throw VmIndexOutOfBounds() }
        if t.sp > HTask.STACK_WORDS - Vm.ST_SLACK { throw VmIndexOutOfBounds() }
        if p.fnEntry[fi] < 0 { throw VmFault(Vm.BAD_CALL, "call of undefined function '\(p.funcs[fi].name)'") }
        if t.depth >= HTask.MAX_DEPTH { throw VmFault(Vm.STK_OVER, "stack overflow (call depth)") }
        let d = t.depth
        t.fRet[d] = retPc; t.fFp[d] = t.fp; t.fMsp[d] = t.msp
        t.depth = d + 1
        let np = Int(p.fnNParams[fi])
        let extra = n > np ? n - np : 0
        let newFp = (t.msp + 7) & ~7
        let frame = Int(p.fnFrame[fi])
        if newFp + frame + extra * 8 > t.mspLimit { t.depth = d; throw VmFault(Vm.STK_OVER, "stack overflow") }
        let base = t.sp - n
        let offs = try offsOf(p.fnParamOff[fi])
        let m = mem
        let cnt = n < np ? n : np
        var i = 0
        while i < cnt { m.st8(newFp + Int(offs[i]), t.st[base + i]); i += 1 }
        let ac = Int(p.fnArgc[fi])
        if ac >= 0 {
            let va = newFp + frame
            i = 0
            while i < extra { m.st8(va + i * 8, t.st[base + np + i]); i += 1 }
            m.st8(newFp + ac, Int64(extra))
            m.st8(newFp + Int(p.fnArgv[fi]), Int64(va))
        }
        t.sp = base
        t.fp = newFp
        t.msp = newFp + frame + extra * 8
        t.pc = Int(p.fnEntry[fi])
    }

    // ------------------------------------------------------------ exceptions

    /** Transfers control to the innermost handler. Returns false if there is none. */
    private func raise(_ t: HTask, _ ch: Int64, _ msg: String?, _ stopDepth: Int) throws -> Bool {
        if t.fsAddr != 0 && exceptChOff >= 0 {
            mem.st8(t.fsAddr + exceptChOff, ch)
            mem.st1(t.fsAddr + catchExceptOff, 0)
        }
        if t.hCount > t.handlerBase {
            t.hCount -= 1
            let h = t.hCount
            t.sp = t.hSp[h]; t.fp = t.hFp[h]; t.msp = t.hMsp[h]; t.depth = t.hDepth[h]; t.pc = t.hPc[h]
            lastFault = msg
            return true
        }
        let whr = prog.where(t.faultPc)
        let fn = prog.funcAt(t.faultPc)
        let m = "Unhandled exception '\(chStr(ch))' in \(fn) (\(whr))" + ((msg ?? "").isEmpty ? "" : ": \(msg!)")
        if stopDepth > 0 || t.nestLevel > 0 { throw VmUncaught(ch, m) }
        t.deathMessage = m
        t.deathCode = ch
        return false
    }

    /** Raises exception [ch] in a suspended task (Break). Returns false if unhandled. */
    public func inject(_ t: HTask, _ ch: Int64) -> Bool {
        if let e = engine { return e.inject(t, ch) }
        t.blocked = false; t.resumed = false
        t.faultPc = t.pc
        do { return try raise(t, ch, "", 0) } catch let u as VmUncaught { t.deathMessage = u.message; t.deathCode = u.ch; return false } catch {
            t.deathMessage = errorMessage(error); return false
        }
    }

    /** Message of the last runtime fault that was caught by a handler (for PutExcept). */
    public var lastFault: String?

    public func chStr(_ ch: Int64) -> String {
        var b: [UInt8] = []
        var v = ch
        while v != 0 { b.append(UInt8(truncatingIfNeeded: v & 0xFF)); v = ushr(v, 8) }
        return latin1(b)
    }

    // ------------------------------------------------------------ interpreter

    /** Runs [t] for about [budget] backward branches/calls. */
    public func run(_ t: HTask, _ budget: Int, _ stopDepth: Int = 0) throws -> Int {
        if let e = engine { return try e.run(t, budget) }
        while true {
            do {
                return try exec(t, budget, stopDepth)
            } catch let f as VmFault {
                if !(try raise(t, f.ch, f.message, stopDepth)) { return Vm.R_DEAD }
            } catch let u as VmUncaught {
                if t.nestLevel > 0 && stopDepth > 0 { throw u }
                // an exception escaped a callback invoked by a native: rethrow in this context
                if !(try raise(t, u.ch, u.message, stopDepth)) { return Vm.R_DEAD }
            }
        }
    }

    private func exec(_ t: HTask, _ budget0: Int, _ stopDepth: Int) throws -> Int {
        // purity guard: a native kernel never interprets bytecode
        precondition(engine == nil, "bytecode execution in a native kernel")
        let p: Program = prog
        var code = p.code.data
        var k = p.konstArr
        let st = t.st
        let m = mem
        let nat = natives.list
        var pc = t.pc
        var sp = t.sp
        var fp = t.fp
        var budget = budget0
        var opPc = pc
        var count: Int64 = 0
        do {
            while true {
                opPc = pc
                count &+= 1
                // The operand stack is a raw buffer: bound it before every instruction
                // (Kotlin relies on the JVM array check for the same fault).
                if sp > HTask.STACK_WORDS - 4 { throw VmIndexOutOfBounds() }
                let op = Int(code[pc]); pc += 1
                switch op {
                case 0: // NOP
                    break
                case 1: // PUSHI
                    st[sp] = Int64(code[pc]); sp += 1; pc += 1
                case 2: // PUSHK
                    st[sp] = k[Int(code[pc])]; sp += 1; pc += 1
                case 3: // POP
                    sp -= 1
                case 4: // DUP
                    st[sp] = st[sp - 1]; sp += 1
                case 5: // SWAP
                    let a = st[sp - 1]; st[sp - 1] = st[sp - 2]; st[sp - 2] = a
                case 6: // LADDR
                    st[sp] = Int64(fp + Int(code[pc])); sp += 1; pc += 1

                case 7: // LD1S
                    st[sp - 1] = Int64(Int8(truncatingIfNeeded: m.ld1(try m.check(st[sp - 1], 1))))
                case 8: // LD1U
                    st[sp - 1] = m.ld1(try m.check(st[sp - 1], 1))
                case 9: // LD2S
                    st[sp - 1] = Int64(Int16(truncatingIfNeeded: m.ld2(try m.check(st[sp - 1], 2))))
                case 10: // LD2U
                    st[sp - 1] = m.ld2(try m.check(st[sp - 1], 2))
                case 11: // LD4S
                    st[sp - 1] = Int64(Int32(truncatingIfNeeded: m.ld4(try m.check(st[sp - 1], 4))))
                case 12: // LD4U
                    st[sp - 1] = m.ld4(try m.check(st[sp - 1], 4))
                case 13: // LD8
                    st[sp - 1] = m.ld8(try m.check(st[sp - 1], 8))

                case 14: // LLD1S
                    st[sp] = Int64(Int8(truncatingIfNeeded: m.ld1(fp + Int(code[pc])))); sp += 1; pc += 1
                case 15: // LLD1U
                    st[sp] = m.ld1(fp + Int(code[pc])); sp += 1; pc += 1
                case 16: // LLD2S
                    st[sp] = Int64(Int16(truncatingIfNeeded: m.ld2(fp + Int(code[pc])))); sp += 1; pc += 1
                case 17: // LLD2U
                    st[sp] = m.ld2(fp + Int(code[pc])); sp += 1; pc += 1
                case 18: // LLD4S
                    st[sp] = Int64(Int32(truncatingIfNeeded: m.ld4(fp + Int(code[pc])))); sp += 1; pc += 1
                case 19: // LLD4U
                    st[sp] = m.ld4(fp + Int(code[pc])); sp += 1; pc += 1
                case 20: // LLD8
                    st[sp] = m.ld8(fp + Int(code[pc])); sp += 1; pc += 1

                case 21: // GLD1S
                    st[sp] = Int64(Int8(truncatingIfNeeded: m.ld1(Int(code[pc])))); sp += 1; pc += 1
                case 22: // GLD1U
                    st[sp] = m.ld1(Int(code[pc])); sp += 1; pc += 1
                case 23: // GLD2S
                    st[sp] = Int64(Int16(truncatingIfNeeded: m.ld2(Int(code[pc])))); sp += 1; pc += 1
                case 24: // GLD2U
                    st[sp] = m.ld2(Int(code[pc])); sp += 1; pc += 1
                case 25: // GLD4S
                    st[sp] = Int64(Int32(truncatingIfNeeded: m.ld4(Int(code[pc])))); sp += 1; pc += 1
                case 26: // GLD4U
                    st[sp] = m.ld4(Int(code[pc])); sp += 1; pc += 1
                case 27: // GLD8
                    st[sp] = m.ld8(Int(code[pc])); sp += 1; pc += 1

                case 28: // ST1
                    sp -= 1; let v = st[sp]; sp -= 1; m.st1(try m.check(st[sp], 1), v)
                case 29: // ST2
                    sp -= 1; let v = st[sp]; sp -= 1; m.st2(try m.check(st[sp], 2), v)
                case 30: // ST4
                    sp -= 1; let v = st[sp]; sp -= 1; m.st4(try m.check(st[sp], 4), v)
                case 31: // ST8
                    sp -= 1; let v = st[sp]; sp -= 1; m.st8(try m.check(st[sp], 8), v)
                case 32: // STK1
                    sp -= 1; let v = st[sp]; m.st1(try m.check(st[sp - 1], 1), v); st[sp - 1] = v
                case 33: // STK2
                    sp -= 1; let v = st[sp]; m.st2(try m.check(st[sp - 1], 2), v); st[sp - 1] = v
                case 34: // STK4
                    sp -= 1; let v = st[sp]; m.st4(try m.check(st[sp - 1], 4), v); st[sp - 1] = v
                case 35: // STK8
                    sp -= 1; let v = st[sp]; m.st8(try m.check(st[sp - 1], 8), v); st[sp - 1] = v
                case 36: // LST8
                    sp -= 1; m.st8(fp + Int(code[pc]), st[sp]); pc += 1
                case 37: // LSTK8
                    m.st8(fp + Int(code[pc]), st[sp - 1]); pc += 1
                case 38: // GST8
                    sp -= 1; m.st8(Int(code[pc]), st[sp]); pc += 1

                case 40: // ADD
                    sp -= 1; st[sp - 1] = st[sp - 1] &+ st[sp]
                case 41: // SUB
                    sp -= 1; st[sp - 1] = st[sp - 1] &- st[sp]
                case 42: // MUL
                    sp -= 1; st[sp - 1] = st[sp - 1] &* st[sp]
                case 43: // DIVS
                    sp -= 1; let dv = st[sp]
                    // x86 IDIV faults on I64_MIN/-1 too: TempleOS reports it as DivZero (Kernel/KInts.HC)
                    if dv == 0 || (dv == -1 && st[sp - 1] == Int64.min) { throw VmFault(Vm.DIV_ZERO, "division by zero") }
                    st[sp - 1] = dv == -1 ? 0 &- st[sp - 1] : st[sp - 1] / dv
                case 44: // DIVU
                    sp -= 1; let dv = st[sp]
                    if dv == 0 { throw VmFault(Vm.DIV_ZERO, "division by zero") }
                    st[sp - 1] = Int64(bitPattern: UInt64(bitPattern: st[sp - 1]) / UInt64(bitPattern: dv))
                case 45: // MODS
                    sp -= 1; let dv = st[sp]
                    if dv == 0 || (dv == -1 && st[sp - 1] == Int64.min) { throw VmFault(Vm.DIV_ZERO, "division by zero") }
                    st[sp - 1] = dv == -1 ? 0 : st[sp - 1] % dv
                case 46: // MODU
                    sp -= 1; let dv = st[sp]
                    if dv == 0 { throw VmFault(Vm.DIV_ZERO, "division by zero") }
                    st[sp - 1] = Int64(bitPattern: UInt64(bitPattern: st[sp - 1]) % UInt64(bitPattern: dv))
                case 47: // AND
                    sp -= 1; st[sp - 1] = st[sp - 1] & st[sp]
                case 48: // OR
                    sp -= 1; st[sp - 1] = st[sp - 1] | st[sp]
                case 49: // XOR
                    sp -= 1; st[sp - 1] = st[sp - 1] ^ st[sp]
                case 50: // SHL
                    sp -= 1; st[sp - 1] = st[sp - 1] &<< st[sp]
                case 51: // SHRS
                    sp -= 1; st[sp - 1] = st[sp - 1] &>> st[sp]
                case 52: // SHRU
                    sp -= 1; st[sp - 1] = ushr(st[sp - 1], st[sp])
                case 53: // POWI
                    sp -= 1; st[sp - 1] = ipow(st[sp - 1], st[sp])
                case 54: // NEG
                    st[sp - 1] = 0 &- st[sp - 1]
                case 55: // COM
                    st[sp - 1] = ~st[sp - 1]
                case 56: // LNOT
                    st[sp - 1] = st[sp - 1] == 0 ? 1 : 0
                case 58: // TOBOOL
                    st[sp - 1] = st[sp - 1] != 0 ? 1 : 0
                case 57: // LXOR
                    sp -= 1; st[sp - 1] = (st[sp - 1] != 0) != (st[sp] != 0) ? 1 : 0
                case 59: // EQ
                    sp -= 1; st[sp - 1] = st[sp - 1] == st[sp] ? 1 : 0
                case 60: // NE
                    sp -= 1; st[sp - 1] = st[sp - 1] != st[sp] ? 1 : 0
                case 61: // LTS
                    sp -= 1; st[sp - 1] = st[sp - 1] < st[sp] ? 1 : 0
                case 62: // LES
                    sp -= 1; st[sp - 1] = st[sp - 1] <= st[sp] ? 1 : 0
                case 63: // GTS
                    sp -= 1; st[sp - 1] = st[sp - 1] > st[sp] ? 1 : 0
                case 64: // GES
                    sp -= 1; st[sp - 1] = st[sp - 1] >= st[sp] ? 1 : 0
                case 65: // LTU
                    sp -= 1; st[sp - 1] = UInt64(bitPattern: st[sp - 1]) < UInt64(bitPattern: st[sp]) ? 1 : 0
                case 66: // LEU
                    sp -= 1; st[sp - 1] = UInt64(bitPattern: st[sp - 1]) <= UInt64(bitPattern: st[sp]) ? 1 : 0
                case 67: // GTU
                    sp -= 1; st[sp - 1] = UInt64(bitPattern: st[sp - 1]) > UInt64(bitPattern: st[sp]) ? 1 : 0
                case 68: // GEU
                    sp -= 1; st[sp - 1] = UInt64(bitPattern: st[sp - 1]) >= UInt64(bitPattern: st[sp]) ? 1 : 0

                case 70: // FADD
                    sp -= 1; st[sp - 1] = bits(d(st[sp - 1]) + d(st[sp]))
                case 71: // FSUB
                    sp -= 1; st[sp - 1] = bits(d(st[sp - 1]) - d(st[sp]))
                case 72: // FMUL
                    sp -= 1; st[sp - 1] = bits(d(st[sp - 1]) * d(st[sp]))
                case 73: // FDIV
                    sp -= 1; st[sp - 1] = bits(d(st[sp - 1]) / d(st[sp]))
                case 74: // FMOD
                    sp -= 1; st[sp - 1] = bits(d(st[sp - 1]).truncatingRemainder(dividingBy: d(st[sp])))
                case 75: // FPOW
                    sp -= 1; st[sp - 1] = bits(templePow(d(st[sp - 1]), d(st[sp])))
                case 76: // FNEG
                    st[sp - 1] = st[sp - 1] ^ Int64.min
                case 77: // FEQ
                    sp -= 1; st[sp - 1] = d(st[sp - 1]) == d(st[sp]) ? 1 : 0
                case 78: // FNE
                    sp -= 1; st[sp - 1] = d(st[sp - 1]) != d(st[sp]) ? 1 : 0
                case 79: // FLT
                    sp -= 1; st[sp - 1] = d(st[sp - 1]) < d(st[sp]) ? 1 : 0
                case 80: // FLE
                    sp -= 1; st[sp - 1] = d(st[sp - 1]) <= d(st[sp]) ? 1 : 0
                case 81: // FGT
                    sp -= 1; st[sp - 1] = d(st[sp - 1]) > d(st[sp]) ? 1 : 0
                case 82: // FGE
                    sp -= 1; st[sp - 1] = d(st[sp - 1]) >= d(st[sp]) ? 1 : 0
                case 83: // I2F
                    st[sp - 1] = bits(Double(st[sp - 1]))
                case 84: // U2F
                    st[sp - 1] = bits(u2f(st[sp - 1]))
                case 85: // F2I
                    st[sp - 1] = f2i(d(st[sp - 1]))
                case 86: // SX1
                    st[sp - 1] = Int64(Int8(truncatingIfNeeded: st[sp - 1]))
                case 87: // SX2
                    st[sp - 1] = Int64(Int16(truncatingIfNeeded: st[sp - 1]))
                case 88: // SX4
                    st[sp - 1] = Int64(Int32(truncatingIfNeeded: st[sp - 1]))
                case 89: // ZX1
                    st[sp - 1] = st[sp - 1] & 0xFF
                case 90: // ZX2
                    st[sp - 1] = st[sp - 1] & 0xFFFF
                case 91: // ZX4
                    st[sp - 1] = st[sp - 1] & 0xFFFF_FFFF
                case 108: // ADDI
                    st[sp - 1] = st[sp - 1] &+ Int64(code[pc]); pc += 1
                case 117: // MULI
                    st[sp - 1] = st[sp - 1] &* Int64(code[pc]); pc += 1
                case 118: // REV
                    var i = sp - Int(code[pc]), j = sp - 1; pc += 1
                    while i < j { let a = st[i]; st[i] = st[j]; st[j] = a; i += 1; j -= 1 }

                // ---- quickened superinstructions (see Quicken.swift); pc is just past the first opcode
                case 128: // Quick.FLD8
                    st[sp] = m.ld8(try m.check(m.ld8(fp + Int(code[pc])) &+ Int64(code[pc + 2]), 8)); sp += 1; pc += 4
                case 129: // Quick.FLD4S
                    st[sp] = Int64(Int32(truncatingIfNeeded: m.ld4(try m.check(m.ld8(fp + Int(code[pc])) &+ Int64(code[pc + 2]), 4)))); sp += 1; pc += 4
                case 130: // Quick.FLD4U
                    st[sp] = m.ld4(try m.check(m.ld8(fp + Int(code[pc])) &+ Int64(code[pc + 2]), 4)); sp += 1; pc += 4
                case 131: // Quick.FLD2S
                    st[sp] = Int64(Int16(truncatingIfNeeded: m.ld2(try m.check(m.ld8(fp + Int(code[pc])) &+ Int64(code[pc + 2]), 2)))); sp += 1; pc += 4
                case 132: // Quick.FLD2U
                    st[sp] = m.ld2(try m.check(m.ld8(fp + Int(code[pc])) &+ Int64(code[pc + 2]), 2)); sp += 1; pc += 4
                case 133: // Quick.FLD1S
                    st[sp] = Int64(Int8(truncatingIfNeeded: m.ld1(try m.check(m.ld8(fp + Int(code[pc])) &+ Int64(code[pc + 2]), 1)))); sp += 1; pc += 4
                case 134: // Quick.FLD1U
                    st[sp] = m.ld1(try m.check(m.ld8(fp + Int(code[pc])) &+ Int64(code[pc + 2]), 1)); sp += 1; pc += 4
                case 135: // Quick.ALD8
                    st[sp - 1] = m.ld8(try m.check(st[sp - 1] &+ Int64(code[pc]), 8)); pc += 2
                case 136: // Quick.ALD4S
                    st[sp - 1] = Int64(Int32(truncatingIfNeeded: m.ld4(try m.check(st[sp - 1] &+ Int64(code[pc]), 4)))); pc += 2
                case 137: // Quick.ALD4U
                    st[sp - 1] = m.ld4(try m.check(st[sp - 1] &+ Int64(code[pc]), 4)); pc += 2
                case 138: // Quick.ALD2S
                    st[sp - 1] = Int64(Int16(truncatingIfNeeded: m.ld2(try m.check(st[sp - 1] &+ Int64(code[pc]), 2)))); pc += 2
                case 139: // Quick.ALD2U
                    st[sp - 1] = m.ld2(try m.check(st[sp - 1] &+ Int64(code[pc]), 2)); pc += 2
                case 140: // Quick.ALD1S
                    st[sp - 1] = Int64(Int8(truncatingIfNeeded: m.ld1(try m.check(st[sp - 1] &+ Int64(code[pc]), 1)))); pc += 2
                case 141: // Quick.ALD1U
                    st[sp - 1] = m.ld1(try m.check(st[sp - 1] &+ Int64(code[pc]), 1)); pc += 2
                case 142: // Quick.XLD8
                    sp -= 1; st[sp - 1] = m.ld8(try m.check(st[sp - 1] &+ st[sp], 8)); pc += 1
                case 143: // Quick.XLD4S
                    sp -= 1; st[sp - 1] = Int64(Int32(truncatingIfNeeded: m.ld4(try m.check(st[sp - 1] &+ st[sp], 4)))); pc += 1
                case 144: // Quick.XLD4U
                    sp -= 1; st[sp - 1] = m.ld4(try m.check(st[sp - 1] &+ st[sp], 4)); pc += 1
                case 145: // Quick.XLD1U
                    sp -= 1; st[sp - 1] = m.ld1(try m.check(st[sp - 1] &+ st[sp], 1)); pc += 1
                case 146: // Quick.LLD8_ADDI
                    st[sp] = m.ld8(fp + Int(code[pc])) &+ Int64(code[pc + 2]); sp += 1; pc += 3
                case 147: // Quick.LLD8_LLD8
                    st[sp] = m.ld8(fp + Int(code[pc])); st[sp + 1] = m.ld8(fp + Int(code[pc + 2])); sp += 2; pc += 3
                case 148: // Quick.LLD8_MULI
                    st[sp] = m.ld8(fp + Int(code[pc])) &* Int64(code[pc + 2]); sp += 1; pc += 3
                case 165: // Quick.LLD8_LD8
                    st[sp] = m.ld8(try m.check(m.ld8(fp + Int(code[pc])), 8)); sp += 1; pc += 2
                case 167: // Quick.LLD8_PUSHI
                    st[sp] = m.ld8(fp + Int(code[pc])); st[sp + 1] = Int64(code[pc + 2]); sp += 2; pc += 3
                case 149: // Quick.MULI_ADD
                    sp -= 1; st[sp - 1] = st[sp - 1] &+ (st[sp] &* Int64(code[pc])); pc += 2
                case 150: // Quick.LADDR_ADDI
                    st[sp] = Int64(fp + Int(code[pc])) &+ Int64(code[pc + 2]); sp += 1; pc += 3
                case 151: // Quick.ADDI_ADDI
                    st[sp - 1] = st[sp - 1] &+ (Int64(code[pc]) &+ Int64(code[pc + 2])); pc += 3
                case 152: // Quick.PUSHI_AND
                    st[sp - 1] = st[sp - 1] & Int64(code[pc]); pc += 2
                case 153: // Quick.PUSHI_SUB
                    st[sp - 1] = st[sp - 1] &- Int64(code[pc]); pc += 2
                case 154: // Quick.PUSHI_SHL
                    st[sp - 1] = st[sp - 1] &<< Int64(code[pc]); pc += 2
                case 155: // Quick.PUSHI_SHRS
                    st[sp - 1] = st[sp - 1] &>> Int64(code[pc]); pc += 2
                case 156: // Quick.PUSHI_EQ
                    st[sp - 1] = st[sp - 1] == Int64(code[pc]) ? 1 : 0; pc += 2
                case 157: // Quick.PUSHI_NE
                    st[sp - 1] = st[sp - 1] != Int64(code[pc]) ? 1 : 0; pc += 2
                case 166: // Quick.PUSHI_JLTS
                    sp -= 1
                    if st[sp] >= Int64(code[pc]) { pc = Int(code[pc + 2]) } else { pc += 3 }
                case 168: // Quick.LNOT_TOBOOL
                    st[sp - 1] = st[sp - 1] == 0 ? 1 : 0; pc += 1
                case 162: // Quick.ST8_LLD8
                    sp -= 1; let v = st[sp]; sp -= 1
                    m.st8(try m.check(st[sp], 8), v)
                    st[sp] = m.ld8(fp + Int(code[pc + 1])); sp += 1; pc += 2
                case 163: // Quick.LST8_LLD8
                    sp -= 1; m.st8(fp + Int(code[pc]), st[sp])
                    st[sp] = m.ld8(fp + Int(code[pc + 2])); sp += 1; pc += 3
                case 164: // Quick.FMUL_FADD (two roundings, like the originals)
                    sp -= 2
                    let prod = d(st[sp]) * d(st[sp + 1])
                    st[sp - 1] = bits(d(st[sp - 1]) + prod); pc += 1
                case 158, 159, 160, 161: // Quick.TOBOOL_JZ, Quick.TOBOOL_JNZ, Quick.LNOT_JZ, Quick.LNOT_JNZ
                    let o = op
                    let tg = Int(code[pc + 1])
                    sp -= 1
                    let v = st[sp] != 0
                    if v == (o == 159 || o == 160) {
                        if tg <= opPc {
                            budget -= 1
                            if budget <= 0 || interrupt { pc = tg; t.pc = pc; t.sp = sp; t.fp = fp; instructionsExecuted &+= count; ticksExecuted &+= Int64(budget0 - budget); return Vm.R_SLICE }
                        }
                        pc = tg
                    } else { pc += 2 }
                case 92: // JMP
                    let tg = Int(code[pc])
                    if tg <= opPc {
                        if profile != nil { sample(opPc) }
                        budget -= 1
                        if budget <= 0 || interrupt { pc = tg; t.pc = pc; t.sp = sp; t.fp = fp; instructionsExecuted &+= count; ticksExecuted &+= Int64(budget0 - budget); return Vm.R_SLICE }
                    }
                    pc = tg
                case 93: // JZ
                    let tg = Int(code[pc]); pc += 1
                    sp -= 1
                    if st[sp] == 0 {
                        if tg <= opPc {
                            budget -= 1
                            if budget <= 0 || interrupt { pc = tg; t.pc = pc; t.sp = sp; t.fp = fp; instructionsExecuted &+= count; ticksExecuted &+= Int64(budget0 - budget); return Vm.R_SLICE }
                        }
                        pc = tg
                    }
                case 94: // JNZ
                    let tg = Int(code[pc]); pc += 1
                    sp -= 1
                    if st[sp] != 0 {
                        if tg <= opPc {
                            budget -= 1
                            if budget <= 0 || interrupt { pc = tg; t.pc = pc; t.sp = sp; t.fp = fp; instructionsExecuted &+= count; ticksExecuted &+= Int64(budget0 - budget); return Vm.R_SLICE }
                        }
                        pc = tg
                    }
                case 111: // JLTS
                    let tg = Int(code[pc]); pc += 1; sp -= 2; if st[sp] >= st[sp + 1] { pc = tg }
                case 112: // JLES
                    let tg = Int(code[pc]); pc += 1; sp -= 2; if st[sp] > st[sp + 1] { pc = tg }
                case 113: // JGTS
                    let tg = Int(code[pc]); pc += 1; sp -= 2; if st[sp] <= st[sp + 1] { pc = tg }
                case 114: // JGES
                    let tg = Int(code[pc]); pc += 1; sp -= 2; if st[sp] < st[sp + 1] { pc = tg }
                case 115: // JEQ
                    let tg = Int(code[pc]); pc += 1; sp -= 2; if st[sp] != st[sp + 1] { pc = tg }
                case 116: // JNE
                    let tg = Int(code[pc]); pc += 1; sp -= 2; if st[sp] == st[sp + 1] { pc = tg }
                case 95: // SWITCH
                    let tb = p.switchTables[Int(code[pc])]
                    sp -= 1
                    let i = st[sp] &- tb.lo
                    pc = (i >= 0 && i < Int64(tb.targets.count)) ? tb.targets[Int(i)] : tb.dflt

                case 96: // CALL
                    let fi = Int(code[pc]); let n = Int(code[pc + 1]); pc += 2
                    if profile != nil { sample(opPc) }
                    t.sp = sp; t.fp = fp
                    try enter(t, fi, n, pc)
                    sp = t.sp; fp = t.fp; pc = t.pc
                    budget -= 1
                    if budget <= 0 || interrupt { t.pc = pc; instructionsExecuted &+= count; ticksExecuted &+= Int64(budget0 - budget); return Vm.R_SLICE }
                case 97: // CALLP
                    let n = Int(code[pc]); pc += 1
                    sp -= 1
                    let f = st[sp]
                    if (f & Vm.HI_MASK) == Program.FPTR_NATIVE {
                        let ni = Int(Int32(truncatingIfNeeded: f & 0xFFFF_FFFF))
                        if ni < 0 || ni >= nat.count { throw VmIndexOutOfBounds() }
                        let nf = nat[ni]
                        t.sp = sp; t.fp = fp; t.pc = opPc
                        let r = try nf.call(t, sp - n, n)
                        code=p.code.data;k=p.konstArr
                        t.blocked = false
                        sp -= n
                        st[sp] = r; sp += 1
                    } else {
                        if (f & Vm.HI_MASK) != Program.FPTR_TAG { throw VmFault(Vm.BAD_CALL, "call of invalid function pointer 0x\(hex(f))") }
                        t.sp = sp; t.fp = fp
                        try enter(t, Int(Int32(truncatingIfNeeded: f & 0xFFFF_FFFF)), n, pc)
                        sp = t.sp; fp = t.fp; pc = t.pc
                        budget -= 1
                        if budget <= 0 || interrupt { t.pc = pc; instructionsExecuted &+= count; ticksExecuted &+= Int64(budget0 - budget); return Vm.R_SLICE }
                    }
                case 98: // CALLN
                    let ni = Int(code[pc]); let n = Int(code[pc + 1]); pc += 2
                    t.sp = sp; t.fp = fp; t.pc = opPc; t.faultPc = opPc
                    t.blocked = false
                    let r = try nat[ni].call(t, sp - n, n)
                    // Runtime source loading can reallocate code and constant storage.
                    code=p.code.data;k=p.konstArr
                    if t.blocked {
                        t.pc = opPc; t.sp = sp; t.fp = fp
                        instructionsExecuted &+= count; ticksExecuted &+= Int64(budget0 - budget)
                        return Vm.R_BLOCKED
                    }
                    // the wake-up token belongs to this (re-executed) call: a later Sleep/SleepUntil/
                    // Refresh must wait again (Play's note gaps were skipped: SleepUntil left it set)
                    t.resumed = false
                    sp -= n
                    st[sp] = r; sp += 1
                    if t.yieldReq {
                        t.yieldReq = false
                        t.yielded = true
                        t.pc = pc; t.sp = sp; t.fp = fp
                        instructionsExecuted &+= count; ticksExecuted &+= Int64(budget0 - budget)
                        return Vm.R_SLICE
                    }
                case 99: // RET
                    sp -= 1
                    let v = st[sp]
                    let dd = t.depth - 1
                    // the frame arrays are raw buffers: never index them at -1
                    if dd < 0 { throw VmKill("internal error: return with no active call") }
                    t.depth = dd
                    while t.hCount > t.handlerBase && t.hDepth[t.hCount - 1] > dd { t.hCount -= 1 }
                    let rp = t.fRet[dd]
                    fp = t.fFp[dd]
                    t.msp = t.fMsp[dd]
                    if dd <= stopDepth || rp < 0 {
                        t.result = v; t.sp = sp; t.fp = fp; t.pc = rp
                        instructionsExecuted &+= count; ticksExecuted &+= Int64(budget0 - budget)
                        return Vm.R_DONE
                    }
                    pc = rp
                    st[sp] = v; sp += 1
                case 100: // TRY
                    let h = t.hCount
                    if h >= HTask.MAX_HANDLERS { throw VmFault(Vm.STK_OVER, "too many nested try blocks") }
                    t.hPc[h] = Int(code[pc]); pc += 1
                    t.hSp[h] = sp; t.hFp[h] = fp; t.hMsp[h] = t.msp; t.hDepth[h] = t.depth
                    t.hCount = h + 1
                case 101: // UNTRY
                    if t.hCount > t.handlerBase { t.hCount -= 1 }
                case 102: // THROW
                    t.faultPc = opPc; lastFault = nil
                    sp -= 1
                    throw VmFault(st[sp], "")
                case 103: // ENDCATCH
                    if t.fsAddr != 0 && m.ld1(t.fsAddr + catchExceptOff) == 0 {
                        let ch = m.ld8(t.fsAddr + exceptChOff)
                        throw VmFault(ch, lastFault ?? "")
                    }
                case 104: // MEMCPY
                    let n = Int(code[pc]); pc += 1
                    sp -= 1; let src = st[sp]
                    sp -= 1; let dst = st[sp]
                    let dA = try m.check(dst, n)
                    let sA = try m.check(src, n)
                    m.copy(dA, sA, n)
                case 109: // MEMZERO
                    let n = Int(code[pc]); pc += 1
                    sp -= 1; let a = st[sp]
                    m.fill(try m.check(a, n), 0, n)
                case 105: // INC
                    let kind = Int(code[pc]); let delta = Int64(code[pc + 1]); let post = code[pc + 2]; pc += 3
                    st[sp - 1] = try incAt(st[sp - 1], kind, delta, post != 0)
                case 106: // LINC8
                    let a = fp + Int(code[pc]); let delta = Int64(code[pc + 1]); let post = code[pc + 2]; pc += 3
                    let old = m.ld8(a)
                    let nv = old &+ delta
                    m.st8(a, nv)
                    st[sp] = post != 0 ? old : nv; sp += 1
                case 107: // HALT
                    t.pc = opPc; t.sp = sp; t.fp = fp; instructionsExecuted &+= count; return Vm.R_DONE
                default:
                    throw VmKill("bad opcode \(code[opPc]) at \(opPc)")
                }
            }
        } catch let f as VmFault {
            t.pc = opPc; t.sp = sp; t.fp = fp; t.faultPc = opPc
            instructionsExecuted &+= count; ticksExecuted &+= Int64(budget0 - budget)
            throw f
        } catch let u as VmUncaught {
            // an exception that escaped a callback a native made: its ticks still count (virtual time)
            instructionsExecuted &+= count; ticksExecuted &+= Int64(budget0 - budget)
            throw u
        } catch is VmIndexOutOfBounds {
            // operand stack overflow from runaway recursion of expressions
            t.pc = opPc; t.sp = 0; t.fp = fp; t.faultPc = opPc
            throw VmFault(Vm.STK_OVER, "operand stack overflow")
        }
    }

    private func incAt(_ av: Int64, _ kind: Int, _ delta: Int64, _ post: Bool) throws -> Int64 {
        let m = mem
        switch kind {
        case Op.KF64:
            let a = try m.check(av, 8); let old = d(m.ld8(a)); let nv = old + Double(delta)
            m.st8(a, bits(nv)); return bits(post ? old : nv)
        case Op.K8:
            let a = try m.check(av, 8); let old = m.ld8(a); m.st8(a, old &+ delta); return post ? old : old &+ delta
        case Op.K4S, Op.K4U:
            let a = try m.check(av, 4); let raw = m.ld4(a)
            let old = kind == Op.K4S ? Int64(Int32(truncatingIfNeeded: raw)) : raw
            m.st4(a, old &+ delta)
            let nv = kind == Op.K4S ? Int64(Int32(truncatingIfNeeded: old &+ delta)) : (old &+ delta) & 0xFFFF_FFFF
            return post ? old : nv
        case Op.K2S, Op.K2U:
            let a = try m.check(av, 2); let raw = m.ld2(a)
            let old = kind == Op.K2S ? Int64(Int16(truncatingIfNeeded: raw)) : raw
            m.st2(a, old &+ delta)
            let nv = kind == Op.K2S ? Int64(Int16(truncatingIfNeeded: old &+ delta)) : (old &+ delta) & 0xFFFF
            return post ? old : nv
        default:
            let a = try m.check(av, 1); let raw = m.ld1(a)
            let old = kind == Op.K1S ? Int64(Int8(truncatingIfNeeded: raw)) : raw
            m.st1(a, old &+ delta)
            let nv = kind == Op.K1S ? Int64(Int8(truncatingIfNeeded: old &+ delta)) : (old &+ delta) & 0xFF
            return post ? old : nv
        }
    }
}

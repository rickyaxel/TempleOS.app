import Foundation

// Port of purenative/NativeModule.kt.

/**
 * Base class of the Swift modules the translator generates from TempleOS HolyC (Pure Swift mode).
 *
 * Generated functions are ordinary compiled Swift: native locals, native control flow, native
 * arithmetic. They share with the interpreter only what HolyC programs observe: the program's arena
 * (pointers are arena addresses, so data layouts and pointer arithmetic are TempleOS's), the host
 * functions (natives: graphics, sound, files, input, scheduling) and the kernel. The helpers here
 * implement the VM's semantics for operations Swift does not have directly; they are @inlinable so
 * the generated module (a separate Swift module) inlines them.
 */
open class NativeModule {
    public let rt: NativeRuntime
    public let m: Arena
    public let vm: Vm

    public init(_ rt: NativeRuntime) { self.rt = rt; m = rt.mem; vm = rt.vm }

    /** Calls generated function [index] of this module with word arguments t.st[base ..< base+n]. */
    open func dispatch(_ t: HTask, _ index: Int, _ base: Int, _ n: Int) throws -> Int64 { throw VmFault(Vm.BAD_CALL, "no function #\(index)") }
    /** True when this module defines function [index]. */
    open func defines(_ index: Int) -> Bool { false }
    /** Sets the address fields of the globals, strings and binary literals of data-segment unit [unit]. */
    open func bind(_ unit: Int, _ seg: Segment) throws {}
    /** The HolyC name of function [index] (messages). */
    open func nameOf(_ index: Int) -> String? { nil }

    // MARK: memory (checked, as the VM's LDn/STn)

    @inlinable @inline(__always) public final func ld1s(_ a: Int64) throws -> Int64 { Int64(Int8(truncatingIfNeeded: m.ld1(try m.check(a, 1)))) }
    @inlinable @inline(__always) public final func ld1u(_ a: Int64) throws -> Int64 { m.ld1(try m.check(a, 1)) }
    @inlinable @inline(__always) public final func ld2s(_ a: Int64) throws -> Int64 { Int64(Int16(truncatingIfNeeded: m.ld2(try m.check(a, 2)))) }
    @inlinable @inline(__always) public final func ld2u(_ a: Int64) throws -> Int64 { m.ld2(try m.check(a, 2)) }
    @inlinable @inline(__always) public final func ld4s(_ a: Int64) throws -> Int64 { Int64(Int32(truncatingIfNeeded: m.ld4(try m.check(a, 4)))) }
    @inlinable @inline(__always) public final func ld4u(_ a: Int64) throws -> Int64 { m.ld4(try m.check(a, 4)) }
    @inlinable @inline(__always) public final func ld8(_ a: Int64) throws -> Int64 { m.ld8(try m.check(a, 8)) }
    @inlinable @inline(__always) public final func ldf(_ a: Int64) throws -> Double { d(m.ld8(try m.check(a, 8))) }
    @inlinable @inline(__always) public final func st1(_ a: Int64, _ v: Int64) throws { m.st1(try m.check(a, 1), v) }
    @inlinable @inline(__always) public final func st2(_ a: Int64, _ v: Int64) throws { m.st2(try m.check(a, 2), v) }
    @inlinable @inline(__always) public final func st4(_ a: Int64, _ v: Int64) throws { m.st4(try m.check(a, 4), v) }
    @inlinable @inline(__always) public final func st8(_ a: Int64, _ v: Int64) throws { m.st8(try m.check(a, 8), v) }
    /** MEMCPY: destination checked before the source, as the VM pops them. */
    public final func copy(_ dst: Int64, _ src: Int64, _ n: Int) throws { let dd = try m.check(dst, n); let s = try m.check(src, n); m.copy(dd, s, n) }

    // MARK: arithmetic

    @inlinable @inline(__always) public final func f(_ bits: Int64) -> Double { d(bits) }
    @inlinable @inline(__always) public final func b2i(_ b: Bool) -> Int64 { b ? 1 : 0 }
    @inlinable @inline(__always) public final func ltu(_ a: Int64, _ b: Int64) -> Bool { UInt64(bitPattern: a) < UInt64(bitPattern: b) }
    @inlinable @inline(__always) public final func leu(_ a: Int64, _ b: Int64) -> Bool { UInt64(bitPattern: a) <= UInt64(bitPattern: b) }
    @inlinable @inline(__always) public final func gtu(_ a: Int64, _ b: Int64) -> Bool { UInt64(bitPattern: a) > UInt64(bitPattern: b) }
    @inlinable @inline(__always) public final func geu(_ a: Int64, _ b: Int64) -> Bool { UInt64(bitPattern: a) >= UInt64(bitPattern: b) }
    @inlinable @inline(__always) public final func sx1(_ x: Int64) -> Int64 { Int64(Int8(truncatingIfNeeded: x)) }
    @inlinable @inline(__always) public final func sx2(_ x: Int64) -> Int64 { Int64(Int16(truncatingIfNeeded: x)) }
    @inlinable @inline(__always) public final func sx4(_ x: Int64) -> Int64 { Int64(Int32(truncatingIfNeeded: x)) }
    @inlinable @inline(__always) public final func shl(_ a: Int64, _ b: Int64) -> Int64 { a &<< (b & 63) }
    @inlinable @inline(__always) public final func shr(_ a: Int64, _ b: Int64) -> Int64 { a &>> (b & 63) }
    @inlinable @inline(__always) public final func ushr(_ a: Int64, _ b: Int64) -> Int64 { Int64(bitPattern: UInt64(bitPattern: a) &>> UInt64(b & 63)) }
    @inlinable @inline(__always) public final func fpow(_ a: Double, _ b: Double) -> Double { templePow(a, b) }
    @inlinable @inline(__always) public final func fmod(_ a: Double, _ b: Double) -> Double { a.truncatingRemainder(dividingBy: b) }
    @inlinable @inline(__always) public final func eval(_ x: Int64) {}
    @inlinable @inline(__always) public final func eval(_ x: Double) {}
    @inlinable @inline(__always) public final func eval(_ x: Bool) {}

    public final func divs(_ a: Int64, _ dd: Int64) throws -> Int64 {
        if dd == 0 || (dd == -1 && a == Int64.min) { throw VmFault(Vm.DIV_ZERO, "division by zero") }
        return dd == -1 ? 0 &- a : a / dd
    }
    public final func mods(_ a: Int64, _ dd: Int64) throws -> Int64 {
        if dd == 0 || (dd == -1 && a == Int64.min) { throw VmFault(Vm.DIV_ZERO, "division by zero") }
        return dd == -1 ? 0 : a % dd
    }
    public final func divu(_ a: Int64, _ dd: Int64) throws -> Int64 {
        if dd == 0 { throw VmFault(Vm.DIV_ZERO, "division by zero") }
        return Int64(bitPattern: UInt64(bitPattern: a) / UInt64(bitPattern: dd))
    }
    public final func modu(_ a: Int64, _ dd: Int64) throws -> Int64 {
        if dd == 0 { throw VmFault(Vm.DIV_ZERO, "division by zero") }
        return Int64(bitPattern: UInt64(bitPattern: a) % UInt64(bitPattern: dd))
    }

    // MARK: frames, depth, budget

    /** Function entry: call depth as the VM counts it (StkOver at MAX_DEPTH). */
    @inlinable @inline(__always) public final func enter(_ t: HTask) throws {
        t.depth += 1
        if t.depth > HTask.MAX_DEPTH { t.depth -= 1; throw VmFault(Vm.STK_OVER, "stack overflow (call depth)") }
    }

    /** An arena frame of [size] bytes at the 8-aligned top of the task's stack (VM enter). */
    public final func frame(_ t: HTask, _ size: Int) throws -> Int64 {
        let fp = (t.msp + 7) & ~7
        if fp + size > t.mspLimit { t.depth -= 1; throw VmFault(Vm.STK_OVER, "stack overflow") }
        t.msp = fp + size
        return Int64(fp)
    }

    /** One budget tick (a backward branch or a HolyC call): the slice ends when the budget runs out. */
    @inlinable @inline(__always) public final func tick(_ t: HTask) throws {
        t.budget -= 1
        if t.budget <= 0 { try rt.sliceEnd(t) }
    }

    // MARK: calls

    @inline(__always) private func room(_ t: HTask, _ n: Int) throws { if t.sp + n > HTask.STACK_WORDS - 4 { throw VmIndexOutOfBounds() } }

    /** Writes word arguments at the top of the task's stack (natives and pointer calls read them there). */
    public final func push(_ t: HTask, _ a: Int64...) throws -> Int {
        try room(t, a.count)
        let b = t.sp
        for i in 0..<a.count { t.st[b + i] = a[i] }
        t.sp = b + a.count
        return b
    }
    public final func push0(_ t: HTask) -> Int { t.sp }
    public final func push1(_ t: HTask, _ a0: Int64) throws -> Int { try room(t, 1); let b = t.sp; t.st[b] = a0; t.sp = b + 1; return b }
    public final func push2(_ t: HTask, _ a0: Int64, _ a1: Int64) throws -> Int { try room(t, 2); let b = t.sp; t.st[b] = a0; t.st[b + 1] = a1; t.sp = b + 2; return b }
    public final func push3(_ t: HTask, _ a0: Int64, _ a1: Int64, _ a2: Int64) throws -> Int {
        try room(t, 3); let b = t.sp; t.st[b] = a0; t.st[b + 1] = a1; t.st[b + 2] = a2; t.sp = b + 3; return b
    }
    public final func push4(_ t: HTask, _ a0: Int64, _ a1: Int64, _ a2: Int64, _ a3: Int64) throws -> Int {
        try room(t, 4); let b = t.sp; t.st[b] = a0; t.st[b + 1] = a1; t.st[b + 2] = a2; t.st[b + 3] = a3; t.sp = b + 4; return b
    }

    /** Calls host function [index] with the words pushed at [base] (VM CALLN: blocking natives suspend the task). */
    public final func nat(_ t: HTask, _ index: Int, _ base: Int) throws -> Int64 {
        let r = try rt.callNative(t, index, base, t.sp - base)
        t.sp = base
        return r
    }

    /** Calls through a HolyC function pointer with the words pushed at [base] (VM CALLP). */
    public final func ptr(_ t: HTask, _ fp: Int64, _ base: Int) throws -> Int64 {
        let r = try rt.callPointer(t, fp, base, t.sp - base)
        t.sp = base
        return r
    }

    /** A function that was declared but never defined (VM: 'BadCall' when called). */
    public final func undefined(_ name: String) throws -> Int64 { throw VmFault(Vm.BAD_CALL, "call of undefined function '\(name)'") }

    /** Varargs callee: copies the [n] extra words at [base] to the frame at [dst] (where argv points). */
    public final func vaCopy(_ t: HTask, _ dst: Int64, _ base: Int, _ n: Int) { for i in 0..<n { m.st8(Int(dst) + i * 8, t.st[base + i]) } }

    // MARK: exceptions (VM raise / ENDCATCH)

    /** Source files of this module's code (generated); [locate] decodes `fileIndex << 20 | line`. */
    open var files: [String] { [] }

    /**
     * A fault leaving generated function [name]: records where it happened, as the VM's message gives it
     * ("Function (file:line)"), unless a function it called already did.
     */
    public final func locate(_ f: VmFault, _ name: String, _ ln: Int) -> VmFault {
        if f.whereText != nil { return f }
        var g = f
        let fi = ln >> 20
        g.whereText = "\(name) (\(fi < files.count ? files[fi] : "?"):\(ln & 0xFFFFF))"
        return g
    }

    /** In a catch: records the exception as the VM's raise does; rethrows what HolyC cannot catch. */
    public final func caught(_ t: HTask, _ e: Error) throws { try rt.caught(t, e) }
    public final func endCatch(_ t: HTask) throws { try rt.endCatch(t) }
}

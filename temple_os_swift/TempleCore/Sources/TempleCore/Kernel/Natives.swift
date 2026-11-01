import Foundation

// Port of kernel/Natives.kt.

/** Kotlin `Long.toInt()`: keep the low 32 bits, sign-extended. */
@inline(__always) fileprivate func ti(_ v: Int64) -> Int { Int(Int32(truncatingIfNeeded: v)) }

/** Natives that tokenize text (DefinePrint, MenuNew...) raise a HolyC 'Compiler' exception (Kotlin: Natives.reg). */
func compilerErrorsAsExceptions(_ fn: @escaping (HTask, Int, Int) throws -> Int64) -> (HTask, Int, Int) throws -> Int64 {
    return { t, a, n in
        do { return try fn(t, a, n) } catch let e as CompileError { throw VmFault(chCode("Compiler"), e.description) }
    }
}

/**
 * Host functions bound to the prelude's `native` declarations. This file is
 * the complete list of things HolyC code can ask the host to do.
 */
public final class Natives {
    /** Unowned: the kernel owns its Natives (avoids a retain cycle through the native closures). */
    private unowned let k: Kernel
    private var mem: Arena { k.mem }
    private var vm: Vm { k.vm }

    public let SCF_SHIFT: Int64 = 1 << 9
    public let SCF_CTRL: Int64 = 1 << 10
    public let SCF_ALT: Int64 = 1 << 11
    public let SCF_KEY_UP: Int64 = 1 << 8

    public init(_ k: Kernel) { self.k = k }

    private func f(_ x: Double) -> Int64 { bits(x) }
    private func b(_ v: Bool) -> Int64 { v ? 1 : 0 }

    private var table: NativeTable!
    private func reg(_ name: String, _ fn: @escaping (HTask, Int, Int) throws -> Int64) {
        table.add(ClosureNative(name, compilerErrorsAsExceptions(fn)))
    }

    public func register(_ nt: NativeTable) {
        table = nt
        console(); memory(); strings(); math(); time(); exceptions(); input(); tasks(); sound(); files(); graphics()
    }

    // ================================================================ console

    /** Kernel/KMisc.HC Silent(): console output is dropped while set (TempleOS: per-task DISPLAYf_SILENT). */
    private var silent = false

    private func out(_ bytes: [UInt8]) throws { if !silent { try k.documents.output(bytes); k.console.write(bytes) } }

    private func format(_ t: HTask, _ fmtAddr: Int64, _ base: Int, _ argc: Int) throws -> [UInt8] {
        if fmtAddr == 0 { throw VmFault(chCode("StrPrint"), "NULL format string") }
        return try k.fmt.format(try mem.readStrBytes(fmtAddr), t.st, base, argc)
    }

    private func newStr(_ b: [UInt8]) throws -> Int64 {
        let a = try mem.malloc(Int64(b.count) + 1)
        mem.writeBytes(a, b); mem.st1(a + b.count, 0)
        return Int64(a)
    }

    private func console() {
        reg("PutChars") { t, a, _ in
            let v = t.st[a]
            var bytes: [UInt8] = []
            for i in 0..<8 { let c = ushr(v, 8 * i) & 0xFF; if c == 0 { break }; bytes.append(UInt8(truncatingIfNeeded: c)) }
            try self.out(bytes); return 0
        }
        reg("PutS") { t, a, _ in try self.out(try self.mem.readStrBytes(t.st[a])); return 0 }
        reg("Print") { t, a, n in try self.out(try self.format(t, t.st[a], a + 1, n - 1)); return 0 }
        reg("StrPrintJoin") { t, a, _ in
            let mem = self.mem
            let dst = t.st[a]; let fmt = t.st[a + 1]; let argcL = t.st[a + 2]; let argv = t.st[a + 3]
            if argcL < 0 || argcL > 4096 { throw VmFault(chCode("StrPrint"), "bad argument count \(argcL)") }
            let argc = Int(argcL)
            var args = [Int64](repeating: 0, count: argc)
            if argc > 0 { let p = try mem.check(argv, argc * 8); for i in 0..<argc { args[i] = mem.ld8(p + i * 8) } }
            let r = try self.k.fmt.format(try mem.readStrBytes(fmt), args, 0, argc)
            if dst == 0 { return try self.newStr(r) } else { let p = try mem.check(dst, r.count + 1); mem.writeBytes(p, r); mem.st1(p + r.count, 0); return dst }
        }
        reg("StrPrint") { t, a, n in
            let mem = self.mem
            let dst = t.st[a]
            let r = try self.format(t, t.st[a + 1], a + 2, n - 2)
            if dst == 0 { return try self.newStr(r) } else { let p = try mem.check(dst, r.count + 1); mem.writeBytes(p, r); mem.st1(p + r.count, 0); return dst }
        }
        reg("CatPrint") { t, a, n in
            let mem = self.mem
            let dst = t.st[a]
            let r = try self.format(t, t.st[a + 1], a + 2, n - 2)
            let p0 = try mem.check(dst, 1)
            let p = p0 + (try mem.strLen(p0))
            _ = try mem.check(Int64(p), r.count + 1)
            mem.writeBytes(p, r); mem.st1(p + r.count, 0)
            return dst
        }
        reg("MStrPrint") { t, a, n in try self.newStr(try self.format(t, t.st[a], a + 1, n - 1)) }
        reg("Sprite") { t, a, _ in
            let elems = t.st[a]
            let bounds = try self.mem.malloc(32)
            var dc: Int64 = 0
            defer { if dc != 0 { _ = try? self.k.callHolyC("DCDel", dc) }; try? self.mem.free(Int64(bounds)) }
            _ = try self.k.callHolyC("SpriteExtents", elems, Int64(bounds), Int64(bounds + 8), Int64(bounds + 16), Int64(bounds + 24))
            let minX = self.mem.ld8(bounds), minY = self.mem.ld8(bounds + 16)
            if minX > self.mem.ld8(bounds + 8) || minY > self.mem.ld8(bounds + 24) { return 0 }
            if minX < Int64(Int32.min) || minX > Int64(Int32.max) || minY < Int64(Int32.min) || minY > Int64(Int32.max) { return 0 }
            let width = self.mem.ld8(bounds + 8) &- self.mem.ld8(bounds) &+ 1
            let height = self.mem.ld8(bounds + 24) &- self.mem.ld8(bounds + 16) &+ 1
            if width < 1 || width > 4096 || height < 1 || height > 4096 || width * height > 4 * 1024 * 1024 { throw VmKill("document sprite size") }
            dc = try self.k.callHolyC("DCNew", width, height, 0, 0)
            let blank = Int(dc)
            self.mem.fill(Int(self.mem.ld8(blank + self.k.o.dc("body"))), 255,
                Int(self.mem.ld4(blank + self.k.o.dc("width_internal"))) * Int(height))
            _ = try self.k.callHolyC("Sprite3", dc, 0 &- self.mem.ld8(bounds), 0 &- self.mem.ld8(bounds + 16), 0, elems, 0)
            let d = Int(dc)
            let w = Int(self.mem.ld4(d + self.k.o.dc("width"))), h = Int(self.mem.ld4(d + self.k.o.dc("height")))
            let stride = Int(self.mem.ld4(d + self.k.o.dc("width_internal")))
            if w <= 0 || h <= 0 || Int64(w) * Int64(h) > 4 * 1024 * 1024 { throw VmKill("document sprite size") }
            let body = try self.mem.check(self.mem.ld8(d + self.k.o.dc("body")), stride * h)
            var pixels = [UInt8](repeating: 255, count: w * h)
            for y in 0..<h { for x in 0..<w { pixels[y * w + x] = UInt8(truncatingIfNeeded: self.mem.ld1(body + y * stride + x)) } }
            let spec=t.st[a+1] != 0 ? try self.mem.readStr(t.st[a+1]) : ""
            if spec.count>4096 {throw VmKill("document sprite format limit")}
            if !spec.isEmpty {self.k.console.write(spec)}
            let slot=try self.k.console.insertSprite(pixels, w, h, Int(self.mem.ld8(bounds)), Int(self.mem.ld8(bounds + 16)),spec)
            try self.k.documents.trackSprite(elems,slot,self.mem.ld8(bounds),self.mem.ld8(bounds+8),self.mem.ld8(bounds+16),self.mem.ld8(bounds+24))
            self.k.graphicsUsed = true
            return try self.k.callHolyC("MobileDocSprite",elems,t.st[a+1])
        }
        reg("DocClear") { t, a, _ in _ = try self.k.callHolyC("MobileDocClear",t.st[a]);self.k.console.clear(); return 0 }
        reg("DocBottom") { _, _, _ in 0 }
        reg("DocTop") { _, _, _ in 0 }
        reg("DocScroll") { _, _, _ in 0 }
        reg("DocCursor") { t, a, _ in self.k.console.cursorVisible = t.st[a] != 0; return 0 }
        reg("PutExceptMsg") { _, _, _ in
            let m = self.vm.lastFault
            if let m = m, !m.isEmpty { try self.out(latin1(m)) }
            self.vm.lastFault = nil
            return 0
        }
        reg("Silent") { [unowned self] t, a, n in let old = self.silent; self.silent = n > 0 ? t.st[a] != 0 : true; return old ? 1 : 0 }
        reg("IsSilent") { [unowned self] _, _, _ in self.silent ? 1 : 0 }
        reg("SysPlatformName") { _, _, _ in Int64(try self.k.prog.stringAddr(latin1(Brand.appName))) }
        reg("Raw") { _, _, _ in 0 }
        reg("Spaces") { t, a, _ in
            try self.out([UInt8](repeating: 32, count: min(max(ti(t.st[a]), 0), 4096))); return 0
        }
    }

    // ================================================================ memory

    private func memory() {
        reg("MAlloc") { t, a, _ in Int64(try self.mem.malloc(t.st[a])) }
        reg("CAlloc") { t, a, _ in Int64(try self.mem.calloc(t.st[a])) }
        reg("Free") { t, a, _ in try self.mem.free(t.st[a]); return 0 }
        reg("MSize") { t, a, _ in try self.mem.msize(t.st[a]) }
        reg("MSize2") { t, a, _ in t.st[a] == 0 ? 0 : (try self.mem.msize(t.st[a])) &+ Int64(Arena.HDR) }
        // As Kernel/KUtils.HC: counts are 64-bit (a negative count is a huge REP count and
        // faults), the results are dst+cnt, MemCpy copies forward (REP_MOVSB) and MemCmp
        // returns -1/0/1.
        reg("MemCpy") { t, a, _ in
            let mem = self.mem
            let dst = t.st[a]; let src = t.st[a + 1]; let n = t.st[a + 2]
            if n != 0 {
                let d = try self.span(dst, n, 1); let s = try self.span(src, n, 1); let nn = Int(n)
                if d > s && d < s + nn { for i in 0..<nn { mem.st1(d + i, mem.ld1(s + i)) } } // overlapping forward copy
                else { mem.copy(d, s, nn) }
            }
            return dst &+ n
        }
        reg("MemSet") { t, a, _ in
            let mem = self.mem
            let dst = t.st[a]; let n = t.st[a + 2]
            if n != 0 { mem.fill(try self.span(dst, n, 1), ti(t.st[a + 1]) & 0xFF, Int(n)) }
            return dst &+ n
        }
        reg("MemSetU16") { t, a, _ in
            let mem = self.mem
            let dst = t.st[a]; let v = t.st[a + 1]; let n = t.st[a + 2]
            if n != 0 { let p = try self.span(dst, n, 2); for i in 0..<Int(n) { mem.st2(p + i * 2, v) } }
            return dst &+ n &* 2
        }
        reg("MemSetU32") { t, a, _ in
            let mem = self.mem
            let dst = t.st[a]; let v = t.st[a + 1]; let n = t.st[a + 2]
            if n != 0 { let p = try self.span(dst, n, 4); for i in 0..<Int(n) { mem.st4(p + i * 4, v) } }
            return dst &+ n &* 4
        }
        reg("MemSetI64") { t, a, _ in
            let mem = self.mem
            let dst = t.st[a]; let v = t.st[a + 1]; let n = t.st[a + 2]
            if n != 0 { let p = try self.span(dst, n, 8); for i in 0..<Int(n) { mem.st8(p + i * 8, v) } }
            return dst &+ n &* 8
        }
        reg("MemCmp") { t, a, _ in
            let mem = self.mem
            let n = t.st[a + 2]
            if n == 0 { return 0 }
            let p1 = try self.span(t.st[a], n, 1); let p2 = try self.span(t.st[a + 1], n, 1)
            var r: Int64 = 0
            for i in 0..<Int(n) { let x = mem.ld1(p1 + i) - mem.ld1(p2 + i); if x != 0 { r = x > 0 ? 1 : -1; break } }
            return r
        }
        reg("StrLen") { t, a, _ in t.st[a] == 0 ? 0 : Int64(try self.mem.strLen(try self.mem.check(t.st[a], 1))) }
        reg("MemUsed") { _, _, _ in self.mem.allocated }
    }

    // ================================================================ strings

    /** Checks [n] elements of [size] bytes at [addr]; a negative or oversized count faults. */
    private func span(_ addr: Int64, _ n: Int64, _ size: Int) throws -> Int {
        if n < 0 || n > Int64(Int32.max) / Int64(size) { try mem.fault(addr) }
        return try mem.check(addr, Int(n) * size)
    }

    /** -1/0/1 like Kernel/StrA.HC _STRCMP and friends. */
    private func cmp(_ a: [UInt8], _ b: [UInt8], _ n: Int, _ ci: Bool) -> Int64 {
        var i = 0
        while i < n {
            var x = i < a.count ? Int(a[i]) : 0
            var y = i < b.count ? Int(b[i]) : 0
            if ci { if x >= 97 && x <= 122 { x -= 32 }; if y >= 97 && y <= 122 { y -= 32 } }
            if x != y { return x > y ? 1 : -1 }
            if x == 0 { return 0 }
            i += 1
        }
        return 0
    }

    /** Java Character.toUpperCase on a Latin-1 code (Kotlin `equals(ignoreCase = true)`). */
    private static func upperL1(_ c: UInt8) -> Int {
        let x = Int(c)
        if x >= 97 && x <= 122 { return x - 32 }
        if x >= 0xE0 && x <= 0xFE && x != 0xF7 { return x - 32 }
        if x == 0xFF { return 0x178 }
        if x == 0xB5 { return 0x39C }
        return x
    }

    /** Kotlin String.indexOf(other, ignoreCase) on Latin-1 text. */
    private static func indexOf(_ h: [UInt8], _ n: [UInt8], _ ci: Bool) -> Int {
        if n.isEmpty { return 0 }
        if n.count > h.count { return -1 }
        var i = 0
        while i <= h.count - n.count {
            var j = 0
            while j < n.count {
                let x = h[i + j], y = n[j]
                if x != y && (!ci || upperL1(x) != upperL1(y)) { break }
                j += 1
            }
            if j == n.count { return i }
            i += 1
        }
        return -1
    }

    /** Java Character.digit(c, radix) for a Latin-1 code. */
    private static func digit(_ c: Int, _ radix: Int) -> Int {
        var v = -1
        if c >= 48 && c <= 57 { v = c - 48 } else if c >= 97 && c <= 122 { v = c - 87 } else if c >= 65 && c <= 90 { v = c - 55 }
        return v < radix ? v : -1
    }

    /** Length of the match of ^\s*[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)? in [s], or nil. */
    private static func f64Match(_ s: [UInt8]) -> Int? {
        let n = s.count
        var i = 0
        func dig(_ k: Int) -> Bool { k < n && s[k] >= 48 && s[k] <= 57 }
        while i < n && (s[i] == 32 || (s[i] >= 9 && s[i] <= 13)) { i += 1 }
        if i < n && (s[i] == 45 || s[i] == 43) { i += 1 }
        if dig(i) {
            while dig(i) { i += 1 }
            if i < n && s[i] == 46 { i += 1; while dig(i) { i += 1 } }
        } else if i < n && s[i] == 46 && dig(i + 1) {
            i += 1; while dig(i) { i += 1 }
        } else { return nil }
        var j = i
        if j < n && (s[j] == 101 || s[j] == 69) {
            j += 1
            if j < n && (s[j] == 45 || s[j] == 43) { j += 1 }
            if dig(j) { while dig(j) { j += 1 }; i = j }
        }
        return i
    }

    private func strings() {
        reg("StrCmp") { t, a, _ in self.cmp(try self.mem.readStrBytes(t.st[a]), try self.mem.readStrBytes(t.st[a + 1]), Int(Int32.max), false) }
        reg("StrICmp") { t, a, _ in self.cmp(try self.mem.readStrBytes(t.st[a]), try self.mem.readStrBytes(t.st[a + 1]), Int(Int32.max), true) }
        reg("StrNCmp") { t, a, _ in self.cmp(try self.mem.readStrBytes(t.st[a]), try self.mem.readStrBytes(t.st[a + 1]), ti(t.st[a + 2]), false) }
        reg("StrNICmp") { t, a, _ in self.cmp(try self.mem.readStrBytes(t.st[a]), try self.mem.readStrBytes(t.st[a + 1]), ti(t.st[a + 2]), true) }
        let find: (Int64, Int64, Bool) throws -> Int64 = { needle, hay, ci in
            if needle == 0 || hay == 0 { return 0 }
            let n = try self.mem.readStrBytes(needle); let h = try self.mem.readStrBytes(hay)
            let i = Natives.indexOf(h, n, ci)
            return i < 0 ? 0 : hay &+ Int64(i)
        }
        reg("StrFind") { t, a, _ in try find(t.st[a], t.st[a + 1], (t.st[a + 2] & 1) != 0) }
        reg("StrIMatch") { t, a, _ in try find(t.st[a], t.st[a + 1], true) }
        reg("StrMatch") { t, a, _ in try find(t.st[a], t.st[a + 1], false) }
        reg("Str2I64") { t, a, _ in
            let mem = self.mem
            // Port of Kernel/StrScan.HC Str2I64: signs toggle, "0b" "0d" "0x" change the
            // radix only when they cannot be digits of it, *_end_ptr is the first non-digit.
            let s = t.st[a]; let radix0 = t.st[a + 1]; let endp = t.st[a + 2]
            if s == 0 || !(2...36).contains(radix0) {
                if endp != 0 { mem.st8(try mem.check(endp, 8), s) }
                return 0
            }
            var radix = Int(radix0)
            var p = try mem.check(s, 1)
            func up(_ c: Int) -> Int { (97...122).contains(c) ? c - 0x20 : c }
            func white(_ c: Int) -> Bool { c == 9 || c == 10 || c == 13 || c == 0x1F || c == 0x20 }
            while white(Int(mem.ld1(p))) { p += 1 }
            var neg = false
            prefix: while true {
                switch Int(mem.ld1(p)) {
                case 45: p += 1; neg = !neg
                case 43: p += 1
                case 48:
                    p += 1
                    let ch = up(Int(mem.ld1(p)))
                    if ch >= 66 && (radix <= 10 || ch > 65 + radix - 11) {
                        switch ch {
                        case 66: radix = 2; p += 1
                        case 68: radix = 10; p += 1
                        case 88: radix = 16; p += 1
                        default: break
                        }
                    }
                    break prefix
                default: break prefix
                }
            }
            var v: Int64 = 0
            while true {
                let ch = up(Int(mem.ld1(p)))
                let dg: Int
                if radix > 10 && (48...57).contains(ch) { dg = ch - 48 }
                else if radix > 10 && ch >= 65 && ch <= 65 + radix - 11 { dg = ch - 65 + 10 }
                else if radix <= 10 && ch >= 48 && ch <= 48 + radix - 1 { dg = ch - 48 }
                else { dg = -1 }
                if dg < 0 { break }
                v = v &* Int64(radix) &+ Int64(dg); p += 1
            }
            if endp != 0 { mem.st8(try mem.check(endp, 8), Int64(p)) }
            return neg ? 0 &- v : v
        }
        reg("Str2F64") { t, a, _ in
            let s = t.st[a]; let endp = t.st[a + 1]
            if s == 0 { return self.f(0.0) }
            let str = try self.mem.readStrBytes(s)
            let m = Natives.f64Match(str)
            var v = 0.0
            if let m = m {
                var lo = 0
                while lo < m && (str[lo] == 32 || (str[lo] >= 9 && str[lo] <= 13)) { lo += 1 }
                v = Double(latin1(str[lo..<m])) ?? 0.0
            }
            if endp != 0 { self.mem.st8(try self.mem.check(endp, 8), s &+ Int64(m ?? 0)) }
            return self.f(v)
        }
    }

    // ================================================================ math

    /** Java Math.round(double): nearest, ties toward +infinity, saturating, NaN -> 0. */
    private static func javaRound(_ x: Double) -> Int64 {
        if x.isNaN { return 0 }
        var r = x.rounded(.down)
        if x - r >= 0.5 { r += 1 }
        if r >= 9.223372036854775807E18 { return Int64.max }
        if r <= -9.223372036854775808E18 { return Int64.min }
        return Int64(r)
    }

    /**
     * Kotlin Array.sortWith (java.util.TimSort). Arrays shorter than 32 use the
     * exact TimSort path (run detection + binary insertion sort), so comparator
     * calls happen in the same order as on the JVM. Longer arrays use a stable
     * merge sort (same result for consistent comparators).
     */
    private static func sortWith<T>(_ a: inout [T], _ c: (T, T) throws -> Int) throws {
        let n = a.count
        if n < 2 { return }
        if n < 32 {
            // countRunAndMakeAscending
            var runHi = 1
            if runHi < n {
                runHi += 1
                if try c(a[1], a[0]) < 0 {
                    while runHi < n, try c(a[runHi], a[runHi - 1]) < 0 { runHi += 1 }
                    a[0..<runHi].reverse()
                } else {
                    while runHi < n, try c(a[runHi], a[runHi - 1]) >= 0 { runHi += 1 }
                }
            }
            // binarySort
            var start = runHi
            while start < n {
                let pivot = a[start]
                var left = 0, right = start
                while left < right {
                    let mid = (left + right) >> 1
                    if try c(pivot, a[mid]) < 0 { right = mid } else { left = mid + 1 }
                }
                var i = start
                while i > left { a[i] = a[i - 1]; i -= 1 }
                a[left] = pivot
                start += 1
            }
            return
        }
        var src = a
        var dst = a
        var width = 1
        while width < n {
            var lo = 0
            while lo < n {
                let mid = min(lo + width, n), hi = min(lo + 2 * width, n)
                var i = lo, j = mid, k = lo
                while i < mid && j < hi {
                    if try c(src[j], src[i]) < 0 { dst[k] = src[j]; j += 1 } else { dst[k] = src[i]; i += 1 }
                    k += 1
                }
                while i < mid { dst[k] = src[i]; i += 1; k += 1 }
                while j < hi { dst[k] = src[j]; j += 1; k += 1 }
                lo = hi
            }
            swap(&src, &dst)
            width *= 2
        }
        a = src
    }

    private func math() {
        func m1(_ name: String, _ op: @escaping (Double) -> Double) { reg(name) { t, a, _ in self.f(op(d(t.st[a]))) } }
        m1("Sin") { FdLibm.sin($0) }; m1("Cos") { FdLibm.cos($0) }; m1("Tan") { FdLibm.tan($0) }
        m1("ATan") { FdLibm.atan($0) }; m1("ASin") { FdLibm.asin($0) }; m1("ACos") { FdLibm.acos($0) }
        m1("Sinh") { FdLibm.sinh($0) }; m1("Cosh") { FdLibm.cosh($0) }; m1("Tanh") { FdLibm.tanh($0) }
        m1("Sqrt") { $0.squareRoot() }; m1("Exp") { FdLibm.exp($0) }; m1("Ln") { FdLibm.log($0) }
        m1("Log2") { FdLibm.log($0) / FdLibm.log(2.0) }; m1("Log10") { FdLibm.log10($0) }
        m1("Pow10") { FdLibm.pow(10.0, $0) }; m1("Floor") { floor($0) }; m1("Ceil") { ceil($0) }
        m1("Round") { $0.rounded(.toNearestOrEven) }; m1("Trunc") { $0 < 0 ? ceil($0) : floor($0) }
        m1("Abs") { Swift.abs($0) }
        reg("Arg") { t, a, _ in self.f(FdLibm.atan2(d(t.st[a + 1]), d(t.st[a]))) }
        reg("Pow") { t, a, _ in self.f(templePow(d(t.st[a]), d(t.st[a + 1]))) }
        reg("ToI64") { t, a, _ in f2i(d(t.st[a])) }
        reg("ToF64") { t, a, _ in self.f(Double(t.st[a])) }
        reg("ToBool") { t, a, _ in self.b(t.st[a] != 0) }
        // Kernel/KMathB.HC: each task's own seed (Kernel.nextRand); Rand is (res&0x3FFFFFFFFFFFFFFF)/ToF64(1<<62)
        reg("Rand") { t, _, _ in self.f(Double(self.k.nextRand(t) & 0x3FFFFFFFFFFFFFFF) / 4611686018427387904.0) }
        reg("RandI16") { t, _, _ in Int64(Int16(truncatingIfNeeded: self.k.nextRand(t))) }
        reg("RandU16") { t, _, _ in self.k.nextRand(t) & 0xFFFF }
        reg("RandI32") { t, _, _ in Int64(Int32(truncatingIfNeeded: self.k.nextRand(t))) }
        reg("RandU32") { t, _, _ in self.k.nextRand(t) & 0xFFFFFFFF }
        reg("RandI64") { t, _, _ in self.k.nextRand(t) }
        reg("RandU64") { t, _, _ in self.k.nextRand(t) }
        // Kernel/KMathB.HC: returns the new seed (timer-based for 0)
        // Kernel/KMathB.HC Seed(seed=0, task=NULL): returns the new seed (timer-based for 0)
        reg("Seed") { t, a, n in try self.k.seed(t, t.st[a], n > 1 ? t.st[a + 1] : 0) }
        let bitAddr: (HTask, Int) throws -> (Int, Int) = { t, a in
            let bit = t.st[a + 1]
            let addr = t.st[a] &+ (bit &>> 3)
            return (try self.mem.check(addr, 1), Int(bit & 7))
        }
        reg("Bt") { t, a, _ in let (p, bi) = try bitAddr(t, a); return ushr(self.mem.ld1(p), bi) & 1 }
        reg("Bts") { t, a, _ in let (p, bi) = try bitAddr(t, a); let o = self.mem.ld1(p); self.mem.st1(p, o | (Int64(1) << bi)); return ushr(o, bi) & 1 }
        reg("Btr") { t, a, _ in let (p, bi) = try bitAddr(t, a); let o = self.mem.ld1(p); self.mem.st1(p, o & ~(Int64(1) << bi)); return ushr(o, bi) & 1 }
        reg("Btc") { t, a, _ in let (p, bi) = try bitAddr(t, a); let o = self.mem.ld1(p); self.mem.st1(p, o ^ (Int64(1) << bi)); return ushr(o, bi) & 1 }
        reg("Bsf") { t, a, _ in let v = t.st[a]; return v == 0 ? -1 : Int64(v.trailingZeroBitCount) }
        reg("Bsr") { t, a, _ in let v = t.st[a]; return v == 0 ? -1 : Int64(63 - v.leadingZeroBitCount) }
        reg("BFieldExtU32") { t, a, _ in
            let mem = self.mem
            let bit = t.st[a + 1]; let size = ti(t.st[a + 2])
            let p = try mem.check(t.st[a] &+ (bit &>> 3), 8)
            var v: Int64 = 0
            for i in 0..<5 { v = v | (mem.ld1(p + i) << (8 * i)) }
            return ushr(v, Int(bit & 7)) & (size >= 32 ? 0xFFFFFFFF : (Int64(1) &<< Int64(size)) &- 1)
        }
        reg("BFieldOrU32") { t, a, _ in
            let mem = self.mem
            let bit = t.st[a + 1]; let pat = t.st[a + 2] & 0xFFFFFFFF
            let p = try mem.check(t.st[a] &+ (bit &>> 3), 5)
            let v = pat << Int(bit & 7)
            for i in 0..<5 { mem.st1(p + i, mem.ld1(p + i) | (ushr(v, 8 * i) & 0xFF)) }
            return 0
        }
        reg("BCnt") { t, a, _ in Int64(t.st[a].nonzeroBitCount) }
        reg("QSortI64") { t, a, _ in
            let mem = self.mem
            let base = t.st[a]; let nL = t.st[a + 1]; let fp = t.st[a + 2]
            if nL > 1 {
                let p = try self.span(base, nL, 8); let n = Int(nL)
                var arr = (0..<n).map { mem.ld8(p + $0 * 8) }
                try Natives.sortWith(&arr) { x, y in
                    let r = try self.vm.callFunction(t, fp, x, y)
                    return r < 0 ? -1 : (r > 0 ? 1 : 0)
                }
                for i in 0..<n { mem.st8(p + i * 8, arr[i]) }
            }
            return 0
        }
        reg("QSort") { t, a, _ in
            let mem = self.mem
            let base = t.st[a]; let nL = t.st[a + 1]; let wL = t.st[a + 2]; let fp = t.st[a + 3]
            if nL > 1 && wL > 0 {
                if wL > Int64(Int32.max) || nL > Int64(Int32.max) / wL { try mem.fault(base) }
                let n = Int(nL); let w = Int(wL)
                let p = try mem.check(base, n * w)
                let tmp1 = try mem.malloc(Int64(w)); let tmp2 = try mem.malloc(Int64(w))
                var items = (0..<n).map { mem.readBytes(p + $0 * w, w) }
                do {
                    try Natives.sortWith(&items) { x, y in
                        mem.writeBytes(tmp1, x); mem.writeBytes(tmp2, y)
                        let r = try self.vm.callFunction(t, fp, Int64(tmp1), Int64(tmp2))
                        return r < 0 ? -1 : (r > 0 ? 1 : 0)
                    }
                } catch {
                    try mem.free(Int64(tmp1)); try mem.free(Int64(tmp2))
                    throw error
                }
                try mem.free(Int64(tmp1)); try mem.free(Int64(tmp2))
                for i in 0..<n { mem.writeBytes(p + i * w, items[i]) }
            }
            return 0
        }
    }

    // ================================================================ time

    private func time() {
        reg("Sleep") { t, a, _ in
            let ms = t.st[a]
            if t.nestLevel > 0 { return 0 }
            else if t.resumed { t.resumed = false; return 0 }
            else if ms <= 0 && t.speakerTask {
                // TempleOS's SoundEffectTask (Adam/ASnd.HC) compares its pause t, in ms, with tS, in seconds,
                // so for its last second (all of a short Noise) it calls Sleep(0) = Yield and retunes the
                // speaker as fast as its CPU runs. How that sounded depended on the machine (each retune
                // restarts the PIT; docs/audio/TEMPLEOS_AUDIO_FIDELITY.md §7); here the loop waits for the next
                // jiffy instead of spinning: it still ends at its timeout and retunes about 1000 times a second,
                // without a core at 100%.
                t.wakeAt = TempleClock.jiffyStartNs(TempleClock.jiffyAt(self.k.taskNow(t)) &+ 1); self.k.block(t, Kernel.SLEEP); return 0
            }
            else if ms <= 0 { t.yieldReq = true; t.lateNs = 0; return 0 }
            // Kernel/KMisc.HC: SleepUntil(cnts.jiffies+mS*JIFFY_FREQ/1000), so a Sleep ends on a jiffy: a loop
            // that sleeps after some work keeps its period (the work done within the jiffy costs no time)
            else { t.wakeAt = TempleClock.jiffyStartNs(TempleClock.jiffyAt(self.k.taskNow(t)) &+ ms &* TempleClock.JIFFY_FREQ / 1000); self.k.block(t, Kernel.SLEEP); return 0 }
        }
        reg("Yield") { t, _, _ in if t.nestLevel == 0 { t.yieldReq = true; t.lateNs = 0 }; return 0 }
        reg("Refresh") { t, a, _ in
            if t.nestLevel > 0 { return 0 }
            else if t.resumed { t.resumed = false; return 0 }
            else {
                t.blockToken = self.k.frameCount &+ max(t.st[a], 1) &- 1
                self.k.block(t, Kernel.WAIT_FRAME); return 0
            }
        }
        reg("tS") { t, _, _ in self.f(Double(self.k.taskNow(t)) / 1e9) }
        reg("GetTSC") { t, _, _ in self.k.taskNow(t) }
        reg("SysTimerRead") { t, _, _ in self.k.taskNow(t) / 838 }
        reg("Now") { _, _, _ in Dates.fromEpochMillis(self.k.env.epochMillis(), self.k.env.utcOffsetMillis()) }
        reg("Busy") {t,a,_ in
            try self.k.vga.sync()
            if t.nestLevel>0 || t.resumed {t.resumed=false;return 0}
            t.wakeAt=self.k.taskNow(t)+min(max(t.st[a],0),60_000_000)*1000;self.k.block(t,Kernel.SLEEP);return 0
        }
    }

    // ================================================================ exceptions

    private func exceptions() {
        reg("throw") { t, a, _ in
            self.vm.lastFault = nil
            t.faultPc = t.pc
            throw VmFault(t.st[a], "")
        }
        reg("Break") { _, _, _ in throw VmFault(chCode("Break"), "") }
        reg("BreakLock") { _, _, _ in 1 }
        reg("BreakUnlock") { _, _, _ in 1 }
    }

    // ================================================================ input

    /** Removes and returns the first message matching [mask], discarding others before it. */
    private func takeMsg(_ mask:Int64) -> Kernel.Msg? {k.takeMessage(mask)}

    private func waitMsg(_ t: HTask) { t.resumed = false; k.block(t, Kernel.WAIT_MSG) }

    private func keyDownOnly(_ ch:Bool) -> Kernel.Msg? {
        while let message=k.takeMessage(1 << 2) {if !ch || message.a1 != 0 {return message}}
        return nil
    }

    private func input() {
        reg("GetChar") { t, a, _ in
            let mem = self.mem
            guard let m = self.keyDownOnly(true) else { if t.nestLevel == 0 { self.waitMsg(t) }; return 0 }
            if t.st[a] != 0 { mem.st8(try mem.check(t.st[a], 8), m.a2) }
            if t.st[a + 1] != 0 && m.a1 >= 32 && m.a1 <= 255 { try self.out([UInt8(truncatingIfNeeded: m.a1)]) }
            return m.a1
        }
        reg("GetKey") { t, a, _ in
            let mem = self.mem
            guard let m = self.keyDownOnly(false) else { if t.nestLevel == 0 { self.waitMsg(t) }; return 0 }
            if t.st[a] != 0 { mem.st8(try mem.check(t.st[a], 8), m.a2) }
            if t.st[a + 1] != 0 && m.a1 >= 32 && m.a1 <= 255 { try self.out([UInt8(truncatingIfNeeded: m.a1)]) }
            return m.a1
        }
        reg("ScanKey") { t, a, _ in
            let mem = self.mem
            guard let m = self.keyDownOnly(false) else {
                // Kernel/SerialDev/Message.HC: no key sets *_ch and *_scan_code to 0
                if t.st[a] != 0 { mem.st8(try mem.check(t.st[a], 8), 0) }
                if t.st[a + 1] != 0 { mem.st8(try mem.check(t.st[a + 1], 8), 0) }
                return 0
            }
            if t.st[a] != 0 { mem.st8(try mem.check(t.st[a], 8), m.a1) }
            if t.st[a + 1] != 0 { mem.st8(try mem.check(t.st[a + 1], 8), m.a2) }
            return 1
        }
        reg("GetMsg") { t, a, _ in
            let mem = self.mem
            let mask = t.st[a + 2]
            guard let m = self.takeMsg(mask) else { if t.nestLevel == 0 { self.waitMsg(t) }; return 0 }
            if t.st[a] != 0 { mem.st8(try mem.check(t.st[a], 8), m.a1) }
            if t.st[a + 1] != 0 { mem.st8(try mem.check(t.st[a + 1], 8), m.a2) }
            return Int64(m.code)
        }
        reg("ScanMsg") { t, a, _ in
            let mem = self.mem
            guard let m = self.takeMsg(t.st[a + 2]) else {
                // no message: *_arg1 and *_arg2 are set to 0 (Kernel/SerialDev/Message.HC)
                if t.st[a] != 0 { mem.st8(try mem.check(t.st[a], 8), 0) }
                if t.st[a + 1] != 0 { mem.st8(try mem.check(t.st[a + 1], 8), 0) }
                return 0
            }
            if t.st[a] != 0 { mem.st8(try mem.check(t.st[a], 8), m.a1) }
            if t.st[a + 1] != 0 { mem.st8(try mem.check(t.st[a + 1], 8), m.a2) }
            return Int64(m.code)
        }
        reg("FlushMsgs") { _, _, _ in self.k.clearMessages(); return 0 }
        // the same 256-message bound as posted input (Kernel.enqueue): `while (1) Msg(0,0,0);` grew host memory without limit
        reg("Msg") {t,a,_ in self.k.enqueueTo(t,Kernel.Msg(Int(t.st[a]),t.st[a+1],t.st[a+2]));return 0}

        // Kernel/SerialDev/Mouse.HC MsSet: moves the pointer (and wheel and buttons); like the hardware,
        // the window manager then queues a move message (Zing aims the bow with it, BattleLines sets the
        // wheel to 25 for its command force)
        reg("MsSet") { t, a, _ in
            let k = self.k, mem = self.mem, ms = k.o.msAddr
            var x = t.st[a], y = t.st[a + 1], z = t.st[a + 2]
            let l = t.st[a + 3], r = t.st[a + 4]
            if !(x >= 0 && x < Int64(Kernel.W)) { x = mem.ld8(ms + k.o.msPos) }
            if !(y >= 0 && y < Int64(Kernel.H)) { y = mem.ld8(ms + k.o.msPos + 8) }
            if z == Int64.max { z = mem.ld8(ms + k.o.msPos + 16) }
            let lb = (l == 0 || l == 1) ? l != 0 : mem.ld1(ms + k.o.msLb) != 0
            let rb = (r == 0 || r == 1) ? r != 0 : mem.ld1(ms + k.o.msRb) != 0
            k.msUpdate(x, y, z, lb, rb)
            return 0
        }
        reg("Char2ScanCode") { t, a, _ in Int64(Keys.char2ScanCode(ti(t.st[a]))) }
        reg("ScanCode2Char") { t, a, _ in Int64(Keys.scanCode2Char(t.st[a])) }
        // GetStr, GetS, GetI64 and GetF64 are the original HolyC (Prelude.HC) over this reader
        reg("MobileGetStr2") { t, a, _ in
            if let s = try self.lineInput(t, ti(t.st[a])) { return try self.newStr(s) }
            return 0
        }
    }

    // line editing state for MobileGetStr2 (per kernel; one reader at a time)
    private var lineBuf: [UInt8] = []
    private var lineDone: [UInt8] = []
    private var lineActive = false

    /**
     * Collects a line from key messages like Adam/DolDoc/DocGet.HC DocGetStr2: ENTER ends it, ESC is
     * ignored (it would run the document entry under the cursor; a prompt has none), SHIFT-ESC
     * returns "" or ends the task with GSF_SHIFT_ESC_EXIT, and with GSF_WITH_NEW_LINE ENTER starts a
     * new line and ESC ends the text. Blocks until done; returns nil while waiting.
     */
    private func lineInput(_ t: HTask, _ flags: Int) throws -> [UInt8]? {
        if t.nestLevel > 0 { return [] }
        if !lineActive { lineActive = true; lineBuf.removeAll(); lineDone.removeAll(); k.console.setInput("", 0) }
        let multi = flags & Natives.GSF_WITH_NEW_LINE != 0
        while true {
            guard let m = keyDownOnly(false) else { break }
            let ch = ti(m.a1)
            if ch == Keys.CH_SHIFT_ESC {
                // the typed text stays on the screen, as in the TempleOS document
                lineActive = false
                k.console.setInput(nil, 0)
                try out(lineBuf)
                if flags & Natives.GSF_SHIFT_ESC_EXIT != 0 {
                    t.state = Kernel.DEAD; t.blocked = true; k.taskEnded(t, nil)
                }
                return []
            } else if ch == Keys.CH_ESC {
                if multi {
                    lineActive = false
                    k.console.setInput(nil, 0)
                    try out(lineBuf)
                    lineDone += lineBuf
                    return lineDone
                }
            } else if ch == 10 || ch == 13 {
                try out(lineBuf + [10])
                if multi {
                    lineDone += lineBuf + [10]; lineBuf.removeAll()
                } else {
                    lineActive = false
                    k.console.setInput(nil, 0)
                    return lineBuf
                }
            } else if ch == 8 {
                if !lineBuf.isEmpty { lineBuf.removeLast() }
            } else if ch >= 32 && ch <= 255 {
                lineBuf.append(UInt8(ch))
            }
            k.console.setInput(latin1(lineBuf), lineBuf.count)
        }
        waitMsg(t)
        return nil
    }

    // ================================================================ tasks & windows

    private func tasks() {
        reg("Spawn") { t, a, _ in
            let k = self.k
            let fp = t.st[a]; let data = t.st[a + 1]; let nameP = t.st[a + 2]
            let name = nameP != 0 ? try self.mem.readStr(nameP) : "Task"
            let parentFs = t.st[a + 4]
            let parent = parentFs != 0 ? (k.taskByFs(parentFs) ?? t) : t
            // TempleOS has no task cap (memory is the limit; each task gets a 256 KiB stack, MEM_DFT_STK).
            // BomberGolf spawns a 3 s Noise task per bomb, about 90 at once while SPACE repeats; the
            // program's memory limit bounds them here too, this cap only bounds host memory
            if k.tasks.count >= Natives.MAX_TASKS { throw VmFault(chCode("TooMany"), "too many tasks") }
            let nt = try k.newTask(name, parent)
            // an invalid function pointer must not leave a runnable task without a frame
            do { try self.vm.pushCall(nt, fp, [data]) } catch let e as VmFault { k.taskEnded(nt, nil); throw e }
            nt.speakerTask = fp != 0 && fp == k.soundEffectFp
            return Int64(nt.fsAddr)
        }
        reg("Kill") { t, a, _ in
            let k = self.k
            if let target = k.taskByFs(t.st[a]) {
                if target === t { k.block(t, Kernel.DEAD); t.blocked = true; k.taskEnded(t, nil) }
                else { k.taskEnded(target, nil) }
            }
            return 0
        }
        reg("Exit") { t, _, _ in t.state = Kernel.DEAD; t.blocked = true; self.k.taskEnded(t, nil); return 0 }
        reg("TaskValidate") { t, a, _ in self.b(self.k.taskByFs(t.st[a]).map { $0.state != Kernel.DEAD } ?? false) }
        reg("Suspend") { t, a, _ in
            let target = t.st[a] == 0 ? t : self.k.taskByFs(t.st[a])
            if let target = target {
                if t.st[a + 1] != 0 { target.state = Kernel.SUSPENDED; if target === t { t.blocked = true } }
                else if target.state == Kernel.SUSPENDED { target.state = Kernel.READY }
            }
            return 0
        }
        // one window per kernel: nothing to raise or focus. WinMax/WinBorder/WinHorz/WinVert and
        // SettingsPush/SettingsPop are the original TempleOS HolyC (Prelude.HC).
        for n in ["WinToTop", "MenuPop"] {
            reg(n) { _, _, _ in 0 }
        }
        reg("WinFocus") {t,a,_ in self.k.focus(t.st[a]==0 ? t : self.k.taskByFs(t.st[a]));return 0}
        reg("AutoComplete") { _, _, _ in 0 }
        reg("MenuPush") { _, _, _ in 0 }
        reg("MenuEntryFind") { _, _, _ in 0 }
        reg("JobQue") { t, a, _ in
            // run synchronously: TempleOS queues to another core
            let fp = t.st[a]; let data = t.st[a + 1]
            let result=try self.vm.callFunction(t, fp, data)
            let job=try self.mem.calloc(Int64(self.k.prog.classes["CJob"]!.size));self.mem.st8(job+self.k.o.member("CJob","res"),result);return Int64(job)
        }
        reg("JobResGet") {t,a,_ in if t.st[a]==0 {return 0};let job=try self.mem.check(t.st[a],self.k.prog.classes["CJob"]!.size);let result=self.mem.ld8(job+self.k.o.member("CJob","res"));try self.mem.free(t.st[a]);return result}
        reg("mp_cnt") { _, _, _ in 1 }
    }



    // ================================================================ sound

    /** CTRL-ALT-M (Kernel/KeyDev.HC CtrlAltM: Mute(!IsMute)). */
    func toggleMute() { _ = mute(nil, !muted) }

    /** Kernel/KMisc.HC Mute: muting turns the speaker off (Snd) and then sets the flag; unmuting only clears it. */
    private func mute(_ t: HTask?, _ v: Bool) -> Bool {
        let o = muted
        if v && !muted { speakerOff(t) }
        muted = v
        return o
    }

    private func speakerOff(_ t: HTask?) { setOna(0); k.speakerChanges &+= 1; k.speaker(t, 0.0) }

    /** scrncast.ona in the arena (Kernel/KGlbls.HC CScrnCastGlbls scrncast), resolved once the prelude is compiled. */
    private lazy var scrncastOna: Int = k.o.global("scrncast") + k.o.member("CScrnCastGlbls", "ona")

    /** Kernel/KMisc.HC Snd keeps the ona in scrncast.ona, which programs read (ToTheFront: while (scrncast.ona) Yield;). */
    private func setOna(_ ona: Int) { lastOna = ona; mem.st1(scrncastOna, Int64(ona)) }

    /** The tone the PIT makes for [fr] Hz: the nearest count of its 1193182 Hz clock (1..65535). */
    public func pitFreq(_ fr: Double) -> Double { Natives.PIT_FREQ / min(max((Natives.PIT_FREQ / fr).rounded(), 1), 65535) }
    static let MAX_TASKS = 256
    /** Kernel/KernelA.HH SYS_TIMER_FREQ and the PC's PIT input clock. */
    static let SYS_TIMER_FREQ = Double(18333 * 65536 / 1000)
    static let PIT_FREQ = Double(TempleClock.PIT_HZ)
    // GetStr flags (Kernel/KernelA.HH)
    static let GSF_SHIFT_ESC_EXIT = 1
    static let GSF_WITH_NEW_LINE = 2

    private var muted = false
    /** The ona the PIT was last set for (Kernel/KMisc.HC scrncast.ona); Int.min after SndFreq. */
    private var lastOna = 0
    public func ona2freq(_ ona: Int) -> Double { ona == 0 ? 0.0 : 440.0 / 32 * FdLibm.pow(2.0, Double(ona) / 12.0) }

    /**
     * The tone the PC speaker makes for [ona] (Kernel/KMisc.HC Snd): TempleOS programs PIT channel 2
     * with period=ClampI64(SYS_TIMER_FREQ/Ona2Freq(ona),1,U16_MAX), where SYS_TIMER_FREQ is
     * 18333*65536/1000, but the PIT counts at 1193182 Hz, so every note is about 0.7% flat (A4 is
     * 437.06 Hz; measured on the reference VM). A negative ona is a valid I8 and plays ~18.2 Hz.
     */
    public func speakerFreq(_ ona: Int) -> Double {
        if ona == 0 { return 0.0 }
        let period = min(max((Natives.SYS_TIMER_FREQ / ona2freq(ona)).rounded(.towardZero), 1), 65535)
        return Natives.PIT_FREQ / period
    }

    private func sound() {
        // Kernel/KMisc.HC: a muted speaker ignores Snd (scrncast.ona keeps its value), and the ona already
        // playing leaves the PIT alone; anything else reprograms it until the next Snd
        reg("Snd") { t, a, _ in
            let ona = Int(Int8(truncatingIfNeeded: t.st[a]))
            if !self.muted && ona != self.lastOna {
                self.setOna(ona)
                self.k.speakerChanges &+= 1
                self.k.speaker(t, self.speakerFreq(ona))
            }
            return 0
        }
        // Not in TempleOS V5.03 (a TempleOS Mobile addition, used by no bundled program): sets the PIT to
        // the count nearest [freq] Hz, as Snd does for an ona; 0 or less turns the speaker off
        reg("SndFreq") { t, a, _ in
            let fr = d(t.st[a])
            if !self.muted {
                if fr.isFinite && fr > 0 { self.lastOna = Int.min; self.k.speakerChanges &+= 1; self.k.speaker(t, self.pitFreq(fr)) }
                else if self.lastOna != 0 { self.speakerOff(t) }
            }
            return 0
        }
        reg("Mute") { t, a, _ in self.b(self.mute(t, t.st[a] != 0)) }
        reg("IsMute") { _, _, _ in self.b(self.muted) }
        // Kernel/KMisc.HC: "Fix stuck sound": frees the sound semaphore and turns the speaker off (Snd)
        reg("SndRst") { t, _, _ in if !self.muted { self.speakerOff(t) }; return 0 }
        reg("Ona2Freq") { t, a, _ in self.f(self.ona2freq(Int(Int8(truncatingIfNeeded: t.st[a])))) }
        // Kernel/KMisc.HC: ClampI64(12*Log2(32.0/440.0*freq),1,I8_MAX); the F64 argument is truncated
        // toward zero (Compiler/BackFA.HC FISTTP)
        reg("Freq2Ona") { t, a, _ in
            let fr = d(t.st[a])
            if fr > 0 { return Int64(min(max((12 * FdLibm.log(32.0 / 440.0 * fr) / FdLibm.log(2.0)).rounded(.towardZero), 1), 127)) }
            return 0
        }
    }

    // ================================================================ files

    private func fsOrFail() throws -> VirtualFs {
        guard let fs = k.env.fs else { throw VmFault(chCode("NoFS"), "no filesystem") }
        return fs
    }

    private func abs(_ t: HTask, _ p: Int64) throws -> String? {
        let s = try mem.readStr(p)
        return Paths.normalize(try k.curDir(t), s)
    }

    private func files() {
        reg("FileRead") { t, a, _ in
            let mem = self.mem
            guard let path = try self.abs(t, t.st[a]) else { return 0 }
            guard let data = self.k.env.fs?.readFile(path) ?? self.k.env.fs?.readFile("\(path).Z") else { return 0 }
            let p = try mem.malloc(Int64(data.count) + 1)
            mem.writeBytes(p, data); mem.st1(p + data.count, 0)
            if t.st[a + 1] != 0 { mem.st8(try mem.check(t.st[a + 1], 8), Int64(data.count)) }
            return Int64(p)
        }
        reg("FileWrite") { t, a, _ in
            let mem = self.mem
            guard let path = try self.abs(t, t.st[a]) else { throw VmFault(chCode("BadPath"), "invalid path") }
            let n = ti(t.st[a + 2])
            let data = n > 0 ? mem.readBytes(try mem.check(t.st[a + 1], n), n) : []
            do { try self.fsOrFail().writeFile(path, data); return Int64(n) } catch let e as FsError {
                try self.out(latin1("$RED$\(e.message)$FG$\n")); return 0
            }
        }
        reg("FileFind") { t, a, _ in
            let p = try self.abs(t, t.st[a])
            return self.b(p != nil && ((self.k.env.fs?.exists(p!) ?? false) || (["C:/Adam/AutoComplete/ACDefs.DATA","C:/Adam/AutoComplete/ACWords.DATA.Z"].contains(p!) && self.k.prog.requiredServices.contains("dictionary"))))
        }
        // the files of a directory as a TempleOS list ("a\0b\0\0"), for PopUpPickFile (Prelude.HC)
        reg("MobileDirLst") { t, a, _ in
            guard let p = try self.abs(t, t.st[a]), let entries = self.k.env.fs?.list(p) else { return 0 }
            let names = entries.filter { !$0.isDir }.map { $0.name }.sorted()
            return try self.newStr(latin1(names.map { $0 + "\u{0}" }.joined()))
        }
        reg("Dir") { t, a, _ in
            let m = try self.mem.readStr(t.st[a])
            return try FsCommands(self.k, t).dir(m.isEmpty ? "*" : m, t.st[a + 1] != 0)
        }
        reg("Cd") { t, a, _ in
            let target = t.st[a] == 0 ? "C:/Home" : try self.mem.readStr(t.st[a])
            return self.b(try FsCommands(self.k, t).cd(target, t.st[a + 1] != 0))
        }
        reg("DirCur") { t, _, _ in try self.newStr(latin1(try self.k.curDir(t))) }
        reg("DirMk") { t, a, _ in self.b(try FsCommands(self.k, t).mkdir(try self.mem.readStr(t.st[a]))) }
        reg("Del") { t, a, _ in try FsCommands(self.k, t).del(try self.mem.readStr(t.st[a]), t.st[a + 2] != 0, t.st[a + 3] != 0) }
        reg("DelTree") { t, a, _ in try FsCommands(self.k, t).delTree(try self.mem.readStr(t.st[a])) }
        reg("Copy") { t, a, _ in self.b(try FsCommands(self.k, t).copy(try self.mem.readStr(t.st[a]), try self.mem.readStr(t.st[a + 1]))) }
        reg("Move") { t, a, _ in self.b(try FsCommands(self.k, t).move(try self.mem.readStr(t.st[a]), try self.mem.readStr(t.st[a + 1]))) }
        reg("Type") { t, a, _ in try FsCommands(self.k, t).type(try self.mem.readStr(t.st[a])); return 0 }
        reg("Ed") { t, a, _ in if let p = try self.abs(t, t.st[a]) { self.k.env.openEditor(self.k, p) }; return 0 }
        reg("Man") { t, a, _ in self.k.env.openDocument(self.k, "man:" + (try self.mem.readStr(t.st[a]))); return 0 }
        reg("Help") { _, _, _ in self.k.env.openDocument(self.k, "C:/Doc/HelpIndex.DD"); return 0 }
        reg("DocLink") { t, a, _ in if let p = try self.abs(t, t.st[a]) { self.k.env.openDocument(self.k, p) }; return 0 }
        reg("FileNameAbs") { t, a, _ in try self.newStr(latin1(try self.abs(t, t.st[a]) ?? "")) }
    }

    // ================================================================ graphics

    private var v3: [Int64] = [0, 0, 0]

    private func xyz(_ t: HTask, _ a: Int, _ f: (inout [Int64]) throws -> Void) throws {
        let px = try mem.check(t.st[a], 8); let py = try mem.check(t.st[a + 1], 8); let pz = try mem.check(t.st[a + 2], 8)
        v3[0] = mem.ld8(px); v3[1] = mem.ld8(py); v3[2] = mem.ld8(pz)
        try f(&v3)
        mem.st8(px, v3[0]); mem.st8(py, v3[1]); mem.st8(pz, v3[2])
    }

    private func graphics() {
        reg("GrUsed") { _, _, _ in self.k.graphicsUsed = true; return 0 }
        reg("GrPlot0") { t, a, _ in try self.k.gfx.plot0(t.st[a], t.st[a + 1], t.st[a + 2]); return 1 }
        reg("GrPlot") { t, a, _ in try self.k.raster.plot(t.st[a], t.st[a + 1], t.st[a + 2]) }
        reg("GrPlot1") { t, a, _ in try self.k.raster.plot1(t.st[a], t.st[a + 1], t.st[a + 2]) }
        reg("GrPeek") { t, a, _ in try self.k.raster.peek(t.st[a], t.st[a + 1], t.st[a + 2]) }
        reg("GrRect") { t, a, _ in try self.k.raster.rect(t.st[a], t.st[a + 1], t.st[a + 2], t.st[a + 3], t.st[a + 4]) }
        reg("GrHLine") { t, a, _ in try self.k.raster.hline(t.st[a], t.st[a + 1], t.st[a + 2], t.st[a + 3], t.st[a + 4], t.st[a + 5]) }
        reg("GrVLine") { t, a, _ in try self.k.raster.vline(t.st[a], t.st[a + 1], t.st[a + 2], t.st[a + 3], t.st[a + 4], t.st[a + 5]) }
        reg("GrFillTri0") { t, a, _ in try self.k.raster.fillTri0(t.st[a], t.st[a + 1], t.st[a + 2], t.st[a + 3]) }
        reg("GrBlot3") { t, a, _ in try self.k.raster.blot3(t.st[a], t.st[a + 1], t.st[a + 2], t.st[a + 3], t.st[a + 4]) }
        reg("GrPutChar") { t, a, _ in try self.k.raster.putChar(t.st[a], t.st[a + 1], t.st[a + 2], t.st[a + 3]) }
        reg("Circle") { t, a, _ in try self.k.raster.circle(t, t.st[a], t.st[a + 1], t.st[a + 2], t.st[a + 3], t.st[a + 4], t.st[a + 5], t.st[a + 6], d(t.st[a + 7]), d(t.st[a + 8])) }
        reg("DCLighting") { t, a, _ in try self.k.raster.lighting(t.st[a], t.st[a + 1], t.st[a + 2], t.st[a + 3], t.st[a + 4]); return 0 }
        reg("Mat4x4MulMat4x4Equ") { t, a, _ in try self.k.raster.mulMat4x4(t.st[a], t.st[a + 1], t.st[a + 2]) }
        reg("Mat4x4MulXYZ") { t, a, _ in
            let r = try self.mem.check(t.st[a], 128)
            try self.xyz(t, a + 1) { self.k.raster.mulXYZ(r, &$0) }; return 0
        }
        reg("DCTransform") { t, a, _ in
            let dc = try self.mem.check(t.st[a], 8)
            try self.xyz(t, a + 1) { try self.k.raster.dcTransform(dc, &$0) }; return 0
        }
        reg("DCReflect") { t, a, _ in
            let dc = try self.mem.check(t.st[a], 8)
            try self.xyz(t, a + 1) { self.k.raster.dcReflect(dc, &$0) }; return 0
        }
        reg("GrFillCircle") { t, a, _ in try self.k.raster.fillCircle(t.st[a], t.st[a + 1], t.st[a + 2], t.st[a + 3], t.st[a + 4]) }
        reg("GrFillSemiCircle") { t, a, _ in try self.k.raster.fillSemiCircle(t.st[a], t.st[a + 1], t.st[a + 2], t.st[a + 3], t.st[a + 4], t.st[a + 5]) }
        reg("GrLineFat3") { t, a, _ in try self.k.raster.lineFat3(t.st[a], t.st[a + 1], t.st[a + 2], t.st[a + 3], t.st[a + 4], t.st[a + 5], t.st[a + 6], t.st[a + 7], t.st[a + 8]) }
        reg("SpriteElemSize") { t, a, _ in try self.k.raster.spriteElemSize(t.st[a]) }
        reg("SpriteSize") { t, a, _ in try self.k.raster.spriteSize(t.st[a]) }
        reg("Line") { t, a, _ in try self.k.raster.line(t, t.st[a], t.st[a + 1], t.st[a + 2], t.st[a + 3], t.st[a + 4], t.st[a + 5], t.st[a + 6], t.st[a + 7], t.st[a + 8], t.st[a + 9]) }
        reg("GrBlot") { t, a, _ in try self.k.raster.blot(t.st[a], t.st[a + 1], t.st[a + 2], t.st[a + 3]) }
        reg("GrFloodFillRay") { t, a, _ in try self.k.gfx.floodFillRay(t.st[a], t.st[a + 1], t.st[a + 2], t.st[a + 3]) }
        reg("DefinePrint") { t, a, n in
            let name = try self.mem.readStr(t.st[a])
            let text = try self.format(t, t.st[a + 1], a + 2, n - 2)
            self.k.defines.value[name] = try Lexer(nil, self.k.defines).tokenizeFragment(latin1(text), "DefinePrint", 0)
            let p = try self.newStr(text)
            self.k.defineStrs[name] = Kernel.DefStr(Int(p), -1, 0)
            return p
        }
        // Kernel/KDefine.HC: DEFINE strings and lists
        reg("DefineLoad") { t, a, _ in
            let name = try self.mem.readStr(t.st[a])
            let text = try self.mem.readStrBytes(t.st[a + 1])
            self.k.defines.value[name] = try Lexer(nil, self.k.defines).tokenizeFragment(latin1(text), "DefineLoad", 0)
            let p = try self.newStr(text)
            self.k.defineStrs[name] = Kernel.DefStr(Int(p), -1, 0)
            return p
        }
        reg("DefineLstLoad") { t, a, _ in
            let m = self.mem
            let name = try m.readStr(t.st[a])
            let lst = try m.check(t.st[a + 1], 1)
            // entries are NUL-terminated; the list ends with an empty entry. '@' entries are skipped.
            var q = lst, cnt = 0
            while m.ld1(try m.check(Int64(q), 1)) != 0 {
                if m.ld1(q) != 64 { cnt += 1 }
                q += try m.strLen(q) + 1
            }
            let len = q + 1 - lst
            let data = try m.malloc(Int64(len))
            m.copy(data, lst, len)
            let subs = try m.malloc(Int64(max(cnt, 1) * 8))
            var p = data, i = 0
            while m.ld1(p) != 0 {
                if m.ld1(p) != 64 { m.st8(subs + i * 8, Int64(p)); i += 1 }
                p += try m.strLen(p) + 1
            }
            self.k.defineStrs[name] = Kernel.DefStr(data, cnt, subs)
            return Int64(data)
        }
        func undefinedDefine(_ name: String) -> VmFault { VmFault(chCode("UndefDef"), "Undefined Define: '\(name)'.") }
        reg("Define") { t, a, _ in
            if t.st[a] == 0 { return 0 }
            let name = try self.mem.readStr(t.st[a])
            guard let d = self.k.defineStrs[name] else { throw undefinedDefine(name) }
            return Int64(d.data)
        }
        reg("DefineSub") { t, a, _ in
            if t.st[a + 1] == 0 { return 0 }
            let name = try self.mem.readStr(t.st[a + 1])
            let r = self.k.defineSub(t.st[a], name)
            if r < 0 { throw undefinedDefine(name) }
            return Int64(r)
        }
        reg("DefineCnt") { t, a, _ in
            if t.st[a] == 0 { return -1 }
            let name = try self.mem.readStr(t.st[a])
            guard let d = self.k.defineStrs[name] else { throw undefinedDefine(name) }
            return Int64(d.cnt)
        }
        reg("GrPeek0") { t, a, _ in try self.k.gfx.peek0(t.st[a], t.st[a + 1], t.st[a + 2]) }
        reg("IsPixCovered0") { _, _, _ in 0 }
        reg("GrPaletteColorSet") { t, a, _ in self.k.gfx.paletteSet(ti(t.st[a]), t.st[a + 1]); return 0 }
        reg("GrPaletteColorGet") { t, a, _ in self.k.gfx.paletteGet(ti(t.st[a])) }
        reg("TextChar") { t, a, _ in
            self.k.graphicsUsed = true
            return self.b(try self.k.gfx.textChar(t.st[a], t.st[a + 1] != 0, t.st[a + 2], t.st[a + 3], t.st[a + 4]))
        }
        reg("TextLenStr") { t, a, _ in
            let k = self.k, mem = self.mem
            k.graphicsUsed = true
            let task = t.st[a]; let x = t.st[a + 1]; let y = t.st[a + 2]; let len = ti(t.st[a + 3]); let attr = t.st[a + 4]
            let sp = t.st[a + 5]
            var any = false
            if len > 0 && sp != 0 {
                let p = try mem.check(sp, len)
                for i in 0..<len { let r = try k.gfx.textChar(task, false, x &+ Int64(i), y, attr | mem.ld1(p + i)); any = r || any }
            }
            return self.b(any)
        }
        reg("TextLenAttrStr") { t, a, _ in
            let k = self.k, mem = self.mem
            k.graphicsUsed = true
            let task = t.st[a]; let x = t.st[a + 1]; let y = t.st[a + 2]; let len = ti(t.st[a + 3]); let ap = t.st[a + 4]
            var any = false
            if len > 0 && ap != 0 {
                let p = try mem.check(ap, len * 4)
                for i in 0..<len { let r = try k.gfx.textChar(task, false, x &+ Int64(i), y, mem.ld4(p + i * 4)); any = r || any }
            }
            return self.b(any)
        }
        reg("TextLenAttr") { t, a, _ in
            let k = self.k
            k.graphicsUsed = true
            let task = t.st[a]; let x = t.st[a + 1]; let y = t.st[a + 2]; let len = ti(t.st[a + 3]); let attr = t.st[a + 4]
            var any = false
            for i in 0..<max(len, 0) { let r = try k.gfx.textAttr(task, x &+ Int64(i), y, attr); any = r || any }
            return self.b(any)
        }
        reg("Option") { _, _, _ in 0 }
        reg("SysFont") { _, _, _ in Int64(self.k.gfx.fontAddr) }
    }
}

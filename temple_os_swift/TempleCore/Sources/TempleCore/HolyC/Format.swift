import Foundation

/**
 * Port of TempleOS `StrPrintJoin` (Kernel/StrPrint.HC, public domain).
 * Formats [fmt] with raw 64-bit arguments exactly as TempleOS does, including
 * its quirks (e.g. `%f` without a precision rounds to an integer).
 * Port of holyc/Format.kt; output must be byte-identical to the Kotlin runtime.
 */
public final class Formatter {
    private static let LEFT = 1, PAD_ZERO = 2, DECIMAL = 4, DOLLAR = 8
    private static let SLASH = 16, COMMA = 32, TRUNCATE = 64, AUX = 128
    private static let QUESTION = 256, NEG_AUX = 512, NEG = 1024, NEG_E = 2048
    private static let POS_LETS: [UInt8] = latin1(" KMGTPEZY")
    private static let NEG_LETS: [UInt8] = [32, 109 /* m */, 0xE6, 110 /* n */, 112 /* p */, 102 /* f */, 97 /* a */, 122 /* z */, 121 /* y */]
    private static let STR_PRINT = chCode("StrPrint")
    /** Largest field width, precision or repeat count honoured. */
    public static let MAX_FIELD: Int64 = 1 << 20
    /** Largest formatted string (bytes). */
    public static let MAX_OUT = 16 << 20

    // character codes
    private static let cPCT = 37, cMINUS = 45, cZERO = 48, cNINE = 57, cSTAR = 42, cDOT = 46
    private static let cSP = 32, cCOMMA = 44, cINF = 0xEC

    private let mem: Arena
    public init(_ mem: Arena) { self.mem = mem }

    /** Hook for %p/%P symbol names (address -> text), %D/%T dates. */
    public var symbolName: (Int64) -> String? = { _ in nil }
    /** %Z: entry [sub] of the DEFINE list named by the string at [nameAddr] (TempleOS DefineSub). */
    public var defineSub: (Int64, Int64) throws -> [UInt8]? = { _, _ in nil }

    /** Kotlin `format(fmt, args: LongArray, argBase, argc)`. */
    public func format(_ fmt: [UInt8], _ args: [Int64], _ argBase: Int, _ argc: Int) throws -> [UInt8] {
        try format0(fmt, { args[$0] }, argBase, argc)
    }

    /** Same, reading arguments from a task stack (`t.st`). */
    public func format(_ fmt: [UInt8], _ args: UnsafeMutablePointer<Int64>, _ argBase: Int, _ argc: Int) throws -> [UInt8] {
        try format0(fmt, { args[$0] }, argBase, argc)
    }

    private func format0(_ fmt: [UInt8], _ argAt: (Int) -> Int64, _ argBase: Int, _ argc: Int) throws -> [UInt8] {
        typealias F = Formatter
        var out: [UInt8] = []
        out.reserveCapacity(fmt.count + 16)
        var fi = 0
        var cur = 0
        func arg() throws -> Int64 {
            if cur >= argc { throw VmFault(F.STR_PRINT, "not enough arguments for format") }
            let v = argAt(argBase + cur); cur += 1
            return v
        }
        func at(_ i: Int) -> Int { i < fmt.count ? Int(fmt[i]) : 0 }
        func isDig(_ c: Int) -> Bool { c >= F.cZERO && c <= F.cNINE }
        var tmp = [UInt8](repeating: 0, count: 512)
        while fi < fmt.count {
            if out.count > Formatter.MAX_OUT { try tooLong() }
            let ch = at(fi); fi += 1
            if ch == 0 { break }
            if ch != F.cPCT { out.append(UInt8(ch)); continue }
            var flags = 0
            if at(fi) == F.cMINUS { flags |= F.LEFT; fi += 1 }
            if at(fi) == F.cZERO { flags |= F.PAD_ZERO; fi += 1 }
            var len: Int64 = 0
            while isDig(at(fi)) { len = len &* 10 &+ Int64(at(fi) - F.cZERO); fi += 1 }
            if at(fi) == F.cSTAR { fi += 1; len = try arg() }
            var decLen: Int64 = 0
            if at(fi) == F.cDOT {
                fi += 1
                while isDig(at(fi)) { decLen = decLen &* 10 &+ Int64(at(fi) - F.cZERO); fi += 1 }
                if at(fi) == F.cSTAR { fi += 1; decLen = try arg() }
                flags |= F.DECIMAL
            }
            // program-supplied widths and repeat counts are bounded (they could hang or exhaust host memory)
            len = min(len, Formatter.MAX_FIELD); decLen = min(decLen, Formatter.MAX_FIELD)
            var aux: Int64 = 0
            loop: while true {
                switch at(fi) {
                case 36: flags |= F.DOLLAR; fi += 1   // $
                case 47: flags |= F.SLASH; fi += 1    // /
                case 44: flags |= F.COMMA; fi += 1    // ,
                case 116: flags |= F.TRUNCATE; fi += 1 // t
                case 108: fi += 1                     // l
                case 104:                             // h
                    fi += 1
                    flags |= F.AUX
                    if at(fi) == 63 { fi += 1; flags |= F.QUESTION } // ?
                    else if at(fi) == F.cSTAR { fi += 1; aux = try arg() }
                    else {
                        if at(fi) == F.cMINUS { fi += 1; flags |= F.NEG_AUX }
                        while isDig(at(fi)) { aux = aux &* 10 &+ Int64(at(fi) - F.cZERO); fi += 1 }
                        if flags & F.NEG_AUX != 0 { aux = 0 &- aux }
                    }
                default: break loop
                }
            }
            var k = 0
            let code = at(fi); fi += 1
            switch code {
            case 81: // Q
                outStr(&out, mprintQ(try mem.readStrBytes(try arg()), flags), len, flags)
            case 113: // q
                outStr(&out, mprintq(try mem.readStrBytes(try arg())), len, flags)
            case 68: // D
                outStr(&out, latin1(dateStr(try arg())), len, flags)
            case 84: // T
                outStr(&out, latin1(timeStr(try arg())), len, flags)
            case 70: // F
                _ = try arg(); outStr(&out, [], len, flags)
            case 115: // s
                outStr(&out, try mem.readStrBytes(try arg()), len, flags)
            case 83: // S
                _ = try arg(); outStr(&out, [], len, flags)
            case 122: // z
                let sub = try arg(); let lst = try arg()
                outStr(&out, try lstSub(sub, lst), len, flags)
            case 90: // Z
                let sub = try arg(); let name = try arg()
                outStr(&out, try defineSub(sub, name) ?? [], len, flags)
            case 99, 67: // c C
                let v = try arg()
                var b: [UInt8] = []
                for i in 0..<8 {
                    var c = Int(ushr(v, 8 * i) & 0xFF)
                    if c == 0 { break }
                    if code == 67 && c >= 97 && c <= 122 { c -= 32 }
                    b.append(UInt8(c))
                }
                if flags & F.AUX == 0 { aux = 1 }
                if aux > Formatter.MAX_FIELD { aux = Formatter.MAX_FIELD }
                while aux > 0 { aux -= 1; outStr(&out, b, len, flags); if out.count > Formatter.MAX_OUT { try tooLong() } }
            case 112, 80: // p P
                let v = try arg()
                let s = symbolName(v) ?? ("0x" + String(UInt64(bitPattern: v), radix: 16, uppercase: true).padStart(8, "0"))
                outStr(&out, latin1(s), len, flags)
            case 100, 117: // d u
                var m = try arg()
                if code == 100 && m < 0 { flags |= F.NEG; m = 0 &- m }
                if flags & F.AUX != 0 {
                    if len == 0 { len = 12 }
                    let dv = u2f(m)
                    k = try engineering(&tmp, dv, flags, len, decLen, aux, &out)
                    continue
                }
                var um = UInt64(bitPattern: m)
                if flags & F.COMMA != 0 {
                    var cc = 3
                    while true {
                        tmp[k] = UInt8(F.cZERO + Int(um % 10)); k += 1
                        um /= 10
                        if um == 0 { break }
                        cc -= 1
                        if cc == 0 { tmp[k] = UInt8(F.cCOMMA); k += 1; cc = 3 }
                    }
                    outCommaNum(&out, tmp, k, len, flags, 3, cc)
                } else {
                    while true {
                        tmp[k] = UInt8(F.cZERO + Int(um % 10)); k += 1
                        um /= 10
                        if um == 0 { break }
                    }
                    outNum(&out, tmp, k, len, flags)
                }
            case 102: // f
                var dv = d(try arg())
                if dv < 0 { flags |= F.NEG; dv = -dv }
                if dv == Double.infinity { outInf(&out, len, flags); continue }
                outF(&out, &tmp, 0, dv, decLen, flags, len)
            case 101: // e
                if len == 0 { len = 12 }
                flags |= F.TRUNCATE
                var dv = d(try arg())
                if dv < 0 { flags |= F.NEG; dv = -dv }
                if dv == Double.infinity { outInf(&out, len, flags); continue }
                let n: Int64 = dv != 0.0 ? f2i(Foundation.floor(FdLibm.log10(dv))) : 0
                outE(&out, &tmp, dv, n, flags, len)
            case 103: // g
                if len == 0 { len = 12 }
                flags |= F.TRUNCATE
                var dv = d(try arg())
                if dv < 0 { flags |= F.NEG; dv = -dv }
                if dv == Double.infinity { outInf(&out, len, flags); continue }
                let n: Int64 = dv != 0.0 ? f2i(Foundation.floor(FdLibm.log10(dv))) : 0
                if n >= len &- 1 &- decLen || n < 0 &- (decLen &- 1) { outE(&out, &tmp, dv, n, flags, len) }
                else { outF(&out, &tmp, 0, dv, decLen, flags, len) }
            case 110: // n
                if len == 0 { len = 12 }
                flags |= F.TRUNCATE
                var dv = d(try arg())
                if dv < 0 { flags |= F.NEG; dv = -dv }
                _ = try engineering(&tmp, dv, flags, len, decLen, aux, &out)
            case 88, 120: // X x
                var m = try arg()
                let base = code == 88 ? 65 : 97
                if flags & F.COMMA != 0 {
                    var cc = 4
                    while true {
                        let dgt = Int(m & 15)
                        tmp[k] = UInt8(dgt < 10 ? F.cZERO + dgt : base + dgt - 10); k += 1
                        m = ushr(m, 4)
                        if m == 0 { break }
                        cc -= 1
                        if cc == 0 { tmp[k] = UInt8(F.cCOMMA); k += 1; cc = 4 }
                    }
                    outCommaNum(&out, tmp, k, len, flags, 4, cc)
                } else {
                    repeat {
                        let dgt = Int(m & 15)
                        tmp[k] = UInt8(dgt < 10 ? F.cZERO + dgt : base + dgt - 10); k += 1
                        m = ushr(m, 4)
                    } while m != 0
                    outNum(&out, tmp, k, len, flags)
                }
            case 98, 66: // b B
                var m = try arg()
                if flags & F.COMMA != 0 {
                    var cc = 4
                    while true {
                        tmp[k] = UInt8(F.cZERO + Int(m & 1)); k += 1
                        m = ushr(m, 1)
                        if m == 0 { break }
                        cc -= 1
                        if cc == 0 { tmp[k] = UInt8(F.cCOMMA); k += 1; cc = 4 }
                    }
                    outCommaNum(&out, tmp, k, len, flags, 4, cc)
                } else {
                    repeat { tmp[k] = UInt8(F.cZERO + Int(m & 1)); k += 1; m = ushr(m, 1) } while m != 0
                    outNum(&out, tmp, k, len, flags)
                }
            case F.cPCT: out.append(UInt8(F.cPCT))
            default: break
            }
            _ = k
        }
        return out
    }

    private func tooLong() throws -> Never { throw VmFault(Arena.OUT_MEM, "formatted string longer than \(Formatter.MAX_OUT >> 20) MiB") }

    private func outStr(_ out: inout [UInt8], _ s: [UInt8], _ len: Int64, _ flags: Int) {
        var i = Int64(s.count)
        if flags & Formatter.TRUNCATE != 0 && i > len { i = len }
        if i < 0 { i = 0 }
        if flags & Formatter.LEFT != 0 {
            out.append(contentsOf: s[0..<Int(i)])
            var j: Int64 = 0; while j < len &- i { out.append(32); j += 1 }
        } else {
            var j: Int64 = 0; while j < len &- i { out.append(32); j += 1 }
            out.append(contentsOf: s[0..<Int(i)])
        }
    }

    private func outInf(_ out: inout [UInt8], _ len0: Int64, _ flags: Int) {
        var i: Int64 = flags & Formatter.NEG != 0 ? 1 : 0
        var k: Int64 = 1
        let len = len0 < 0 ? 0 : len0
        if flags & Formatter.TRUNCATE != 0 && k + i > len { k = len - i }
        if k < 0 { k = 0 }
        while i < len - k { out.append(32); i += 1 }
        if flags & Formatter.NEG != 0 { out.append(45) }
        var x: Int64 = 0
        while x < k { out.append(UInt8(Formatter.cINF)); x += 1 } // CP437 infinity
    }

    private func outNum(_ out: inout [UInt8], _ tmp: [UInt8], _ k0: Int, _ len0: Int64, _ flags: Int) {
        var k = Int64(k0)
        var i: Int64 = flags & Formatter.NEG != 0 ? 1 : 0
        let len = len0 < 0 ? 0 : len0
        if flags & Formatter.TRUNCATE != 0 && k + i > len { k = len - i }
        if k < 0 { k = 0 }
        if flags & Formatter.PAD_ZERO != 0 {
            if flags & Formatter.NEG != 0 { out.append(45) }
            while i < len - k { out.append(48); i += 1 }
        } else {
            while i < len - k { out.append(32); i += 1 }
            if flags & Formatter.NEG != 0 { out.append(45) }
        }
        var j = k - 1
        while j >= 0 { out.append(tmp[Int(j)]); j -= 1 }
    }

    private func outCommaNum(_ out: inout [UInt8], _ tmp: [UInt8], _ k0: Int, _ len0: Int64, _ flags: Int, _ cfc: Int, _ cc0: Int) {
        var k = Int64(k0)
        var i: Int64 = flags & Formatter.NEG != 0 ? 1 : 0
        let len = len0 < 0 ? 0 : len0
        if flags & Formatter.TRUNCATE != 0 && k + i > len { k = len - i }
        if k < 0 { k = 0 }
        if flags & Formatter.PAD_ZERO != 0 {
            if flags & Formatter.NEG != 0 { out.append(45) }
            var cc: Int64 = ((len &- k &- i &+ Int64(cfc) &- Int64(cc0) &+ 1) % Int64(cfc + 1) + 1)
            while i < len - k {
                cc -= 1
                if cc == 0 {
                    out.append(44)
                    cc = Int64(cfc)
                    i += 1
                    if i >= len - k { break }
                }
                out.append(48)
                i += 1
            }
        } else {
            while i < len - k { out.append(32); i += 1 }
            if flags & Formatter.NEG != 0 { out.append(45) }
        }
        var j = k - 1
        while j >= 0 { out.append(tmp[Int(j)]); j -= 1 }
    }

    /** Kotlin `"1e$i".toDouble()` (correctly rounded decimal parse). */
    private func pow10(_ i: Int64) -> Double {
        if i > 308 { return Double.infinity }
        if i < -308 { return 0.0 }
        return Double("1e\(i)")!
    }

    @inline(__always) private func digit(_ m: inout Int64) -> UInt8 {
        let u = UInt64(bitPattern: m)
        m = Int64(bitPattern: u / 10)
        return UInt8(48 + Int(u % 10))
    }

    /** sp_out_f: tmp already holds k chars (exponent suffix, reversed). */
    private func outF(_ out: inout [UInt8], _ tmp: inout [UInt8], _ k0: Int, _ d0: Double, _ decLen0: Int64, _ flags: Int, _ len: Int64) {
        var k = k0
        var dv = d0
        let decLen = decLen0 < 0 ? 0 : decLen0
        var n = f2i(FdLibm.log10(dv))
        var i: Int64
        if decLen != 0 {
            i = decLen
            if flags & Formatter.COMMA != 0 { i -= i / 4 }
            if n &+ i > 17 { n = n &+ (i &- 17); dv *= pow10(i &- n) } else { n = 0; dv *= pow10(i) }
            i = decLen
        } else if n > 17 {
            n -= 17; dv *= pow10(0 &- n); i = 0
        } else { n = 0; i = 0 }
        var m = f2u(dv.rounded(.toNearestOrEven))
        let lim = tmp.count - 20
        if flags & Formatter.COMMA != 0 {
            var cc = i & 3
            while true {
                let oi = i; i = i &- 1
                if !(oi != 0 && k < lim) { break }
                if i > 2 {
                    let occ = cc; cc = cc &- 1
                    if occ == 0 {
                        tmp[k] = 44; k += 1
                        cc = 2
                        i = i &- 1
                        if i == 0 { break }
                    }
                }
                if n != 0 { n = n &- 1; tmp[k] = 48; k += 1 }
                else { tmp[k] = digit(&m); k += 1 }
                if i == 0 { break }
            }
        } else {
            while true {
                let oi = i; i = i &- 1
                if !(oi != 0 && k < lim) { break }
                if n != 0 { n = n &- 1; tmp[k] = 48; k += 1 }
                else { tmp[k] = digit(&m); k += 1 }
            }
        }
        if decLen != 0 { tmp[k] = 46; k += 1 }
        if flags & Formatter.COMMA != 0 {
            var cc = 3
            while k < lim {
                if n != 0 { n = n &- 1; tmp[k] = 48; k += 1 }
                else { tmp[k] = digit(&m); k += 1 }
                if m == 0 { break }
                cc -= 1
                if cc == 0 { tmp[k] = 44; k += 1; cc = 3 }
            }
        } else {
            while k < lim {
                if n != 0 { n = n &- 1; tmp[k] = 48; k += 1 }
                else { tmp[k] = digit(&m); k += 1 }
                if m == 0 { break }
            }
        }
        outNum(&out, tmp, k, len, flags)
    }

    /** Kotlin Double.toLong(): saturating, NaN -> 0. */
    private func ktToLong(_ x: Double) -> Int64 {
        if x.isNaN { return 0 }
        if x >= 9.223372036854775807E18 { return Int64.max }
        if x <= -9.223372036854775808E18 { return Int64.min }
        return Int64(x)
    }

    private func f2u(_ x: Double) -> Int64 {
        x >= 9.223372036854775807E18 ? ktToLong(x - 9.223372036854775808E18) &+ Int64.min : f2i(x)
    }

    private func outE(_ out: inout [UInt8], _ tmp: inout [UInt8], _ d0: Double, _ n0: Int64, _ flags0: Int, _ len: Int64) {
        var dv = d0
        var n = n0
        var flags = flags0
        dv /= pow10(n)
        var k = 0
        var decLen: Int64 = 0
        for _ in 0..<2 {
            let nn = n
            var e = n
            if e < 0 { e = 0 &- e; flags |= Formatter.NEG_E } else { flags &= ~Formatter.NEG_E }
            var i = 3
            while true {
                tmp[k] = UInt8(truncatingIfNeeded: 48 + Int(e % 10)); k += 1; e /= 10
                if !(e != 0) { break }
                let oi = i; i -= 1
                if oi == 0 { break }
            }
            if flags & Formatter.NEG_E != 0 { tmp[k] = 45; k += 1 }
            tmp[k] = 101; k += 1 // e
            decLen = len &- Int64(k) &- 2
            if flags & Formatter.NEG != 0 { decLen = decLen &- 1 }
            if dv != 0.0 {
                let d1 = dv + pow10(0 &- decLen) / 2
                if d1 < 1.0 { dv *= 10; n = nn &- 1; k = 0 }
                else if d1 >= 10 { dv /= 10; n = nn &+ 1; k = 0 }
                else { break }
            } else { break }
        }
        outF(&out, &tmp, k, dv, decLen, flags, len)
    }

    private func engineering(_ tmp: inout [UInt8], _ d0: Double, _ flags0: Int, _ len: Int64, _ decLen0: Int64, _ aux: Int64, _ out: inout [UInt8]) throws -> Int {
        var dv = d0
        var flags = flags0
        var decLen = decLen0
        var k = 0
        if dv == Double.infinity { outInf(&out, len, flags); return 0 }
        var n: Int64
        if dv != 0.0 {
            let f = f2i(Foundation.floor(FdLibm.log10(dv)))
            let fm = ((f % 3) + 3) % 3 // Math.floorMod(f, 3L)
            n = f &- fm
        } else { n = 0 }
        dv /= pow10(n)
        if n < 0 { n = 0 &- n; flags |= Formatter.NEG_E }
        if flags & Formatter.AUX != 0 && n >= -24 && n <= 24 {
            let i: Int64
            var j: Int64 = 0
            if flags & Formatter.QUESTION != 0 {
                i = flags & Formatter.NEG_E != 0 ? (0 &- n) / 3 : n / 3
            } else {
                j = flags & Formatter.NEG_E != 0 ? (0 &- n) &- aux : n &- aux
                dv *= pow10(j)
                i = aux / 3
            }
            if i < 0 {
                // Kotlin (-i).toInt().coerceAtMost(8); a negative index throws there
                let ix = min(Int(Int32(truncatingIfNeeded: 0 &- i)), 8)
                if ix < 0 { throw VmKill("internal error: java.lang.ArrayIndexOutOfBoundsException: Index \(ix) out of bounds for length 9") }
                tmp[k] = Formatter.NEG_LETS[ix]; k += 1
            } else if i > 0 {
                let ix = min(Int(Int32(truncatingIfNeeded: i)), 8)
                if ix < 0 { throw VmKill("internal error: java.lang.StringIndexOutOfBoundsException: index \(ix), length 9") }
                tmp[k] = Formatter.POS_LETS[ix]; k += 1
            } else if len != 0 { tmp[k] = 32; k += 1 }
            if flags & Formatter.DECIMAL == 0 {
                decLen = len &- Int64(k) &- 2
                if flags & Formatter.NEG != 0 { decLen = decLen &- 1 }
                if j > 0 { decLen = decLen &- (flags & Formatter.COMMA != 0 ? (4 &* j) / 3 : j) }
                let d1 = dv + pow10((0 &- decLen) &+ 1) / 2
                if d1 >= 10 { decLen = decLen &- 1; if d1 >= 100 { decLen = decLen &- 1 } }
            }
        } else {
            var e = n
            var i = 3
            while true {
                tmp[k] = UInt8(truncatingIfNeeded: 48 + Int(e % 10)); k += 1; e /= 10
                if !(e != 0) { break }
                let oi = i; i -= 1
                if oi == 0 { break }
            }
            if flags & Formatter.NEG_E != 0 { tmp[k] = 45; k += 1 }
            tmp[k] = 101; k += 1 // e
            if decLen == 0 {
                decLen = len &- Int64(k) &- 2
                if flags & Formatter.NEG != 0 { decLen = decLen &- 1 }
                let d1 = dv + pow10((0 &- decLen) &+ 1) / 2
                if d1 >= 10 { decLen = decLen &- 1; if d1 >= 100 { decLen = decLen &- 1 } }
            }
        }
        if flags & Formatter.COMMA != 0 {
            if len != 0 && decLen > 0 && (decLen & 3) == 0 { tmp[k] = 44; k += 1 }
            decLen = decLen &- decLen / 4
        }
        outF(&out, &tmp, k, dv, decLen, flags, len)
        return k
    }

    private func mprintQ(_ s: [UInt8], _ flags: Int) -> [UInt8] {
        var o: [UInt8] = []
        for b in s {
            let ch = Int(b)
            switch ch {
            case 36: // $
                if flags & Formatter.DOLLAR != 0 { o.append(92); o.append(100) } else { o.append(b); o.append(b) }
            case 37: // %
                o.append(b); if flags & Formatter.SLASH != 0 { o.append(b) }
            case 10: o.append(92); o.append(110)
            case 13: o.append(92); o.append(114)
            case 9: o.append(92); o.append(116)
            case 34, 92: o.append(92); o.append(b)
            default:
                if ch >= 32 && ch != 0x7F { o.append(b) } else { o.append(contentsOf: latin1(String(format: "\\x%02lX", ch))) }
            }
        }
        return o
    }

    private func mprintq(_ s: [UInt8]) -> [UInt8] {
        var o: [UInt8] = []
        var i = 0
        while i < s.count {
            let ch = Int(s[i])
            if ch == 92 && i + 1 < s.count {
                i += 1
                let c = s[i]
                switch c {
                case 110: o.append(10)
                case 114: o.append(13)
                case 116: o.append(9)
                case 100: o.append(36)
                case 120: // x
                    let hl = min(2, s.count - i - 1)
                    let h = latin1(s, i + 1, hl)
                    // Kotlin toIntOrNull(16) accepts a leading sign, as does Int(_:radix:)
                    o.append(UInt8(truncatingIfNeeded: Int(h, radix: 16) ?? 0)); i += hl
                default: o.append(c)
                }
                i += 1
            } else { o.append(UInt8(ch)); i += 1 }
        }
        return o
    }

    private func lstSub(_ sub: Int64, _ lst: Int64) throws -> [UInt8] {
        if lst == 0 || sub < 0 { return [] }
        var p = try mem.check(lst, 1)
        var n = sub
        while n > 0 {
            if mem.ld1(p) == 0 {
                if mem.ld1(p + 1) == 0 && n > 0 { return [] }
                n -= 1
            }
            p += 1
        }
        return try mem.readStrBytes(Int64(p))
    }

    // TempleOS CDate: upper 32 bits = days since year 0, lower 32 bits = fraction of day.
    private func dateStr(_ cdt: Int64) -> String {
        let (y, mo, dd) = Dates.civil(cdt)
        return String(format: "%02lld/%02lld/%02lld", mo, dd, y % 100)
    }

    private func timeStr(_ cdt: Int64) -> String {
        let secs = ushr((cdt & 0xFFFFFFFF) * 86400, 32)
        return String(format: "%02lld:%02lld:%02lld", secs / 3600, (secs / 60) % 60, secs % 60)
    }
}

public enum Dates {
    @inline(__always) private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q
    }
    @inline(__always) private static func floorMod(_ a: Int64, _ b: Int64) -> Int64 { a &- floorDiv(a, b) &* b }

    /** Days from 0000-03-01-based civil algorithm; TempleOS day 0 = Jan 1, year 0. */
    public static func civil(_ cdt: Int64) -> (Int64, Int64, Int64) {
        let days = cdt &>> 32
        // shift so that 0 = 0000-03-01 (Howard Hinnant's algorithm), TempleOS day 0 = 0000-01-01
        let z = days - 60
        let era = floorDiv(z, 146097)
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }

    /** Converts epoch milliseconds (UTC) plus a local offset into a TempleOS CDate. */
    public static func fromEpochMillis(_ ms: Int64, _ offsetMs: Int64) -> Int64 {
        let local = ms &+ offsetMs
        let dayMs: Int64 = 86_400_000
        let epochDays = floorDiv(local, dayMs)
        let frac = floorMod(local, dayMs)
        // days from 0000-01-01 to 1970-01-01 in the proleptic Gregorian calendar
        let days = epochDays &+ 719528
        return (days &<< 32) | ((frac &<< 32) / dayMs)
    }
}

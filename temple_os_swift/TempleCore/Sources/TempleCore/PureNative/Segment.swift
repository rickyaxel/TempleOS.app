import Foundation

// Port of purenative/Segment.kt.

/**
 * The data segment and symbol table of a translated program, written by the translator from what
 * the compiler did and read here instead of compiling. Loading a unit repeats the compiler's arena
 * effects in the compiler's order (globals, interned strings, binary literals, constant
 * initializers), so a native program's arena layout is the interpreted program's, and registers the
 * unit's classes, globals and functions in the [Program] symbol tables the kernel reads.
 */
public final class Segment {
    public final class Unit {
        public let name: String
        public var lines: [String] = []
        public var initIndex = -1
        /** Registry path when this unit is a RegExe compilation of the program's RegDft default. */
        public var registry: String?
        init(_ name: String) { self.name = name }
    }

    private unowned let prog: Program
    private let natives: NativeTable
    /** Translator address -> arena address, for every allocation of the loaded units. */
    private var reloc: [Int: Int] = [:]
    /** Global storage by translator address, to relocate constant writes inside them. */
    private var globalStarts: [Int] = []
    private var funcsByIndex: [Int: FuncSym] = [:]

    public init(_ prog: Program, _ natives: NativeTable) { self.prog = prog; self.natives = natives }

    public static let MAGIC = "TOSIMG 1"

    /** Translator address of a global/string/binary -> this arena's address. */
    public func a(_ buildAddr: Int) throws -> Int64 {
        guard let r = reloc[buildAddr] else { throw VmKill("segment: no allocation at 0x\(String(buildAddr, radix: 16))") }
        return Int64(r)
    }

    public static func parse(_ text: String) throws -> [Unit] {
        var out: [Unit] = []
        var cur: Unit?
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first.map({ $0.trimmingCharacters(in: .whitespaces) }) == MAGIC else { throw VmKill("not a TempleOS native image") }
        for i in 1..<lines.count {
            let l = String(lines[i])
            if l.isEmpty { continue }
            if l.hasPrefix("unit ") { let u = Unit(String(l.dropFirst(5))); out.append(u); cur = u; continue }
            guard let u = cur else { throw VmKill("segment: data before the first unit") }
            if l.hasPrefix("init ") { u.initIndex = Int(l.dropFirst(5)) ?? -1; continue }
            if l.hasPrefix("registry ") { u.registry = String(l.dropFirst(9)); continue }
            u.lines.append(l)
        }
        return out
    }

    static func hexBytes(_ s: Substring) -> [UInt8] {
        var b: [UInt8] = []
        b.reserveCapacity(s.utf8.count / 2)
        var hi: UInt8 = 0, odd = false
        for c in s.utf8 {
            let v: UInt8 = c >= 97 ? c - 87 : (c >= 65 ? c - 55 : c - 48)
            if odd { b.append(hi << 4 | v) } else { hi = v }
            odd.toggle()
        }
        return b
    }

    /** Replays [u]'s arena effects and registers its symbols; returns its init function (or nil). */
    @discardableResult
    public func load(_ u: Unit) throws -> FuncSym? {
        let mem = prog.vm.mem
        var cls: ClassType?
        for l in u.lines {
            let f = l.split(separator: " ", omittingEmptySubsequences: false)
            switch f[0] {
            case "service": try prog.requireService(String(f[1]))
            case "value": prog.uiConstants[String(f[1])]=Int64(f[2])!
            case "g":
                let build = Int(f[1], radix: 16)!, size = Int(f[2])!
                let at = try prog.allocGlobal(size)
                reloc[build] = at
                let i = globalStarts.firstIndex { $0 > build } ?? globalStarts.count
                globalStarts.insert(build, at: i)
            case "s":
                reloc[Int(f[1], radix: 16)!] = try prog.stringAddr(f.count > 2 ? Segment.hexBytes(f[2]) : [])
            case "b":
                reloc[Int(f[1], radix: 16)!] = try prog.binAddr(f.count > 2 ? Segment.hexBytes(f[2]) : [])
            case "c":
                let build = Int(f[1], radix: 16)!, w = Int(f[2])!
                var v = Int64(bitPattern: UInt64(f[3], radix: 16)!)
                if f.count > 4 && f[4] == "s" { v = try a(Int(v)) }
                guard let base = globalStarts.last(where: { $0 <= build }) else { throw VmKill("segment: constant outside any global") }
                let at = Int(try a(base)) + (build - base)
                switch w { case 1: mem.st1(at, v); case 2: mem.st2(at, v); case 4: mem.st4(at, v); default: mem.st8(at, v) }
            case "class":
                let name = String(f[1])
                let c: ClassType
                if let old = prog.classes[name], !old.defined { c = old } else { c = ClassType(name, f[3] == "1") }
                c.clearMembers()
                c.sizeValue = Int(f[2])!
                c.valueType = f[4] == "-" ? nil : Types.builtins[String(f[4])] as? IntType
                c.base = f[5] == "-" ? nil : prog.classes[String(f[5])]
                c.defined = f.count <= 6 || f[6] != "fwd"
                prog.classes[name] = c
                cls = c
            case "m":
                let fmt: [UInt8]? = f.count > 4 ? stride(from: 0, to: f[4].count, by: 2).map { i in let a = f[4].index(f[4].startIndex, offsetBy: i); return UInt8(f[4][a..<f[4].index(a, offsetBy: 2)], radix: 16)! } : nil
                cls!.addMember(Member(String(f[1]), try type(String(f[3])), Int(f[2])!, fmt))
            case "sym":
                if f[1] == "g" {
                    let name = String(f[2])
                    prog.globals[name] = GlobalSym(name, try type(String(f[4])), Int(try a(Int(f[3], radix: 16)!)))
                } else if f[1] == "f" {
                    let name = String(f[2])
                    prog.globals[name] = try function(name, Int(f[3])!, String(f[4]), f.count > 6 && f[5] == "n" ? String(f[6]) : nil)
                }
            case "fn":
                _ = try function(String(f[2]), Int(f[1])!, String(f[3]), nil)
            default:
                throw VmKill("segment: unknown record \(f[0])")
            }
        }
        if u.initIndex >= 0 && u.initIndex < prog.funcs.count && prog.funcs[u.initIndex].index == u.initIndex { return prog.funcs[u.initIndex] }
        return nil
    }

    /** The FuncSym for function [idx] (one object per index, as the compiler has). */
    private func function(_ name: String, _ idx: Int, _ type: String, _ native: String?) throws -> FuncSym {
        if let native = native {
            let fs = FuncSym(name, try self.type(type) as! FuncType)
            guard let n = natives.find(native) else { throw VmKill("segment: host function \(native) is missing") }
            fs.nativeIndex = n.index
            fs.defined = true
            return fs
        }
        if let f = funcsByIndex[idx] { return f }
        let fs = FuncSym(name, try self.type(type) as! FuncType)
        fs.defined = true
        prog.installFunc(fs, idx)
        funcsByIndex[idx] = fs
        return fs
    }

    // MARK: types: U0 I64 F64 *T [n]T $Class (R;P,P;v)

    public func type(_ s: String) throws -> HType {
        let b = Array(s.utf8)
        var p = 0
        func one() throws -> HType {
            switch b[p] {
            case UInt8(ascii: "*"): p += 1; return PtrType(try one())
            case UInt8(ascii: "["):
                var e = p
                while b[e] != UInt8(ascii: "]") { e += 1 }
                let n = Int(String(decoding: b[(p + 1)..<e], as: UTF8.self))!
                p = e + 1
                return ArrType(try one(), n)
            case UInt8(ascii: "$"):
                p += 1
                let st = p
                while p < b.count && (isIdent(b[p])) { p += 1 }
                let n = String(decoding: b[st..<p], as: UTF8.self)
                if let c = prog.classes[n] { return c }
                let c = ClassType(n, false)
                prog.classes[n] = c
                return c
            case UInt8(ascii: "("):
                p += 1
                let ret = try one()
                p += 1 // ;
                var params: [Param] = []
                while b[p] != UInt8(ascii: ";") {
                    params.append(Param("", try one(), nil))
                    if b[p] == UInt8(ascii: ",") { p += 1 }
                }
                p += 1
                let va = b[p] == UInt8(ascii: "v"); p += 1
                p += 1 // )
                return FuncType(ret, params, va)
            default:
                let st = p
                while p < b.count && ((b[p] >= 48 && b[p] <= 57) || (b[p] >= 65 && b[p] <= 90) || (b[p] >= 97 && b[p] <= 122)) { p += 1 }
                let n = String(decoding: b[st..<p], as: UTF8.self)
                guard let t = Types.builtins[n] else { throw VmKill("segment: unknown type \(n)") }
                return t
            }
        }
        let t = try one()
        return t
    }

    private func isIdent(_ c: UInt8) -> Bool { (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c >= 128 }
}

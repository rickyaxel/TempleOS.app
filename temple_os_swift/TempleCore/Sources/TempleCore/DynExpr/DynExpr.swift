import Foundation

// Port of core/dynexpr/DynExpr.kt.

/**
 * Sandbox limits of the native dynamic expression engine (the same numbers in core/dynexpr). Text beyond
 * them is rejected with a compile error before anything runs (source length) or when the parser reaches the
 * limit (tokens, nesting); the evaluation budget cannot be reached by text within the token limit and is a
 * backstop.
 */
public enum DynLimits {
    /** Bytes of text (after ExePrint's formatting). */
    public static let MAX_SOURCE_BYTES = 8192
    /** Tokens after macro expansion, all statements together. */
    public static let MAX_TOKENS = 4096
    /** Height of a statement's tree (left-associative operator sequences count once: see DFold). */
    public static let MAX_AST_HEIGHT = 256
    /** Sub-expressions being parsed inside one another (parentheses, unary operators, arguments, `` ` ``, `=`). */
    public static let MAX_PARSE_NESTING = 1024
    /** Nodes evaluated per ExePrint call. */
    public static let MAX_EVAL_OPS = 100_000
    /** The kernel's stop flag is polled every this many nodes, at every statement and every HolyC call. */
    public static let CANCEL_CHECK_EVERY = 1024
    /** Parsed and checked texts kept per kernel (least recently used are dropped). */
    public static let CACHE_ENTRIES = 32
}

/** A text compiled for one kernel: its chunks, and the symbol lookups the parse depended on. */
public final class DynCompiled {
    public let chunks: [DChunk]
    private let names: [String], syms: [Sym?], classNames: [String], classFlags: [Bool]
    init(_ chunks: [DChunk], _ names: [String], _ syms: [Sym?], _ classNames: [String], _ classFlags: [Bool]) {
        self.chunks = chunks; self.names = names; self.syms = syms; self.classNames = classNames; self.classFlags = classFlags
    }
    /** True while every name still means what it meant when the text was parsed. */
    func valid(_ prog: Program) -> Bool {
        for i in 0..<names.count where prog.globals[names[i]] !== syms[i] { return false }
        for i in 0..<classNames.count where (prog.classes[classNames[i]] != nil) != classFlags[i] { return false }
        return true
    }
}

/**
 * Native, sandboxed evaluation of the HolyC that TempleOS programs compile at run time with
 * ExePrint/ExePrint2 (Cartesian's formula, GetI64/GetF64's typed numbers), for kernels that run a program
 * as native code (Pure Swift mode). Pipeline: DynLexer -> DynParser (typed AST) -> DynChecker -> DynEval.
 * See core/dynexpr/DynExpr.kt for the supported subset; what is outside it is a compile error.
 */
public enum DynExpr {
    /** The name the interpreter compiles ExePrint text under (NativesSys.runNested). */
    public static let FILE = "C:/Home/ExePrint.HC"
    private static let OUTSIDE = "outside the native expression subset: "
    private static let LIMIT = "outside the native expression engine's limits: "

    static func outside(_ what: String, _ file: String, _ line: Int) -> CompileError { CompileError("\(OUTSIDE)\(what); Pure Terry compiles it", file, line) }
    static func limit(_ what: String, _ file: String, _ line: Int) -> CompileError { CompileError("\(LIMIT)\(what)", file, line) }
    public static func isOutside(_ e: CompileError) -> Bool { e.bare.hasPrefix(OUTSIDE) || e.bare.hasPrefix(LIMIT) }

    /** Lexes, parses and checks [src] against [scope] (no evaluation). */
    public static func compile(_ src: [UInt8], _ scope: DynScope, _ policy: @escaping DynGlobalPolicy, file: String = FILE) -> [DChunk] {
        if src.count > DynLimits.MAX_SOURCE_BYTES { return [DError(limit("longer than \(DynLimits.MAX_SOURCE_BYTES) bytes", file, 1), true)] }
        // SourceFile.parse: the text ends at a NUL; binary attachments follow
        let nul = src.firstIndex(of: 0)
        let text = nul.map { Array(src[0..<$0]) } ?? src
        let bins = nul.map { attachments(src, $0 + 1) } ?? [:]
        let parser = DynParser(DynLexer(text, bins, file), scope, file)
        let checker = DynChecker(file, policy)
        var chunks: [DChunk] = []
        while true {
            let c: DChunk
            do {
                guard let ch = try parser.parseChunk() else { break }
                if let s = ch as? DStmt { try checker.check(s) }
                c = ch
            } catch let e as CompileError {
                c = DError(e, isOutside(e))
            } catch {
                c = DError(CompileError("\(error)", file, 0), false)
            }
            chunks.append(c)
            if c is DError { break }
        }
        return chunks
    }

    private static func attachments(_ raw: [UInt8], _ from: Int) -> [Int: [UInt8]] {
        func le32(_ p: Int) -> Int { Int(Int32(bitPattern: UInt32(raw[p]) | UInt32(raw[p + 1]) << 8 | UInt32(raw[p + 2]) << 16 | UInt32(raw[p + 3]) << 24)) }
        var bins: [Int: [UInt8]] = [:]
        var p = from
        while p + 16 <= raw.count {
            let num = le32(p), size = le32(p + 8)
            p += 16
            if size < 0 || size > raw.count - p { break }
            bins[num] = Array(raw[p..<(p + size)])
            p += size
        }
        return bins
    }

    /** "Unhandled exception 'X' in WHERE: msg" -> WHERE (the format of Vm.raise and NativeRuntime). */
    static func whereOf(_ message: String, _ chName: String) -> String? {
        let prefix = "Unhandled exception '\(chName)' in "
        guard message.hasPrefix(prefix) else { return nil }
        let rest = Array(message.dropFirst(prefix.count))
        for i in 0..<rest.count where rest[i] == ")" {
            if i == rest.count - 1 { return String(rest[0...i]) }
            if i + 2 < rest.count && rest[i + 1] == ":" && rest[i + 2] == " " { return String(rest[0...i]) }
        }
        return nil
    }
}

/** Counters that show where ExePrint text was evaluated (provenance). */
public final class DynExprStats {
    /** ExePrint/ExePrint2 calls served by the engine. */
    public var evaluations: Int64 = 0
    /** Texts lexed, parsed and checked (cache misses). */
    public var compiles: Int64 = 0
    public var cacheHits: Int64 = 0
    /** Statements evaluated. */
    public var statements: Int64 = 0
    /** Calls that ended in a compile error, and how many of those were outside the subset. */
    public var compileErrors: Int64 = 0
    public var outsideSubset: Int64 = 0
}

/** The engine of one kernel: its cache (globals resolve per kernel) and counters. */
public final class DynExprEngine {
    private unowned let k: Kernel
    public let stats = DynExprStats()
    private var cache: [String: DynCompiled] = [:]
    /** Least recently used first (LinkedHashMap with access order). */
    private var order: [String] = []

    public init(_ k: Kernel) { self.k = k }

    /** Drops every cached text (the kernel's program changed). */
    public func invalidate() { cache.removeAll(); order.removeAll() }

    private func touch(_ key: String) {
        if let i = order.firstIndex(of: key) { order.remove(at: i) }
        order.append(key)
    }

    private final class Scope: DynScope {
        unowned let k: Kernel
        var names: [String] = [], syms: [Sym?] = [], classNames: [String] = [], classFlags: [Bool] = []
        init(_ k: Kernel) { self.k = k }
        func symbol(_ name: String) -> Sym? { let s = k.prog.globals[name]; names.append(name); syms.append(s); return s }
        func isClassName(_ name: String) -> Bool { let c = k.prog.classes[name] != nil; classNames.append(name); classFlags.append(c); return c }
        func isKnownMacro(_ name: String) -> Bool { let env = k.env; return DynMacros.isKnownMacro(name) { env.runtimeFile($0) } }
    }

    /** Compiles [src] for this kernel, or returns the cached result when its names still resolve alike. */
    public func compiled(_ src: [UInt8]) -> DynCompiled {
        let key = latin1(src)
        if let c = cache[key] {
            touch(key)
            if c.valid(k.prog) { stats.cacheHits += 1; return c }
        }
        stats.compiles += 1
        let scope = Scope(k)
        let prelude = k.preludeGlobals
        let kk = k
        let chunks = DynExpr.compile(src, scope, { g in !prelude.contains(g.name) && kk.prog.globals[g.name] === g })
        let c = DynCompiled(chunks, scope.names, scope.syms, scope.classNames, scope.classFlags)
        cache[key] = c
        touch(key)
        if order.count > DynLimits.CACHE_ENTRIES { cache[order.removeFirst()] = nil }
        return c
    }

    /**
     * ExePrint (rethrow = false) and ExePrint2 (rethrow = true) in a native kernel, with the interpreter's
     * behaviour (NativesSys.runNested).
     */
    public func exePrint(_ t: HTask, _ src: [UInt8], rethrow: Bool) throws -> Int64 {
        stats.evaluations += 1
        if let value=try pointerBindings(src) {return value}
        let c = compiled(src)
        var res: Int64 = 0
        let host = KernelHost(k, t)
        let eval = DynEval(host)
        for (i, chunk) in c.chunks.enumerated() {
            if let e = chunk as? DError {
                stats.compileErrors += 1
                if e.outsideSubset { stats.outsideSubset += 1 }
                k.console.write("$RED$\(e.error.message)$FG$\n")
                if rethrow { throw e.error }
                k.compileErrorCaught(t)
                return res
            } else if chunk is DEmpty {
                res = 0
            } else if let s = chunk as? DStmt {
                res = try runChunk(t, eval, host, s, i)
            }
        }
        return res
    }

    /// Runtime-selected native implementations in typed, bounded original AI tables.
    private func pointerBindings(_ src:[UInt8]) throws -> Int64? {
        if src.count>DynLimits.MAX_SOURCE_BYTES {return nil}
        let parts=latin1(src).components(separatedBy:";").filter {!$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}
        if parts.isEmpty || parts.count>128 {return nil}
        let regex=try NSRegularExpression(pattern:#"\s*([A-Za-z_][A-Za-z_0-9]*)\s*\[\s*([0-9]+)\s*]\s*=\s*&\s*([A-Za-z_][A-Za-z_0-9]*)\s*"#)
        var rows:[[String]]=[]
        for part in parts {
            let ns=part as NSString
            guard let match=regex.firstMatch(in:part,range:NSRange(location:0,length:ns.length)),match.range.length==ns.length else {return nil}
            rows.append((1...3).map {ns.substring(with:match.range(at:$0))})
        }
        var result:Int64=0
        for row in rows {
            guard let g=k.prog.globals[row[0]] as? GlobalSym,let arr=g.type as? ArrType,arr.elem.size==8,!k.preludeGlobals.contains(g.name),let f=k.prog.globals[row[2]] as? FuncSym else {return nil}
            if let fn=(arr.elem as? PtrType)?.target as? FuncType,fn.name != f.type.name {throw CompileError("Function pointer type mismatch",DynExpr.FILE,1)}
            guard let index=Int(row[1]),index>=0,index<arr.count else {throw VmFault(Arena.BAD_MEM,"Function pointer array index out of bounds")}
            result=k.prog.funcPtr(f);k.mem.st8(try k.mem.check(Int64(g.addr)+8*Int64(index),8),result);stats.statements+=1
        }
        return result
    }

    /** One chunk, framed as the interpreter's call of the compiled chunk function (Vm.callFunction + enter). */
    private func runChunk(_ t: HTask, _ eval: DynEval, _ host: KernelHost, _ s: DStmt, _ index: Int) throws -> Int64 {
        if k.vm.interrupt { throw VmKill("stopped") }
        if t.depth >= HTask.MAX_DEPTH { throw VmFault(Vm.STK_OVER, "stack overflow (call depth)") }
        let fp = (t.msp + 7) & ~7
        if fp + s.frameSize > t.mspLimit { throw VmFault(Vm.STK_OVER, "stack overflow") }
        let savedMsp = t.msp, savedDepth = t.depth, savedNest = t.nestLevel
        host.fp = fp
        t.depth = savedDepth + 1; t.msp = fp + s.frameSize; t.nestLevel = savedNest + 1
        defer {
            t.msp = savedMsp; t.depth = savedDepth; t.nestLevel = savedNest
            t.blocked = false
        }
        do {
            stats.statements += 1
            return try eval.run(s)
        } catch let c as CalleeFault {
            // a fault in a HolyC function the expression called: the interpreter's nested run reports it where it happened
            let u = c.u
            exceptCh(t, u.ch)
            throw VmFault(u.ch, u.message, whereText: DynExpr.whereOf(u.message, k.vm.chStr(u.ch)) ?? chunkWhere(index, eval.line))
        } catch let f as VmFault {
            // a fault in the expression itself (or a native it called): raised in the chunk, as Vm.raise words it
            exceptCh(t, f.ch)
            let w = chunkWhere(index, eval.line)
            let m = "Unhandled exception '\(k.vm.chStr(f.ch))' in \(w)" + (f.message.isEmpty ? "" : ": \(f.message)")
            throw VmFault(f.ch, m, whereText: w)
        }
    }

    private func chunkWhere(_ index: Int, _ line: Int) -> String { "$init:\(DynExpr.FILE)#\(index) (\(DynExpr.FILE):\(line))" }

    private func exceptCh(_ t: HTask, _ ch: Int64) {
        if t.fsAddr != 0 && k.vm.exceptChOff >= 0 {
            k.mem.st8(t.fsAddr + k.vm.exceptChOff, ch)
            k.mem.st1(t.fsAddr + k.vm.catchExceptOff, 0)
        }
    }

    /** A fault that escaped a HolyC function the expression called (Vm.callFunction's VmUncaught). */
    private struct CalleeFault: Error { let u: VmUncaught }

    /** The kernel as evaluation sees it: arena memory, natives, HolyC calls, the stop flag. */
    private final class KernelHost: DynHost {
        unowned let k: Kernel
        let t: HTask
        var fp = 0
        init(_ k: Kernel, _ t: HTask) { self.k = k; self.t = t }
        func ld(_ addr: Int, _ size: Int) -> Int64 {
            switch size { case 1: return k.mem.ld1(addr); case 2: return k.mem.ld2(addr); case 4: return k.mem.ld4(addr); default: return k.mem.ld8(addr) }
        }
        func st(_ addr: Int, _ size: Int, _ v: Int64) {
            switch size { case 1: k.mem.st1(addr, v); case 2: k.mem.st2(addr, v); case 4: k.mem.st4(addr, v); default: k.mem.st8(addr, v) }
        }
        func frameStore(_ off: Int, _ v: Int64) { k.mem.st8(fp + off, v) }
        func poll() throws { if k.vm.interrupt || k.stopRequested { throw VmKill("stopped") } }
        func call(_ fn: FuncSym, _ args: [Int64]) throws -> Int64 {
            if fn.isNative {
                // CALLN
                let nf = k.vm.natives.list[fn.nativeIndex]
                let base = t.sp
                if base + args.count > HTask.STACK_WORDS { throw VmIndexOutOfBounds() }
                for i in 0..<args.count { t.st[base + i] = args[i] }
                t.sp = base + args.count
                t.blocked = false
                defer { t.sp = base; t.blocked = false }
                let r = try nf.call(t, base, args.count)
                t.resumed = false
                return r
            }
            // CALL: one budget tick, then the function (its own ticks are counted by the call)
            k.vm.ticksExecuted &+= 1
            if k.vm.interrupt { throw VmKill("stopped") }
            do {
                return try k.vm.callFunction(t, k.prog.funcPtr(fn), args)
            } catch let u as VmUncaught { throw CalleeFault(u: u) }
        }
    }
}

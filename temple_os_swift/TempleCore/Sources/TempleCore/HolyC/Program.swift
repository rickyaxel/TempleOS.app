import Foundation

// Port of holyc/Program.kt. IntList lives in Basics.swift.

/** A host function implementation. Arguments are t.st[base until base+argc]. */
/** Where the main task's code comes from, one executable chunk at a time (TempleOS JIT order). */
public protocol ChunkSource: AnyObject {
    /** The next chunk's function (its top-level statements), or nil when the program is done. */
    func next() throws -> FuncSym?
    /** Command-line answer kind of the last chunk (Program.ANS_*). */
    var answerKind: Int { get }
}

open class Native {
    public let name: String
    public var index = -1
    public init(_ name: String) { self.name = name }
    open func call(_ t: HTask, _ base: Int, _ argc: Int) throws -> Int64 { fatalError("abstract") }
}

/** A native backed by a closure: `ClosureNative(name) { t, a, n in ... }`. */
public final class ClosureNative: Native {
    private let fn: (HTask, Int, Int) throws -> Int64
    public init(_ name: String, _ fn: @escaping (HTask, Int, Int) throws -> Int64) {
        self.fn = fn
        super.init(name)
    }
    public override func call(_ t: HTask, _ base: Int, _ argc: Int) throws -> Int64 { try fn(t, base, argc) }
}

/** Registry of host functions available to the prelude's `native` declarations. */
public final class NativeTable {
    public private(set) var list: [Native] = []
    private var byName: [String: Native] = [:]
    public init() {}
    public func add(_ n: Native) {
        n.index = list.count
        list.append(n)
        byName[n.name] = n
    }
    public func find(_ name: String) -> Native? { byName[name] }
}

/**
 * Compiled program state: symbol tables, bytecode and constant pools. Units are
 * compiled incrementally (the terminal compiles each command into the same
 * program, as the TempleOS shell does).
 */
public final class Program {
    public static let FPTR_TAG: Int64 = 0x7FFF000000000000
    public static let FPTR_NATIVE: Int64 = 0x7FFF000100000000
    public static let ANS_NONE = 0
    public static let ANS_INT = 1
    public static let ANS_F64 = 2
    public static let NATIVE_NO_COMPILE = "HolyC compilation is not available to a natively translated program"

    public unowned let vm: Vm
    public var requiredServices: Set<String> = []
    public var uiConstants: [String:Int64] = [:]
    public var serviceHandler: ((String) throws -> Void)?
    public func requireService(_ name:String) throws {if requiredServices.insert(name).inserted {try serviceHandler?(name)}}
    public var classes: [String: ClassType] = [:]
    public var globals: [String: Sym] = [:]
    public var funcs: [FuncSym] = []
    public let code = IntList(16384)
    public var consts: [Int64] = []
    private var constIndex: [Int64: Int] = [:]
    public var switchTables: [SwitchTable] = []
    /** Kotlin `val codegen = CodeGen(this)` (assigned at the end of init). */
    public private(set) var codegen: CodeGen!
    private var strings: [String: Int] = [:]

    // function metadata arrays used by the VM (indexed by FuncSym.index)
    public var fnEntry = [Int](repeating: 0, count: 256); public var fnFrame = [Int](repeating: 0, count: 256)
    public var fnNParams = [Int](repeating: 0, count: 256)
    public var fnArgc = [Int](repeating: 0, count: 256); public var fnArgv = [Int](repeating: 0, count: 256)
    public var fnParamOff = [[Int]?](repeating: nil, count: 256)
    public var konstArr: [Int64] = []

    // line table
    private var linePc = [Int](repeating: 0, count: 1024); private var lineNo = [Int](repeating: 0, count: 1024)
    private var lineFile = [Int](repeating: 0, count: 1024)
    private var lineCount = 0
    private var files: [String] = []
    private var fileIdx: [String: Int] = [:]

    public init(_ vm: Vm) {
        self.vm = vm
        codegen = CodeGen(self)
    }

    public func konst(_ v: Int64) -> Int {
        if let i = constIndex[v] { return i }
        consts.append(v); konstArr = consts
        let i = consts.count - 1
        constIndex[v] = i
        return i
    }

    public func addFunc(_ f: FuncSym) {
        if f.index >= 0 { return }
        f.index = funcs.count
        funcs.append(f)
        if f.index >= fnEntry.count {
            let n = fnEntry.count * 2
            func grow(_ a: inout [Int]) { a.append(contentsOf: [Int](repeating: 0, count: n - a.count)) }
            grow(&fnEntry); grow(&fnFrame); grow(&fnNParams)
            grow(&fnArgc); grow(&fnArgv)
            fnParamOff.append(contentsOf: [[Int]?](repeating: nil, count: n - fnParamOff.count))
        }
        fnEntry[f.index] = -1
    }

    public func registerFunc(_ f: FuncSym) {
        addFunc(f)
        let i = f.index
        fnEntry[i] = f.entry
        fnFrame[i] = f.frameSize
        fnNParams[i] = f.ftype.params.count
        fnArgc[i] = f.ftype.varargs ? f.argcSlot : -1
        fnArgv[i] = f.argvSlot
        fnParamOff[i] = f.paramOffsets
    }

    public func bindNative(_ f: FuncSym) throws {
        guard let n = vm.natives.find(f.name) else {
            throw CompileError("host function '\(f.name)' is not implemented", f.file, f.line)
        }
        f.nativeIndex = n.index
        f.defined = true
    }

    public func allocGlobal(_ size: Int) throws -> Int { try vm.mem.calloc(Int64(max(size, 8))) }

    public func stringAddr(_ b: [UInt8]) throws -> Int {
        let key = latin1(b)
        if let a = strings[key] { return a }
        let a = try vm.mem.malloc(Int64(b.count) + 1)
        vm.mem.writeBytes(a, b)
        vm.mem.st1(a + b.count, 0)
        strings[key] = a
        return a
    }

    public func binAddr(_ b: [UInt8]) throws -> Int {
        let a = try vm.mem.malloc(max(Int64(b.count), 1))
        vm.mem.writeBytes(a, b)
        return a
    }

    public func funcPtr(_ f: FuncSym) -> Int64 {
        if f.isNative { return Program.FPTR_NATIVE | Int64(f.nativeIndex) }
        addFunc(f)
        return Program.FPTR_TAG | Int64(f.index)
    }

    public func markLine(_ pc: Int, _ file: String, _ line: Int) {
        if line <= 0 { return }
        let fi: Int
        if let x = fileIdx[file] { fi = x } else { files.append(file); fi = files.count - 1; fileIdx[file] = fi }
        if lineCount > 0 && lineNo[lineCount - 1] == line && lineFile[lineCount - 1] == fi { return }
        if lineCount == linePc.count {
            linePc.append(contentsOf: [Int](repeating: 0, count: lineCount))
            lineNo.append(contentsOf: [Int](repeating: 0, count: lineCount))
            lineFile.append(contentsOf: [Int](repeating: 0, count: lineCount))
        }
        linePc[lineCount] = pc; lineNo[lineCount] = line; lineFile[lineCount] = fi
        lineCount += 1
    }

    /** Source location for a pc, e.g. "C:/Home/Test.HC:12". */
    public func `where`(_ pc: Int) -> String {
        var lo = 0, hi = lineCount - 1, best = -1
        while lo <= hi {
            let m = (lo + hi) >> 1
            if linePc[m] <= pc { best = m; lo = m + 1 } else { hi = m - 1 }
        }
        if best < 0 { return "?" }
        return "\(files[lineFile[best]]):\(lineNo[best])"
    }

    public func funcAt(_ pc: Int) -> String {
        var best: FuncSym? = nil
        for f in funcs where f.entry >= 0 && f.entry <= pc && (best == nil || f.entry > best!.entry) { best = f }
        return best?.name ?? "?"
    }

    /**
     * Compiles a source unit. Returns the hidden function containing the unit's
     * top-level statements (call it to run them).
     */
    public func compile(_ src: SourceFile, _ dir: String, _ provider: SourceProvider?, _ defines: Defines, allowNative: Bool = false) throws -> FuncSym {
        try refuseNative()
        let toks = Lexer(provider, defines) { [unowned self] n in self.globals[n] != nil || self.classes[n] != nil }.stream(src, dir)
        let parser = Parser(self, toks, allowNative)
        let initF = FuncSym("$init:\(src.name)", FuncType(Types.I64, [], false))
        initF.file = src.name; initF.line = 1
        let (stmts, frame) = try parser.parseTopLevel()
        initF.frameSize = frame
        initF.defined = true
        addFunc(initF)
        try codegen.compileFunction(initF, Block(stmts))
        return initF
    }

    /** Evaluates an expression by running it (set by the kernel). */
    public var evalAtCompileTime: ((Expr) throws -> Int64?)? = nil
    private var evalCounter = 0

    /** Compiles `return e;` into a hidden function and returns it. */
    public func compileExprFunc(_ e: Expr) throws -> FuncSym {
        try refuseNative()
        let f = FuncSym("$eval\(evalCounter)", FuncType(Types.I64, [], false))
        evalCounter += 1
        f.file = e.file; f.line = e.line; f.defined = true
        addFunc(f)
        let r = Return(e); r.file = e.file; r.line = e.line
        try codegen.compileFunction(f, r)
        return f
    }

    /**
     * Set for a native kernel (Pure Swift mode): its symbols come from the translated image
     * (purenative Segment) and nothing is ever compiled; [compile] and [session] refuse.
     */
    public var nativeMode = false

    func refuseNative() throws { if nativeMode { throw CompileError(Program.NATIVE_NO_COMPILE) } }

    /** Registers function [f] at [index] (the translated image keeps the compiler's numbering). */
    public func installFunc(_ f: FuncSym, _ index: Int) {
        while funcs.count <= index {
            let u = FuncSym("$unused\(funcs.count)", FuncType(Types.U0, [], false))
            u.index = funcs.count
            funcs.append(u)
        }
        f.index = index
        funcs[index] = f
    }

    /** Incremental compilation of a unit, one executable chunk at a time (TempleOS JIT order). */
    public final class Session: ChunkSource {
        private unowned let prog: Program
        private let src: SourceFile
        private let parser: Parser
        private var n = 0
        private let answers: Swift.Bool
        /** Command-line answer of the last compiled chunk (TempleOS Fs->answer_type): ANS_NONE, ANS_INT or ANS_F64. */
        public private(set) var answerKind = Program.ANS_NONE
        init(_ prog: Program, _ src: SourceFile, _ dir: String, _ provider: SourceProvider?, _ defines: Defines, _ answers: Swift.Bool = false) {
            self.prog = prog
            self.src = src
            self.answers = answers
            let toks = Lexer(provider, defines) { [unowned prog] nm in prog.globals[nm] != nil || prog.classes[nm] != nil }.stream(src, dir)
            parser = Parser(prog, toks, false)
        }
        /** Compiles the next chunk; returns its function, or nil when the unit is done. */
        public func next() throws -> FuncSym? {
            try prog.refuseNative()
            guard var (stmts, frame) = try parser.parseChunk() else { return nil }
            // Shell answers: like TempleOS's LexStmt2Bin, the value of a final
            // expression statement is returned so the command line can print it.
            answerKind = Program.ANS_NONE
            var ret: HType = Types.I64
            if answers, let last = stmts.last as? ExprStmt {
                let t = last.e.type
                let kind: Int
                if t is F64Type { kind = Program.ANS_F64 }
                else if t is IntType || t is PtrType || ((t as? ClassType)?.valueType != nil) { kind = Program.ANS_INT }
                else { kind = Program.ANS_NONE }
                if kind != Program.ANS_NONE {
                    answerKind = kind
                    if kind == Program.ANS_F64 { ret = F64Type.shared }
                    let r = Return(last.e); r.file = last.file; r.line = last.line
                    stmts = Array(stmts.dropLast()) + [r]
                }
            }
            let initF = FuncSym("$init:\(src.name)#\(n)", FuncType(ret, [], false))
            n += 1
            initF.file = src.name; initF.line = stmts.first?.line ?? 1
            initF.frameSize = frame
            initF.defined = true
            prog.addFunc(initF)
            try prog.codegen.compileFunction(initF, Block(stmts))
            return initF
        }
    }

    public func session(_ src: SourceFile, _ dir: String, _ provider: SourceProvider?, _ defines: Defines, answers: Swift.Bool = false) -> Session {
        Session(self, src, dir, provider, defines, answers)
    }
}

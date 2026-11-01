import Foundation

// Port of kernel/NativesSys.kt.

/**
 * System-level host functions: runtime compilation (ExePrint/ExeFile), the
 * registry (game settings and high scores), and document/task utilities.
 */
public final class NativesSys {
    /** Unowned: the kernel owns its NativesSys (avoids a retain cycle through the native closures). */
    private unowned let k: Kernel
    private var mem: Arena { k.mem }

    public init(_ k: Kernel) { self.k = k }

    private func reg(_ t: NativeTable, _ name: String, _ fn: @escaping (HTask, Int, Int) throws -> Int64) {
        t.add(ClosureNative(name, compilerErrorsAsExceptions(fn)))
    }

    public func register(_ nt: NativeTable) {
        // Compiler/CMain.HC: ExePrint catches a compile error and returns 0; ExePrint2 throws it
        // ('Compiler'), which GetI64 and GetF64 catch to ask again
        reg(nt, "ExePrint") { t, a, n in
            let src = try self.k.fmt.format(try self.mem.readStrBytes(t.st[a]), t.st, a + 1, n - 1)
            if self.k.isNative { return try self.k.dynExpr.exePrint(t, src, rethrow: false) }
            return try self.runNested(t, "C:/Home/ExePrint.HC", src, try self.k.curDir(t))
        }
        reg(nt, "ExePrint2") { t, a, n in
            let src = try self.k.fmt.format(try self.mem.readStrBytes(t.st[a]), t.st, a + 1, n - 1)
            if self.k.isNative { return try self.k.dynExpr.exePrint(t, src, rethrow: true) }
            return try self.runNested(t, "C:/Home/ExePrint.HC", src, try self.k.curDir(t), rethrow: true)
        }
        reg(nt, "ExeFile") { t, a, _ in
            if let native=self.k.native {
                guard let path=try Paths.normalize(self.k.curDir(t),self.mem.readStr(t.st[a])) else {return 0}
                let source=try native.fileSession(self.k,path);var result:Int64=0
                while let f=try source.next() {result=try self.k.vm.callFunction(t,self.k.prog.funcPtr(f))};return result
            }
            guard let p = Paths.normalize(try self.k.curDir(t), try self.mem.readStr(t.st[a])) else { return 0 }
            guard let data = self.k.env.fs?.readFile(p) else { self.k.console.write("$RED$File not found: \(p)$FG$\n"); return 0 }
            return try self.runNested(t, p, data, Paths.parent(p))
        }
        reg(nt, "RegDft") { t, a, _ in
            let path = try self.mem.readStr(t.st[a])
            let reg = self.registry()
            if reg.containsKey(path) { return 1 }
            reg[path] = try self.mem.readStr(t.st[a + 1])
            self.saveRegistry(reg)
            return 0
        }
        reg(nt, "RegExe") { t, a, _ in
            let path = try self.mem.readStr(t.st[a])
            guard let code = self.registry()[path] else { return 0 }
            if let nb = self.k.native { return try nb.regExe(self.k, t, path, code) }
            return try self.runNested(t, "C:/Home/Registry.HC", latin1(code), "C:/Home")
        }
        reg(nt, "RegWrite") { t, a, n in
            let path = try self.mem.readStr(t.st[a])
            let code = latin1(try self.k.fmt.format(try self.mem.readStrBytes(t.st[a + 1]), t.st, a + 2, n - 2))
            let reg = self.registry()
            reg[path] = code
            self.saveRegistry(reg)
            return 1
        }
        reg(nt, "RegCnt") { t, a, _ in self.registry().containsKey(try self.mem.readStr(t.st[a])) ? 1 : 0 }
        reg(nt, "MenuNew") { t, a, _ in
            let task = t.st[a + 2] != 0 ? t.st[a + 2] : Int64(t.fsAddr)
            return try self.menuNew(try self.mem.readStr(t.st[a]), t.st[a + 1], task)
        }
        reg(nt, "PopUpChoose") { t, a, _ in
            // PopUpChoose(U8 *header,U8 *footer,U8 *labels,I64 *values,I64 *bgs,I64 cnt)
            let k = self.k, mem = self.mem
            let pending = k.popup
            if t.resumed, let pending = pending, let r = pending.result {
                t.resumed = false
                k.popup = nil
                return r
            } else if t.nestLevel > 0 { return -1 } else {
                let cnt = min(max(Int(Int32(truncatingIfNeeded: t.st[a + 5])), 0), 4096)
                var items: [PopupRequest.Item] = []
                var lp = t.st[a + 2] != 0 ? try mem.check(t.st[a + 2], 1) : 0
                let vp = cnt > 0 ? try mem.check(t.st[a + 3], cnt * 8) : 0
                let bp = t.st[a + 4] != 0 && cnt > 0 ? try mem.check(t.st[a + 4], cnt * 8) : 0
                for i in 0..<cnt {
                    let lb = try mem.readStrBytes(Int64(lp))
                    lp += lb.count + 1
                    items.append(PopupRequest.Item(latin1(lb), mem.ld8(vp + i * 8), bp != 0 ? Int(Int32(truncatingIfNeeded: mem.ld8(bp + i * 8))) : -1))
                }
                let req = PopupRequest(self.stripDolDoc(try mem.readStr(t.st[a])), self.stripDolDoc(try mem.readStr(t.st[a + 1])), items)
                k.popup = req
                k.env.popupRequested(k, req)
                if let r = req.result { k.popup = nil; return r }
                else { t.resumed = false; k.block(t, Kernel.WAIT_POPUP); return 0 }
            }
        }
        reg(nt, "MPInt") { _, _, _ in 0 }
        // Kernel/KHashB.HC: named values in a task's hash table (task, default Fs), found through the parent
        // tasks' tables; each Noise/Sweep task keeps its own CSoundEffectFrame there (Adam/ASnd.HC)
        reg(nt, "FramePtr") { t, a, _ in
            guard let f = self.frameFind(self.fsArg(t, t.st[a + 1]), try self.mem.readStr(t.st[a])) else { return 0 }
            return self.framePtrs[f.fs]![f.name]!.last!
        }
        reg(nt, "FramePtrAdd") { t, a, _ in
            let fs = self.fsArg(t, t.st[a + 2]), n = try self.mem.readStr(t.st[a])
            self.framePtrs[fs, default: [:]][n, default: []].append(t.st[a + 1]); return 0
        }
        reg(nt, "FramePtrSet") { t, a, _ in
            guard let f = self.frameFind(self.fsArg(t, t.st[a + 2]), try self.mem.readStr(t.st[a])) else { return 0 }
            let l = self.framePtrs[f.fs]![f.name]!
            self.framePtrs[f.fs]![f.name]![l.count - 1] = t.st[a + 1]
            return l.last!
        }
        reg(nt, "FramePtrDel") { t, a, _ in
            guard let f = self.frameFind(self.fsArg(t, t.st[a + 1]), try self.mem.readStr(t.st[a])) else { return 0 }
            let old = self.framePtrs[f.fs]![f.name]!.removeLast()
            if self.framePtrs[f.fs]![f.name]!.isEmpty {
                self.framePtrs[f.fs]!.removeValue(forKey: f.name)
                if self.framePtrs[f.fs]!.isEmpty { self.framePtrs.removeValue(forKey: f.fs) }
            }
            return old
        }
        reg(nt, "SleepUntil") { t, a, _ in
            let wake = TempleClock.jiffyStartNs(t.st[a])
            if t.nestLevel > 0 || self.k.taskNow(t) >= wake { return 0 } // already due on the task's own clock (Kernel.taskNow)
            else if t.resumed { t.resumed = false; return 0 }
            else { t.wakeAt = wake; self.k.block(t, Kernel.SLEEP); return 0 }
        }
        reg(nt, "TaskRep") { _, _, _ in
            self.k.console.write("$PURPLE$CPU00$FG$\n")
            for tk in self.k.tasks { self.k.console.write("  $BLUE$\(tk.name)$FG$ #\(tk.id) \(self.stateName(tk.state))\n") }
            return 0
        }
    }

    /** FramePtr tables by task (Fs address): name -> values, the newest last (HashGenericAdd shadows older ones). */
    private var framePtrs: [Int64: [String: [Int64]]] = [:]

    private func fsArg(_ t: HTask, _ task: Int64) -> Int64 { task != 0 ? task : Int64(t.fsAddr) }

    /** The table holding [name], searched from [fs] up through its parent tasks (HashFind follows hash_table->next). */
    private func frameFind(_ fs: Int64, _ name: String) -> (fs: Int64, name: String)? {
        var f = fs
        var depth = 0
        while f != 0 && depth < 64 {
            depth += 1
            if let l = framePtrs[f]?[name], !l.isEmpty { return (f, name) }
            guard let task = k.taskByFs(f) else { return nil }
            f = mem.ld8(task.fsAddr + k.o.task("parent_task"))
        }
        return nil
    }

    /** A task is gone: so is its hash table (TempleOS frees it with the task). */
    public func taskGone(_ fs: Int64) { framePtrs.removeValue(forKey: fs) }
    public func allTasksGone() { framePtrs.removeAll() }

    private func stripDolDoc(_ s: String) -> String {
        let c = Console(); c.write(s); return c.plainText()
    }

    // ---------------------------------------------------------------- menus

    /** Builds a CMenu from TempleOS menu syntax: Name(msg_code,arg1,arg2); and Dir { ... }. */
    private func menuNew(_ st: String, _ flags: Int64, _ task: Int64) throws -> Int64 {
        let defs = Ref(k.defines.value) // Kotlin: HashMap(k.defines) (a private copy)
        if k.isNative {
            // Native images retain scalars; header macros such as SCF_SHIFT are
            // expressions. Tokenizing definitions does not compile/execute code.
            if menuHeaderDefines == nil,let data=k.env.runtimeFile("PreludeDefines.HC") {
                let header=Ref<[String:[Token]]>([:])
                _ = try Lexer(nil,header).tokenize(SourceFile.parse("C:/Runtime/PreludeDefines.HC",data),"C:/")
                menuHeaderDefines=header.value
            }
            for (name,body) in menuHeaderDefines ?? [:] where defs.value[name] == nil {defs.value[name]=body}
        }
        let toks = try Lexer(nil, defs).tokenize(SourceFile.ofString("menu", st), "C:/")
        var i = 0
        let o: Offsets = k.o
        let mem = self.mem
        let entrySize = Int64(o.cls("CMenuEntry").size)
        func tk() throws -> Token {
            if i >= toks.count { throw NativesSys.indexError(i, toks.count) }
            return toks[i]
        }
        func isP(_ s: String) throws -> Bool { let x = try tk(); return x.kind == .PUNCT && x.text == s }
        func expr() throws -> Int64 { let e = MenuExpr(toks, i, k.prog.uiConstants); let v = try e.eval(); i = e.i; return v }
        func entry() throws -> Int64 {
            if try tk().kind != .IDENT { return 0 }
            let e = try mem.calloc(entrySize)
            let name = latin1(try tk().text.take(31))
            mem.writeBytes(e + (o.member("CMenuEntry", "name")), name)
            i += 1
            if try isP("(") {
                i += 1
                mem.st8(e + (o.member("CMenuEntry", "msg_code")), -2) // MSG_KEY_DOWN_UP
                if try !isP(",") && !isP(")") { mem.st8(e + (o.member("CMenuEntry", "msg_code")), try expr()) }
                if try isP(",") { i += 1 }
                if try !isP(",") && !isP(")") { mem.st8(e + (o.member("CMenuEntry", "arg1")), try expr()) }
                if try isP(",") { i += 1 }
                if try !isP(",") && !isP(")") { mem.st8(e + (o.member("CMenuEntry", "arg2")), try expr()) }
                if try isP(")") { i += 1 }
                if try isP(";") { i += 1 }
            } else if try isP("{") {
                i += 1
                mem.st1(e + (o.member("CMenuEntry", "dir")), 1)
                var prev = e + (o.member("CMenuEntry", "sub"))
                while try !isP("}") && tk().kind != .EOF {
                    let c = try entry()
                    if c == 0 { break }
                    mem.st8(prev, c)
                    prev = Int(Int32(truncatingIfNeeded: c)) + (o.member("CMenuEntry", "next"))
                }
                if try isP("}") { i += 1 }
            } else { throw VmFault(chCode("Menu"), "menu syntax: expecting '{' or '('") }
            return Int64(e)
        }
        let m = try mem.calloc(Int64(o.cls("CMenu").size))
        mem.st8(m + (o.member("CMenu", "task")), task)
        mem.st8(m + (o.member("CMenu", "flags")), flags)
        mem.st1(m + (o.member("CMenu", "attr")), (1 << 4) + 14)
        var prev = m + (o.member("CMenu", "sub"))
        while try tk().kind != .EOF {
            let e = try entry()
            if e == 0 { break }
            mem.st8(prev, e)
            prev = Int(Int32(truncatingIfNeeded: e)) + (o.member("CMenuEntry", "next"))
        }
        k.menuChanged = true
        return Int64(m)
    }

    /** Kotlin's List.get out of range (IndexOutOfBoundsException), reported by the kernel as an internal error. */
    fileprivate static func indexError(_ i: Int, _ n: Int) -> VmKill {
        VmKill("internal error: java.lang.IndexOutOfBoundsException: Index \(i) out of bounds for length \(n)")
    }

    private var menuHeaderDefines:[String:[Token]]?
    private final class MenuExpr {
        let t: [Token]
        var i: Int
        let constants:[String:Int64]
        init(_ t: [Token], _ i: Int, _ constants:[String:Int64]) { self.t = t; self.i = i;self.constants=constants }
        func eval() throws -> Int64 { try or() }
        private func at(_ k: Int) throws -> Token {
            if k < 0 || k >= t.count { throw NativesSys.indexError(k, t.count) }
            return t[k]
        }
        private func p(_ s: String) throws -> Bool { let x = try at(i); return x.kind == .PUNCT && x.text == s }
        private func or() throws -> Int64 { var v = try xor(); while try p("|") { i += 1; v = v | (try xor()) }; return v }
        private func xor() throws -> Int64 { var v = try and(); while try p("^") { i += 1; v = v ^ (try and()) }; return v }
        private func and() throws -> Int64 { var v = try add(); while try p("&") { i += 1; v = v & (try add()) }; return v }
        private func add() throws -> Int64 {
            var v = try mul()
            while try p("+") || p("-") { let o = try at(i).text; i += 1; let r = try mul(); v = o == "+" ? v &+ r : v &- r }
            return v
        }
        private func mul() throws -> Int64 {
            var v = try sh()
            while try p("*") || p("/") { let o = try at(i).text; i += 1; let r = try sh(); v = o == "*" ? v &* r : (r != 0 ? sdiv(v, r) : 0) }
            return v
        }
        private func sh() throws -> Int64 {
            var v = try un()
            while try p("<<") || p(">>") {
                let o = try at(i).text; i += 1; let r = try un()
                let n = Int64(Int32(truncatingIfNeeded: r))
                v = o == "<<" ? v &<< n : v &>> n
            }
            return v
        }
        private func un() throws -> Int64 {
            let tk = try at(i); i += 1
            if tk.kind == .PUNCT && tk.text == "-" { return 0 &- (try un()) }
            if tk.kind == .PUNCT && tk.text == "~" { return ~(try un()) }
            if tk.kind == .PUNCT && tk.text == "!" { return try un() == 0 ? 1 : 0 }
            if tk.kind == .PUNCT && tk.text == "(" { let v = try or(); if try p(")") { i += 1 }; return v }
            if tk.kind == .INT || tk.kind == .CHAR { return tk.ival }
            if tk.text == "TRUE" { return 1 }
            if tk.text == "FALSE" {return 0}
            if let value=constants[tk.text] {return value}
            throw VmFault(chCode("Menu"),"undefined menu constant '\(tk.text)'")
        }
    }

    private func stateName(_ s: Int) -> String {
        switch s {
        case Kernel.READY: return "Ready"
        case Kernel.SLEEP: return "Sleeping"
        case Kernel.WAIT_MSG: return "AwaitingMsg"
        case Kernel.WAIT_FRAME: return "Refresh"
        case Kernel.SUSPENDED: return "Suspended"
        default: return "Dead"
        }
    }

    /**
     * Compiles and runs [src] synchronously on task [t] (TempleOS ExePrint/ExeFile).
     * Runs chunk by chunk so later code can use symbols defined by earlier code.
     * Code executed this way cannot block (it runs nested inside a native call).
     */
    /**
     * A natively translated program has no HolyC compiler at run time. ExePrint/ExePrint2 text (Cartesian's
     * formula, GetI64/GetF64's typed numbers) is evaluated by the native expression engine (k.dynExpr);
     * a file to compile (ExeFile) is reported, as a compile error would be.
     */
    private func nativeNoCompile(_ s: String) -> Int64 {
        let msg = "this program runs as native code, which does not compile HolyC at run time; use Pure Terry mode to compile \(String(s.prefix(60)))"
        k.console.write("$RED$\(msg)$FG$\n")
        return 0
    }

    public func runNested(_ t: HTask, _ name: String, _ src: [UInt8], _ dir: String, rethrow: Swift.Bool = false) throws -> Int64 {
        // Kotlin wraps this in try/catch(CompileError); the Swift session() cannot throw
        // (lexing is lazy, errors surface from next()).
        // Like TempleOS's ExePutS, the value of the last expression is the result (an F64 as its
        // bits: GetF64 does ExePrint("ToF64(%s);",st)(F64)).
        let session = k.prog.session(SourceFile.parse(name, src), dir, k.vfsProvider(), k.defines, answers: true)
        var res: Int64 = 0
        while true {
            let f: FuncSym?
            do { f = try session.next() } catch let e as CompileError {
                k.console.write("$RED$\(e.message)$FG$\n"); if rethrow { throw e }; k.compileErrorCaught(t); return res
            }
            guard let fn = f else { break }
            res = try k.vm.callFunction(t, k.prog.funcPtr(fn))
        }
        return res
    }

    // ---------------------------------------------------------------- registry

    /** Kotlin LinkedHashMap<String, String> (insertion-ordered, shared by reference). */
    public final class RegMap {
        public private(set) var keys: [String] = []
        private var map: [String: String] = [:]
        public init() {}
        public func containsKey(_ k: String) -> Bool { map[k] != nil }
        public subscript(_ k: String) -> String? {
            get { map[k] }
            set {
                if let v = newValue {
                    if map.updateValue(v, forKey: k) == nil { keys.append(k) }
                } else if map.removeValue(forKey: k) != nil {
                    keys.removeAll { $0 == k }
                }
            }
        }
        public var entries: [(String, String)] { keys.map { ($0, map[$0]!) } }
    }

    private let regPath = "C:/Home/Registry.HC"

    private var regCache: RegMap?

    /** Registry file format: "//#REG path" header lines followed by HolyC code. */
    public func registry() -> RegMap {
        if let c = regCache { return c }
        let map = RegMap()
        regCache = map
        guard let data = k.env.fs?.readFile(regPath) else { return map }
        var cur: String?
        var sb: [UInt8] = []
        let prefix = latin1("//#REG ")
        for line in data.split(separator: 10, omittingEmptySubsequences: false) {
            if line.starts(with: prefix) {
                if let c = cur { map[c] = latin1(sb) }
                cur = NativesSys.ktTrim(latin1(line.dropFirst(7))); sb.removeAll()
            } else if cur != nil { sb.append(contentsOf: line); sb.append(10) }
        }
        if let c = cur {
            if sb.last == 10 { sb.removeLast() }
            map[c] = latin1(sb)
        }
        return map
    }

    /** Kotlin String.trim() (Char.isWhitespace) on Latin-1 text. */
    private static func ktTrim(_ s: String) -> String {
        func ws(_ c: Unicode.Scalar) -> Bool {
            let v = c.value
            return (v >= 9 && v <= 13) || (v >= 28 && v <= 32) || v == 0xA0
        }
        let sc = Array(s.unicodeScalars)
        var lo = 0, hi = sc.count
        while lo < hi && ws(sc[lo]) { lo += 1 }
        while hi > lo && ws(sc[hi - 1]) { hi -= 1 }
        var r = String.UnicodeScalarView()
        r.append(contentsOf: sc[lo..<hi])
        return String(r)
    }

    private func saveRegistry(_ map: RegMap) {
        regCache = map
        var sb = latin1("//\(Brand.appName) registry: settings saved by programs (RegWrite).\n")
        for (p, code) in map.entries {
            var c = latin1(code)
            while c.last == 10 { c.removeLast() } // code.trimEnd('\n')
            sb.append(contentsOf: latin1("//#REG ")); sb.append(contentsOf: latin1(p)); sb.append(10)
            sb.append(contentsOf: c); sb.append(10)
        }
        do { try k.env.fs?.writeFile(regPath, sb) } catch is FsError {} catch {}
    }
}

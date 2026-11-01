import Foundation

/**
 * Lowers the typed AST to stack bytecode in [Program.code] (port of holyc/CodeGen.kt).
 *
 * Value representation on the operand stack: every value is 64 bits. Integers
 * are sign/zero-extended from their storage type, F64 values are raw IEEE bits,
 * pointers and arrays are arena addresses, class values are their address.
 */
public final class CodeGen {
    /** Unowned: the Program owns its CodeGen (Kotlin `val codegen = CodeGen(this)`). */
    private unowned let prog: Program
    private var fn: FuncSym!
    private var frameSize = 0
    private var labels: [String: Int] = [:]
    private var labelTry: [String: Int] = [:]
    private var gotoPatches: [(Int, String, Int)] = [] // (operand pos, label, tryDepth)
    private var tryDepth = 0

    /** Patch lists are shared by reference (Kotlin ArrayList), hence Ref. */
    private final class Loop {
        let breakPatches: Ref<[Int]>
        let contPatches: Ref<[Int]>?
        let tryDepth: Int
        let isSwitchGroup: Bool
        init(_ breakPatches: Ref<[Int]>, _ contPatches: Ref<[Int]>?, _ tryDepth: Int, isSwitchGroup: Bool = false) {
            self.breakPatches = breakPatches; self.contPatches = contPatches; self.tryDepth = tryDepth; self.isSwitchGroup = isSwitchGroup
        }
    }
    private var loops: [Loop] = []

    public init(_ prog: Program) { self.prog = prog }

    // ------------------------------------------------------------ emission

    private var code: IntList { prog.code }
    private var lastOp = -1
    private var labelAt = -1 // pc that is a jump target (peephole barrier)
    private var curFile = ""
    private var curLine = 0

    private func pc() -> Int { code.size }
    private func op(_ o: Int, _ a: Int...) {
        // peephole: STKn + POP -> STn ; LSTK8 + POP -> LST8
        if o == Op.POP && lastOp >= 0 && labelAt != pc() {
            let prev = code[lastOp]
            let repl: Int
            switch prev {
            case Op.STK1: repl = Op.ST1
            case Op.STK2: repl = Op.ST2
            case Op.STK4: repl = Op.ST4
            case Op.STK8: repl = Op.ST8
            case Op.LSTK8: repl = Op.LST8
            default: repl = -1
            }
            if repl >= 0 { code[lastOp] = repl; return }
            if prev == Op.LINC8 || prev == Op.INC {
                // value of an increment is unused: keep instruction, pop result
            }
        }
        lastOp = pc()
        prog.markLine(pc(), curFile, curLine)
        code.add(o)
        for x in a { code.add(x) }
    }

    @discardableResult
    private func here() -> Int { labelAt = pc(); return pc() }
    private func patch(_ pos: Int, _ target: Int) { code[pos] = target }
    /** Emits a jump with a placeholder; returns the operand position to patch. */
    private func jump(_ o: Int) -> Int { op(o, 0); return pc() - 1 }

    private func allocTemp(_ size: Int = 8) -> Int {
        frameSize = (frameSize + 7) & ~7
        let off = frameSize
        frameSize += size
        return off
    }

    private func err(_ msg: String, _ e: Expr) throws -> Never { throw CompileError(msg, e.file, e.line) }
    private func err(_ msg: String, _ s: Stmt) throws -> Never { throw CompileError(msg, s.file, s.line) }

    // ------------------------------------------------------------ functions

    private var nesting = 0
    private var quickFrom = 0

    public func compileFunction(_ f: FuncSym, _ body: Stmt) throws {
        let outermost = nesting == 0
        nesting += 1
        if outermost { quickFrom = pc() }
        do { try compileFunction0(f, body) } catch { nesting -= 1; throw error }
        nesting -= 1
        if nesting == 0 { Quick.quicken(code, quickFrom, pc()) }
    }

    /**
     * TempleOS returns whatever is in RAX when a non-U0 function falls off its
     * end; programs rely on that (Apps/X-Caliber ShotNew ends with QueIns()).
     * The common case is mirrored: a trailing expression statement becomes the
     * return value.
     */
    private func fallOffValue(_ f: FuncSym, _ body: Stmt) -> Stmt {
        guard !(f.ftype.ret is VoidType), let b = body as? Block, let last = b.list.last as? ExprStmt else { return body }
        if last.e.type is VoidType { return body }
        let ret = Return(last.e); ret.file = last.file; ret.line = last.line
        let nb = Block(Array(b.list.dropLast()) + [ret]); nb.file = b.file; nb.line = b.line
        return nb
    }

    private func compileFunction0(_ f: FuncSym, _ body: Stmt) throws {
        fn = f
        frameSize = f.frameSize
        labels.removeAll(); labelTry.removeAll(); gotoPatches.removeAll(); loops.removeAll()
        tryDepth = 0
        lastOp = -1
        f.entry = pc()
        here()
        curFile = f.file; curLine = f.line
        try stmt(fallOffValue(f, body))
        // implicit return
        op(Op.PUSHI, 0)
        op(Op.RET)
        for (pos, name, _) in gotoPatches {
            guard let t = labels[name] else { throw CompileError("undefined label '\(name)'", f.file, f.line) }
            code[pos] = t
        }
        f.frameSize = (frameSize + 7) & ~7
        prog.registerFunc(f)
    }

    // ------------------------------------------------------------ statements

    private func stmt(_ s: Stmt) throws {
        try checkStack()
        if s.line > 0 { curFile = s.file; curLine = s.line }
        switch s {
        case let s as Block: for x in s.list { try stmt(x) }
        case is NopStmt: break
        case let s as ExprStmt: try value(s.e); op(Op.POP)
        case let s as If:
            let jf = try cond(s.c, false)
            try stmt(s.t)
            if let sf = s.f {
                let je = jump(Op.JMP)
                patchAll(jf, here())
                try stmt(sf)
                patch(je, here())
            } else { patchAll(jf, here()) }
        case let s as While:
            let top = here()
            let jf = try cond(s.c, false)
            let lp = Loop(Ref([]), Ref([]), tryDepth)
            loops.append(lp)
            try stmt(s.body)
            loops.removeLast()
            let cont = here()
            op(Op.JMP, top)
            let end = here()
            patchAll(jf, end)
            for x in lp.breakPatches.value { patch(x, end) }
            for x in lp.contPatches!.value { patch(x, cont) }
        case let s as DoWhile:
            let top = here()
            let lp = Loop(Ref([]), Ref([]), tryDepth)
            loops.append(lp)
            try stmt(s.body)
            loops.removeLast()
            let cont = here()
            let jt = try cond(s.c, true)
            patchAll(jt, top)
            let end = here()
            for x in lp.breakPatches.value { patch(x, end) }
            for x in lp.contPatches!.value { patch(x, cont) }
        case let s as For:
            if let i = s.initS { try stmt(i) }
            let top = here()
            let jf: [Int] = try s.c.map { try cond($0, false) } ?? []
            let lp = Loop(Ref([]), Ref([]), tryDepth)
            loops.append(lp)
            try stmt(s.body)
            loops.removeLast()
            let cont = here()
            if let st = s.step { try value(st); op(Op.POP) }
            op(Op.JMP, top)
            let end = here()
            patchAll(jf, end)
            for x in lp.breakPatches.value { patch(x, end) }
            for x in lp.contPatches!.value { patch(x, cont) }
        case is Break:
            guard let lp = loops.last else { try err("break outside loop or switch", s) }
            for _ in 0..<max(tryDepth - lp.tryDepth, 0) { op(Op.UNTRY) }
            lp.breakPatches.value.append(jump(Op.JMP))
        case is Continue:
            guard let lp = loops.last(where: { $0.contPatches != nil }) else { try err("continue outside loop", s) }
            for _ in 0..<max(tryDepth - lp.tryDepth, 0) { op(Op.UNTRY) }
            lp.contPatches!.value.append(jump(Op.JMP))
        case let s as Return:
            let rt = fn.ftype.ret
            if let e = s.e {
                try value(e)
                if !(rt is VoidType) { try convert(e.type, rt, e) } else { op(Op.POP); op(Op.PUSHI, 0) }
                narrow(rt)
            } else { op(Op.PUSHI, 0) }
            op(Op.RET)
        case let s as Goto:
            op(Op.JMP, 0)
            gotoPatches.append((pc() - 1, s.label, tryDepth))
        case let s as Label: labels[s.name] = here(); labelTry[s.name] = tryDepth
        case let s as Try:
            let tryPos = jump(Op.TRY)
            tryDepth += 1
            try stmt(s.body)
            tryDepth -= 1
            op(Op.UNTRY)
            let je = jump(Op.JMP)
            patch(tryPos, here())
            try stmt(s.handler)
            op(Op.ENDCATCH)
            patch(je, here())
        case let s as LocalInit: if let iv = s.initV { try initLocal(s.sym, iv, s) }
        case let s as GlobalInit: try initGlobal(s.sym, s.initV, s)
        case let s as Switch: try switchStmt(s)
        case is CaseLabel, is SubStart, is SubEnd: try err("case label outside switch", s)
        default: break
        }
    }

    private func patchAll(_ list: [Int], _ target: Int) { for x in list { patch(x, target) } }

    /** Emits a conditional jump taken when [c] is [whenTrue]; returns patch positions. */
    private func cond(_ c: Expr, _ whenTrue: Bool) throws -> [Int] {
        if !whenTrue, let b = c as? Binary, CodeGen.CMP_OPS.contains(b.op), isIntOrPtr(b.l.type), isIntOrPtr(b.r.type),
           !Types.isUnsignedAny(b.l.type), !Types.isUnsignedAny(b.r.type) {
            try value(b.l); try value(b.r)
            let o: Int
            switch b.op {
            case "<": o = Op.JLTS
            case "<=": o = Op.JLES
            case ">": o = Op.JGTS
            case ">=": o = Op.JGES
            case "==": o = Op.JEQ
            default: o = Op.JNE
            }
            return [jump(o)]
        }
        if let l = c as? Logical, l.op == "&&", !whenTrue {
            return try cond(l.l, false) + cond(l.r, false)
        }
        if let l = c as? Logical, l.op == "||", whenTrue {
            return try cond(l.l, true) + cond(l.r, true)
        }
        if let u = c as? Unary, u.op == "!" { return try cond(u.e, !whenTrue) }
        try value(c)
        if c.type is F64Type { op(Op.PUSHK, prog.konst(bits(0.0))); op(Op.FNE) }
        return [jump(whenTrue ? Op.JNZ : Op.JZ)]
    }

    private func isIntOrPtr(_ t: HType) -> Bool { Types.isInt(t) || Types.isPtrLike(t) }

    // ------------------------------------------------------------ switch

    private final class CaseInfo {
        let lo: Int64
        let hi: Int64
        var pc: Int
        let group: Int
        init(_ lo: Int64, _ hi: Int64, pc: Int = -1, group: Int) { self.lo = lo; self.hi = hi; self.pc = pc; self.group = group }
    }

    private func switchStmt(_ s: Switch) throws {
        try value(s.e)
        if s.e.type is F64Type { op(Op.F2I) }
        let tmp = allocTemp()
        op(Op.LST8, tmp)
        // collect labels (only direct children; nested switches have their own)
        var cases: [CaseInfo] = []
        var dflt: CaseInfo? = nil
        var curGroup = -1
        var groupCounter = 0
        for st in s.body {
            switch st {
            case let c as CaseLabel:
                if c.isDefault { dflt = CaseInfo(0, 0, group: curGroup) } else { cases.append(CaseInfo(c.lo, c.hi, group: curGroup)) }
            // Nested start:/end: groups (legal in TempleOS, Compiler/PrsStmt.HC) are not
            // supported: a compile error instead of a malformed dispatch table.
            case is SubStart: if curGroup >= 0 { try err("nested start: blocks are not supported", st) } else { curGroup = groupCounter; groupCounter += 1 }
            case is SubEnd: if curGroup < 0 { try err("end: without start:", st) } else { curGroup = -1 }
            default: break
            }
        }
        _ = pc() // dispatchPos (unused)
        op(Op.LLD8, tmp)
        let tableIdx = prog.switchTables.count
        prog.switchTables.append(SwitchTable(0, 0, [])) // placeholder
        op(Op.SWITCH, tableIdx)
        var groupStart = [Int](repeating: -1, count: groupCounter)
        let groupEndPatches = (0..<groupCounter).map { _ in Ref<[Int]>([]) }
        var groupPorchDispatch = [Int](repeating: -1, count: groupCounter)
        let outer = Loop(Ref([]), nil, tryDepth)
        loops.append(outer)
        var ci = 0
        var inGroup = -1
        var groupIdx = -1
        var porchOpen = false
        for st in s.body {
            switch st {
            case let c as CaseLabel:
                if porchOpen {
                    // end of the front porch: dispatch among this group's cases
                    op(Op.LLD8, tmp)
                    groupPorchDispatch[inGroup] = prog.switchTables.count
                    prog.switchTables.append(SwitchTable(0, 0, []))
                    op(Op.SWITCH, groupPorchDispatch[inGroup])
                    porchOpen = false
                }
                let target = here()
                if c.isDefault { dflt!.pc = target } else { cases[ci].pc = target; ci += 1 }
            case is SubStart:
                groupIdx += 1
                inGroup = groupIdx
                groupStart[inGroup] = here()
                porchOpen = true
                loops.append(Loop(groupEndPatches[inGroup], nil, tryDepth, isSwitchGroup: true))
            case is SubEnd:
                if porchOpen { porchOpen = false }
                loops.removeLast()
                let endPc = here()
                for x in groupEndPatches[inGroup].value { patch(x, endPc) }
                inGroup = -1
            default: try stmt(st)
            }
        }
        if inGroup >= 0 { loops.removeLast() }
        loops.removeLast()
        let end = here()
        for x in outer.breakPatches.value { patch(x, end) }
        let dfltPc = dflt?.pc ?? end
        // main table: group cases jump to their group's porch
        prog.switchTables[tableIdx] = try buildTable(cases.map {
            ($0.lo, $0.hi, $0.group >= 0 ? groupStart[$0.group] : $0.pc)
        }, dfltPc, s)
        for g in 0..<groupCounter {
            let ti = groupPorchDispatch[g]
            if ti < 0 { continue }
            prog.switchTables[ti] = try buildTable(cases.filter { $0.group == g }.map { ($0.lo, $0.hi, $0.pc) }, dfltPc, s)
        }
    }

    private func buildTable(_ entries: [(Int64, Int64, Int)], _ dflt: Int, _ s: Stmt) throws -> SwitchTable {
        if entries.isEmpty { return SwitchTable(0, dflt, []) }
        let lo = entries.map { $0.0 }.min()!
        let hi = entries.map { $0.1 }.max()!
        if hi &- lo > 65536 { try err("switch case range too large for a jump table", s) }
        // Kotlin IntArray((hi - lo + 1).toInt()): a negative size throws there; report it as a compile error
        let n = Int(Int32(truncatingIfNeeded: hi &- lo &+ 1))
        if n < 0 { try err("switch case range is empty", s) }
        var t = [Int](repeating: dflt, count: n)
        for (a, b, target) in entries {
            if a > b { continue }
            var v = a
            while true {
                let i = Int(Int32(truncatingIfNeeded: v &- lo))
                if i < 0 || i >= n { try err("switch case range too large for a jump table", s) }
                t[i] = target
                if v == b { break }
                v += 1
            }
        }
        return SwitchTable(lo, dflt, t)
    }

    // ------------------------------------------------------------ initializers

    private func initLocal(_ sym: LocalSym, _ initV: Init, _ s: Stmt) throws {
        try storeInit(sym.type, initV, s) { off in self.op(Op.LADDR, sym.offset + off) }
    }

    private func initGlobal(_ sym: GlobalSym, _ initV: Init, _ s: Stmt) throws {
        if try constStore(sym.type, initV, sym.addr) { return }
        try storeInit(sym.type, initV, s) { off in self.op(Op.PUSHI, sym.addr + off) }
    }

    /** Writes constant initializers straight into the arena. Returns false if not constant. */
    private func constStore(_ t: HType, _ initV: Init, _ addr: Int) throws -> Bool {
        if !isConstInit(t, initV) { return false }
        try writeConst(t, initV, addr)
        return true
    }

    private func isConstInit(_ t: HType, _ initV: Init) -> Bool {
        if let li = initV as? ListInit {
            if let a = t as? ArrType { return li.items.allSatisfy { isConstInit(a.elem, $0) } }
            if let ct = t as? ClassType {
                let ms = ct.memberList
                return li.items.enumerated().allSatisfy { (i, it) in i < ms.count && isConstInit(ms[i].type, it) }
            }
            return li.items.count == 1 && isConstInit(t, li.items[0])
        }
        if let ei = initV as? ExprInit {
            if t is ArrType && ei.e is StrLit { return true }
            if t is F64Type { return ConstFold.float(ei.e) != nil }
            if Types.isInt(t) || t is PtrType { return ConstFold.int(ei.e) != nil && !(ei.e.type is F64Type) || ei.e is StrLit }
            return false
        }
        return false
    }

    // Every store is checked like a VM store (Arena.check): an initializer list longer than its array
    // (`U8 g[0][N]={{0},{65}};`) or a huge dimension must fault (BadMem), never write past the arena.
    // Addresses wrap (&+, &*) so an absurd size reaches the check instead of trapping.
    private func writeConst(_ t: HType, _ initV: Init, _ addr: Int) throws {
        let mem = prog.vm.mem
        if let li = initV as? ListInit {
            if let a = t as? ArrType {
                for (i, it) in li.items.enumerated() { try writeConst(a.elem, it, addr &+ i &* a.elem.size) }
            } else if let ct = t as? ClassType {
                let ms = ct.memberList
                for (i, it) in li.items.enumerated() { try writeConst(ms[i].type, it, addr &+ ms[i].offset) }
            } else {
                try writeConst(t, li.items[0], addr)
            }
        } else if let ei = initV as? ExprInit {
            let e = ei.e
            if t is ArrType, let sl = e as? StrLit {
                let n = max(min(sl.bytes.count, t.size), 0)
                _ = try mem.check(Int64(addr), n)
                for i in 0..<n { mem.st1(addr + i, Int64(sl.bytes[i])) }
                return
            }
            let v: Int64
            if t is F64Type { v = bits(ConstFold.float(e)!) }
            else if let sl = e as? StrLit { v = Int64(try prog.stringAddr(sl.bytes)) }
            else { v = ConstFold.int(e)! }
            _ = try mem.check(Int64(addr), [1, 2, 4].contains(t.size) ? t.size : 8) // the width the switch below stores
            switch t.size {
            case 1: mem.st1(addr, v)
            case 2: mem.st2(addr, v)
            case 4: mem.st4(addr, v)
            default: mem.st8(addr, v)
            }
        }
    }

    private func storeInit(_ t: HType, _ initV: Init, _ s: Stmt, _ addrOf: @escaping (Int) -> Void) throws {
        func rec(_ t: HType, _ initV: Init, _ off: Int) throws {
            if let li = initV as? ListInit {
                if let a = t as? ArrType {
                    for (i, it) in li.items.enumerated() { try rec(a.elem, it, off + i * a.elem.size) }
                } else if let ct = t as? ClassType {
                    let ms = ct.memberList
                    for (i, it) in li.items.enumerated() {
                        if i >= ms.count { try err("too many initializers", s) }
                        try rec(ms[i].type, it, off + ms[i].offset)
                    }
                } else {
                    guard let first = li.items.first else { return }
                    try rec(t, first, off)
                }
            } else if let ei = initV as? ExprInit {
                let e = ei.e
                if t is ArrType, let sl = e as? StrLit {
                    addrOf(off)
                    op(Op.PUSHI, try prog.stringAddr(sl.bytes))
                    op(Op.MEMCPY, min(sl.bytes.count + 1, t.size))
                    return
                }
                if let ct = t as? ClassType, ct.valueType == nil {
                    addrOf(off); try value(e); op(Op.MEMCPY, ct.size); return
                }
                addrOf(off)
                try value(e)
                try convert(e.type, t, e)
                op(storeOp(t))
            }
        }
        try rec(t, initV, 0)
    }

    // ------------------------------------------------------------ expressions

    private func loadOp(_ t: HType) -> Int {
        if let it = Types.asInt(t) {
            switch it.size {
            case 1: return it.signed ? Op.LD1S : Op.LD1U
            case 2: return it.signed ? Op.LD2S : Op.LD2U
            case 4: return it.signed ? Op.LD4S : Op.LD4U
            default: return Op.LD8
            }
        }
        return Op.LD8
    }

    private func storeOp(_ t: HType, keep: Bool = false) -> Int {
        let size = Types.asInt(t)?.size ?? 8
        switch size {
        case 1: return keep ? Op.STK1 : Op.ST1
        case 2: return keep ? Op.STK2 : Op.ST2
        case 4: return keep ? Op.STK4 : Op.ST4
        default: return keep ? Op.STK8 : Op.ST8
        }
    }

    private func incKind(_ t: HType) -> Int {
        if t is F64Type { return Op.KF64 }
        guard let it = Types.asInt(t) else { return Op.K8 }
        switch it.size {
        case 1: return it.signed ? Op.K1S : Op.K1U
        case 2: return it.signed ? Op.K2S : Op.K2U
        case 4: return it.signed ? Op.K4S : Op.K4U
        default: return Op.K8
        }
    }

    /** True when values of this type are represented by their address. */
    private func isAggregate(_ t: HType) -> Bool {
        t is ArrType || ((t as? ClassType).map { $0.valueType == nil } ?? false) || t is FuncType
    }

    /** Pushes the value of [e]. */
    public func value(_ e: Expr) throws {
        try checkStack()
        if e.line > 0 { curFile = e.file; curLine = e.line }
        switch e {
        case let e as IntLit: pushInt(e.v)
        case let e as FloatLit: op(Op.PUSHK, prog.konst(bits(e.v)))
        case let e as StrLit: op(Op.PUSHI, try prog.stringAddr(e.bytes))
        case let e as BinLit: op(Op.PUSHI, try prog.binAddr(e.bytes))
        case let e as FuncAddr: op(Op.PUSHK, prog.konst(prog.funcPtr(e.fn)))
        case let e as VarRef: loadVar(e)
        case is IndexExpr, is Deref, is MemberAccess:
            if isAggregate(e.type) { try addr(e) } else { try addr(e); op(loadOp(e.type)) }
        case let e as AddrOf: try addr(e.e)
        case let e as Cast:
            try value(e.e)
            castValue(e.e.type, e.type, e)
        case let e as Unary:
            try value(e.e)
            switch e.op {
            case "-": if e.e.type is F64Type { op(Op.FNEG) } else { op(Op.NEG) }
            case "~": if e.e.type is F64Type { op(Op.F2I) }; op(Op.COM)
            case "!": if e.e.type is F64Type { op(Op.PUSHK, prog.konst(bits(0.0))); op(Op.FEQ) } else { op(Op.LNOT) }
            default: break
            }
        case let e as Binary: try binary(e)
        case let e as Chain: try chain(e)
        case let e as Logical: try logical(e)
        case let e as Assign: try assign(e)
        case let e as IncDec: try incDec(e)
        case let e as Call: try call(e)
        case let e as Comma:
            for (i, x) in e.xs.enumerated() {
                try value(x)
                if i < e.xs.count - 1 { op(Op.POP) }
            }
        case is ArgvRef: try err("internal: argv", e)
        default: break
        }
    }

    private func pushInt(_ v: Int64) {
        if v >= Int64(Int32.min) && v <= Int64(Int32.max) { op(Op.PUSHI, Int(v)) } else { op(Op.PUSHK, prog.konst(v)) }
    }

    private func loadVar(_ e: VarRef) {
        let t: HType = e.type
        switch e.sym {
        case let s as LocalSym:
            if isAggregate(t) { op(Op.LADDR, s.offset); return }
            let o: Int
            if let it = Types.asInt(t) {
                switch it.size {
                case 1: o = it.signed ? Op.LLD1S : Op.LLD1U
                case 2: o = it.signed ? Op.LLD2S : Op.LLD2U
                case 4: o = it.signed ? Op.LLD4S : Op.LLD4U
                default: o = Op.LLD8
                }
            } else { o = Op.LLD8 }
            op(o, s.offset)
        case let s as GlobalSym:
            if isAggregate(t) { op(Op.PUSHI, s.addr); return }
            let o: Int
            if let it = Types.asInt(t) {
                switch it.size {
                case 1: o = it.signed ? Op.GLD1S : Op.GLD1U
                case 2: o = it.signed ? Op.GLD2S : Op.GLD2U
                case 4: o = it.signed ? Op.GLD4S : Op.GLD4U
                default: o = Op.GLD8
                }
            } else { o = Op.GLD8 }
            op(o, s.addr)
        case let s as FuncSym: op(Op.PUSHK, prog.konst(prog.funcPtr(s)))
        default: break
        }
    }

    /** Pushes the address of an lvalue. */
    public func addr(_ e: Expr) throws {
        try checkStack()
        switch e {
        case let e as VarRef:
            switch e.sym {
            case let s as LocalSym: op(Op.LADDR, s.offset)
            case let s as GlobalSym: op(Op.PUSHI, s.addr)
            case is FuncSym: try err("cannot take the address of a function this way", e)
            default: break
            }
        case let e as Deref: try value(e.e)
        case let e as IndexExpr:
            try value(e.base) // pointer or array address
            let sz = max(e.type.size, 1)
            let ci = ConstFold.int(e.idx)
            if let ci = ci {
                let off = ci &* Int64(sz)
                if off != 0 {
                    if off >= Int64(Int32.min) && off <= Int64(Int32.max) { op(Op.ADDI, Int(off)) } else { pushInt(off); op(Op.ADD) }
                }
            } else {
                try value(e.idx)
                if e.idx.type is F64Type { op(Op.F2I) }
                if sz != 1 { op(Op.MULI, sz) }
                op(Op.ADD)
            }
        case let e as MemberAccess:
            if e.viaPtr { try value(e.base) } else { try addr(e.base) }
            if e.offset != 0 { op(Op.ADDI, e.offset) }
        case let e as Comma:
            for (i, x) in e.xs.enumerated() {
                if i < e.xs.count - 1 { try value(x); op(Op.POP) } else { try addr(x) }
            }
        case let e as Cast: try addr(e.e)
        default: try err("expression is not addressable", e)
        }
    }

    /** Arithmetic conversion of the value on the stack from [from] to [to] (no truncation). */
    public func convert(_ from: HType, _ to: HType, _ at: Expr) throws {
        if to is F64Type && !(from is F64Type) {
            if isAggregate(from) { try err("cannot convert \(from.name) to F64", at) }
            op(Types.isUnsigned64(from) && !(from is PtrType) ? Op.U2F : Op.I2F)
        } else if from is F64Type && !(to is F64Type) && !isAggregate(to) {
            op(Op.F2I)
        }
    }

    /** Truncates/extends the stack value to the storage width of [t]. */
    private func narrow(_ t: HType) {
        guard let it = Types.asInt(t) else { return }
        switch it.size {
        case 1: op(it.signed ? Op.SX1 : Op.ZX1)
        case 2: op(it.signed ? Op.SX2 : Op.ZX2)
        case 4: op(it.signed ? Op.SX4 : Op.ZX4)
        default: break
        }
    }

    private func castValue(_ from: HType, _ to: HType, _ at: Expr) {
        if to is F64Type {
            // HolyC: a postfix (F64) cast of an integer reinterprets the bits.
            if !(from is F64Type) { return }
            return
        }
        if from is F64Type {
            // (I64) on a F64 reinterprets bits as well (use ToI64() to convert)
            narrow(to); return
        }
        narrow(to)
    }

    private static let bitOps: Set<String> = ["&", "|", "^", "<<", ">>"]

    private func binary(_ e: Binary) throws {
        let lt: HType = e.l.type
        let rt: HType = e.r.type
        let op0 = e.op
        // pointer arithmetic
        if (op0 == "+" || op0 == "-") && (Types.isPtrLike(lt) || Types.isPtrLike(rt)) {
            if Types.isPtrLike(lt) && Types.isPtrLike(rt) {
                try value(e.l); try value(e.r); op(Op.SUB)
                let sc = Types.scale(lt)
                if sc != 1 { pushInt(Int64(sc)); op(Op.DIVS) }
                return
            }
            if Types.isPtrLike(lt) {
                try value(e.l); try value(e.r); if rt is F64Type { op(Op.F2I) }
                let sc = Types.scale(lt)
                if sc != 1 { op(Op.MULI, sc) }
                op(op0 == "+" ? Op.ADD : Op.SUB)
            } else {
                try value(e.l); if lt is F64Type { op(Op.F2I) }
                let sc = Types.scale(rt)
                if sc != 1 { op(Op.MULI, sc) }
                try value(e.r)
                op(Op.ADD)
            }
            return
        }
        let isF = (lt is F64Type || rt is F64Type || op0 == "`") && !CodeGen.bitOps.contains(op0)
        try value(e.l); if isF { try convert(lt, Types.F64, e) } else if lt is F64Type { op(Op.F2I) }
        try value(e.r); if isF { try convert(rt, Types.F64, e) } else if rt is F64Type { op(Op.F2I) }
        let unsigned = CodeGen.CMP_OPS.contains(op0) ? Types.isUnsignedAny(lt) || Types.isUnsignedAny(rt) : Types.isUnsigned64(lt) || Types.isUnsigned64(rt)
        op(isF ? floatOp(op0) : intOp(op0, unsigned, lt))
    }

    private func floatOp(_ o: String) -> Int {
        switch o {
        case "+": return Op.FADD
        case "-": return Op.FSUB
        case "*": return Op.FMUL
        case "/": return Op.FDIV
        case "%": return Op.FMOD
        case "`": return Op.FPOW
        case "==": return Op.FEQ
        case "!=": return Op.FNE
        case "<": return Op.FLT
        case "<=": return Op.FLE
        case ">": return Op.FGT
        case ">=": return Op.FGE
        default: fatalError(o) // Kotlin: IllegalStateException (unreachable)
        }
    }

    private func intOp(_ o: String, _ unsigned: Bool, _ lt: HType) -> Int {
        switch o {
        case "+": return Op.ADD
        case "-": return Op.SUB
        case "*": return Op.MUL
        case "/": return unsigned ? Op.DIVU : Op.DIVS
        case "%": return unsigned ? Op.MODU : Op.MODS
        case "&": return Op.AND
        case "|": return Op.OR
        case "^": return Op.XOR
        case "<<": return Op.SHL
        case ">>": return Types.isUnsigned64(lt) ? Op.SHRU : Op.SHRS
        case "`": return Op.POWI
        case "==": return Op.EQ
        case "!=": return Op.NE
        case "<": return unsigned ? Op.LTU : Op.LTS
        case "<=": return unsigned ? Op.LEU : Op.LES
        case ">": return unsigned ? Op.GTU : Op.GTS
        case ">=": return unsigned ? Op.GEU : Op.GES
        default: fatalError(o) // Kotlin: IllegalStateException (unreachable)
        }
    }

    private func chain(_ e: Chain) throws {
        let anyF = e.xs.contains { $0.type is F64Type }
        let anyU = e.xs.contains { Types.isUnsignedAny($0.type) }
        var falses: [Int] = []
        let tmp = allocTemp()
        try value(e.xs[0]); if anyF { try convert(e.xs[0].type, Types.F64, e) }
        for i in 1..<max(e.xs.count, 1) {
            let x = e.xs[i]
            try value(x); if anyF { try convert(x.type, Types.F64, e) }
            if i < e.xs.count - 1 { op(Op.LSTK8, tmp) }
            let o = e.ops[i - 1]
            op(anyF ? floatOp(o) : intOp(o, anyU, Types.I64))
            if i < e.xs.count - 1 {
                falses.append(jump(Op.JZ))
                op(Op.LLD8, tmp)
            }
        }
        if !falses.isEmpty {
            let j = jump(Op.JMP)
            let f = here()
            for x in falses { patch(x, f) }
            op(Op.PUSHI, 0)
            patch(j, here())
        }
    }

    private func truth(_ t: HType) {
        if t is F64Type { op(Op.PUSHK, prog.konst(bits(0.0))); op(Op.FNE) } else { op(Op.TOBOOL) }
    }

    private func logical(_ e: Logical) throws {
        switch e.op {
        case "^^":
            try value(e.l); truth(e.l.type)
            try value(e.r); truth(e.r.type)
            op(Op.XOR)
        case "&&":
            try value(e.l); truth(e.l.type)
            let j = jump(Op.JZ)
            try value(e.r); truth(e.r.type)
            let je = jump(Op.JMP)
            patch(j, here()); op(Op.PUSHI, 0)
            patch(je, here())
        default:
            try value(e.l); truth(e.l.type)
            let j = jump(Op.JNZ)
            try value(e.r); truth(e.r.type)
            let je = jump(Op.JMP)
            patch(j, here()); op(Op.PUSHI, 1)
            patch(je, here())
        }
    }

    private func assign(_ e: Assign) throws {
        let t: HType = e.target.type
        if let ct = t as? ClassType, ct.valueType == nil {
            if e.op != "=" { try err("compound assignment to a class value", e) }
            try addr(e.target); try value(e.value); op(Op.MEMCPY, ct.size)
            try addr(e.target)
            return
        }
        if t is ArrType { try err("cannot assign to an array", e) }
        let target = e.target
        // fast path: 8-byte local
        if e.op == "=", let tv = target as? VarRef, let ls = tv.sym as? LocalSym, t.size == 8, !isAggregate(t) {
            try value(e.value); try convert(e.value.type, t, e)
            op(Op.LSTK8, ls.offset)
            return
        }
        if e.op == "=" && hasSideEffects(target) {
            // TempleOS evaluates the value before the target address, so code like
            // `*dst++=*dst&mask|c;` reads the old pointer (relied on by GrRect).
            try value(e.value)
            try convert(e.value.type, t, e)
            try addr(target)
            op(Op.SWAP)
            op(storeOp(t, keep: true))
            return
        }
        try addr(target)
        if e.op == "=" {
            try value(e.value)
            try convert(e.value.type, t, e)
            op(storeOp(t, keep: true))
            return
        }
        // compound
        op(Op.DUP)
        op(loadOp(t))
        let bop = String(e.op.dropLast())
        let rt: HType = e.value.type
        if Types.isPtrLike(t) && (bop == "+" || bop == "-") {
            try value(e.value); if rt is F64Type { op(Op.F2I) }
            let sc = Types.scale(t)
            if sc != 1 { op(Op.MULI, sc) }
            op(bop == "+" ? Op.ADD : Op.SUB)
        } else if (t is F64Type || rt is F64Type) && !CodeGen.bitOps.contains(bop) {
            try convert(t, Types.F64, e)
            try value(e.value); try convert(rt, Types.F64, e)
            op(floatOp(bop))
            try convert(Types.F64, t, e)
        } else {
            try value(e.value); if rt is F64Type { op(Op.F2I) }
            op(intOp(bop, Types.isUnsigned64(t) || Types.isUnsigned64(rt), t))
        }
        op(storeOp(t, keep: true))
    }

    private func incDec(_ e: IncDec) throws {
        let t: HType = e.type
        let delta = Types.isPtrLike(t) ? e.delta * Types.scale(t) : e.delta
        let target = e.target
        if let tv = target as? VarRef, let ls = tv.sym as? LocalSym, t.size == 8, !(t is F64Type), !isAggregate(t) {
            op(Op.LINC8, ls.offset, delta, e.post ? 1 : 0)
            return
        }
        try addr(target)
        op(Op.INC, incKind(t), delta, e.post ? 1 : 0)
    }

    private func call(_ e: Call) throws {
        let ft = e.ftype
        let params = ft.params
        // Compiler/OptPass012.HC IC_TO_I64/IC_TO_F64: ToI64 of an integer and ToF64 of an F64 drop the
        // argument conversion and the call, leaving the value as it is (GetF64 relies on ToF64(1/4.0))
        if let f0 = e.fn, f0.isNative, e.args.count == 1, let a0 = e.args[0], !isAggregate(a0.type),
           (f0.name == "ToF64" && a0.type is F64Type) || (f0.name == "ToI64" && !(a0.type is F64Type)) {
            try value(a0)
            return
        }
        if e.args.count > params.count && !ft.varargs {
            try err("too many arguments to \(e.fn?.name ?? "function")", e)
        }
        // TempleOS evaluates arguments right to left (CodeGen.kt): variadic ones from the last, then the fixed
        // ones from the last (defaults included); REV puts them back in parameter order on the stack
        if params.count < e.args.count { for i in params.count..<e.args.count where e.args[i] == nil { try err("empty variadic argument", e) } }
        for i in params.indices where (i < e.args.count ? e.args[i] : nil) == nil && params[i].defaultExpr == nil {
            try err("missing argument '\(params[i].name)' to \(e.fn?.name ?? "function")", e)
        }
        let n = max(params.count, e.args.count)
        if params.count < e.args.count { for i in stride(from: e.args.count - 1, through: params.count, by: -1) { try value(e.args[i]!) } }
        for i in params.indices.reversed() {
            let a: Expr? = i < e.args.count ? e.args[i] : nil
            let prm = params[i]
            let ex = a ?? prm.defaultExpr!
            try value(ex)
            if isAggregate(prm.type) && !isAggregate(ex.type) {
                // passing an integer where a class is expected: keep raw
            } else { try convert(ex.type, prm.type, ex) }
        }
        if n > 1 { op(Op.REV, n) }
        if let f = e.fn {
            if f.isNative { op(Op.CALLN, f.nativeIndex, n) }
            else {
                if f.index < 0 { prog.addFunc(f) }
                op(Op.CALL, f.index, n)
            }
        } else {
            try value(e.callee!)
            op(Op.CALLP, n)
        }
        if ft.ret is VoidType { return } // value is 0 (RET pushes 0)
    }

    private func hasSideEffects(_ e: Expr?) -> Bool {
        if stackRemaining() < STACK_RESERVE { return true }
        switch e {
        case nil: return false
        case is IncDec, is Assign, is Call: return true
        case let x as IndexExpr: return hasSideEffects(x.base) || hasSideEffects(x.idx)
        case let x as MemberAccess: return hasSideEffects(x.base)
        case let x as Deref: return hasSideEffects(x.e)
        case let x as Cast: return hasSideEffects(x.e)
        case let x as Binary: return hasSideEffects(x.l) || hasSideEffects(x.r)
        case let x as Unary: return hasSideEffects(x.e)
        case let x as Comma: return x.xs.contains { hasSideEffects($0) }
        default: return false
        }
    }

    public static let CMP_OPS: Set<String> = ["<", "<=", ">", ">=", "==", "!="]
}

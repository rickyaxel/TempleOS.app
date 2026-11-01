import XCTest
@testable import TempleCore

/**
 * Unit tests of the native dynamic expression engine (port of DynExprUnitTest.kt): lexer, parser
 * (precedence, associativity, typing), errors and their messages, sandbox limits and the cache. Pure tests
 * use a small fake environment; the semantic tests at the end compare the engine with the interpreter's own
 * ExePrint (NativesSys.runNested) on the same interpreted kernel.
 */
final class DynExprUnitTests: XCTestCase {
    // ------------------------------------------------------------ a fake environment (no kernel)

    private final class Fake: DynScope, DynHost {
        var mem = [UInt8](repeating: 0, count: 4096)
        var globals: [String: Sym] = [:]
        var calls: [String] = []
        private var nextAddr = 64
        @discardableResult func global(_ name: String, _ t: HType) -> GlobalSym {
            let g = GlobalSym(name, t, nextAddr); globals[name] = g; nextAddr += 8; return g
        }
        func fn(_ name: String, _ ret: HType, _ params: [(String, HType)], native: Bool = true) {
            let f = FuncSym(name, FuncType(ret, params.map { Param($0.0, $0.1, nil) }, false))
            if native { f.nativeIndex = globals.count } else { f.index = globals.count }
            globals[name] = f
        }
        init() {
            global("x", Types.F64); global("y", Types.F64); global("y_last", Types.F64)
            global("b", Types.U8); global("c", Types.I8); global("i32", Types.I32); global("u", Types.U64); global("flag", Types.Bool)
            global("p", PtrType(Types.U8))
            fn("ToF64", Types.F64, [("i", Types.I64)]); fn("ToI64", Types.I64, [("d", Types.F64)])
            fn("Sin", Types.F64, [("d", Types.F64)]); fn("Min", Types.F64, [("n1", Types.F64), ("n2", Types.F64)], native: false)
            fn("Sqr", Types.F64, [("d", Types.F64)], native: false); fn("Print", Types.U0, [("fmt", Types.U8Ptr)])
        }
        func symbol(_ name: String) -> Sym? { globals[name] }
        func isClassName(_ name: String) -> Bool { name == "CTask" }
        func isKnownMacro(_ name: String) -> Bool { name == "RED" }
        func ld(_ addr: Int, _ size: Int) -> Int64 { var v: Int64 = 0; for i in stride(from: size - 1, through: 0, by: -1) { v = (v << 8) | Int64(mem[addr + i]) }; return v }
        func st(_ addr: Int, _ size: Int, _ v: Int64) { for i in 0..<size { mem[addr + i] = UInt8(truncatingIfNeeded: ushr(v, 8 * i)) } }
        func frameStore(_ off: Int, _ v: Int64) {}
        func poll() throws {}
        func call(_ fn: FuncSym, _ args: [Int64]) throws -> Int64 {
            calls.append(fn.name)
            switch fn.name {
            case "ToF64": return bits(Double(args[0]))
            case "ToI64": return f2i(d(args[0]))
            case "Sin": return bits(sin(d(args[0])))
            case "Sqr": return bits(d(args[0]) * d(args[0]))
            case "Min": return bits(d(args[0]) < d(args[1]) ? d(args[0]) : d(args[1]))
            default: throw VmKill(fn.name)
            }
        }
        func addr(_ n: String) -> Int { (globals[n] as! GlobalSym).addr }
        func setF(_ n: String, _ v: Double) { st(addr(n), 8, bits(v)) }
        func getF(_ n: String) -> Double { d(ld(addr(n), 8)) }
        func getRaw(_ n: String, _ size: Int) -> Int64 { ld(addr(n), size) }
        func compile(_ text: String) -> [DChunk] { DynExpr.compile(latin1(text), self, { _ in true }) }
        func run(_ text: String) throws -> Int64 {
            var r: Int64 = 0
            let ev = DynEval(self)
            for c in compile(text) {
                if let e = c as? DError { throw e.error }
                if c is DEmpty { r = 0 }
                if let s = c as? DStmt { r = try ev.run(s) }
            }
            return r
        }
        func f(_ e: String) throws -> Double { d(try run("ToF64(\(e));")) }
        func i(_ e: String) throws -> Int64 { try run("\(e);") }
        func error(_ text: String) -> String {
            do { _ = try run(text); return "no error for \(text)" } catch let e as CompileError { return e.message } catch { return "\(error)" }
        }
    }

    // ------------------------------------------------------------ lexer

    private func tokens(_ s: String) throws -> [DToken] {
        let lx = DynLexer(latin1(s), [:], DynExpr.FILE)
        var out: [DToken] = []
        var i = 0
        while try lx.get(i).kind != .EOF { out.append(try lx.get(i)); i += 1 }
        return out
    }

    func testLexesNumbersCharsAndPunctuation() throws {
        let t = try tokens("0x1F 0b101 12 1.5e-1 1. .25 1e400 'AB' '' <<= ^^ ` 12345678901234567890 0xFFFFFFFFFFFFFFFFF")
        XCTAssertEqual([DTok.INT, .INT, .INT, .FLOAT, .FLOAT, .FLOAT, .FLOAT, .CHAR, .CHAR, .PUNCT, .PUNCT, .PUNCT, .INT, .INT], t.map { $0.kind })
        XCTAssertEqual(31, t[0].ival); XCTAssertEqual(5, t[1].ival); XCTAssertEqual(0.15, t[3].fval)
        XCTAssertEqual(1.0, t[4].fval); XCTAssertEqual(0.25, t[5].fval); XCTAssertEqual(Double.infinity, t[6].fval)
        XCTAssertEqual(0x4241, t[7].ival); XCTAssertEqual(0, t[8].charLen)
        XCTAssertEqual(-6101065172474983726, t[12].ival)
        XCTAssertEqual(-1, t[13].ival)
    }

    func testSkipsCommentsAndDolDocAndExpandsConstants() throws {
        let t = try tokens("/* a /* nested */ */ 1 // x\n $FG,RED$+$$ pi $ 2")
        XCTAssertEqual(["1", "+", "(", "4614256656552045848", "(", "F64", ")", ")", "2"], t.map { $0.description })
        XCTAssertEqual(2, t.last!.line)
    }

    func testLexerErrorsAreTheCompilers() {
        let f = Fake()
        XCTAssertEqual("C:/Home/ExePrint.HC:1: integer constant too large: 99999999999999999999", f.error("99999999999999999999;"))
        XCTAssertEqual("C:/Home/ExePrint.HC:1: char constant longer than 8 chars", f.error("'ABCDEFGHI';"))
        XCTAssertEqual("C:/Home/ExePrint.HC:1: unterminated literal", f.error("'A"))
        XCTAssertEqual("C:/Home/ExePrint.HC:1: unknown directive #x", f.error("ToF64(#x);"))
        XCTAssertTrue(f.error("#define A 1\nA;").contains("outside the native expression subset"))
        XCTAssertEqual("C:/Home/ExePrint.HC:1: expected ',' but found 'y'", f.error("ToF64(x y 'ABCDEFGHI');"))
    }

    // ------------------------------------------------------------ precedence, associativity, typing

    func testHolycPrecedence() throws {
        let f = Fake()
        XCTAssertEqual(5, try f.i("1<<2+1")); XCTAssertEqual(3, try f.i("6&3+1")); XCTAssertEqual(3, try f.i("1+6&3"))
        XCTAssertEqual(9, try f.i("5&3|8")); XCTAssertEqual(7, try f.i("1+2*3")); XCTAssertEqual(3, try f.i("10-4-3"))
        XCTAssertEqual(5, try f.i("100/10/2"))
        XCTAssertEqual(512.0, try f.f("2`3`2")); XCTAssertEqual(-4.0, try f.f("-2`2")); XCTAssertEqual(18.0, try f.f("2*3`2"))
        XCTAssertEqual(1, try f.i("1<2<3")); XCTAssertEqual(1, try f.i("3>2>1")); XCTAssertEqual(0, try f.i("1<3<2"))
        XCTAssertEqual(0, try f.i("2<3==1")); XCTAssertEqual(1, try f.i("1==2<3"))
    }

    func testChainsAndLogic() throws {
        let f = Fake()
        f.setF("x", 5.0)
        XCTAssertEqual(1.0, try f.f("0<x<10")); XCTAssertEqual(0.0, try f.f("0<x<3"))
        XCTAssertEqual(1.0, try f.f("x>0 ^^ x>25")); XCTAssertEqual(0.0, try f.f("x>0 ^^ x<25"))
        XCTAssertEqual(1.0, try f.f("x<-50 || x>0")); XCTAssertEqual(0.0, try f.f("!x")); XCTAssertEqual(1.0, try f.f("!!x"))
        f.setF("y", 0.0)
        XCTAssertEqual(0.0, try f.f("x<0 && (y=1)")); XCTAssertEqual(0.0, f.getF("y"))
    }

    func testIntegerAndFloatSemantics() throws {
        let f = Fake()
        XCTAssertEqual(3, try f.i("7/2")); XCTAssertEqual(-3, try f.i("-7/2")); XCTAssertEqual(-1, try f.i("-7%3"))
        XCTAssertEqual(3.5, try f.f("7/2.0")); XCTAssertEqual(3.5, try f.f("7.0/2"))
        XCTAssertEqual(Int64.min, try f.i("0x7FFFFFFFFFFFFFFF+1"))
        XCTAssertEqual(0x7FFFFFFFFFFFFFFF, try f.i("0xFFFFFFFFFFFFFFFF/2"))
        XCTAssertEqual(1, try f.i("-0xFFFFFFFFFFFFFFFF"))
        XCTAssertEqual(-32, try f.i("-256>>3")); XCTAssertEqual(0x1FFFFFFFFFFFFFFF, try f.i("0xFFFFFFFFFFFFFFFF>>3"))
        XCTAssertEqual(2, try f.i("1<<65")); XCTAssertEqual(-6, try f.i("~5"))
        XCTAssertEqual(255, try f.i("(-1)(U8)")); XCTAssertEqual(44, try f.i("300(U8)"))
        XCTAssertEqual(0x4000000000000000, try f.i("2.0(I64)"))
        XCTAssertEqual(2.0, d(try f.i("0x4000000000000000(F64)")))
        XCTAssertEqual(Int64.min, try f.i("ToI64(1e300)"))
        XCTAssertEqual(1024.0, try f.f("2`10")); XCTAssertEqual(1.0, try f.f("0`0"))
        XCTAssertEqual(0x4241, try f.i("'AB'+0"))
        XCTAssertEqual(8, try f.i("sizeof(F64)")); XCTAssertEqual(1, try f.i("sizeof(Bool)")); XCTAssertEqual(8, try f.i("sizeof(x)")); XCTAssertEqual(8, try f.i("sizeof(U8*)"))
        f.st(f.addr("b"), 1, 200)
        XCTAssertEqual(1, try f.i("b<-1")); XCTAssertEqual(0, try f.i("b>-1"))
    }

    func testDivisionByZeroIsTheVmsFault() throws {
        let f = Fake()
        for e in ["1/0", "1%0", "x(I64)/0", "0x8000000000000000(I64)/-1"] {
            do { _ = try f.i(e); XCTFail(e) } catch let v as VmFault { XCTAssertEqual(Vm.DIV_ZERO, v.ch) }
        }
        XCTAssertTrue(try f.f("1.0/0").isInfinite); XCTAssertTrue(try f.f("0.0/0").isNaN)
    }

    func testAssignmentsAndIncrements() throws {
        let f = Fake()
        f.setF("x", 2.0)
        XCTAssertEqual(4.0, try f.f("y=2*x")); XCTAssertEqual(4.0, f.getF("y"))
        XCTAssertEqual(300, try f.i("b=300")); XCTAssertEqual(44, f.getRaw("b", 1))
        XCTAssertEqual(2.0, try f.f("x++")); XCTAssertEqual(3.0, f.getF("x"))
        XCTAssertEqual(4.0, try f.f("++x")); XCTAssertEqual(8.0, try f.f("x*=2"))
        f.st(f.addr("c"), 1, 127)
        XCTAssertEqual(-128, try f.i("++c"))
        XCTAssertEqual(3, try f.i("i32=3.7"))
        XCTAssertEqual(5, try f.i("x(I64)=5")); XCTAssertEqual(5, f.getRaw("x", 8))
        f.setF("x", 1.0)
        XCTAssertEqual(3.0, d(try f.run("ToF64(1);y=3;ToF64(y);")))
        XCTAssertEqual(0, try f.run("ToF64(1);;"))
    }

    func testCallsAreBoundLikeTheCodeGenerator() throws {
        let f = Fake()
        f.setF("x", 0.5)
        XCTAssertEqual(sin(0.5), try f.f("Sin(x)"))
        f.calls.removeAll()
        XCTAssertEqual(0.5, try f.f("x")); XCTAssertEqual([], f.calls)
        XCTAssertEqual(3.0, try f.f("ToF64(3)")); XCTAssertEqual(["ToF64"], f.calls)
        XCTAssertEqual(0.25, try f.f("Sqr(x)")); XCTAssertEqual(0.5, try f.f("Min(x,1)"))
        XCTAssertEqual("C:/Home/ExePrint.HC:1: too many arguments to Sin", f.error("ToF64(Sin(x,1));"))
        XCTAssertEqual("C:/Home/ExePrint.HC:1: missing argument 'd' to Sin", f.error("ToF64(Sin());"))
        XCTAssertEqual("C:/Home/ExePrint.HC:1: missing argument 'n1' to Min", f.error("ToF64(Min(,2));"))
        XCTAssertEqual("C:/Home/ExePrint.HC:1: missing argument 'i' to ToF64", f.error("ToF64($);"))
    }

    // ------------------------------------------------------------ errors

    func testSyntaxErrorsCarryTheCompilersMessages() {
        let f = Fake()
        XCTAssertEqual("C:/Home/ExePrint.HC:1: unexpected ')'", f.error("ToF64(2*);"))
        XCTAssertEqual("C:/Home/ExePrint.HC:0: unexpected end of file", f.error("ToF64(x+"))
        XCTAssertEqual("C:/Home/ExePrint.HC:0: expected ',' but found 'end of file'", f.error("ToF64(x"))
        XCTAssertEqual("C:/Home/ExePrint.HC:1: undefined identifier 'foo'", f.error("ToF64(foo(x));"))
        XCTAssertEqual("C:/Home/ExePrint.HC:1: expression is not assignable", f.error("ToF64(1++);"))
        XCTAssertEqual("C:/Home/ExePrint.HC:1: called object is not a function", f.error("ToF64(x(2));"))
        XCTAssertEqual("C:/Home/ExePrint.HC:1: expected identifier but found '.2'", f.error("ToF64(1..2);"))
        XCTAssertEqual("C:/Home/ExePrint.HC:1: unexpected character '\u{01}' (0x1)", f.error("ToF64(x\u{01});"))
        XCTAssertEqual("C:/Home/ExePrint.HC:1: cannot index F64", f.error("ToF64(x[0]);"))
        XCTAssertEqual("C:/Home/ExePrint.HC:1: unknown type 'class'", f.error("ToF64(x(class));"))
    }

    func testConstructsOutsideTheSubsetAreRejectedPredictably() {
        let f = Fake()
        let cases: [(String, String)] = [
            ("ToF64(\"str\");", "a string literal"), ("Print(\"hi\");", "the function 'Print'"), ("ToF64(p);", "the variable 'p'"),
            ("ToF64(*p);", "a pointer dereference"), ("ToF64(&x);", "the address operator"), ("ToF64(RED);", "the TempleOS macro 'RED'"),
            ("ToF64(x(CTask));", "a cast to CTask"), ("ToF64(x(U8*));", "a cast to U8*"), ("I64 z=1;", "a declaration"),
            ("if (x) y=1;", "the statement 'if'"), ("\"hi\";", "a string statement"), ("ToF64(x.u8[0]);", "indexing"),
        ]
        for (text, what) in cases {
            guard let c = f.compile(text).last as? DError, c.outsideSubset else { XCTFail(text); continue }
            let m = c.error.message
            XCTAssertTrue(m.hasPrefix("C:/Home/ExePrint.HC:1: outside the native expression subset: \(what)"), "\(text): \(m)")
            XCTAssertTrue(m.hasSuffix("Pure Terry compiles it"), m)
        }
        let chunks = f.compile("ToF64(1);y=2;Print(\"x\");")
        XCTAssertEqual(3, chunks.count); XCTAssertTrue(chunks[0] is DStmt && chunks[1] is DStmt && chunks[2] is DError)
    }

    // ------------------------------------------------------------ limits

    func testSandboxLimits() throws {
        let f = Fake()
        func limited(_ text: String) -> Bool { (f.compile(text).last as? DError)?.error.message.contains("outside the native expression engine's limits") ?? false }
        func rep(_ s: String, _ n: Int) -> String { String(repeating: s, count: n) }
        XCTAssertTrue(limited("ToF64(" + rep("1+", 5000) + "1);"))
        XCTAssertTrue(limited("ToF64(" + rep("x+", 2100) + "x);"))
        XCTAssertFalse(limited("ToF64(" + rep("x+", 1000) + "x);"))
        XCTAssertTrue(limited("ToF64(" + rep("(", 600) + "x" + rep(")", 600) + ");"))
        XCTAssertFalse(limited("ToF64(" + rep("(", 150) + "x" + rep(")", 150) + ");"))
        XCTAssertTrue(limited("ToF64(x" + rep("(I64)", 300) + ");"))
        XCTAssertTrue(limited("ToF64(" + rep("Sin(", 300) + "x" + rep(")", 300) + ");"))
        XCTAssertFalse(limited("ToF64(" + rep("Sin(", 40) + "x" + rep(")", 40) + ");"))
        XCTAssertEqual(1001.0, try f.f("1" + rep("+1", 1000)))
    }

    // ------------------------------------------------------------ the engine on a kernel, against the interpreter

    private func kernel() throws -> Kernel { try runHolyC(latin1("F64 x,y,y_last; U8 b; I8 c; I32 i32; U64 u; Bool flag;\n")) }
    private let testGlobals = ["x", "y", "y_last", "b", "c", "i32", "u", "flag"]

    private func setGlobals(_ k: Kernel, _ x: Double) {
        for n in testGlobals { k.mem.st8((k.prog.globals[n] as! GlobalSym).addr, 0) }
        k.mem.st8((k.prog.globals["x"] as! GlobalSym).addr, bits(x))
    }

    private func outcome(_ k: Kernel, _ run: () throws -> Int64) -> String {
        k.console.clear()
        let r: String
        do { r = "=" + hex(try run()) }
        catch let u as VmUncaught { r = "raise \(k.vm.chStr(u.ch)): \(u.message)" }
        catch let f as VmFault { r = "raise \(k.vm.chStr(f.ch)): \(f.message)" }
        catch { r = "error \(error)" }
        let g = testGlobals.map { n -> String in
            let s = k.prog.globals[n] as! GlobalSym
            return hex(k.mem.ld8(s.addr) & DynEval.mask(s.type.size))
        }.joined(separator: ",")
        return "\(r) [\(g)] \(k.console.plainText().trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    func testEngineAgreesWithTheInterpreterOnTheSameKernel() throws {
        let k = try kernel()
        let t = k.adamTask!
        let exprs = ["2*x", "x/3", "x%7", "-x%7", "x(I64)&15", "x(I64)<<1", "x`0.5", "-x`2", "0<x<10", "x>0 ^^ x>25",
            "Sin(x/20)*100", "Sqrt(Abs(x))*Sign(x)*10", "FloorI64(17,5)", "CeilI64(-17,5)", "ClampI64(x,-5,5)", "ASin(0.5)", "ACos(-2)",
            "y=2*x", "x++", "--x", "x*=2", "b=x", "c=x", "i32=x*1000000000", "u=x", "flag=x", "b+=200", "c-=x", "u/=3", "u>>=1",
            "(x/3)(I64)", "x(U8)", "(x*1000000000)(I32)", "300(U8)", "1/0", "x%0", "FloorI64(17,0)", "I64_MIN/-1", "1e308*10",
            "0x8000000000000000", "-I64_MIN", "pi*x", "eps*1e16", "1);y=3;ToF64(y", "1);;ToF64(2", "x);", "u=-1,u<1", "b=200,b<c",
            "flag=2,flag", "Pow(x,2)/100", "Arg(x,10)*50", "Log2(x)", "x>=10", "sizeof(x)+sizeof(I32)", "(y=x,y)+1", "(x,y)=7"]
        var compared = 0
        for e in exprs { for x in [-7.0, -0.5, 0.0, 1.0, 45.0] {
            setGlobals(k, x)
            let src = latin1("ToF64(\(e));")
            let a = outcome(k) { try k.sys.runNested(t, DynExpr.FILE, src, "C:/Home") }
            setGlobals(k, x)
            let b = outcome(k) { try k.dynExpr.exePrint(t, src, rethrow: false) }
            XCTAssertEqual(a, b, "ToF64(\(e)); at x=\(x)")
            compared += 1
        } }
        XCTAssertEqual(exprs.count * 5, compared)
        k.terminate("done")
    }

    func testParsedTextIsCachedPerKernel() throws {
        let k = try kernel()
        let t = k.adamTask!
        let before = k.dynExpr.stats.compiles
        for i in 0..<640 { setGlobals(k, Double(i - 320)); _ = try k.dynExpr.exePrint(t, latin1("ToF64(2*x);"), rethrow: false) }
        XCTAssertEqual(before + 1, k.dynExpr.stats.compiles)
        XCTAssertEqual(639, k.dynExpr.stats.cacheHits)
        XCTAssertEqual(640, k.dynExpr.stats.evaluations)
        for i in 0...DynLimits.CACHE_ENTRIES { _ = try k.dynExpr.exePrint(t, latin1("ToF64(\(i));"), rethrow: false) }
        let c = k.dynExpr.stats.compiles
        _ = try k.dynExpr.exePrint(t, latin1("ToF64(2*x);"), rethrow: false)
        XCTAssertEqual(c + 1, k.dynExpr.stats.compiles)
        k.terminate("done")
    }

    func testBuiltInConstantsAreTheHeadersMacros() throws {
        let k = try kernel()
        for (name, text) in DynMacros.TEXT {
            guard let body = k.defines.value[name] else { XCTFail("\(name) is not defined by the prelude"); continue }
            let mine = DynMacros.body(name)!
            XCTAssertEqual(body.map { $0.description }, mine.map { $0.description }, name)
            XCTAssertEqual(body.map { "\($0.kind)" }, mine.map { $0.kind == .BIN ? "INS_BIN" : "\($0.kind)" }, name)
            XCTAssertFalse(text.isEmpty)
        }
        k.terminate("done")
    }

    func testWhitelistedFunctionsHaveThePreludesParameters() throws {
        let k = try kernel()
        for (name, params) in DynFunctions.ORDERED {
            guard let f = k.prog.globals[name] as? FuncSym else { XCTFail("\(name) is not a prelude function"); continue }
            XCTAssertEqual(params, f.ftype.params.map { $0.name }, name)
            XCTAssertFalse(f.ftype.varargs, name)
        }
        k.terminate("done")
    }
}

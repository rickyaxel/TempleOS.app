import XCTest
import TempleCore
import PureSwift

// Port of temple_os_kotlin/purekotlin/src/test/.../DynExprDiffTest.kt: the native expression engine against
// the interpreter (the Swift interpreter and the Kotlin interpreter's shared fixture), a seeded fuzz, and
// Cartesian itself on both Swift engines (and the Kotlin runs when present).

let CARTESIAN = "C:/Demo/Graphics/Cartesian.HC"

/** Cartesian with its globals x, y, y_last on [engine], waiting for a formula; [run] calls the ExePrint native as Cartesian's loop does. */
final class ExeHarness {
    let k: Kernel
    private let fmt: Int64, buf: Int64, exe: Int64
    private let gx: GlobalSym, gy: GlobalSym, gyl: GlobalSym

    init(_ engine: Engine) throws {
        let (kk, _) = try bootProgram(CARTESIAN, engine)
        k = kk
        _ = try advanceTo(k, 300)
        let f = try k.mem.malloc(16)
        k.mem.writeBytes(f, latin1("ToF64(%s);\u{0}"))
        fmt = Int64(f)
        buf = Int64(try k.mem.malloc(8192))
        exe = Program.FPTR_NATIVE | Int64(k.vm.natives.find("ExePrint")!.index)
        gx = k.prog.globals["x"] as! GlobalSym; gy = k.prog.globals["y"] as! GlobalSym; gyl = k.prog.globals["y_last"] as! GlobalSym
    }

    /** One ExePrint call with x=[x], y=y_last=0: [result, x, y, y_last, ticks, outcome] ("" | "out:console text" | "ex:Ch:msg"). */
    func run(_ text: String, _ x: Double) -> [String] {
        k.mem.st8(gx.addr, bits(x)); k.mem.st8(gy.addr, 0); k.mem.st8(gyl.addr, 0)
        let b = latin1(text)
        k.mem.writeBytes(Int(buf), b); k.mem.st1(Int(buf) + b.count, 0)
        k.console.clear()
        let ticks0 = k.vm.ticksExecuted
        var r: Int64 = 0
        var ex: String?
        do { r = try k.vm.callFunction(k.adamTask!, exe, fmt, buf) }
        catch let u as VmUncaught { ex = "ex:\(k.vm.chStr(u.ch)):\(u.message)" }
        catch let f as VmFault { ex = "ex:\(k.vm.chStr(f.ch)):\(f.message)" }
        catch { ex = "ex:?:\(error)" }
        let out = k.console.plainText().trimmingCharacters(in: .whitespacesAndNewlines)
        let outcome = ex ?? (out.isEmpty ? "" : "out:\(out)")
        return [hex(r), hex(k.mem.ld8(gx.addr)), hex(k.mem.ld8(gy.addr)), hex(k.mem.ld8(gyl.addr)), String(k.vm.ticksExecuted - ticks0), outcome]
    }

    /** Cartesian's loop alone for x = -320..320 (641 points); wall time in ns. */
    func graph(_ text: String) throws -> Int64 {
        let b = latin1(text)
        k.mem.writeBytes(Int(buf), b); k.mem.st1(Int(buf) + b.count, 0)
        let t = k.adamTask!
        let st = monoNanos()
        for x in -320...320 {
            k.mem.st8(gx.addr, bits(Double(x)))
            let r = try k.vm.callFunction(t, exe, fmt, buf)
            k.mem.st8(gy.addr, r ^ Int64.min)
        }
        return monoNanos() - st
    }

    func close() { k.terminate("done") }
}

/** SplitMix64 random expressions over the supported grammar (Gen in DynExprDiffTest.kt: the same draws). */
final class DynGen {
    private var s: Int64
    init(_ seed: Int64) { s = seed }
    private func next() -> Int64 {
        s = s &+ -0x61c8864680b583eb
        var z = s
        z = (z ^ ushr(z, 30)) &* -0x40a7b892e31b1a47
        z = (z ^ ushr(z, 27)) &* -0x6b2fb644ecceee15
        return z ^ ushr(z, 31)
    }
    func int(_ n: Int) -> Int { Int(ushr(next(), 1) % Int64(n)) }
    private func pick<T>(_ xs: [T]) -> T { xs[int(xs.count)] }

    private let lits = ["0", "1", "2", "3", "7", "10", "100", "255", "256", "1000", "0x10", "0xFF", "0x7FFFFFFFFFFFFFFF", "0xFFFFFFFFFFFFFFFF",
        "0b101", "'A'", "'AB'", "0.5", "1.5", "2.", ".25", "1e3", "1e-3", "3.14159", "1e308", "12345678901234567890", "0.0", "-1", "-0.5"]
    private let consts = ["pi", "exp_1", "eps", "I64_MAX", "I64_MIN", "U8_MAX", "U32_MAX", "TRUE", "FALSE", "NULL", "inf", "log2_10", "sqrt2"]
    private let vars = ["x", "y", "y_last"]
    private let bin = ["+", "-", "*", "/", "%", "`", "<<", ">>", "&", "|", "^", "<", ">", "<=", ">=", "==", "!=", "&&", "||", "^^"]
    private let casts = ["I64", "U64", "I32", "U32", "I16", "U16", "I8", "U8", "Bool", "F64"]
    private let assigns = ["=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>="]
    private let fns = DynFunctions.ORDERED.filter { !$0.0.hasPrefix("Rand") && $0.0 != "tS" }

    func expr(_ depth: Int) -> String {
        if depth <= 0 {
            switch int(3) { case 0: return pick(lits); case 1: return pick(consts); default: return pick(vars) }
        }
        switch int(13) {
        case 0, 1: return pick(vars)
        case 2: return pick(lits)
        case 3:
            let e = expr(depth - 1)
            let op = pick(["-", "!", "~", "+"])
            return op + (e.hasPrefix("-") || e.hasPrefix("+") ? " " : "") + e
        case 4, 5:
            let l = expr(depth - 1); let op = pick(bin); let r = expr(depth - 1)
            return "(" + l + op + r + ")"
        case 6:
            let n = 2 + int(4)
            var s = ""
            for i in 0..<n {
                if i > 0 { s += pick(bin) }
                s += expr(depth - 2)
            }
            return s
        case 7:
            let e = expr(depth - 1); let c = pick(casts)
            return "(" + e + ")(" + c + ")"
        case 8:
            let (name, ps) = pick(fns)
            var args: [String] = []
            for _ in ps { args.append(expr(depth - 1)) }
            return name + "(" + args.joined(separator: ",") + ")"
        case 9:
            let t = pick(["y", "y_last", "x"]); let a = pick(assigns); let e = expr(depth - 1)
            return t + a + e
        case 10: return pick(["y++", "y--", "++y_last", "--x", "x++"])
        case 11:
            let a = expr(depth - 1); let b = expr(depth - 1)
            return "(" + a + "," + b + ")"
        default:
            let v = pick(vars); let c = pick(casts)
            return v + "(" + c + ")"
        }
    }

    func text() -> String {
        if int(10) == 0 {
            let a = expr(2), b = expr(2), c = expr(2)
            return a + ");y=" + b + ";ToF64(" + c
        }
        return expr(4)
    }
}

final class DynExprDiffTests: XCTestCase {
    private func isOutside(_ o: String) -> Bool { o.hasPrefix("out:") && o.contains("outside the native expression") }
    private func isCompileError(_ o: String) -> Bool { o.hasPrefix("out:\(DynExpr.FILE):") }

    private func corpus() throws -> (samples: [Double], formulas: [[String: Any]]) {
        let data = try Data(contentsOf: SHARED.appendingPathComponent("test-vectors/dynexpr/cartesian-corpus.json"))
        let c = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(c["template"] as? String, "ToF64(%s);")
        return ((c["samples"] as! [NSNumber]).map { $0.doubleValue }, c["formulas"] as! [[String: Any]])
    }

    private func fixture() throws -> [String: [[String]]] {
        let data = try Data(contentsOf: SHARED.appendingPathComponent("test-vectors/dynexpr/cartesian-interpreter-results.json"))
        let f = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return f["results"] as! [String: [[String]]]
    }

    /** The Swift interpreter reproduces the Kotlin interpreter's results exactly; the Swift engine matches them (outside-subset aside). */
    func testCartesianCorpusAgainstTheInterpreterFixture() throws {
        let (samples, formulas) = try corpus()
        let expected = try fixture()
        let terry = try ExeHarness(.terry)
        let native = try ExeHarness(.native)
        var terryMismatch: [String] = [], nativeMismatch: [String] = [], rejected: [String] = []
        var rows: [(String, [Int])] = [] // category -> [formulas, identical, rejected, rejectedBothErr, mismatch]
        func row(_ cat: String) -> Int { if let i = rows.firstIndex(where: { $0.0 == cat }) { return i }; rows.append((cat, [0, 0, 0, 0, 0])); return rows.count - 1 }
        for f in formulas {
            let id = f["id"] as! String, cat = f["cat"] as! String, text = f["text"] as! String
            guard var exp = expected[id] else { XCTFail("fixture has no \(id)"); continue }
            let a = samples.map { terry.run(text, $0) }
            let b = samples.map { native.run(text, $0) }
            if ["invalid-11","unsupported-04","unsupported-05"].contains(id) {
                // Pointer values depend on real prelude allocations. Assert their semantics directly;
                // the numeric/control-flow fields of the shared fixture still match exactly.
                if id=="unsupported-04" {
                    for result in a {
                        let address=f2i(d(Int64(bitPattern:try XCTUnwrap(UInt64(result[0],radix:16)))))
                        XCTAssertEqual(try terry.k.mem.msize(address),16,"MAlloc(10) owns a rounded 16-byte allocation")
                    }
                    XCTAssertEqual(Set(a.map {$0[0]}).count,a.count,"live allocations are distinct")
                } else {
                    let address=id=="invalid-11" ? Int64(try terry.k.prog.stringAddr(latin1("str"))) : terry.k.mem.ld8(terry.k.o.fsGlobal)
                    for result in a {XCTAssertEqual(result[0],hex(bits(Double(address))))}
                }
                for i in exp.indices {exp[i][0]=a[i][0]}
            }
            if a != exp, let i = a.indices.first(where: { a[$0] != exp[$0] }) { terryMismatch.append("\(id) [\(text)] x=\(samples[i]): swift terry=\(a[i]) kotlin terry=\(exp[i])") }
            let r = row(cat)
            rows[r].1[0] += 1
            if b == exp { rows[r].1[1] += 1 }
            else if b.allSatisfy({ isOutside($0[5]) }) {
                rows[r].1[exp.allSatisfy { isCompileError($0[5]) } ? 3 : 2] += 1
                rejected.append(id)
            } else {
                rows[r].1[4] += 1
                let i = b.indices.first { b[$0] != exp[$0] }!
                nativeMismatch.append("\(id) [\(text)] x=\(samples[i]): swift native=\(b[i]) interpreter=\(exp[i])")
            }
        }
        XCTAssertEqual(native.k.vm.instructionsExecuted, 0)
        XCTAssertGreaterThanOrEqual(native.k.dynExprEvaluations, Int64(formulas.count * samples.count))
        terry.close(); native.close()
        var table = "category       formulas identical rejected(outside subset; interpreter accepted) rejected(both errors) mismatch\n"
        func pad(_ s: String) -> String { s.padding(toLength: 14, withPad: " ", startingAt: 0) }
        for (cat, v) in rows { table += pad(cat) + String(format: " %8d %9d %8d %8d %8d\n", v[0], v[1], v[2], v[3], v[4]) }
        let tot = (0..<5).map { i in rows.reduce(0) { $0 + $1.1[i] } }
        table += pad("total") + String(format: " %8d %9d %8d %8d %8d\n", tot[0], tot[1], tot[2], tot[3], tot[4])
        print(table)
        print("swift interpreter vs fixture: \(terryMismatch.count) formulas differ")
        for m in terryMismatch.prefix(20) { print("  " + m) }
        for m in nativeMismatch.prefix(20) { print("  native: " + m) }
        print("rejected: \(rejected)")
        XCTAssertEqual(terryMismatch.count, 0, terryMismatch.prefix(5).joined(separator: "\n"))
        XCTAssertEqual(nativeMismatch.count, 0, nativeMismatch.prefix(5).joined(separator: "\n"))
        XCTAssertEqual(rejected, ["invalid-11", "unsupported-01", "unsupported-02", "unsupported-03", "unsupported-04", "unsupported-05", "unsupported-07"])
    }

    func testRandomExpressionsAgainstTheInterpreter() throws {
        let n = Int(ProcessInfo.processInfo.environment["TEMPLEOS_DYNEXPR_FUZZ"] ?? "") ?? 3000
        let gen = DynGen(20261020)
        let terry = try ExeHarness(.terry)
        let native = try ExeHarness(.native)
        let xs = [-45.0, -1.0, 0.0, 0.5, 7.0, 320.0]
        var ran = 0, errors = 0, raised = 0, outside = 0, mismatch = 0
        var report = ""
        for i in 0..<n {
            let text = gen.text()
            let x = xs[i % xs.count]
            let a = terry.run(text, x), b = native.run(text, x)
            if isOutside(b[5]) { outside += 1; report += "outside: [\(text)] \(b[5])\n" }
            else if a != b { mismatch += 1; report += "[\(text)] x=\(x)\n  terry =\(a)\n  native=\(b)\n" }
            else if isCompileError(a[5]) { errors += 1 }
            else if a[5].hasPrefix("ex:") { raised += 1 }
            else { ran += 1 }
        }
        XCTAssertEqual(native.k.vm.instructionsExecuted, 0)
        terry.close(); native.close()
        print("fuzz: \(n) expressions: \(ran) evaluated alike, \(errors) compile errors alike, \(raised) exceptions alike, \(outside) outside the subset, \(mismatch) mismatches")
        print(String(report.prefix(4000)))
        XCTAssertEqual(mismatch + outside, 0, String(report.prefix(3000)))
    }

    // ------------------------------------------------------------ Cartesian on both engines

    private func tap(_ ms: Int64, _ ch: Character) -> [Ev] {
        let (c, sc) = Keys.forChar(Int(ch.unicodeScalars.first!.value))
        return [.key(ms, c, sc, true), .key(ms + 40, c, sc | Keys.SCF_KEY_UP, false)]
    }

    private func cartesianScript(_ formulas: [String], escape: Bool) -> ([Ev], Int64) {
        var ev: [Ev] = []
        var ms: Int64 = 600
        for f in formulas {
            for c in f { ev += tap(ms, c); ms += 100 }
            ev += tap(ms, "\n"); ms += 100
            ms += 1500
            ev += tap(ms, " "); ms += 600
        }
        if escape {
            let (c, sc) = Keys.special(Keys.SC_ESC)
            ev += [.key(ms, c, sc, true), .key(ms + 40, c, sc | Keys.SCF_KEY_UP, false)]
        }
        return (ev, ms + 1500)
    }

    private func compareWithKotlin(_ id: String, _ a: [Checkpoint], _ b: [Checkpoint]) -> [String] {
        var out: [String] = []
        if let kt = kotlinCheckpoints(id, "terry") { if let d = firstDifference(a, kt) { out.append("swift terry vs kotlin terry: \(d)") } else { print("\(id): swift terry == kotlin terry") } }
        else { print("\(id): no Kotlin checkpoints (run the Kotlin DynExprDiffTest first)") }
        if let kn = kotlinCheckpoints(id, "native") { if let d = firstDifference(b, kn) { out.append("swift native vs kotlin native: \(d)") } else { print("\(id): swift native == kotlin native") } }
        return out
    }

    func testCartesianRunsNativelyWithTypedFormulas() throws {
        let formulas = ["2*x", "Sin(x/20)*100", "x*x/100", "2*", "0<x<100 ^^ x`2/500>20"]
        let (ev, dur) = cartesianScript(formulas, escape: true)
        let (ka, a) = try runScript(CARTESIAN, .terry, ev, dur)
        let (kb, b) = try runScript(CARTESIAN, .native, ev, dur)
        let evals = kb.dynExprEvaluations, compiles = kb.dynExprCompiles, ins = kb.vm.instructionsExecuted
        ka.terminate("done"); kb.terminate("done")
        print("Cartesian: native ExePrint evaluations=\(evals) compiles=\(compiles) bytecode=\(ins); terry frames=\(a.last!.frames) ticks=\(a.last!.ticks)")
        XCTAssertNil(firstDifference(a, b))
        XCTAssertEqual(compareWithKotlin("dynexpr.cartesian-formulas", a, b), [])
        XCTAssertEqual(ins, 0)
        XCTAssertTrue(evals % Int64(formulas.count) == 0 && evals / Int64(formulas.count) > 600, "evaluations: \(evals)")
        XCTAssertEqual(compiles, Int64(formulas.count))
    }

    func testCartesianDivisionByZeroEndsTheProgramAlike() throws {
        let (ev, dur) = cartesianScript(["1/0"], escape: false)
        let (ka, a) = try runScript(CARTESIAN, .terry, ev, dur)
        let (kb, b) = try runScript(CARTESIAN, .native, ev, dur)
        let ca = ka.console.plainText()
        ka.terminate("done"); kb.terminate("done")
        print("Cartesian 1/0, console: \(ca.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " | "))")
        XCTAssertNil(firstDifference(a, b))
        XCTAssertEqual(compareWithKotlin("dynexpr.cartesian-divzero", a, b), [])
        XCTAssertTrue(ca.contains("DivZero"), ca)
    }

    // ------------------------------------------------------------ timing (run with -c release)

    private final class PlainScope: DynScope {
        unowned let k: Kernel
        init(_ k: Kernel) { self.k = k }
        func symbol(_ name: String) -> Sym? { k.prog.globals[name] }
        func isClassName(_ name: String) -> Bool { k.prog.classes[name] != nil }
        func isKnownMacro(_ name: String) -> Bool { false }
    }

    func testTimings() throws {
        let native = try ExeHarness(.native)
        let terry = try ExeHarness(.terry)
        let k = native.k
        let scope = PlainScope(k)
        let prelude = k.preludeGlobals
        let formulas = ["2*x", "Sin(x/20)*100", "x*x*x*x/1000000-x*x/100", "Abs(Sin(x/30))*Exp(-Abs(x)/200)*150", "Sqr(x)/100"]
        var out = "Swift: parse+check one text, evaluate it once (cached, through DynExprEngine.exePrint), and graph it (641 ExePrint calls through the kernel's native; best of 10) natively and on the interpreter\n"
        out += "formula".padding(toLength: 42, withPad: " ", startingAt: 0) + "  parse+check     evaluate   graph native    graph terry\n"
        for f in formulas {
            let src = latin1("ToF64(\(f));")
            for _ in 0..<500 { _ = DynExpr.compile(src, scope, { !prelude.contains($0.name) }) }
            let n1 = 5000
            var t0 = monoNanos()
            for _ in 0..<n1 { _ = DynExpr.compile(src, scope, { !prelude.contains($0.name) }) }
            let parseNs = Double(monoNanos() - t0) / Double(n1)
            for _ in 0..<5 { _ = try native.graph(f); _ = try terry.graph(f) }
            var gn = Int64.max, gt = Int64.max
            for _ in 0..<10 { gn = min(gn, try native.graph(f)); gt = min(gt, try terry.graph(f)) }
            let t = k.adamTask!
            for _ in 0..<5000 { _ = try k.dynExpr.exePrint(t, src, rethrow: false) }
            let n2 = 50000
            t0 = monoNanos()
            for _ in 0..<n2 { _ = try k.dynExpr.exePrint(t, src, rethrow: false) }
            let evalNs = Double(monoNanos() - t0) / Double(n2)
            out += String(f.prefix(42)).padding(toLength: 42, withPad: " ", startingAt: 0) + String(format: " %9.2f us %9.2f us %11.3f ms %11.3f ms\n", parseNs / 1000, evalNs / 1000, Double(gn) / 1e6, Double(gt) / 1e6)
        }
        native.close(); terry.close()
        print(out)
    }
}

import Foundation
import XCTest
@testable import TempleCore

/**
 * Runs the shared, source-derived program scenarios (shared/fidelity/scenarios.json) on the Swift
 * runtime: the same file and the same rules as ScenarioTest.kt. TEMPLEOS_SCENARIOS selects:
 * unset = the regression list, "all" = every scenario that is not slow, "slow" = all, or id prefixes.
 * Results: .build/scenario-results.json.
 */
final class ScenarioTests: XCTestCase {
    static let REGRESSION = [
        "game.battlelines#0", "game.battlelines#1", "game.digits#0", "game.digits#2", "game.circletrace#2",
        "game.flapbat#0", "game.flapbat#1", "game.zing#0", "game.zing#1", "game.raindrops#2", "demo.mousedemo#1",
        "demo.mousedemo#2", "demo.charanimation#1", "game.elephantwalk#1", "game.elephantwalk#0", "game.rocket#1",
        "game.whap#0", "game.whap#1", "demo.speedline#2",
        "demo.cartesian#3", "demo.scrollbars#3", "demo.transform#4", "demo.elephant#1", "app.span#1", "demo.collision#1", "game.tictactoe#0", "game.tictactoe#1",
    ]

    static func keyOf(_ k: String) throws -> (Int, Int64) {
        switch k {
        case "CH_ESC", "ESC", "SC_ESC": return Keys.special(Keys.SC_ESC)
        case "CH_SHIFT_ESC": return Keys.special(Keys.SC_ESC, shift: true)
        case "SC_ENTER": return Keys.special(Keys.SC_ENTER)
        case "SC_SPACE": return Keys.forChar(32)
        case "SC_CURSOR_UP": return Keys.special(Keys.SC_CURSOR_UP)
        case "SC_CURSOR_DOWN": return Keys.special(Keys.SC_CURSOR_DOWN)
        case "SC_CURSOR_LEFT": return Keys.special(Keys.SC_CURSOR_LEFT)
        case "SC_CURSOR_RIGHT": return Keys.special(Keys.SC_CURSOR_RIGHT)
        case "SC_HOME": return Keys.special(Keys.SC_HOME)
        case "SC_END": return Keys.special(Keys.SC_END)
        case "SC_PAGE_UP": return Keys.special(Keys.SC_PAGE_UP)
        case "SC_PAGE_DOWN": return Keys.special(Keys.SC_PAGE_DOWN)
        case "SC_DELETE": return Keys.special(Keys.SC_DELETE)
        case "SC_BACKSPACE": return Keys.special(Keys.SC_BACKSPACE)
        case "SC_TAB": return Keys.special(Keys.SC_TAB)
        default:
            let u = Array(k.unicodeScalars)
            if u.count == 1 { return Keys.forChar(Int(u[0].value) & 0xFF) }
            if k.hasPrefix("SC_F"), let n = Int(k.dropFirst(4)) { return Keys.special(n <= 10 ? Keys.SC_F1 + n - 1 : 0x57 + n - 11) }
            throw NSError(domain: "scenario", code: 1, userInfo: [NSLocalizedDescriptionKey: "unknown key \(k)"])
        }
    }

    struct Result { let id: String, status: String, detail: String }

    private final class ScenarioEnv: KernelEnv {
        let fs: VirtualFs?
        var answers: [Int64]
        let memMb: Int
        init(_ fs: VirtualFs, _ answers: [Int64], _ memMb: Int) { self.fs = fs; self.answers = answers; self.memMb = memMb }
        func runtimeFile(_ name: String) -> [UInt8]? { readFileBytes(SHARED.appendingPathComponent("runtime/\(name)")) }
        func sound(_ kernel: Kernel, _ freq: Double, _ atNs: Int64) {}
        func entropy() -> Int64 { 12345 }
        var memoryLimit: Int { memMb << 20 }
        func popupRequested(_ kernel: Kernel, _ req: PopupRequest) {
            if !answers.isEmpty { req.result = answers.removeFirst() }
            else { req.result = req.items.first(where: { $0.value != -1 })?.value ?? -1 }
        }
    }

    private func findMember(_ c: ClassType, _ n: String) -> Member? { c.find(n) ?? c.base.flatMap { findMember($0, n) } }

    private struct ProbeError: Error, CustomStringConvertible { let description: String }

    /** Reads a probe path (`a.b[2]->c`, `$main.x`) with the compiler's own types. */
    private func probe(_ k: Kernel, _ path: String) throws -> Double {
        let re = try NSRegularExpression(pattern: #"\$?[A-Za-z_\x{80}-\x{FF}][A-Za-z0-9_\x{80}-\x{FF}]*|->|\.|\[|]|\d+"#)
        let toks = re.matches(in: path, range: NSRange(path.startIndex..., in: path)).map { String(path[Range($0.range, in: path)!]) }
        var i = 0
        var addr: Int64
        var type: HType
        let first = toks[i]; i += 1
        if first == "$main" { addr = Int64(k.mainTask!.fsAddr); type = k.prog.classes["CTask"]! }
        else {
            guard let g = k.prog.globals[first] as? GlobalSym else { throw ProbeError(description: "no global \(first)") }
            addr = Int64(g.addr); type = g.type
        }
        while i < toks.count {
            let t0 = toks[i]; i += 1
            if t0 == "." || t0 == "->" {
                var t = type
                if let p = t as? PtrType { addr = k.mem.ld8(try k.mem.check(addr, 8)); t = p.target }
                guard let c = t as? ClassType, let m = findMember(c, toks[i]) else { throw ProbeError(description: "\(path): no member \(toks[i])") }
                i += 1
                addr += Int64(m.offset); type = m.type
            } else if t0 == "[" {
                let n = Int64(toks[i])!; i += 2
                if let a = type as? ArrType { addr += n * Int64(a.elem.size); type = a.elem }
                else if let p = type as? PtrType { addr = k.mem.ld8(try k.mem.check(addr, 8)) + n * Int64(p.target.size); type = p.target }
                else { throw ProbeError(description: "\(path): not indexable") }
            }
        }
        let a = try k.mem.check(addr, max(1, type.size))
        if type is F64Type { return Double(bitPattern: UInt64(bitPattern: k.mem.ld8(a))) }
        if let it = type as? IntType {
            let v: Int64
            switch it.size { case 1: v = k.mem.ld1(a); case 2: v = k.mem.ld2(a); case 4: v = k.mem.ld4(a); default: v = k.mem.ld8(a) }
            if it.signed {
                switch it.size {
                case 1: return Double(Int8(truncatingIfNeeded: v)); case 2: return Double(Int16(truncatingIfNeeded: v))
                case 4: return Double(Int32(truncatingIfNeeded: v)); default: return Double(v)
                }
            }
            return it.size == 8 ? Double(UInt64(bitPattern: v)) : Double(v)
        }
        if type is PtrType || (type as? ClassType)?.valueType != nil { return Double(k.mem.ld8(a)) }
        throw ProbeError(description: "\(path) is not a scalar (\(type))")
    }

    private func runOne(_ sc: [String: Any]) throws -> Result {
        let id = sc["id"] as! String
        let steps = sc["steps"] as! [[Any]]
        let expect = sc["expect"] as! [String: Any]
        let answers = steps.filter { ($0[0] as! String) == "popup" }.map { Int64(($0[1] as! NSNumber).int64Value) }
        let prog = sc["program"] as! String
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("scen-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let fs = LayeredFs(DirBundle(SHARED.appendingPathComponent("bundled-fs"), SHARED.appendingPathComponent("bundled-fs.index")), tmp)
        let k = Kernel(ScenarioEnv(fs, answers, prog.contains("Talons") ? 96 : 32), String(prog.split(separator: "/").last!))
        k.virtualTime = true
        try k.boot()
        defer { k.terminate("done") }
        guard let src = fs.readFile(prog) else { return Result(id: id, status: "ERROR", detail: "no file") }
        try k.runProgram(prog, src)
        let wallEnd = Date().addingTimeInterval(120)
        func advance(_ ms: Int64) throws {
            let stop = k.now() + ms * 1_000_000
            k.virtualStopAt = stop
            while k.now() < stop && !k.finished && Date() < wallEnd { if try k.step(50_000_000) < 0 { break } }
        }
        func mouse(_ x: Int, _ y: Int, _ l: Bool, _ r: Bool) { k.post(.mouse(x: x, y: y, lb: l, rb: r)) }
        func num(_ v: Any) -> Int { (v as! NSNumber).intValue }
        try advance(1)
        for s in steps {
            switch s[0] as! String {
            case "wait_ms": try advance(Int64(num(s[1])))
            case "key": let (ch, c) = try ScenarioTests.keyOf(s[1] as! String); k.post(.key(ch: ch, sc: c, down: true)); k.post(.key(ch: ch, sc: c | Keys.SCF_KEY_UP, down: false)); try advance(40)
            case "key_down": let (ch, c) = try ScenarioTests.keyOf(s[1] as! String); k.post(.key(ch: ch, sc: c, down: true)); try advance(1)
            case "key_up": let (ch, c) = try ScenarioTests.keyOf(s[1] as! String); k.post(.key(ch: ch, sc: c | Keys.SCF_KEY_UP, down: false)); try advance(1)
            case "click", "rclick":
                let x = num(s[1]), y = num(s[2]), r = (s[0] as! String) == "rclick"
                mouse(x, y, !r, r); try advance(70); mouse(x, y, false, false); try advance(70)
            case "drag":
                let x0 = num(s[1]), y0 = num(s[2]), x1 = num(s[3]), y1 = num(s[4])
                mouse(x0, y0, true, false); try advance(50)
                for j in 1...5 { mouse(x0 + (x1 - x0) * j / 5, y0 + (y1 - y0) * j / 5, true, false); try advance(40) }
                mouse(x1, y1, false, false); try advance(50)
            case "popup": try advance(1)
            case "menu":
                let path = s[1] as! String
                var m: MenuSnap?
                for _ in 0..<40 { m = k.menuSnapshot.first { $0.path == path }; if m != nil { break }; try advance(50) }
                guard let mm = m else { return Result(id: id, status: "ERROR", detail: "menu \(path) not found") }
                k.post(.raw(code: Int(mm.msgCode), a1: mm.a1, a2: mm.a2)); try advance(40)
            default: break
            }
        }
        if let want = expect["exited"] as? Bool {
            return k.finished == want ? Result(id: id, status: "PASS", detail: "exited=\(k.finished)")
                : Result(id: id, status: "FAIL", detail: "exited=\(k.finished) (want \(want)) \(k.exitMessage ?? "")")
        }
        do {
            let v = try probe(k, expect["global"] as! String)
            let want = (expect["value"] as! NSNumber).doubleValue
            let ok: Bool
            switch expect["op"] as! String {
            case "<": ok = v < want; case "<=": ok = v <= want; case "==": ok = v == want
            case "!=": ok = v != want; case ">=": ok = v >= want; default: ok = v > want
            }
            return Result(id: id, status: ok ? "PASS" : "FAIL", detail: "\(expect["global"]!)=\(v) \(expect["op"]!) \(want)" + (k.finished ? " (ended: \(k.exitMessage ?? "normally"))" : ""))
        } catch { return Result(id: id, status: "ERROR", detail: "\(error)") }
    }

    func testScenarios() throws {
        let sel = ProcessInfo.processInfo.environment["TEMPLEOS_SCENARIOS"] ?? "regression"
        let data = try Data(contentsOf: SHARED.appendingPathComponent("fidelity/scenarios.json"))
        let all = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["scenarios"] as! [[String: Any]]
        let chosen = all.filter { sc in
            let id = sc["id"] as! String
            switch sel {
            case "regression": return ScenarioTests.REGRESSION.contains(id)
            case "all": return (sc["slow"] as? Bool) != true
            case "slow": return true
            default: return sel.split(separator: ",").contains { id.hasPrefix(String($0)) }
            }
        }
        var results: [Result] = []
        for sc in chosen {
            let r: Result
            do { r = try runOne(sc) } catch { r = Result(id: sc["id"] as! String, status: "ERROR", detail: "\(error)") }
            print("SCENARIO \(r.id) \(r.status) \(r.detail)")
            results.append(r)
        }
        let json = "[\n" + results.map { "{\"id\":\"\($0.id)\",\"status\":\"\($0.status)\",\"detail\":\"\(String(String.UnicodeScalarView($0.detail.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "'").unicodeScalars.map { $0.value < 32 ? " " : $0 })))\"}" }.joined(separator: ",\n") + "\n]\n"
        try? json.write(toFile: SHARED.deletingLastPathComponent().appendingPathComponent("temple_os_swift/TempleCore/.build/scenario-results.json").path, atomically: true, encoding: .utf8)
        if sel == "regression" {
            let bad = results.filter { $0.status != "PASS" }
            XCTAssertTrue(bad.isEmpty, "scenarios failed:\n" + bad.map { "\($0.id) \($0.status) \($0.detail)" }.joined(separator: "\n"))
            XCTAssertEqual(results.count, ScenarioTests.REGRESSION.count, "every regression scenario exists")
        }
    }
}

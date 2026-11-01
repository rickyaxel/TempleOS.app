import XCTest
import TempleCore
import PureSwift

/**
 * Differential tests (port of ParityTest.kt): the same program, input and virtual clock on the Swift
 * interpreter (Pure Terry) and on its Swift translation (Pure Swift); when the Kotlin harness has run,
 * both are also compared with its Kotlin runs (four engines, one behaviour).
 *
 *   TEMPLEOS_PARITY=all|<path>[,<path>]   every / chosen translated catalog program (default: BomberGolf)
 */
final class ParityTests: XCTestCase {
    func testBomberGolfSweep() throws {
        try check("game.bombergolf", "C:/Demo/Games/BomberGolf.HC", 4000)
    }

    /** TreeCheckers completes its source from the board size chosen at start: every size, both engines. */
    func testTreeCheckersEveryBoardSize() throws {
        let path = "C:/Demo/Games/TreeCheckers.HC", evs = sweepScript(1500)
        for size: Int64 in 1...9 {
            let (ka, a) = try runScript(path, .terry, evs, 1500, popups: [size])
            let (kb, b) = try runScript(path, .native, evs, 1500, popups: [size])
            XCTAssertFalse(ka.finished, "size \(size): the program ended (\(ka.exitMessage ?? ""))")
            ka.terminate("done"); kb.terminate("done")
            XCTAssertNil(firstDifference(a, b), "size \(size)")
        }
    }

    func testSweepAll() throws {
        guard let which = ProcessInfo.processInfo.environment["TEMPLEOS_PARITY"] else { return }
        let cat = try Catalog.parse(String(contentsOf: SHARED.appendingPathComponent("program-manifests/catalog.json"), encoding: .utf8))
        let progs = which == "all" ? cat.programs.map { ($0.id, $0.path) } : which.split(separator: ",").map { p in (cat.programs.first { $0.path == String(p) }?.id ?? String(p), String(p)) }
        let secs = Int64(ProcessInfo.processInfo.environment["TEMPLEOS_PARITYSECS"] ?? "") ?? 4
        var rows: [String] = []
        var pass = 0, fail = 0, skipped = 0
        NativePrograms.catalog = NativeCatalog.source
        for (id, path) in progs {
            if NativePrograms.find(path) == nil { skipped += 1; rows.append("{\"id\": \"\(id)\", \"status\": \"not-translated\"}"); continue }
            let r: String?
            // per-program durations (TEMPLEOS_PARITYSECSFOR=app.x-caliber=2,...): programs whose interpreted run is very slow
            let override = (ProcessInfo.processInfo.environment["TEMPLEOS_PARITYSECSFOR"] ?? "").split(separator: ",")
                .first { $0.split(separator: "=").first.map(String.init) == id }.flatMap { Int64($0.split(separator: "=").last ?? "") }
            do { r = try compare(id, path, (override ?? secs) * 1000) } catch { r = "exception: \(error)" }
            if r == nil { pass += 1 } else { fail += 1 }
            print(String(format: "%-26@ %@", id as NSString, (r == nil ? "PARITY" : "MISMATCH \(r!)") as NSString))
            rows.append("{\"id\": \"\(id)\", \"status\": \"\(r == nil ? "parity" : "mismatch")\", \"detail\": \"\((r ?? "").replacingOccurrences(of: "\"", with: "'"))\"}")
        }
        let out = "{\n  \"pass\": \(pass), \"fail\": \(fail), \"not_translated\": \(skipped),\n  \"programs\": [\n    " + rows.joined(separator: ",\n    ") + "\n  ]\n}\n"
        try? out.write(to: REPO.appendingPathComponent("temple_os_swift/TempleCore/.build/parity-results-swift.json"), atomically: true, encoding: .utf8)
        print("parity: \(pass) pass, \(fail) mismatch, \(skipped) not translated")
    }

    private func check(_ id: String, _ path: String, _ ms: Int64) throws {
        let r = try compare(id, path, ms)
        XCTAssertNil(r, r ?? "")
    }

    /** nil when the Swift interpreter, the Swift translation and (if available) both Kotlin engines agree. */
    private func compare(_ id: String, _ path: String, _ ms: Int64) throws -> String? {
        let evs = sweepScript(ms)
        let (ka, a) = try runScript(path, .terry, evs, ms)
        let (kb, b) = try runScript(path, .native, evs, ms)
        ka.terminate("done"); kb.terminate("done")
        XCTAssertEqual(kb.vm.instructionsExecuted, 0, "a native kernel must not interpret bytecode")
        // the checkpoints, for offline four-way comparison with the Kotlin runs (purekotlin/build/parity)
        let dir = REPO.appendingPathComponent("temple_os_swift/TempleCore/.build/parity")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? ScenarioRunner.checkpointsJson(a).write(to: dir.appendingPathComponent("\(id).terry.json"), atomically: true, encoding: .utf8)
        try? ScenarioRunner.checkpointsJson(b).write(to: dir.appendingPathComponent("\(id).native.json"), atomically: true, encoding: .utf8)
        var out: [String] = []
        if let d = firstDifference(a, b) { out.append("swift terry vs swift native: \(d)") }
        if let kt = kotlinCheckpoints(id, "terry"), let d = firstDifference(a, kt) { out.append("swift terry vs kotlin terry: \(d)") }
        if let kn = kotlinCheckpoints(id, "native"), let d = firstDifference(b, kn) { out.append("swift native vs kotlin native: \(d)") }
        return out.isEmpty ? nil : out.joined(separator: " | ")
    }
}

/** Debugging aid (port of SliceTraceTest): the first task slice whose result or budget use differs. TEMPLEOS_SLICETRACE=<path> */
final class SliceTraceTests: XCTestCase {
    func testSlices() throws {
        guard let p = ProcessInfo.processInfo.environment["TEMPLEOS_SLICETRACE"] else { return }
        let path = p.isEmpty ? "C:/Demo/Games/BomberGolf.HC" : p
        var plain: [String] = [] // the Kotlin test's format, for cross-platform comparison
        func trace(_ e: Engine) throws -> [String] {
            var out: [String] = []
            let (k, env) = try bootProgram(path, e)
            k.sliceTrace = { t, r, d in if e == .terry { plain.append("\(k.now() / 1000)us \(t.name) r=\(r) ticks=\(d)") }; out.append("\(k.now() / 1000)us \(t.name)#\(t.id) r=\(r) ticks=\(d) snd=\(env.sound.count) late=\(t.lateNs) wake=\(t.wakeAt) st=\(t.state) tasks=\(k.tasks.map { $0.id }) last=\(env.sound.last.map { "\($0.1)" } ?? "")") }
            let evs = sweepScript(4000).sorted { $0.ms < $1.ms }
            var i = 0; var ms: Int64 = 0
            while ms <= 4000 {
                while i < evs.count && evs[i].ms <= ms {
                    switch evs[i] { case .key(_, let ch, let sc, let dn): k.post(.key(ch: ch, sc: sc, down: dn)); case .mouse(_, let x, let y, let lb, let rb): k.post(.mouse(x: x, y: y, lb: lb, rb: rb)) }
                    i += 1
                }
                if !(try advanceTo(k, ms)) { break }
                ms += 20
            }
            k.terminate("done")
            return out
        }
        let a = try trace(.terry), b = try trace(.native)
        // cross-platform: TEMPLEOS_SLICETRACEFILE=<file> writes the interpreter's trace in the Kotlin test's format
        if let f = ProcessInfo.processInfo.environment["TEMPLEOS_SLICETRACEFILE"] { try? (plain.joined(separator: "\n") + "\n").write(toFile: f, atomically: true, encoding: .utf8) }
        guard let i = (0..<min(a.count, b.count)).first(where: { a[$0] != b[$0] }) else { print("slices agree (\(a.count))"); return }
        print("first differing slice #\(i)")
        for j in max(0, i - 5)...min(i + 5, a.count - 1) { print("  terry  \(a[j])\n  native \(j < b.count ? b[j] : "-")") }
    }
}

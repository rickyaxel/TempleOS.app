import Foundation
import XCTest
@testable import TempleCore

/**
 * Port of SoundSweepTest.kt: every catalog program that calls TempleOS sound runs in virtual time with
 * its fidelity scenarios, the generic play script and its targeted script
 * (shared/test-vectors/audio/sound-sweep.json); every speaker change is rendered through PcSpeaker.
 *
 *   default                         a regression subset
 *   TEMPLEOS_SOUNDSWEEP=all         every program (results: docs/audio/data/sound-sweep-swift.json)
 *   TEMPLEOS_SOUNDSWEEP=<id>,...    chosen catalog ids
 */
final class SoundSweepTests: XCTestCase {
    static let REGRESSION: Set<String> = ["example.sound", "game.tictactoe", "game.digits", "game.flapbat", "game.bombergolf"]
    static let RATE = 48000

    private final class SweepEnv: KernelEnv {
        let fs: VirtualFs?
        let memMb: Int
        var log: [(Double, Double)] = []
        var offsetMs = 0.0
        var endedSounding = 0
        init(_ fs: VirtualFs, _ memMb: Int) { self.fs = fs; self.memMb = memMb }
        func runtimeFile(_ name: String) -> [UInt8]? { readFileBytes(SHARED.appendingPathComponent("runtime/\(name)")) }
        func entropy() -> Int64 { 12345 }
        var memoryLimit: Int { memMb << 20 }
        func sound(_ kernel: Kernel, _ freq: Double, _ atNs: Int64) { log.append((offsetMs + Double(kernel.now()) / 1e6, freq)) }
        func popupRequested(_ kernel: Kernel, _ req: PopupRequest) { req.result = req.items.first(where: { $0.value != -1 })?.value ?? -1 }
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func num(_ v: Any) -> Int { (v as! NSNumber).intValue }

    /** One run (scenario step format plus hold/press/move); returns the exit message if the program ended. */
    private func run(_ env: SweepEnv, _ prog: String, _ steps: [[Any]]) throws -> String? {
        let k = Kernel(env, String(prog.split(separator: "/").last!))
        k.virtualTime = true
        let before = env.log.count
        try k.boot()
        env.log.removeSubrange(before...)
        let first = env.log.count
        guard let src = env.fs!.readFile(prog) else { return "no file" }
        try k.runProgram(prog, src)
        let wallEnd = Date().addingTimeInterval(90)
        func advance(_ ms: Int64) throws {
            let stop = k.now() + ms * 1_000_000
            k.virtualStopAt = stop
            while k.now() < stop && !k.finished && Date() < wallEnd { if try k.step(50_000_000) < 0 { break } }
        }
        func mouse(_ x: Int, _ y: Int, _ l: Bool, _ r: Bool) { k.post(.mouse(x: x, y: y, lb: l, rb: r)) }
        func key(_ s: Any) throws -> (Int, Int64) { try ScenarioTests.keyOf(s as! String) }
        try advance(1)
        for s in steps {
            if k.finished { break }
            switch s[0] as! String {
            case "wait_ms": try advance(Int64(num(s[1])))
            case "key": let (ch, c) = try key(s[1]); k.post(.key(ch: ch, sc: c, down: true)); k.post(.key(ch: ch, sc: c | Keys.SCF_KEY_UP, down: false)); try advance(40)
            case "key_down": let (ch, c) = try key(s[1]); k.post(.key(ch: ch, sc: c, down: true)); try advance(1)
            case "key_up": let (ch, c) = try key(s[1]); k.post(.key(ch: ch, sc: c | Keys.SCF_KEY_UP, down: false)); try advance(1)
            case "hold":
                let (ch, c) = try key(s[1]); k.post(.key(ch: ch, sc: c, down: true)); try advance(Int64(num(s[2])))
                k.post(.key(ch: ch, sc: c | Keys.SCF_KEY_UP, down: false)); try advance(20)
            case "click", "rclick":
                let x = num(s[1]), y = num(s[2]), r = (s[0] as! String) == "rclick"
                mouse(x, y, !r, r); try advance(70); mouse(x, y, false, false); try advance(70)
            case "press":
                let x = num(s[1]), y = num(s[2])
                mouse(x, y, true, false); try advance(Int64(num(s[3]))); mouse(x, y, false, false); try advance(50)
            case "move": mouse(num(s[1]), num(s[2]), false, false); try advance(30)
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
                if let mm = m { k.post(.raw(code: Int(mm.msgCode), a1: mm.a1, a2: mm.a2)); try advance(40) }
            default: break
            }
        }
        try advance(500)
        let msg = k.finished ? k.exitMessage : nil
        let end = Double(k.now()) / 1e6
        k.terminate("done")
        if env.log.count > first && env.log.last!.1 != 0 { env.endedSounding += 1 }
        env.offsetMs += end + 1000
        return msg
    }

    private func genericPlay(_ seconds: Int) -> [[Any]] {
        var s: [[Any]] = [["wait_ms", 1500]]
        let arrows = ["SC_CURSOR_LEFT", "SC_CURSOR_UP", "SC_CURSOR_RIGHT", "SC_CURSOR_DOWN"]
        for r in 0..<(seconds * 2) {
            switch r % 6 {
            case 0: s.append(["key", "SC_SPACE"])
            case 1: s.append(["hold", arrows[(r / 6) % 4], 250])
            case 2: s.append(["click", 40 + (r * 137) % 560, 40 + (r * 89) % 400])
            case 3: s.append(["key", "SC_ENTER"])
            case 4: s.append(["rclick", 40 + (r * 211) % 560, 40 + (r * 53) % 400])
            default: s.append(["key", "\(1 + (r / 6) % 3)"])
            }
            s.append(["wait_ms", 260])
        }
        return s
    }

    func testSoundSweep() throws {
        let sel = ProcessInfo.processInfo.environment["TEMPLEOS_SOUNDSWEEP"]
        let ids: Set<String>? = sel == nil ? SoundSweepTests.REGRESSION : sel == "all" ? nil : Set(sel!.split(separator: ",").map(String.init))
        let docs = REPO.appendingPathComponent("docs")
        let inv = try json(docs.appendingPathComponent("audio/data/sound-inventory.json"))["rows"] as! [[String: Any]]
        let scen = try json(SHARED.appendingPathComponent("fidelity/scenarios.json"))["scenarios"] as! [[String: Any]]
        let targeted = try json(SHARED.appendingPathComponent("test-vectors/audio/sound-sweep.json"))["programs"] as! [String: [String: Any]]
        let catalog = try json(SHARED.appendingPathComponent("program-manifests/catalog.json"))["programs"] as! [[String: Any]]
        var rows: [String] = []
        var bad: [String] = []
        for row in inv {
            let id = row["id"] as! String
            if let ids = ids, !ids.contains(id) { continue }
            let entry = catalog.first { ($0["id"] as! String) == id }!
            let prog = entry["path"] as! String, status = entry["status"] as! String, title = row["title"] as! String
            let t = targeted[id]
            if status == "unsupported" {
                print("SOUNDSWEEP \(id) unsupported: skipped")
                rows.append("{\"id\":\"\(id)\",\"title\":\"\(title)\",\"status\":\"\(status)\",\"pass\":true,\"runs\":0,\"changes\":0,\"tones\":0,\"distinct_hz\":0,\"audible_ms\":0.0,\"note\":\"not runnable on TempleOS Mobile\"}")
                continue
            }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-\(UUID().uuidString)").path
            try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tmp) }
            let env = SweepEnv(LayeredFs(DirBundle(SHARED.appendingPathComponent("bundled-fs"), SHARED.appendingPathComponent("bundled-fs.index")), tmp),
                               id == "game.talons" ? 96 : 32)
            var scripts: [[[Any]]] = []
            if let st = t?["steps"] as? [[Any]] { scripts.append(st) }
            if (t?["only_targeted"] as? Bool) != true {
                for sc in scen where (sc["program"] as! String) == prog && (sc["slow"] as? Bool) != true { scripts.append(sc["steps"] as! [[Any]]) }
                scripts.append(genericPlay((t?["generic_s"] as? NSNumber)?.intValue ?? 20))
            }
            var errors: [String] = []
            for st in scripts {
                let msg: String?
                do { msg = try run(env, prog, st) } catch { msg = "crash: \(error)" }
                if let m = msg, m.range(of: "crash|fault|Except|error", options: [.regularExpression, .caseInsensitive]) != nil { errors.append(String(m.prefix(120))) }
            }
            let log = env.log
            if let d = ProcessInfo.processInfo.environment["TEMPLEOS_SOUNDSWEEP_DUMP"] {
                try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
                try? log.map { String(format: "%.3f %.4f", $0.0, $0.1) }.joined(separator: "\n").write(toFile: d + "/\(id).txt", atomically: true, encoding: .utf8)
            }
            let sounding = log.filter { $0.1 > 0 }.count
            let invalid = log.filter { !($0.1 == 0 || ($0.1.isFinite && $0.1 >= 18.2 && $0.1 <= 1193182)) }.count
            var perSecond: [Int64: Int] = [:]
            for e in log { perSecond[Int64(e.0 / 1000), default: 0] += 1 }
            var audibleMs = 0.0
            if sounding > 0 {
                let sp = PcSpeaker(SoundSweepTests.RATE, 20_000_000, capacity: 4096)
                let base: Int64 = 10_000_000_000
                var buf = [Float](repeating: 0, count: 4800)
                var frame: Int64 = 0, idx = 0
                let endMs = log.last!.0 + 200
                var tNs = base
                while Double(tNs - base) / 1e6 < endMs {
                    while idx < log.count && log[idx].0 * 1e6 <= Double(tNs - base) + 100_000_000 { sp.post(base + Int64(log[idx].0 * 1e6), log[idx].1); idx += 1 }
                    sp.render(&buf, 0, buf.count, nowNs: tNs)
                    audibleMs += Double(buf.filter { abs(Double($0)) >= PcSpeaker.AMPLITUDE / 2 }.count) * 1000 / Double(SoundSweepTests.RATE)
                    frame += Int64(buf.count); tNs = base + frame * 1_000_000_000 / Int64(SoundSweepTests.RATE)
                }
            }
            let expectSilent = (t?["expect_silent"] as? Bool) == true
            let pass = errors.isEmpty && invalid == 0 && env.endedSounding == 0 && (expectSilent ? sounding == 0 : audibleMs > 20)
            let distinct = Set(log.map { $0.1 }.filter { $0 > 0 }).count
            let audible = (audibleMs * 10).rounded() / 10
            print("SOUNDSWEEP \(id) \(pass ? "PASS" : "FAIL") runs=\(scripts.count) changes=\(log.count) tones=\(sounding) distinct=\(distinct) audible_ms=\(audible) max_per_s=\(perSecond.values.max() ?? 0) invalid=\(invalid) ended_sounding=\(env.endedSounding) \(errors)")
            rows.append("{\"id\":\"\(id)\",\"title\":\"\(title)\",\"status\":\"\(status)\",\"pass\":\(pass),\"runs\":\(scripts.count),\"changes\":\(log.count),\"tones\":\(sounding),\"distinct_hz\":\(distinct),\"audible_ms\":\(audible),\"max_changes_per_s\":\(perSecond.values.max() ?? 0),\"invalid\":\(invalid),\"ended_sounding\":\(env.endedSounding)}")
            if !pass { bad.append("\(id): tones=\(sounding) audible_ms=\(audible) invalid=\(invalid) ended_sounding=\(env.endedSounding) \(errors)") }
        }
        if sel == "all" {
            let out = docs.appendingPathComponent("audio/data/sound-sweep-swift.json")
            try ("{\"platform\": \"swift\", \"results\": [\n" + rows.joined(separator: ",\n") + "\n]}\n").write(to: out, atomically: true, encoding: .utf8)
            print("wrote \(out.path)")
        }
        XCTAssertTrue(bad.isEmpty, "programs without valid sound:\n" + bad.joined(separator: "\n"))
    }
}

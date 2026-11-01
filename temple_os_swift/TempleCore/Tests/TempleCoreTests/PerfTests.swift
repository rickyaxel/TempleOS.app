import Foundation
import XCTest
@testable import TempleCore

/**
 * Port of PerfTest.kt: real-clock program benchmarks (opt-in). TEMPLEOS_PERF=<catalog ids or path parts,
 * comma separated, or "all">, TEMPLEOS_PERFSEC (default 6), TEMPLEOS_PERFOUT (default .build/perf-swift.json).
 * Each program runs as KernelRunner runs it in the app (step(12 ms), then wait), with the player input of
 * shared/benchmark-scenarios/player-input.json; a program that ends under it is measured again with the mouse
 * only. Run it in Release (`swift test -c release`) for app-like numbers.
 */
final class PerfTests: XCTestCase {
    private func threadCpuNs() -> Int64 {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)
    }

    func testPerf() throws {
        let envv = ProcessInfo.processInfo.environment
        guard let which = envv["TEMPLEOS_PERF"] else { return }
        let seconds = Double(envv["TEMPLEOS_PERFSEC"] ?? "") ?? 6
        let root = SHARED.appendingPathComponent("bundled-fs")
        let cat = try Catalog.parse(String(contentsOf: SHARED.appendingPathComponent("program-manifests/catalog.json"), encoding: .utf8))
        let progs = cat.programs.filter { p in which == "all" || which.split(separator: ",").contains { p.id == $0 || p.path.contains($0) } }
        var rows: [String] = []
        for p in progs {
            guard var res = try measure(p, root, seconds, keys: true) else { rows.append("{\"id\": \"\(p.id)\", \"crash\": true}"); continue }
            if res.finished, let r2 = try measure(p, root, seconds, keys: false) { res = r2 }
            rows.append(res.json)
        }
        let json = "[\n  " + rows.joined(separator: ",\n  ") + "\n]\n"
        let out = URL(fileURLWithPath: envv["TEMPLEOS_PERFOUT"] ?? FileManager.default.currentDirectoryPath + "/.build/perf-swift.json")
        try json.write(to: out, atomically: true, encoding: .utf8)
        print("PERF swift (\(seconds) s each):\n" + json)
    }

    private struct Result {
        let id: String, input: String, finished: Bool, bootMs: Double, fps: Double, composeMean: Double, p50: Double, p95: Double, maxMs: Double
        let cpu: Double, minstr: Double, published: Double, tones: Double
        var json: String {
            func f(_ v: Double) -> String { String(format: "%.2f", v) }
            return "{\"id\": \"\(id)\", \"input\": \"\(input)\", \"finished\": \(finished), \"bootMs\": \(f(bootMs)), \"fps\": \(f(fps)), \"composeMeanMs\": \(f(composeMean)), " +
                "\"composeP50Ms\": \(f(p50)), \"composeP95Ms\": \(f(p95)), \"composeMaxMs\": \(f(maxMs)), \"cpuPct\": \(f(cpu)), \"minstrPerSec\": \(f(minstr)), " +
                "\"publishedPerSec\": \(f(published)), \"tonesPerSec\": \(f(tones))}"
        }
    }

    private func measure(_ p: ProgramInfo, _ root: URL, _ seconds: Double, keys: Bool) throws -> Result? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let env = TestEnv(LayeredFs(DirBundle(root, SHARED.appendingPathComponent("bundled-fs.index")), tmp))
        let k = Kernel(env, p.id)
        let b0 = monoNanos()
        try k.boot()
        let bootMs = Double(monoNanos() - b0) / 1e6
        guard let src = readFileBytes(root.appendingPathComponent(String(p.path.dropFirst(3)))) else { return nil }
        do { try k.runProgram(p.path, src) } catch { return nil }
        let start = monoNanos(), warm = start + 1_000_000_000, end = warm + Int64(seconds * 1e9)
        var measuring = false
        var fr0: Int64 = 0, cpu0: Int64 = 0, in0: Int64 = 0, pub0: Int64 = 0, tone0 = 0, t0 = start
        var nextKey = start, keyPhase = 0, heldSince: Int64 = -1, lastRepeat: Int64 = 0
        var finished = false
        while true {
            let now = monoNanos()
            if now >= end { break }
            if !measuring && now >= warm {
                measuring = true; k.frameStats.reset()
                fr0 = k.frameCount; cpu0 = threadCpuNs(); in0 = k.vm.instructionsExecuted; pub0 = k.publishedVersion; tone0 = env.sounds.count; t0 = now
            }
            let ms = (now - start) / 1_000_000
            k.post(.mouse(x: 170 + Int((ms / 10) % 300), y: 120 + Int((ms / 7) % 240), lb: (ms / 500) % 4 == 1, rb: false, wheel: 0))
            if keys && now >= nextKey {
                switch keyPhase % 4 {
                case 0, 2: let (ch, sc) = Keys.forChar(32); k.post(.key(ch: ch, sc: sc, down: true)); k.post(.key(ch: ch, sc: sc | Keys.SCF_KEY_UP, down: false))
                case 1: let (ch, sc) = Keys.special(Keys.SC_CURSOR_LEFT); k.post(.key(ch: ch, sc: sc, down: true)); heldSince = now; lastRepeat = now
                default: let (ch, sc) = Keys.special(Keys.SC_CURSOR_LEFT); k.post(.key(ch: ch, sc: sc | Keys.SCF_KEY_UP, down: false)); heldSince = -1
                }
                keyPhase += 1; nextKey = now + 700_000_000
            }
            if keys && heldSince >= 0 && now - heldSince >= 250_000_000 && now - lastRepeat >= 33_000_000 {
                let (ch, sc) = Keys.special(Keys.SC_CURSOR_LEFT); k.post(.key(ch: ch, sc: sc, down: true)); lastRepeat = now
            }
            let wait = (try? k.step(12_000_000)) ?? -1
            if wait < 0 { finished = true; break }
            if wait > 0 { usleep(useconds_t(max(1, min(wait / 1000, 50_000)))) }
        }
        let wall = Double(monoNanos() - t0) / 1e9
        let st = k.frameStats
        let frames = Double(k.frameCount - fr0)
        let res = Result(id: p.id, input: keys ? "keys" : "mouse", finished: finished, bootMs: bootMs, fps: frames / wall,
                         composeMean: st.frames > 0 ? Double(st.composeTotalNs) / 1e6 / Double(st.frames) : 0,
                         p50: Double(st.composePercentile(50)) / 1e6, p95: Double(st.composePercentile(95)) / 1e6, maxMs: Double(st.composeMaxNs) / 1e6,
                         cpu: 100 * Double(threadCpuNs() - cpu0) / 1e9 / wall, minstr: Double(k.vm.instructionsExecuted - in0) / 1e6 / wall,
                         published: Double(k.publishedVersion - pub0) / wall, tones: Double(env.sounds.count - tone0) / wall)
        k.terminate("done")
        return res
    }
}

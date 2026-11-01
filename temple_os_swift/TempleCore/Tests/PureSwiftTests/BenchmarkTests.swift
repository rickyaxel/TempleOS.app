import XCTest
import TempleCore
import PureSwift

/**
 * Pure Terry vs Pure Swift on the same host (port of BenchmarkTest.kt): the cost of simulating the
 * same program, input and virtual time. Run optimized: `swift test -c release --filter BenchmarkTests`.
 *
 *   TEMPLEOS_BENCH=default|<path>[,<path>]  TEMPLEOS_BENCHSECS=10  TEMPLEOS_BENCHRUNS=5
 *
 * Engines alternate after one warm-up run each. Results: .build/bench-swift.json and a table.
 */
final class BenchmarkTests: XCTestCase {
    static let DEFAULT = [
        "C:/Demo/Games/BomberGolf.HC", "C:/Demo/Games/BattleLines.HC", "C:/Demo/Games/Varoom.HC", "C:/Demo/Games/Maze.HC",
        "C:/Apps/X-Caliber/Run.HC", "C:/Demo/Games/Squirt.HC", "C:/Demo/Graphics/Bounce.HC", "C:/Demo/Graphics/Life.HC",
        "C:/Demo/Games/RawHide.HC", "C:/Demo/Games/Talons.HC",
    ]

    struct Sample { let engine: Engine; let wallMs: Double; let cpuMs: Double; let ticks: Int64; let frames: Int64 }

    private func cpuNs() -> Int64 {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return (Int64(u.ru_utime.tv_sec) + Int64(u.ru_stime.tv_sec)) * 1_000_000_000 + (Int64(u.ru_utime.tv_usec) + Int64(u.ru_stime.tv_usec)) * 1_000
    }

    private func once(_ path: String, _ engine: Engine, _ secs: Int64) throws -> Sample {
        let c0 = cpuNs(), t0 = monoNanos()
        let (k, cps) = try runScript(path, engine, sweepScript(secs * 1000), secs * 1000, light: true)
        let t1 = monoNanos(), c1 = cpuNs()
        k.terminate("done")
        let last = cps.last!
        return Sample(engine: engine, wallMs: Double(t1 - t0) / 1e6, cpuMs: Double(c1 - c0) / 1e6, ticks: last.ticks, frames: last.frames)
    }

    func testBenchmark() throws {
        guard let which = ProcessInfo.processInfo.environment["TEMPLEOS_BENCH"] else { return }
        let env = ProcessInfo.processInfo.environment
        let paths = which == "default" ? BenchmarkTests.DEFAULT : which.split(separator: ",").map(String.init)
        let secs = Int64(env["TEMPLEOS_BENCHSECS"] ?? "") ?? 10
        let runs = Int(env["TEMPLEOS_BENCHRUNS"] ?? "") ?? 5
        var rows: [String] = []
        var table = String(format: "%-34@ %12@ %12@ %8@ %10@ %8@\n", "program" as NSString, "terry ms" as NSString, "swift ms" as NSString, "speedup" as NSString, "ticks" as NSString, "frames" as NSString)
        for path in paths {
            do {
                // profiling aid: TEMPLEOS_BENCHONLY=native|terry runs one engine only
                if let only = env["TEMPLEOS_BENCHONLY"] {
                    let s = try once(path, only == "native" ? .native : .terry, secs)
                    table += "\(path) \(only): \(String(format: "%.1f", s.wallMs)) ms\n"
                    continue
                }
                _ = try once(path, .terry, min(secs, 2)); _ = try once(path, .native, min(secs, 2)) // warm-up
                var samples: [Sample] = []
                for i in 0..<runs {
                    for e in (i % 2 == 0 ? [Engine.terry, .native] : [.native, .terry]) { samples.append(try once(path, e, secs)) }
                }
                func med(_ e: Engine, _ f: (Sample) -> Double) -> Double { let v = samples.filter { $0.engine == e }.map(f).sorted(); return v[v.count / 2] }
                let tw = med(.terry) { $0.wallMs }, nw = med(.native) { $0.wallMs }
                let tc = med(.terry) { $0.cpuMs }, nc = med(.native) { $0.cpuMs }
                let same = samples.allSatisfy { $0.ticks == samples[0].ticks && $0.frames == samples[0].frames }
                table += String(format: "%-34@ %12.1f %12.1f %7.2fx %10lld %8lld%@\n", String(path.dropFirst(3)) as NSString, tw, nw, tw / nw, samples[0].ticks, samples[0].frames, (same ? "" : "  (work differed!)") as NSString)
                let ss = samples.map { "{\"engine\": \"\($0.engine)\", \"wall_ms\": \(String(format: "%.1f", $0.wallMs)), \"cpu_ms\": \(String(format: "%.1f", $0.cpuMs))}" }.joined(separator: ", ")
                rows.append("    {\"path\": \"\(path)\", \"virtual_seconds\": \(secs), \"runs\": \(runs), \"same_work\": \(same), \"ticks\": \(samples[0].ticks), \"frames\": \(samples[0].frames), " +
                    "\"terry_wall_ms_median\": \(String(format: "%.1f", tw)), \"swift_wall_ms_median\": \(String(format: "%.1f", nw)), \"speedup_wall\": \(String(format: "%.3f", tw / nw)), " +
                    "\"terry_cpu_ms_median\": \(String(format: "%.1f", tc)), \"swift_cpu_ms_median\": \(String(format: "%.1f", nc)), \"speedup_cpu\": \(String(format: "%.3f", tc / nc)), \"samples\": [\(ss)]}")
            } catch {
                table += "\(path) failed: \(error)\n"
            }
        }
        #if DEBUG
        let config = "debug"
        #else
        let config = "release"
        #endif
        let host = "\"host\": {\"os\": \"\(ProcessInfo.processInfo.operatingSystemVersionString)\", \"cpus\": \(ProcessInfo.processInfo.activeProcessorCount), \"config\": \"\(config)\"}"
        let out = "{\n  \(host),\n  \"programs\": [\n" + rows.joined(separator: ",\n") + "\n  ]\n}\n"
        try? out.write(to: REPO.appendingPathComponent("temple_os_swift/TempleCore/.build/bench-swift.json"), atomically: true, encoding: .utf8)
        print(table)
    }
}

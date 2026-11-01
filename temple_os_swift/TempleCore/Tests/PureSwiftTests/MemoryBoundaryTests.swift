import Foundation
import TempleCore
import PureSwift
import XCTest

/**
 * Program-memory boundary sweep (port of MemoryBoundaryTest.kt; docs/native-validation, Talons): a program on both
 * engines at a list of program-memory sizes; whether it started, its ExitCategory and exit message, and arena use.
 *
 *   TEMPLEOS_MEMBOUNDS=C:/Demo/Games/Talons.HC  TEMPLEOS_MEMBOUNDS_MB=32,64,96,128  TEMPLEOS_MEMBOUNDS_SECS=4
 *
 * Results: .build/membounds-swift.json and a table on stdout.
 */
final class MemoryBoundaryTests: XCTestCase {
    func testSweep() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["TEMPLEOS_MEMBOUNDS"] else { return }
        let sizes = (env["TEMPLEOS_MEMBOUNDS_MB"] ?? "32,48,64,80,88,92,94,95,96,97,100,112,128,160,256").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let secs = Int64(env["TEMPLEOS_MEMBOUNDS_SECS"] ?? "") ?? 4
        var rows: [String] = []
        var table = "MiB     engine  result   high water   peak alloc        arena  category / exit\n"
        for mb in sizes {
            for engine in [ScenarioEngine.terry, .native] {
                var o = ScenarioRunner.Options()
                o.light = true
                o.memMb = mb
                o.env = { ScenarioEnv($0, memMb: mb, runtime: sharedRuntimeFile) }
                var result = "host-exception", detail = "", category = ""
                var st: ScenarioStats? = nil
                do {
                    let r = try runner.run(path, engine, ScenarioScript.sweep(secs * 1000), o)
                    let k = r.kernel
                    result = (!k.finished && r.failure == nil) ? "runs" : "ended"
                    category = k.exitCategory ?? ""
                    detail = (k.exitMessage ?? "") + " | " + String(k.console.plainText().suffix(300))
                    st = r.stats
                    k.terminate("done")
                } catch { detail = "\(error)" }
                table += String(format: "%-7d %-7@ %-8@ %12d %12lld %12d  %@\n", mb, engine.rawValue as NSString, result as NSString, st?.arenaHighWater ?? -1,
                                st?.arenaPeakAllocated ?? -1, st?.arenaBytes ?? -1, String((category + " | " + detail).replacingOccurrences(of: "\n", with: " ").prefix(140)) as NSString)
                let esc = detail.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
                rows.append("    {\"memmb\": \(mb), \"engine\": \"\(engine.rawValue)\", \"result\": \"\(result)\", \"category\": \"\(category)\", \"arena_high_water\": \(st?.arenaHighWater ?? -1), " +
                            "\"arena_peak_allocated\": \(st?.arenaPeakAllocated ?? -1), \"arena_bytes\": \(st?.arenaBytes ?? -1), \"detail\": \"\(esc)\"}")
            }
        }
        let out = "{\n  \"program\": \"\(path)\", \"virtual_seconds\": \(secs),\n  \"runs\": [\n" + rows.joined(separator: ",\n") + "\n  ]\n}\n"
        try? out.write(to: REPO.appendingPathComponent("temple_os_swift/TempleCore/.build/membounds-swift.json"), atomically: true, encoding: .utf8)
        print(table)
    }
}

import XCTest
@testable import TempleCore

/**
 * Interpreter benchmarks (opt-in: TEMPLEOS_BENCH=N runs each program N times).
 * Port of BenchTest.kt; use a release build for meaningful numbers:
 * swift build -c release --build-tests -Xswiftc -enable-testing &&
 * TEMPLEOS_BENCH=3 swift test -c release --skip-build -Xswiftc -enable-testing --filter BenchTests
 */
final class BenchTests: XCTestCase {
    func testBench() throws {
        guard let reps = Int(ProcessInfo.processInfo.environment["TEMPLEOS_BENCH"] ?? "") else { return }
        let dir = SHARED.appendingPathComponent("test-vectors/bench")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".HC") }.sorted()
        var rows: [String] = []
        for name in files {
            let src = readFileBytes(dir.appendingPathComponent(name))!
            var best = Int64.max; var instr: Int64 = 0; var out = ""
            for _ in 0..<reps {
                let k = Kernel(TestEnv(), "bench")
                try k.boot()
                let i0 = k.vm.instructionsExecuted
                let t0 = monoNanos()
                try k.runProgram("C:/Home/\(name)", src)
                while !k.finished { _ = try k.step(50_000_000) }
                let dt = monoNanos() - t0
                if dt < best { best = dt; instr = k.vm.instructionsExecuted - i0 }
                out = k.console.plainText().trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? ""
                XCTAssertNil(k.exitMessage, "\(name) failed: \(out)")
            }
            rows.append(String(format: "%-12@ %8.1f ms %12lld instr %7.1f M instr/s  -> %@", name as NSString, Double(best) / 1e6, instr, Double(instr) * 1e3 / Double(best), out as NSString))
        }
        print("BENCH swift:\n" + rows.joined(separator: "\n"))
    }
}

import Foundation
import XCTest
@testable import TempleCore

/** Runs an original TempleOS graphics demo headlessly (port of GraphicsDemoTest.kt). */
final class GraphicsDemoTests: XCTestCase {
    private let iso = REFERENCE.appendingPathComponent("templeos-iso")

    /** Boots, starts a program and runs it for [ms] of virtual time. */
    private func runFor(_ path: String, _ ms: Int64) throws -> Kernel {
        let fs = HostDirFs(iso)
        let k = Kernel(TestEnv(fs), "demo")
        k.virtualTime = true
        try k.boot()
        try k.runProgram(path, fs.readFile(path)!)
        var t = 0
        while k.now() < ms * 1_000_000 {
            if try k.step(5_000_000) < 0 { break }
            t += 1
            if t > 2_000_000 { break }
        }
        return k
    }

    func testBootTime() throws {
        let t0 = monoNanos()
        let k = Kernel(TestEnv(), "boot"); try k.boot()
        let t1 = monoNanos()
        let k2 = Kernel(TestEnv(), "boot2"); try k2.boot()
        let t2 = monoNanos()
        print("boot cold \((t1 - t0) / 1_000_000) ms, warm \((t2 - t1) / 1_000_000) ms (\(k.name), \(k2.name))")
    }

    func testLines() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: iso.appendingPathComponent("Demo/Graphics/Lines.HC").path),
                          "needs the gitignored ISO extraction in reference/templeos-iso")
        let k = try runFor("C:/Demo/Graphics/Lines.HC", 1500)
        XCTAssertNil(k.exitMessage)
        XCTAssertTrue(k.graphicsUsed)
        var colors = Set<UInt8>()
        for i in 0..<(640 * 480) { colors.insert(k.published[i]) }
        print("lines: frames=\(k.frameCount) instr=\(k.vm.instructionsExecuted) colors=\(colors.count)")
        XCTAssertGreaterThanOrEqual(colors.count, 3, "expected colored lines")
    }
}

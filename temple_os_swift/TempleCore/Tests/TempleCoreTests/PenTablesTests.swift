import XCTest
@testable import TempleCore

/**
 * Port of PenTablesTest.kt: the kernel's pen-table setup (Kernel.setUpPens) against the prelude's HolyC GrSetUpPens it
 * replaces at boot: the arena (every allocation, pen brush, circle table and bit table) and the allocator's state must
 * be identical, and a program drawing with every pen width must draw the same frame.
 */
final class PenTablesTests: XCTestCase {
    private func boot(_ holyC: Bool) throws -> Kernel {
        let k = Kernel(TestEnv(), "pens")
        k.virtualTime = true
        k.holyCPens = holyC
        try k.boot()
        return k
    }

    func testNativeSetupLeavesTheSameArenaAsTheHolyCFunction() throws {
        let a = try boot(true), b = try boot(false)
        XCTAssertEqual(a.mem.size, b.mem.size, "arena size")
        XCTAssertEqual(a.mem.highWater, b.mem.highWater, "high water")
        XCTAssertEqual(a.mem.peakAllocated, b.mem.peakAllocated, "peak allocated")
        // every allocation, table and brush byte must match; only the unused part of the boot task's memory stack
        // (above its stack pointer) differs, holding whatever the last calls left there
        let dead = ([a.current, a.adamTask].compactMap { $0 } + a.tasks).map { $0.msp..<($0.mspBase + HTask.MEM_STACK) }
        var live: [Int] = []
        for i in 0..<a.mem.size where a.mem.base.load(fromByteOffset: i, as: UInt8.self) != b.mem.base.load(fromByteOffset: i, as: UInt8.self) {
            if !dead.contains(where: { $0.contains(i) }) { live.append(i); if live.count >= 8 { break } }
        }
        XCTAssertTrue(live.isEmpty, "differing live bytes at \(live)")
        // the HolyC version really ran in one and not in the other
        XCTAssertGreaterThan(a.vm.instructionsExecuted, b.vm.instructionsExecuted + 1_000_000)
    }

    func testEveryPenWidthDrawsTheSameFrame() throws {
        let src = Array("""
            CDC *dc=DCAlias;
            I64 i;
            for (i=0;i<64;i++) {
              dc->color=i&15;
              dc->thick=i;
              GrLine3(dc,10+i*9,40,0,10+i*9+5,400,0);
              GrPlot3(dc,320,240,0);
            }
            DCDel(dc);
            Refresh;
            """.utf8)
        func frame(_ holyC: Bool) throws -> [UInt8] {
            let k = try boot(holyC)
            try k.runProgram("C:/Home/Pens.HC", src)
            var steps = 0
            while !k.finished && steps < 2000 { steps += 1; if try k.step(50_000_000) < 0 { break } }
            XCTAssertNil(k.exitMessage, k.console.plainText())
            return k.publishLock.sync { Array(UnsafeBufferPointer(start: k.published, count: Kernel.W * Kernel.H)) }
        }
        let a = try frame(true), b = try frame(false)
        XCTAssertGreaterThan(a.filter { $0 != 0 }.count, 1000, "the program drew")
        XCTAssertEqual(a, b)
    }
}

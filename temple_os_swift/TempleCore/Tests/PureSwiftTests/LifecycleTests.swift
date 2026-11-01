import XCTest
import TempleCore
import PureSwift

/**
 * Engine lifecycle and isolation (port of LifecycleTest.kt): a native program's task threads end with it
 * (closed, killed mid-slice, or ended by itself), the speaker is silenced, and switching engines back and
 * forth in one process leaves nothing behind that changes the next run.
 */
final class LifecycleTests: XCTestCase {
    /** Waits up to 3 s for the condition (a thread's last instructions after it has handed back). */
    private func eventually(_ what: @autoclosure () -> String, _ cond: () -> Bool) {
        let end = monoNanos() + 3_000_000_000
        while !cond() {
            if monoNanos() > end { XCTFail(what()); return }
            usleep(5_000)
        }
    }

    func testClosingAProgramEndsItsTaskThreads() throws {
        let before = NativeRuntime.liveThreads
        // BomberGolf: a main task plus Noise/Sweep sound tasks, parked in Sleep/Refresh when closed
        let (k, env) = try bootProgram("C:/Demo/Games/BomberGolf.HC", .native)
        _ = try advanceTo(k, 2500)
        XCTAssertGreaterThan(NativeRuntime.liveThreads, before, "task threads while running")
        k.terminate("closed")
        eventually("task threads ended: \(NativeRuntime.liveThreads - before) left") { NativeRuntime.liveThreads == before }
        XCTAssertEqual(env.sound.last?.1, 0.0, "speaker silenced at close")
    }

    func testAProgramThatEndsItselfLeavesNoThreads() throws {
        let before = NativeRuntime.liveThreads
        let (k, _) = try bootProgram("C:/Home/Examples/Hello.HC", .native)
        var ms: Int64 = 0
        while !k.finished && ms < 20_000 { ms += 100; if try !advanceTo(k, ms) { break } }
        k.terminate("done")
        eventually("task threads ended: \(NativeRuntime.liveThreads - before) left") { NativeRuntime.liveThreads == before }
    }

    func testRepeatedOpenCloseDoesNotLeak() throws {
        let before = NativeRuntime.liveThreads
        for i in 0..<12 {
            let (k, _) = try bootProgram(i % 2 == 0 ? "C:/Demo/Graphics/Bounce.HC" : "C:/Demo/Games/Squirt.HC", .native)
            _ = try advanceTo(k, 300 + 37 * Int64(i)) // closed at different points of a slice
            k.terminate("closed")
        }
        eventually("no task threads left: \(NativeRuntime.liveThreads - before)") { NativeRuntime.liveThreads == before }
    }

    func testSwitchingEnginesLeavesNoState() throws {
        // T N T N in one process: the same results each time, so neither engine leaves state for the other
        let evs = sweepScript(1500)
        var runs: [[Checkpoint]] = []
        for e in [Engine.terry, .native, .terry, .native] {
            let (k, cps) = try runScript("C:/Demo/Games/BomberGolf.HC", e, evs, 1500)
            k.terminate("done")
            runs.append(cps)
        }
        for i in 1..<runs.count { XCTAssertNil(firstDifference(runs[0], runs[i]), "run \(i)") }
    }
}

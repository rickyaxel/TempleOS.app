import Foundation
import XCTest
@testable import TempleCore

/**
 * A task that has ended must never have frames pushed on its stack: the kernel frees the stack and a new task may
 * get it (Whap: "Unhandled exception 'BadMem' in SoundEffectTask (GrLib.HC:6674): invalid memory access at
 * 0x3fb99999999999a0"). Port of TaskLifecycleTest.kt; docs/audio/TEMPLEOS_AUDIO_FIDELITY.md §15 (A-7).
 */
final class TaskLifecycleTests: XCTestCase {
    func testTasksSpawnedDuringAFrameKeepTheirArguments() throws {
        let src = """
            I64 bad=0,ok=0;
            U0 Child(I64 *p) { if (*p==12345) ok++; else bad++; Free(p); }
            U0 DrawIt(CTask *,CDC *) { I64 *p=MAlloc(8); *p=12345; Spawn(&Child,p,"Child"); }
            Fs->draw_it=&DrawIt;
            Sleep(3000);
            Fs->draw_it=NULL;
            Sleep(100);
            "OK:%d BAD:%d\\n",ok,bad;

            """
        let k = try runHolyC(latin1(src))
        let text = k.console.plainText()
        guard let r = text.range(of: #"OK:(\d+) BAD:(\d+)"#, options: .regularExpression) else { return XCTFail(text) }
        let parts = text[r].split(separator: " ").map { Int($0.split(separator: ":")[1])! }
        XCTAssertEqual(parts[1], 0, text)
        XCTAssertGreaterThan(parts[0], 50, text)
        XCTAssertFalse(text.contains("Unhandled exception"), text)
    }

    func testWhapsCollisionNoiseRunsWithoutBadMem() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fs = LayeredFs(DirBundle(SHARED.appendingPathComponent("bundled-fs"), SHARED.appendingPathComponent("bundled-fs.index")), dir)
        let env = TestEnv(fs)
        let k = Kernel(env, "whap")
        k.virtualTime = true
        try k.boot()
        try k.runProgram("C:/Demo/Games/Whap.HC", try XCTUnwrap(fs.readFile("C:/Demo/Games/Whap.HC")))
        var step = 0
        let wall = Date().addingTimeInterval(600)
        while k.now() < 30_000_000_000 && !k.finished && Date() < wall {
            let a = Double(step) * 0.07
            k.post(.mouse(x: Int(320 + 200 * cos(a)), y: Int(240 + 150 * sin(a)), lb: false, rb: false))
            k.virtualStopAt = k.now() + 20_000_000
            _ = try k.step(50_000_000); step += 1
        }
        let text = k.console.plainText()
        XCTAssertFalse(text.contains("Unhandled exception"), String(text.suffix(600)))
        XCTAssertFalse(k.finished, "Whap keeps running")
        let noise = Set((102...104).map { o -> Double in Natives.PIT_FREQ / Double(Int64(Double(18333 * 65536 / 1000) / (440.0 / 32 * pow(2.0, Double(o) / 12.0)))) })
        let n = env.sounds.filter { noise.contains($0) }.count
        XCTAssertGreaterThan(n, 500, "collisions sounded: \(n)")
    }
}

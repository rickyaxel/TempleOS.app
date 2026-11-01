import Foundation
import XCTest
@testable import TempleCore

/**
 * Note timing of the original Play() (Adam/ASnd.HC, in GrLib.HC): at the default tempo of 2.5
 * quarter notes per second a quarter note lasts JIFFY_FREQ*1/2.5 = 400 ms, sounding for
 * stacatto_factor 0.9 of it (360 ms) and silent for the rest (40 ms), via two SleepUntil calls.
 * Regression (docs/fidelity-audit FA-03): the second SleepUntil returned at once, so songs lost
 * every gap and ran 10% fast. Port of SoundTimingTest.kt.
 */
final class SoundTimingTests: XCTestCase {
    func testPlayKeepsTempleOsNoteTiming() throws {
        let env = TestEnv()
        _ = try runHolyC(latin1("Play(\"4qCDE\");\n"), env: env)
        let log = env.soundLog.filter { $0.1 >= 0 }
        guard let t0 = log.first(where: { $0.1 > 0 })?.0 else { return XCTFail("no notes") }
        let events = Array(log.drop(while: { $0.1 == 0 })).map { ($0.0 - t0, $0.1 > 0) }
        let expected: [(Int64, Bool)] = [(0, true), (360, false), (400, true), (760, false), (800, true), (1160, false)]
        XCTAssertGreaterThanOrEqual(events.count, expected.count, "tone changes: \(events)")
        for (i, e) in expected.enumerated() where i < events.count {
            XCTAssertEqual(events[i].1, e.1, "event \(i) sounding")
            XCTAssertLessThanOrEqual(abs(events[i].0 - e.0), 5, "event \(i) at \(events[i].0) ms, expected \(e.0) ms (all: \(events))")
        }
    }

    /** A completed GetKey must not leave the wake-up token for the next Sleep (it returned at once). */
    func testSleepAfterAWaitedKeyStillSleeps() throws {
        // the key arrives while GetKey waits (a second task posts it), so GetKey resumes from a wait
        let k = try runHolyC(latin1("U0 Poster(CTask *parent) {Sleep(50);PostMsg(parent,MSG_KEY_DOWN,'a',0x1E);}\n" +
            "FlushMsgs;Spawn(&Poster,Fs);GetKey;F64 t=tS;Sleep(200);\"%d\\n\",ToI64((tS-t)*1000);\n"))
        let ms = Int(k.console.plainText().trimmed().components(separatedBy: "\n").last!.trimmingCharacters(in: .whitespaces)) ?? -1
        XCTAssertTrue((195...260).contains(ms), "Sleep(200) after GetKey slept \(ms) ms")
    }
}

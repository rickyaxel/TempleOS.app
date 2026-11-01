import Foundation
import XCTest
@testable import TempleCore

/**
 * The TempleOS sound path above the renderer: Snd/Mute/SndRst semantics (Kernel/KMisc.HC), the Sound
 * example's trace against TempleOS's (shared/test-vectors/audio/sound-example.json), the timing of speaker
 * changes, and which program window owns the device speaker. Port of SoundTest.kt.
 */
final class SoundTests: XCTestCase {
    private struct RefEvent { let tMs: Int64; let ona: Int; let hz: Double }

    private func num(_ v: Any?) -> Double {
        if let d = v as? Double { return d }; if let i = v as? Int64 { return Double(i) }; if let i = v as? Int { return Double(i) }
        return .nan
    }

    private func reference() throws -> [RefEvent] {
        let text = try String(contentsOf: SHARED.appendingPathComponent("test-vectors/audio/sound-example.json"), encoding: .utf8)
        let doc = try XCTUnwrap(try Json.parse(text) as? [String: Any?])
        return try XCTUnwrap(doc["events"] as? [Any?]).map { e in
            let m = e as! [String: Any?]
            // t_ms: the reference's jiffies in ms (a jiffy is 0.999009 ms; AudioFidelityTests compares jiffies exactly)
            return RefEvent(tMs: Int64(num(m["t_ms"]).rounded()), ona: Int(num(m["ona"])), hz: num(m["hz"]))
        }
    }

    /** The program's speaker changes: without the boot's SndRst and the silence posted when it ends. */
    private func speakerChanges(_ env: TestEnv) -> [(Int64, Double)] {
        let l = Array(env.soundLog.drop { $0.1 == 0 })
        var n = l.count
        while n >= 2 && l[n - 1].1 == 0 && l[n - 2].1 == 0 { n -= 1 }
        return Array(l.prefix(n))
    }

    private func soundExample(_ env: TestEnv) throws -> Kernel {
        let src = try XCTUnwrap(readFileBytes(SHARED.appendingPathComponent("bundled-fs/Home/Examples/Sound.HC")))
        return try runHolyC(src, "C:/Home/Examples/Sound.HC", env: env)
    }

    func testSoundExamplePlaysTempleOsTrace() throws {
        let env = TestEnv()
        let k = try soundExample(env)
        XCTAssertTrue(k.finished)
        let text = k.console.plainText()
        XCTAssertTrue(text.contains("60 62 64 66 68 70 72") && text.contains("Done."), text)
        let got = speakerChanges(env)
        let ref = try reference()
        XCTAssertEqual(got.count, ref.count, "speaker changes: \(got)")
        guard got.count == ref.count else { return }
        let t0 = got[0].0
        for (i, r) in ref.enumerated() {
            XCTAssertEqual(got[i].1, r.hz, accuracy: 1e-3, "change \(i) (ona \(r.ona)) Hz")
            XCTAssertLessThanOrEqual(abs(got[i].0 - t0 - r.tMs), 2, "change \(i) at \(got[i].0 - t0) ms, TempleOS \(r.tMs) ms")
        }
    }

    func testSoundExampleRendersTheTraceSampleExactly() throws {
        let env = TestEnv()
        _ = try soundExample(env)
        let rate = 48000
        let sp = PcSpeaker(rate, 20_000_000)
        let got = speakerChanges(env)
        let base: Int64 = 5_000_000_000
        for (ms, hz) in got { sp.post(base + (ms - got[0].0) * 1_000_000, hz) }
        var x = [Float](repeating: 0, count: rate * 3)
        var i = 0
        while i < x.count { let m = min(512, x.count - i); sp.render(&x, i, m, nowNs: base + Int64(i) * 1_000_000_000 / Int64(rate)); i += m }
        let posted = got.map { RefEvent(tMs: $0.0 - got[0].0, ona: $0.1 > 0 ? 1 : 0, hz: $0.1) }
        let bad = check(x, rate, posted)
        XCTAssertTrue(bad.isEmpty, bad.joined(separator: "\n"))
    }

    /** Same rules as SoundTest.kt checkAgainstReference and tools/audio/analyze_capture.py. */
    private func check(_ x: [Float], _ rate: Int, _ ref: [RefEvent]) -> [String] {
        var bad: [String] = []
        let thr = Float(PcSpeaker.AMPLITUDE / 2)
        guard let s0 = x.firstIndex(where: { abs($0) >= thr }) else { return ["no sound"] }
        func at(_ ms: Int64) -> Int { s0 + Int(ms * Int64(rate) / 1000) }
        let lastMs = ref.last!.tMs
        for (j, e) in ref.enumerated() {
            let end = j + 1 < ref.count ? ref[j + 1].tMs : e.tMs + 100
            if end - e.tMs < 5 { continue }
            if e.ona != 0 {
                let a = at(e.tMs) + rate / 500, b = at(end) - rate / 500
                var cr: [Double] = []
                for k in (a + 1)..<b where x[k - 1] < 0 && x[k] >= 0 { cr.append(Double(k - 1) + Double(0 - x[k - 1]) / Double(x[k] - x[k - 1])) }
                let hz = cr.count > 2 ? Double(cr.count - 1) / ((cr.last! - cr.first!) / Double(rate)) : 0
                if abs(hz - e.hz) > e.hz * 0.002 { bad.append("note \(j) at \(e.tMs) ms: \(hz) Hz, expected \(e.hz)") }
            } else {
                var off = at(e.tMs) + rate / 200
                while off > 0 && x[off - 1] == 0 { off -= 1 }
                var on = off
                while on < x.count && x[on] == 0 { on += 1 }
                let offMs = Double(off - s0) * 1000 / Double(rate), onMs = Double(on - s0) * 1000 / Double(rate)
                if abs(offMs - Double(e.tMs)) > 0.1 { bad.append("rest \(j) starts at \(offMs) ms, expected \(e.tMs)") }
                if e.tMs < lastMs && abs(onMs - Double(end)) > 0.1 { bad.append("rest \(j) ends at \(onMs) ms, expected \(end)") }
            }
        }
        return bad
    }

    private func rounded(_ env: TestEnv) -> [Double] { speakerChanges(env).map { ($0.1 * 100).rounded() / 100 } }

    func testMutedSndIsIgnoredAsInTempleOs() throws {
        let env = TestEnv()
        let k = try runHolyC(latin1("Snd(60);Mute(ON);Snd(62);Snd(60);\"%d\\n\",IsMute;Mute(OFF);Snd(60);Snd(62);Snd;\n"), env: env)
        XCTAssertEqual(rounded(env), [437.06, 0, 437.06, 490.62, 0])
        XCTAssertTrue(k.console.plainText().contains("1"))
    }

    func testSndRstAndRepeatedOnas() throws {
        let env = TestEnv()
        _ = try runHolyC(latin1("Snd(60);Snd(60);Snd(60);SndRst;Snd(60);Snd;Snd;\n"), env: env)
        XCTAssertEqual(rounded(env), [437.06, 0, 437.06, 0])
    }

    func testOnaEdgesFollowThePit() throws {
        let env = TestEnv()
        _ = try runHolyC(latin1("Snd(1);Snd(-128);Snd(200);Snd(127);Snd(0);SndFreq(1000.0);SndFreq(0);\n"), env: env)
        let hz = speakerChanges(env).map { $0.1 }
        XCTAssertEqual(hz.count, 7)
        guard hz.count == 7 else { return }
        for j in 0...2 { XCTAssertEqual(hz[j], 1193182.0 / 65535, accuracy: 1e-9) }
        XCTAssertEqual(hz[3], 1193182.0 / 56, accuracy: 1e-6)
        XCTAssertEqual(hz[4], 0)
        XCTAssertEqual(hz[5], 1193182.0 / 1193, accuracy: 1e-9)
        XCTAssertEqual(hz[6], 0)
    }

    func testLateWakeUpsDoNotMoveSpeakerChanges() throws {
        let env = TestEnv()
        env.fakeClock = 50_000_000_000
        let k = Kernel(env, "late")
        try k.boot()
        try k.runProgram("C:/Home/Late.HC", latin1("Snd(60);Sleep(100);Snd(62);Sleep(100);Snd;\n"))
        for _ in 0..<50 where !env.sounds.contains(where: { $0 > 0 }) { _ = try k.step(10_000_000) }
        let i0 = try XCTUnwrap(env.sounds.firstIndex { $0 > 0 })
        XCTAssertEqual(i0, env.sounds.count - 1, "first change at once")
        let first = env.soundStamps[i0]
        env.fakeClock! += 107_000_000; _ = try k.step(10_000_000)
        env.fakeClock! += 109_000_000; _ = try k.step(10_000_000)
        XCTAssertGreaterThanOrEqual(env.soundStamps.count, i0 + 3)
        guard env.soundStamps.count >= i0 + 3 else { return }
        // Sleep(100) is SleepUntil(cnts.jiffies+100): it ends on a jiffy (0.999009 ms each), up to one jiffy
        // sooner than 100 jiffies from a call made inside a jiffy
        let d1 = env.soundStamps[i0 + 1] - first
        XCTAssertTrue((98_900_000...99_901_000).contains(d1), "Snd(62) dated at its Sleep's end, not 7 ms later: \(d1)")
        // the task resumed as if on its jiffy, so its next Sleep(100) ends 100 jiffies later, not 107 ms
        XCTAssertEqual(Double(env.soundStamps[i0 + 2] - env.soundStamps[i0 + 1]), 99_900_937.0, accuracy: 1.0)
    }

    func testASleepUntilCalledLateDatesTheNextChangeAtItsTime() throws {
        let env = TestEnv()
        env.fakeClock = 50_000_000_000
        let k = Kernel(env, "late2")
        try k.boot()
        try k.runProgram("C:/Home/Late2.HC", latin1("I64 j0=cnts.jiffies;Sleep(100);Snd(60);Sleep(50);Snd;SleepUntil(j0+160);Snd(62);\n"))
        for _ in 0..<50 { _ = try k.step(10_000_000) }
        env.fakeClock! += 108_000_000; _ = try k.step(10_000_000)
        env.fakeClock! += 60_000_000; _ = try k.step(10_000_000)
        let i0 = try XCTUnwrap(env.sounds.firstIndex { $0 > 0 })
        let s = env.soundStamps[i0...].map { Double($0 - env.soundStamps[i0]) }
        // Snd(60) is on a jiffy (Sleep's end); Snd 50 jiffies and Snd(62) 60 jiffies later (0.999009 ms each)
        XCTAssertGreaterThanOrEqual(s.count, 3)
        guard s.count >= 3 else { return }
        XCTAssertEqual(s[1], 49_950_468.6, accuracy: 1.0)
        XCTAssertEqual(s[2], 59_940_562.3, accuracy: 1.0)
    }

    private final class Tones: ShellEnv {
        let lock = NSLock()
        var rec: [Double] = []
        let fs: LayeredFs
        var session: String?
        lazy var stateStore: StateStore = Store(self)
        final class Store: StateStore {
            unowned let e: Tones
            init(_ e: Tones) { self.e = e }
            func load() throws -> String? { e.session }
            func save(_ text: String) throws { e.session = text }
        }
        init(_ overlay: URL) {
            fs = LayeredFs(DirBundle(SHARED.appendingPathComponent("bundled-fs"), SHARED.appendingPathComponent("bundled-fs.index")), overlay)
        }
        func runtimeFile(_ name: String) -> [UInt8]? {
            readFileBytes(name == "catalog.json" ? SHARED.appendingPathComponent("program-manifests/catalog.json") : SHARED.appendingPathComponent("runtime/\(name)"))
        }
        func tone(_ freq: Double, at atNs: Int64) { lock.lock(); rec.append(freq); lock.unlock() }
        var last: Double? { lock.lock(); defer { lock.unlock() }; return rec.last }
        var all: [Double] { lock.lock(); defer { lock.unlock() }; return rec }
    }

    func testTheFocusedProgramOwnsTheSpeaker() {
        let env = Tones(FileManager.default.temporaryDirectory)
        let mux = SpeakerMux(env)
        let a = NSObject(), b = NSObject()
        mux.set(a, 440, 1)
        mux.claim(a, 440)
        mux.set(b, 0, 2)
        mux.set(a, 500, 3)
        mux.claim(b, 300)
        mux.release(a)
        mux.set(a, 0, 4)
        mux.release(b)
        XCTAssertEqual(env.all, [440, 500, 300, 0])
    }

    func testPausingSilencesAndResumingRestoresTheHeldNote() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tosm-snd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = Tones(dir)
        let sh = Shell(env)
        sh.resize(360, 640)
        sh.restoreSession()
        try sh.fs.writeFile("C:/Home/Held.HC", latin1("Snd(60);Sleep(60000);\n"))
        Launch.program(sh, "C:/Home/Held.HC", nil)
        let app = try XCTUnwrap(sh.windows.last?.app as? ProgramApp)
        func waitFor(_ ms: Int, _ cond: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(Double(ms) / 1000)
            while Date() < end { _ = sh.tick(); if cond() { return true }; Thread.sleep(forTimeInterval: 0.01) }
            return false
        }
        func held() -> Bool { abs((env.last ?? 0) - 437.063) < 0.01 }
        XCTAssertTrue(waitFor(30_000, held), "held note sounds: \(env.all)")
        app.onBackground()
        XCTAssertTrue(waitFor(2000) { env.last == 0 }, "silent while paused: \(env.all)")
        app.onForeground()
        XCTAssertTrue(waitFor(2000, held), "the held note again: \(env.all)")
        sh.settings.sound = false
        XCTAssertTrue(waitFor(2000) { env.last == 0 }, "Sound OFF in Settings silences: \(env.all)")
        sh.settings.sound = true
        XCTAssertTrue(waitFor(2000, held), "and ON restores: \(env.all)")
        app.close()
        XCTAssertTrue(waitFor(5000) { env.last == 0 }, "closing silences: \(env.all)")
    }

    /** A sound loop typed in the Terminal stops with the app in the background and resumes with it. */
    func testTerminalCommandsPauseInTheBackground() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tosm-snd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = Tones(dir)
        let sh = Shell(env)
        sh.resize(360, 640)
        sh.restoreSession()
        let term = TerminalApp(sh)
        _ = sh.open(term)
        func waitFor(_ ms: Int, _ cond: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(Double(ms) / 1000)
            while Date() < end { _ = sh.tick(); if cond() { return true }; Thread.sleep(forTimeInterval: 0.01) }
            return false
        }
        func tones() -> Int { env.all.filter { $0 != 0 }.count }
        term.kernel.post(.exec("while (TRUE) { Snd(60); Sleep(5); Snd(0); Sleep(5); }"))
        XCTAssertTrue(waitFor(30_000) { tones() >= 3 }, "the loop plays: \(env.all)")
        sh.onBackground()
        Thread.sleep(forTimeInterval: 0.1) // a note already handed to the speaker may still arrive
        let before = tones()
        Thread.sleep(forTimeInterval: 0.5); _ = sh.tick()
        XCTAssertEqual(tones(), before, "no notes while the app is in the background")
        XCTAssertEqual(env.last, 0, "and the speaker is silent")
        sh.onForeground()
        XCTAssertTrue(waitFor(5000) { tones() > before }, "the loop plays again")
        term.close()
    }
}

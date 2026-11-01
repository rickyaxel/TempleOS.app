import Foundation
import XCTest
@testable import TempleCore

/**
 * TempleOS sound semantics against the independent reference: tools/audio/templeos_snd.py, a port of the original
 * HolyC that matches the original TempleOS jiffy for jiffy in the reference VM. Covers the jiffy clock, Sleep,
 * every Play fixture (shared/test-vectors/audio/play-fixtures.json), the PIT table and the F64 arithmetic as the
 * original printed them, and the Noise/Sweep bookkeeping. Port of AudioFidelityTest.kt.
 * Spec: docs/audio/TEMPLEOS_AUDIO_FIDELITY.md.
 */
final class AudioFidelityTests: XCTestCase {
    private func num(_ v: Any?) -> Double {
        if let d = v as? Double { return d }; if let i = v as? Int64 { return Double(i) }; if let i = v as? Int { return Double(i) }
        return .nan
    }

    private lazy var fx: [String: Any?] = {
        let text = try! String(contentsOf: SHARED.appendingPathComponent("test-vectors/audio/play-fixtures.json"), encoding: .utf8)
        return (try! Json.parse(text)) as! [String: Any?]
    }()

    /** ona -> Hz from the fixture's PIT table (1193182 / count). */
    private lazy var onaHz: [Int: Double] = {
        var m: [Int: Double] = [0: 0]
        for row in fx["pit_counts"] as! [Any?] { let r = row as! [Any?]; m[Int(num(r[0]))] = num(r[2]) }
        return m
    }()

    /** The speaker's audible changes as (jiffy, Hz): a setting equal to the current one is not a change. */
    private func changes(_ env: TestEnv, from: Int64 = Int64.min) -> [(Int64, Double)] {
        var out: [(Int64, Double)] = []
        var cur = 0.0
        for i in env.sounds.indices {
            let j = TempleClock.jiffyAt(env.soundNowNs[i])
            if j < from { cur = env.sounds[i]; continue }
            if env.sounds[i] != cur { out.append((j, env.sounds[i])); cur = env.sounds[i] }
        }
        return out
    }

    private func hcString(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }

    // ------------------------------------------------------------------ clock

    func testAJiffyIs1192PitClocks() {
        XCTAssertEqual(TempleClock.jiffyAt(0), 0)
        XCTAssertEqual(TempleClock.jiffyStartNs(1), 999_010)
        XCTAssertEqual(TempleClock.jiffyStartNs(1000), 999_009_372)
        // the reference VM: 20019 jiffies in 20 RTC seconds
        XCTAssertEqual(TempleClock.jiffyAt(20_000_000_000), 20_019)
        for j: Int64 in [0, 1, 2, 999, 1000, 1192, 1193182, 86_400_000, 3_000_000_000] {
            let s = TempleClock.jiffyStartNs(j)
            XCTAssertEqual(TempleClock.jiffyAt(s), j)
            XCTAssertEqual(TempleClock.jiffyAt(s - 1), j - 1)
        }
    }

    func testCntsJiffiesAndSleepCountRealJiffies() throws {
        let env = TestEnv()
        let k = try runHolyC(latin1("SleepUntil(5000);I64 j=cnts.jiffies;Snd(60);Sleep(1000);Snd(62);\"%d\\n\",cnts.jiffies-j;\n"), env: env)
        XCTAssertTrue(k.console.plainText().contains("1000"), k.console.plainText())
        let c = changes(env, from: 5000)
        XCTAssertEqual(c.prefix(2).map { $0.0 }, [5000, 6000])
        let i = try XCTUnwrap(env.sounds.lastIndex { $0 > 480 })
        XCTAssertEqual(Double(env.soundNowNs[i]), Double(TempleClock.jiffyStartNs(6000)), accuracy: 50_000)
    }

    func testASleepLoopWithWorkKeepsItsPeriodAsOnTempleOs() throws {
        let env = TestEnv()
        _ = try runHolyC(latin1("I64 i,n,s=0;SleepUntil(2000);for(i=0;i<20;i++){for(n=0;n<3000;n++)s+=n;Snd(60+i%2);Sleep(10);}Snd;\n"), env: env)
        let c = changes(env, from: 2000)
        XCTAssertEqual(c.count, 21)
        for (i, e) in c.enumerated() { XCTAssertEqual(e.0, 2000 + 10 * Int64(i), "change \(i)") }
    }

    // ------------------------------------------------------------------ the original's own numbers

    func testPitTableAndFreq2OnaHashLikeTheOriginal() throws {
        let k = try runHolyC(latin1("I64 h=0,k;for(k=-128;k<128;k++)if(k)h=h*31+ClampI64(SYS_TIMER_FREQ/Ona2Freq(k),1,U16_MAX);\"H:%X\\n\",h;" +
            "h=0;for(k=1;k<=24000;k++)h=h*31+Freq2Ona(k*0.37);\"F:%X\\n\",h;\n"))
        let h = fx["table_hashes_from_reference_vm"] as! [String: Any?]
        let text = k.console.plainText()
        XCTAssertTrue(text.contains("H:\(h["pit_counts"]! as! String)"), text)
        XCTAssertTrue(text.contains("F:\(h["freq2ona_k_0_37"]! as! String)"), text)
        for (ona, hz) in onaHz { XCTAssertEqual(k.natives.speakerFreq(ona), hz, accuracy: hz * 1e-12, "ona \(ona)") }
    }

    func testI64PlusF64RoundsLikeTheOriginal() throws {
        let a = fx["arith_from_reference_vm"] as! [String: Any?]
        let p = a["printed"] as! [String: Any?]
        let k = try runHolyC(latin1((a["source"] as! String) + "\"R:%d %d %d %d %d\\n\",a-60000,b-70000,c-300000,d-10,e-1000;\n"))
        let want = ["a", "b", "c", "d", "e"].map { String(Int(num(p[$0]!))) }.joined(separator: " ")
        XCTAssertTrue(k.console.plainText().contains("R:\(want)"), k.console.plainText())
    }

    func testSndKeepsScrncastOnaAsTheOriginal() throws {
        let k = try runHolyC(latin1("Snd(60);\"A:%d \",scrncast.ona;Snd(-3);\"B:%d \",scrncast.ona;Mute(ON);\"C:%d \",scrncast.ona;" +
            "Snd(62);\"D:%d \",scrncast.ona;Mute(OFF);Snd(62);\"E:%d \",scrncast.ona;SndRst;\"F:%d\\n\",scrncast.ona;\n"))
        XCTAssertTrue(k.console.plainText().contains("A:60 B:-3 C:0 D:0 E:62 F:0"), k.console.plainText())
    }

    // ------------------------------------------------------------------ Play

    func testEveryPlayFixtureMatchesTheReference() throws {
        let cases = fx["cases"] as! [Any?]
        XCTAssertGreaterThan(cases.count, 50)
        var bad: [String] = []
        for case0 in cases {
            let c = case0 as! [String: Any?]
            let id = c["id"] as! String
            let j0 = Int64(num(c["j0"]!))
            let strings = (c["play"] as! [Any?]).map { $0 as! String }
            var src = "SleepUntil(\(j0));MusicSettingsRst;music.tempo=\(num(c["tempo"]!));music.stacatto_factor=\(num(c["stacatto_factor"]!));"
            for s in strings { src += "Play(\"\(hcString(s))\");" }
            src += "\"E:%d O:%d L:%d M:%d/%d\\n\",cnts.jiffies-\(j0),music.octave,ToI64(music.note_len*1000000),music.meter_top,music.meter_bottom;\n"
            let env = TestEnv()
            let k = try runHolyC(latin1(src), env: env, maxSteps: 400000)
            let want: [(Int64, Double)] = (c["events"] as! [Any?]).map { e in let r = e as! [Any?]; return (Int64(num(r[0])), onaHz[Int(num(r[1]))]!) }
            var got = changes(env, from: j0).map { ($0.0 - j0, $0.1) }
            // the program's end turns a note left sounding (a final tie) off: TempleOS Mobile's window adaptation
            if got.count == want.count + 1 && got.last!.1 == 0 && (want.last?.1 ?? 0) != 0 { got.removeLast() }
            let same = got.count == want.count && got.indices.allSatisfy { got[$0].0 == want[$0].0 && abs(got[$0].1 - want[$0].1) <= 1e-9 * want[$0].1 }
            if !same {
                let i = got.indices.first { $0 >= want.count || got[$0].0 != want[$0].0 || abs(got[$0].1 - want[$0].1) > 1e-6 } ?? got.count
                bad.append("\(id): \(got.count) changes, reference \(want.count); first difference at \(i): got \(i < got.count ? "\(got[i])" : "-"), reference \(i < want.count ? "\(want[i])" : "-")")
                continue
            }
            let st = c["state"] as! [String: Any?]
            let meter = (st["meter"] as! [Any?]).map { Int(num($0)) }
            let len = Int64(num(st["note_len"]!) * 1_000_000) // ToI64 truncates
            let line = "E:\(Int64(num(c["end"]!))) O:\(Int(num(st["octave"]!))) L:\(len) M:\(meter[0])/\(meter[1])"
            if !k.console.plainText().contains(line) { bad.append("\(id): wanted '\(line)' in \(k.console.plainText().suffix(200))") }
        }
        XCTAssertTrue(bad.isEmpty, bad.joined(separator: "\n"))
    }

    func testSoundExampleMatchesTheOriginalJiffyForJiffy() throws {
        let text = try String(contentsOf: SHARED.appendingPathComponent("test-vectors/audio/sound-example.json"), encoding: .utf8)
        let ref = ((try Json.parse(text)) as! [String: Any?])["events"] as! [Any?]
        let env = TestEnv()
        let src = try XCTUnwrap(readFileBytes(SHARED.appendingPathComponent("bundled-fs/Home/Examples/Sound.HC")))
        let k = try runHolyC(src, "C:/Home/Examples/Sound.HC", env: env)
        XCTAssertTrue(k.finished)
        let got = changes(env)
        XCTAssertEqual(got.count, ref.count)
        guard got.count == ref.count else { return }
        let j0 = got[0].0
        for (i, r0) in ref.enumerated() {
            let r = r0 as! [String: Any?]
            XCTAssertEqual(got[i].0 - j0, Int64(num(r["jiffy"]!)), "change \(i) jiffy")
            XCTAssertEqual(got[i].1, num(r["hz"]!), accuracy: 1e-3, "change \(i) Hz")
        }
    }

    // ------------------------------------------------------------------ Noise, Sweep, music.mute

    func testSweepStepsThroughEveryOnaOnJiffiesAndGivesBackTheSpeaker() throws {
        let env = TestEnv()
        let k = try runHolyC(latin1("SleepUntil(3000);Sweep(300,40,60);Sleep(400);\"M:%d\\n\",music.mute;\n"), env: env)
        XCTAssertTrue(k.console.plainText().contains("M:0"))
        let c = changes(env, from: 3000)
        let t0 = TempleClock.jiffyStartNs(3000)
        var want: [(Int64, Int)] = []
        var last = 0
        var j: Int64 = 3000
        while TempleClock.jiffyStartNs(j) - t0 < 300_000_000 {
            let t = Double(TempleClock.jiffyStartNs(j) - t0) / 300e6
            let ona = Int(Int64((1.0 - t) * 40 + t * 60))
            if ona != last { want.append((j, ona)); last = ona }
            j += 1
        }
        want.append((j, 0))
        XCTAssertEqual(c.map { $0.0 }, want.map { $0.0 })
        XCTAssertEqual(c.map { $0.1 }, want.map { onaHz[$0.1]! })
        XCTAssertEqual(want.count - 1, 20)
    }

    func testNoiseRetunesWithinItsRangeAndEndsOnTime() throws {
        let env = TestEnv()
        let k = try runHolyC(latin1("SleepUntil(3000);Noise(200,40,50);Sleep(300);\"M:%d\\n\",music.mute;\n"), env: env)
        XCTAssertTrue(k.console.plainText().contains("M:0"))
        let c = changes(env, from: 3000)
        let allowed = Set((40...49).map { onaHz[$0]! })
        XCTAssertTrue(c.dropLast().allSatisfy { allowed.contains($0.1) })
        XCTAssertEqual(c.last?.1, 0)
        XCTAssertEqual(c.last?.0, 3000 + 201)
        XCTAssertGreaterThan(c.count, 100)
    }

    func testASongIsSilentWhileANoisePlaysAndKeepsItsTime() throws {
        let env = TestEnv()
        _ = try runHolyC(latin1("U0 Song(I64){Play(\"qCDEFG\");}SleepUntil(4000);Spawn(&Song,NULL,\"S\");Sleep(100);Noise(500,70,80);Sleep(2500);\n"), env: env)
        let c = changes(env, from: 4000).map { ($0.0 - 4000, $0.1) }
        let c4 = onaHz[51]!, e = onaHz[55]!, f = onaHz[56]!, g = onaHz[58]!
        XCTAssertEqual(c[0].0, 0); XCTAssertEqual(c[0].1, c4)
        XCTAssertTrue(c.filter { (100...600).contains($0.0) && $0.1 != 0 }.allSatisfy { $0.1 > onaHz[69]! })
        XCTAssertFalse(c.contains { $0.1 == onaHz[53]! }, "D (ona 53) never sounds")
        let off = try XCTUnwrap(c.first { $0.0 > 100 && $0.1 == 0 })
        XCTAssertEqual(off.0, 601)
        let tail = c.filter { $0.0 >= 800 }
        XCTAssertEqual(tail.map { $0.0 }, [800, 1160, 1200, 1560, 1600, 1960])
        XCTAssertEqual(tail.map { $0.1 }, [e, 0, f, 0, g, 0])
    }

    func testOverlappingEffectsEachFreeTheirOwnFrameAndGiveBackMusicMute() throws {
        let env = TestEnv()
        let k = try runHolyC(latin1("SleepUntil(3000);Noise(100,40,50);Noise(250,60,70);Sweep(150,80,90);Sleep(400);\"M:%d\\n\",music.mute;Play(\"qC\");\n"), env: env)
        let text = k.console.plainText()
        XCTAssertTrue(text.contains("M:0"), text)
        XCTAssertFalse(text.contains("Bad"), text)
        let c = changes(env, from: 3000).map { ($0.0 - 3000, $0.1) }
        let second = Set((60...69).map { onaHz[$0]! })
        XCTAssertTrue(c.contains { (152...250).contains($0.0) && second.contains($0.1) })
        XCTAssertEqual(c.first { $0.0 > 300 }?.1, onaHz[51]!)
    }

    func testATerminalCommandsNoiseGivesBackMusicMuteWhenItEnds() throws {
        let env = TestEnv()
        let k = Kernel(env, "Terminal", shellMode: true)
        k.virtualTime = true
        try k.boot()
        func run(_ line: String) throws -> String {
            let before = k.console.plainText().count
            try k.execLine(line)
            let deadline = Date().addingTimeInterval(20)
            while k.busy && Date() < deadline { _ = try k.step(50_000_000) }
            return String(k.console.plainText().dropFirst(before))
        }
        let n0 = env.sounds.count
        _ = try run("Noise(2000,40,50);")       // returns at once; the Noise task plays on, as on TempleOS
        for _ in 0..<60 { _ = try k.step(50_000_000) }
        let m = try run("music.mute;")
        XCTAssertTrue(m.contains("ans=0x00000000=0"), m)
        let ns = (n0..<env.sounds.count).filter { env.sounds[$0] > 0 }.map { env.soundNowNs[$0] }
        XCTAssertGreaterThan(ns.last! - ns.first!, 1_900_000_000, "the noise played its 2 s")
        XCTAssertEqual(env.sounds.last, 0, "and ended with the speaker off")
        let n = env.sounds.count
        _ = try run("Play(\"qC\");")
        XCTAssertTrue(env.sounds[n...].contains { abs($0 - onaHz[51]!) < 1e-6 }, "the next song is heard: \(Array(env.sounds[n...]))")
    }
}

import Foundation
import XCTest
@testable import TempleCore

/**
 * The sound of the three programs TempleOS Mobile cannot run as a whole (Psalmody and ToTheFront need the DolDoc
 * document API, Vocabulary the 26 MB AutoComplete dictionary), checked by running their original HolyC headless:
 * Psalmody's song files unmodified, Vocabulary's VocabQuiz.HC and ToTheFront's fire and move code unmodified behind
 * a test-only stand-in for the missing API. Nothing here is shipped. Port of BlockedProgramsSoundTest.kt.
 * Spec: docs/audio/TEMPLEOS_AUDIO_FIDELITY.md §11.
 */
final class BlockedProgramsSoundTests: XCTestCase {
    private func num(_ v: Any?) -> Double {
        if let d = v as? Double { return d }; if let i = v as? Int64 { return Double(i) }; if let i = v as? Int { return Double(i) }
        return .nan
    }

    private lazy var fx: [String: Any?] = {
        let text = try! String(contentsOf: SHARED.appendingPathComponent("test-vectors/audio/play-fixtures.json"), encoding: .utf8)
        return (try! Json.parse(text)) as! [String: Any?]
    }()

    private lazy var onaHz: [Int: Double] = {
        var m: [Int: Double] = [0: 0]
        for row in fx["pit_counts"] as! [Any?] { let r = row as! [Any?]; m[Int(num(r[0]))] = num(r[2]) }
        return m
    }()

    private func bundledFs() -> LayeredFs {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tosm-blocked-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return LayeredFs(DirBundle(SHARED.appendingPathComponent("bundled-fs"), SHARED.appendingPathComponent("bundled-fs.index")), dir)
    }

    /** Boots, runs [src] as [name], and steps virtual time until [untilNs] (or the end); [during] may post input. */
    private func run(_ env: TestEnv, _ src: [UInt8], _ name: String, until untilNs: Int64, during: (Kernel) throws -> Void = { _ in }) throws -> Kernel {
        let k = Kernel(env, "blocked")
        k.virtualTime = true
        try k.boot()
        try k.runProgram(name, src)
        let wall = Date().addingTimeInterval(300)
        k.virtualStopAt = untilNs
        while !k.finished && k.now() < untilNs && Date() < wall {
            try during(k)
            if try k.step(50_000_000) < 0 { break }
        }
        return k
    }

    private func changes(_ env: TestEnv, from: Int64) -> [(Int64, Double)] {
        var out: [(Int64, Double)] = []
        var cur = 0.0
        for i in env.sounds.indices {
            let j = TempleClock.jiffyAt(env.soundNowNs[i])
            if j < from { cur = env.sounds[i]; continue }
            if env.sounds[i] != cur { out.append((j, env.sounds[i])); cur = env.sounds[i] }
        }
        return out
    }

    // ------------------------------------------------------------------ Psalmody

    func testPsalmodySongFilesPlayTheirScoresAsTheReference() throws {
        let cases = (fx["cases"] as! [Any?]).map { $0 as! [String: Any?] }.filter { ($0["id"] as! String).hasPrefix("psalmody:") }
        XCTAssertEqual(cases.count, 3)
        for c in cases {
            let file = String((c["id"] as! String).dropFirst("psalmody:".count))
            let j0 = Int64(num(c["j0"]!)), end = Int64(num(c["end"]!))
            let bytes = try XCTUnwrap(readFileBytes(SHARED.appendingPathComponent("bundled-fs/Apps/Psalmody/Examples/\(file)")))
            let env = TestEnv(bundledFs())
            let k = try run(env, latin1("SleepUntil(\(j0));\n") + bytes, "C:/Apps/Psalmody/Examples/\(file)", until: TempleClock.jiffyStartNs(j0 + end + 30))
            XCTAssertFalse(k.finished, "\(file): \(k.console.plainText().suffix(300))")
            let want: [(Int64, Double)] = (c["events"] as! [Any?]).map { e in let r = e as! [Any?]; return (Int64(num(r[0])), onaHz[Int(num(r[1]))]!) }
            let all = changes(env, from: j0).map { ($0.0 - j0, $0.1) }
            let got = all.filter { $0.0 < end }
            XCTAssertEqual(got.map { $0.0 }, want.map { $0.0 }, "\(file): one pass of the song (jiffies)")
            XCTAssertEqual(got.map { $0.1 }, want.map { $0.1 }, "\(file): one pass of the song (Hz)")
            let second = try XCTUnwrap(all.first { $0.0 >= end })
            XCTAssertEqual(second.0, end, "\(file): second pass")
            XCTAssertEqual(second.1, want[0].1, "\(file): second pass")
        }
    }

    // ------------------------------------------------------------------ Vocabulary

    /** Test-only stand-in for Adam/AutoComplete's dictionary (see BlockedProgramsSoundTest.kt). */
    private let vocabShim = """
        class CAcdShim { U8 *word_lst; I64 num_words; };
        CAcdShim acd;
        U8 *ACDDefGet(U8 *st,I64 def_num=1) { no_warn def_num; return MStrPrint("the meaning of %s",st); }
        U0 ACDPopUpDef(U8 *st,I64 def_num=1,CTask *mem_task=NULL) { no_warn st,def_num,mem_task; }
        U0 AcdShimInit()
        {
          U8 *names[4]={"alpha","beta","gamma","delta"},*p;
          I64 i;
          p=acd.word_lst=CAlloc(256);
          for (i=0;i<4;i++) { *p++=ACD_WORD_CHAR; StrCpy(p,names[i]); p+=StrLen(names[i])+1+2; }
          acd.num_words=4;
        }
        AcdShimInit;
        #include "C:/Apps/Vocabulary/VocabQuiz.HC"
        VocabQuiz;

        """

    func testVocabularyQuizSoundsAsTheOriginal() throws {
        var right = 0
        for key in ["1", "2", "3", "4"] {
            let fs = bundledFs()
            try fs.mkdir("C:/Adam/AutoComplete")
            try fs.writeFile("C:/Adam/AutoComplete/ACDefs.DATA", [UInt8](repeating: 0, count: 16))
            let env = TestEnv(fs)
            var posted = 0
            let k = try run(env, latin1(vocabShim), "C:/Home/VocabShim.HC", until: 5_000_000_000) { kk in
                let ms = kk.now() / 1_000_000
                if posted == 0 && ms > 1000 { let (ch, sc) = try ScenarioTests.keyOf(key); kk.post(.key(ch: ch, sc: sc, down: true)); kk.post(.key(ch: ch, sc: sc | Keys.SCF_KEY_UP, down: false)); posted = 1 }
                if posted == 1 && ms > 3000 { let (ch, sc) = try ScenarioTests.keyOf("ESC"); kk.post(.key(ch: ch, sc: sc, down: true)); kk.post(.key(ch: ch, sc: sc | Keys.SCF_KEY_UP, down: false)); posted = 2 }
            }
            let text = k.console.plainText()
            XCTAssertTrue(text.contains("Answer:"), "key \(key): \(text)")
            let c = changes(env, from: 0)
            let correct = text.contains("Correct")
            XCTAssertTrue(correct != text.contains("Incorrect"), "key \(key): \(text)")
            if correct { right += 1 }
            XCTAssertEqual(c.count, 2, "key \(key): a tone and its end: \(c)")
            guard c.count == 2 else { continue }
            XCTAssertEqual(c[0].1, onaHz[correct ? 74 : 46]!)
            XCTAssertEqual(c[1].1, 0)
            XCTAssertEqual(c[1].0 - c[0].0, 500, "key \(key)")
        }
        XCTAssertEqual(right, 1, "exactly one of the four keys is the right answer")
    }

    // ------------------------------------------------------------------ ToTheFront

    /** Test-only harness: ToTheFront's files without its DolDoc-bound ones (see BlockedProgramsSoundTest.kt). */
    private let ttfHarness = """
        Cd("C:/Apps/ToTheFront");;
        #include "C:/Apps/ToTheFront/TTFGlbls.HC"
        #include "C:/Apps/ToTheFront/TTFLib.HC"
        #include "C:/Apps/ToTheFront/TTFVis.HC"
        #include "C:/Apps/ToTheFront/TTFFire.HC"
        #include "C:/Apps/ToTheFront/TTFMove.HC"
        I64 plots;
        Bool CountPlot(U0,I64,I64,I64) { plots++; return TRUE; }
        U0 Harness()
        {
          Unit *a=&units[0][0],*b=&units[1][0];
          I64 j;
          animation_delay=0.5;
          hex_centers[2][2].x=40; hex_centers[2][2].y=40;
          hex_centers[2][3].x=73; hex_centers[2][3].y=49;
          a->num=0; a->player=0; a->row=2; a->col=2; a->life=10; a->infantry=TRUE; a->facing=0;
          b->num=0; b->player=1; b->row=2; b->col=3; b->life=10; b->infantry=FALSE; b->armor=5; b->facing=3;
          plots=0; Line(NULL,40,40,0,73,49,0,&CountPlot);
          "PLOTS:%d\\n",plots;
          SleepUntil(10000);
          UnitMoveAnimation(a,2,3,1);                        //infantry: Snd(53), the move, Snd
          SleepUntil(12000);
          UnitMoveAnimation(b,2,2,0);                        //armour: Snd(41) while turning, Snd(34) moving, Snd
          SleepUntil(16000);
          DamageDo(a,100.0);                                 //killed: Noise(1000*animation_delay,74,98)
          "KILL_END:%d\\n",cnts.jiffies;
          SleepUntil(20000);
          a->life=10; b->life=10; b->fired=FALSE;
          HexOccupy(TRUE,b,a);                               //Noise(500*d,34,41), then while (scrncast.ona) Yield;
          "OCC_END:%d MUTE:%d\\n",cnts.jiffies,music.mute;
        }
        Harness;

        """

    func testToTheFrontMoveAndFireSoundAsTheOriginal() throws {
        let env = TestEnv(bundledFs())
        let k = try run(env, latin1(ttfHarness), "C:/Home/TTFShim.HC", until: TempleClock.jiffyStartNs(26000))
        let text = k.console.plainText()
        XCTAssertTrue(k.finished && text.contains("MUTE:0"), text)
        func value(_ key: String) -> Int64? {
            guard let r = text.range(of: key + ":") else { return nil }
            return Int64(text[r.upperBound...].prefix { $0.isNumber })
        }
        XCTAssertGreaterThan(value("PLOTS") ?? 0, 10)
        let c = changes(env, from: 10000)
        // known gap (docs §11.5): the move's Sleep runs inside the native Line's callback and takes no time here
        XCTAssertEqual(c.filter { (10000..<12000).contains($0.0) }.map { $0.1 }, [onaHz[53]!, 0])
        let arm = c.filter { (12000..<16000).contains($0.0) }
        XCTAssertEqual(arm.map { $0.1 }, [onaHz[41]!, onaHz[34]!, 0])
        guard arm.count == 3 else { return }
        XCTAssertEqual(arm[0].0, 12000)
        let turn = arm[1].0 - arm[0].0
        XCTAssertTrue(turn >= 2 && turn % 2 == 0, "turning in 0.03 rad steps of 2 jiffies: \(turn)")
        let kill = c.filter { (16000..<20000).contains($0.0) }
        let killRange = Set((74...97).map { onaHz[$0]! })
        XCTAssertTrue(kill.dropLast().allSatisfy { killRange.contains($0.1) })
        XCTAssertEqual(kill.last?.0, 16000 + 501)
        XCTAssertEqual(kill.last?.1, 0)
        let occ = c.filter { $0.0 >= 20000 }
        let occEnd = try XCTUnwrap(value("OCC_END"))
        XCTAssertEqual(occ.last?.1, 0)
        XCTAssertGreaterThanOrEqual(occEnd, occ.last!.0, "HexOccupy returns once the last noise has ended")
        XCTAssertTrue(occ.dropLast().allSatisfy { $0.1 > 0 })
    }
}

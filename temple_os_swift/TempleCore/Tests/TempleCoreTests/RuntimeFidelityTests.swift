import Foundation
import XCTest
@testable import TempleCore

/**
 * Smaller runtime fidelity fixes (docs/fidelity-audit FA-23..FA-28): the console's newline fill
 * (Adam/DolDoc/DocRecalc.HC:724), no artificial task cap (TempleOS spawns until memory runs out),
 * a paused program not seeing the paused time pass (TempleOS has no pause), the original line
 * input (GetStr, GetI64, View) and the terminal's scroll bars. Port of RuntimeFidelityTest.kt.
 */
final class RuntimeFidelityTests: XCTestCase {
    private func last(_ k: Kernel) -> String {
        (k.console.plainText().trimmed().components(separatedBy: "\n").last ?? "").trimmingCharacters(in: .whitespaces)
    }
    private func key(_ ch: Int) -> KInput { let (c, sc) = Keys.forChar(ch); return .key(ch: c, sc: sc, down: true) }
    private let shiftEsc = KInput.key(ch: Keys.CH_SHIFT_ESC, sc: Int64(Keys.SC_ESC) | Keys.SCF_SHIFT, down: true)
    private func type(_ k: Kernel, _ s: String) { for c in s.unicodeScalars { k.post(key(Int(c.value))) } }

    func testNewlineFillsTheRestOfTheRowWithTheCurrentColors() {
        let c = Console()
        c.write("$BG,RED$x\n$BG$y")
        let cols = 10
        var dst = [Int](repeating: 0, count: cols * 2)
        c.renderCells(&dst, cols, 2, (Console.DFT_BG << 4) | Console.DFT_FG)
        for x in 1..<cols { XCTAssertEqual((dst[x] >> 12) & 15, Palette.RED, "row 0 col \(x) takes RED from the newline") }
        XCTAssertEqual((dst[cols + 3] >> 12) & 15, Console.DFT_BG, "row 1 after 'y' keeps the window color")
    }

    func testManyTasksAreAllowed() throws {
        // BomberGolf: one 3 s Noise task per bomb, about 90 at once while SPACE repeats
        let env = TestEnv(); env.memMB = 64
        let k = try runHolyC(latin1("U0 T(U8 *) {Sleep(1000);}\nI64 i;for (i=0;i<100;i++) Spawn(&T,NULL,\"T\");\"spawned %d\\n\",i;\n"), env: env)
        XCTAssertFalse(k.console.plainText().contains("TooMany"), k.console.plainText())
        XCTAssertTrue(k.console.plainText().contains("spawned 100"), k.console.plainText())
    }

    /** Adam/DolDoc/DocEd.HC View: only ESC (TRUE) and SHIFT-ESC (FALSE) end it; ENTER and SPACE do not. */
    func testViewEndsOnlyOnEscOrShiftEsc() throws {
        let k = try runHolyC(latin1("\"%d\\n\",View;\n")) { kk in self.type(kk, "\n x"); kk.post(self.key(Keys.CH_ESC)) }
        XCTAssertEqual(last(k), "x1", "View edits the document before returning ESC")
        let k2 = try runHolyC(latin1("\"%d\\n\",View;\n")) { kk in self.type(kk, "\n"); kk.post(self.shiftEsc) }
        XCTAssertEqual(last(k2), "0")
    }

    /** Adam/DolDoc/DocGet.HC DocGetStr2: ESC does not end or clear a prompt; SHIFT-ESC returns "" (so the default). */
    func testGetStrIgnoresEscAndShiftEscGivesTheDefault() throws {
        let k = try runHolyC(latin1("U8 *s=GetStr(\"?\");\"[%s]\\n\",s;\n")) { kk in self.type(kk, "ab"); kk.post(self.key(Keys.CH_ESC)); self.type(kk, "c\n") }
        XCTAssertEqual(last(k), "[abc]")
        let k2 = try runHolyC(latin1("U8 *s=GetStr(,\"dft\");\"[%s]\\n\",s;\n")) { kk in self.type(kk, "ab"); kk.post(self.shiftEsc) }
        XCTAssertEqual(last(k2), "ab[dft]", "the typed text stays on the line")
        // GSF_SHIFT_ESC_EXIT ends the task instead
        let k3 = try runHolyC(latin1("GetStr(,,GSF_SHIFT_ESC_EXIT);\"after\\n\";\n")) { kk in kk.post(self.shiftEsc) }
        XCTAssertFalse(k3.console.plainText().contains("after"), k3.console.plainText())
        // GSF_WITH_NEW_LINE: ENTER starts a new line, ESC ends the text
        let k4 = try runHolyC(latin1("U8 *s=GetStr(,,GSF_WITH_NEW_LINE);\"\\n%d %d\\n\",StrLen(s),s[1];\n")) { kk in self.type(kk, "a\nb"); kk.post(self.key(Keys.CH_ESC)) }
        XCTAssertEqual(last(k4), "3 10")
    }

    /** Adam/DolDoc/DocGet.HC GetI64: the answer is an expression; a bad one or one out of range asks again. */
    func testGetI64EvaluatesAndAsksAgain() throws {
        let k = try runHolyC(latin1("\"=%d\\n\",GetI64(\"n:\",7,0,100);\n")) { kk in self.type(kk, "nonsense\n500\n6*7\n") }
        XCTAssertEqual(last(k), "=42")
        let k2 = try runHolyC(latin1("\"=%d\\n\",GetI64(\"n:\",7,0,100);\n")) { kk in self.type(kk, "\n") }
        XCTAssertEqual(last(k2), "=7")
        let k3 = try runHolyC(latin1("\"=%.2f\\n\",GetF64(\"x:\",1.0);\n")) { kk in self.type(kk, "1/4.0\n") }
        XCTAssertEqual(last(k3), "=0.25")
        // Compiler/OptPass012.HC: ToF64 of an F64 and ToI64 of an I64 leave the value as it is
        let k4 = try runHolyC(latin1("F64 z=0.5;\"%.3f %d %.3f %.3f\\n\",ToF64(1/4.0),ToI64(2.75),ToF64(z),ToF64(3);\n"))
        XCTAssertEqual(last(k4), "0.250 2 0.500 3.000")
    }

    /**
     * A program runs in the user's terminal task, which has the window's two scroll bars
     * (Adam/DolDoc/DocTerm.HC:49 WinScrollsInit); the wheel moves the vertical one
     * (Adam/WinMgr.HC wheel_chg). They do not make a text program a graphics one.
     */
    func testProgramsHaveTheTerminalScrollBars() throws {
        let k = try runHolyC(latin1("CCtrl *h=CtrlFindUnique(Fs,CTRLT_WIN_HSCROLL),*v=CtrlFindUnique(Fs,CTRLT_WIN_VSCROLL);" +
            "Refresh(2);\"%d %d\\n\",h!=NULL,v!=NULL;\n"))
        XCTAssertEqual(last(k), "1 1")
        XCTAssertFalse(k.graphicsUsed, "scroll bars alone keep the console")
        // Demo/Graphics/ScrollBars.HC: a drawing program sets the range and reads the position
        let k2 = try runHolyC(latin1("U0 D(CTask *,CDC *) {}\nFs->draw_it=&D;Fs->vert_scroll.max=100;Refresh(2);MsSet(,,3);Refresh(2);" +
            "\"%d\\n\",Fs->vert_scroll.pos;\n"))
        XCTAssertEqual(last(k2), "3")
    }

    /**
     * Kernel/KMisc.HC Snd programs the PIT with SYS_TIMER_FREQ (18333*65536/1000) but the PIT counts at
     * 1193182 Hz: the reference VM's speaker plays 437.1 Hz for ona 60 and 218.43 Hz for ona 48
     * (docs/fidelity-audit/data/vm-observations.json). A negative ona plays the slowest tone.
     */
    func testSpeakerPitchIsTheTempleOsPit() throws {
        let env = TestEnv()
        _ = try runHolyC(latin1("Snd(60);Sleep(10);Snd(48);Sleep(10);Snd(-12);Sleep(10);Snd;\n"), env: env)
        let f = env.sounds.filter { $0 > 0 }
        XCTAssertEqual(f.count, 3)
        if f.count == 3 {
            XCTAssertEqual(f[0], 437.06, accuracy: 0.01)
            XCTAssertEqual(f[1], 218.49, accuracy: 0.01)
            XCTAssertEqual(f[2], 18.21, accuracy: 0.01)
        }
        // Freq2Ona truncates: 12*Log2(32/440*120)=37.5 -> 37
        XCTAssertEqual(last(try runHolyC(latin1("\"%d %d %d\\n\",Freq2Ona(120),Freq2Ona(440),Freq2Ona(0);\n"))), "37 60 0")
    }

    /** Kernel/KMathB.HC Seed returns the seed, a new timer-based one for 0. */
    func testSeedReturnsTheSeed() throws {
        XCTAssertEqual(last(try runHolyC(latin1("\"%d %d\\n\",Seed(5),Seed(0)!=0;\n"))), "5 1")
    }

    /** Kernel/SerialDev/Message.HC ScanChar: a key-down returns only once its key-up has come. */
    func testScanCharWaitsForTheKeyUp() throws {
        let k = try runHolyC(latin1("U0 P(CTask *parent) {Sleep(200);PostMsg(parent,MSG_KEY_UP,'a',0x1E);}\n" +
            "Msg(MSG_KEY_DOWN,'a',0x1E);Spawn(&P,Fs);F64 t0=tS;I64 c=ScanChar;\"%d %d\\n\",c,tS-t0>0.15;\n"))
        XCTAssertEqual(last(k), "97 1")
        // no key: 0 at once; a key-down with no ASCII (SHIFT) is consumed and gives 0
        XCTAssertEqual(last(try runHolyC(latin1("Msg(MSG_KEY_DOWN,0,SC_SHIFT);I64 a=ScanChar,b=ScanChar;\"%d %d\\n\",a,b;\n"))), "0 0")
    }

    /** Panning the text layer or replacing its font shows the TempleOS screen (PanText, CharAnimation). */
    func testTextLayerProgramsShowTheScreen() throws {
        XCTAssertTrue(try runHolyC(latin1("gr.pan_text_x=3;Refresh(2);gr.pan_text_x=0;\n")).graphicsUsed)
        XCTAssertTrue(try runHolyC(latin1("U64 *f=MAlloc(256*8);MemCpy(f,text.font,256*8);f[' ']=0x0011AA440011AA44;text.font=f;Refresh(2);\n")).graphicsUsed)
        XCTAssertFalse(try runHolyC(latin1("\"text\\n\";Refresh(2);\n")).graphicsUsed)
    }

    /**
     * Adam/Gr/GrScrn.HC GrUpdateTasks sums each frame's ODE time into winmgr.last_ode_time, which with
     * Gs->idle_factor budgets the next frame's ODEs (Adam/AMathODE.HC ODEsUpdate).
     */
    func testOdeTimeBudgetIsKept() throws {
        // on the real clock: in virtual time a frame's work takes no time
        let k = Kernel(TestEnv(), "test")
        try k.boot()
        try k.runProgram("C:/Home/Test.HC", latin1("U0 D(CMathODE *,F64,F64 *,F64 *d) {d[0]=1.0;}\nU0 Dr(CTask *,CDC *) {}\n" +
            "Fs->draw_it=&Dr;CMathODE *o=ODENew(1,1e-4);o->derive=&D;QueIns(o,Fs->last_ode);Sleep(500);" +
            "\"%d %d %d\\n\",winmgr.last_ode_time>0,0.0<=Gs->idle_factor<=1.0,o->state[0]>0.3;QueRem(o);\n"))
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let r = try k.step(50_000_000)
            if r < 0 { break }
            if r > 0 { Thread.sleep(forTimeInterval: Double(r) / 1e9) }
        }
        XCTAssertEqual(last(k), "1 1 1")
    }

    /** Span's file choosers (Adam/DolDoc/DocPopUp.HC) as native lists: the default name, the directory's files. */
    func testFileChoosersOfferTheDefaultAndTheFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pick-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fs = LayeredFs(DirBundle(SHARED.appendingPathComponent("bundled-fs"), SHARED.appendingPathComponent("bundled-fs.index")), dir.path)
        let k = try runHolyC(latin1("DirMk(\"~/Span\");FileWrite(\"~/Span/B.DATA\",\"x\",1);FileWrite(\"~/Span/A.DATA\",\"y\",1);" +
            "U8 *n=PopUpFileName(\"~/Span/Game.DATA\"),*p=PopUpPickFile(\"~/Span\");\"%s %s\\n\",n,p;\n"), env: TestEnv(fs))
        // headless popups take the first entry: the default name, and the first file in name order
        XCTAssertEqual(last(k), "~/Span/Game.DATA ~/Span/A.DATA")
    }

    func testPausedTimeIsNotProgramTime() throws {
        let env = TestEnv(); env.fakeClock = 1_000_000_000
        let k = Kernel(env, "t")
        try k.boot()
        let t0 = k.now()
        env.fakeClock! += 2_000_000_000
        k.clockPaused(true)
        env.fakeClock! += 30_000_000_000 // half a minute in the background
        k.clockPaused(false)
        env.fakeClock! += 1_000_000_000
        XCTAssertEqual(k.now() - t0, 3_000_000_000, "only the 3 s the program ran are program time")
    }
}

import Foundation
import XCTest
@testable import TempleCore

/**
 * TempleOS input semantics (docs/fidelity-audit, FA-04..FA-10). Expected values come from the
 * original sources: Kernel/SerialDev/Keyboard.HC (KbdBuildSC, ScanCode2Char, KbdHndlr),
 * Kernel/SerialDev/Mouse.HC (MsSet, MsUpdate, MsHardSpeedSet), Adam/Win.HC (ms.speed) and
 * Adam/WinMgr.HC (WinQueIPMsgs, grab scroll, double click = ESC). Port of InputFidelityTest.kt.
 */
final class InputFidelityTests: XCTestCase {
    private func last(_ k: Kernel) -> String {
        (k.console.plainText().trimmed().components(separatedBy: "\n").last ?? "").trimmingCharacters(in: .whitespaces)
    }

    func testPointerMovesAreOneMessagePerFrame() throws {
        let k = try runHolyC(latin1("I64 n=0,a,b;F64 t0=tS;while (tS-t0<0.3) {while (ScanMsg(&a,&b,1<<MSG_MS_MOVE)) n++;Sleep(1);}\"%d\\n\",n;\n")) { kk in
            for i in 1...100 { kk.post(.mouse(x: 10 + i, y: 20 + i, lb: false, rb: false)) }
        }
        XCTAssertEqual(last(k), "1")
    }

    func testMsSetMovesThePointerAndTheWheel() throws {
        let k = try runHolyC(latin1("MsSet(100,200,25);Refresh;\"%d %d %d\\n\",ms.pos.x,ms.pos.y,ms.pos.z;\n"))
        XCTAssertEqual(last(k), "100 200 25")
    }

    func testMsSpeedFollowsTheMotion() throws {
        let k = try runHolyC(latin1("MsSet(0,0);Sleep(100);MsSet(300,400);Refresh;\"%d\\n\",ToI64(ms.speed);\n"))
        let v = Int(last(k)) ?? -1
        XCTAssertTrue((3500...6000).contains(v), "500 px in ~0.1 s gives ~5000 px/s, got \(v)")
    }

    func testHeldShiftAndCtrlChangeCharAndFlags() throws {
        let a = Keys.forChar(97).1
        func post(_ kk: Kernel) {
            kk.post(.key(ch: 0, sc: Int64(Keys.SC_SHIFT), down: true))
            kk.post(.key(ch: 97, sc: a, down: true))
            kk.post(.key(ch: 0, sc: Int64(Keys.SC_SHIFT) | Keys.SCF_KEY_UP, down: false))
            kk.post(.key(ch: 0, sc: Int64(Keys.SC_CTRL), down: true))
            kk.post(.key(ch: 97, sc: a, down: true))
        }
        let k = try runHolyC(latin1("I64 sc,c1,c2;c1=GetKey(&sc);c2=GetKey;\"%d %d %d %d\\n\",c1,!!(sc&SCF_SHIFT),Bt(kbd.down_bitmap,SC_SHIFT),c2;\n")) { post($0) }
        let k2 = try runHolyC(latin1("I64 c1=GetChar(,FALSE),c2=GetChar(,FALSE);\"%d %d %d\\n\",c1,c2,Bt(kbd.down_bitmap,SC_CTRL);\n")) { post($0) }
        XCTAssertEqual(last(k), "0 1 1 65")
        XCTAssertEqual(last(k2), "65 1 1")
    }

    func testDownBitmap2UsesTheE0Bit() throws {
        let (cu, su) = Keys.special(Keys.SC_CURSOR_UP)
        let k = try runHolyC(latin1("GetKey;\"%d %d %d\\n\",Bt(kbd.down_bitmap,SC_CURSOR_UP),Bt(kbd.down_bitmap2,SC_CURSOR_UP|0x80),Bt(kbd.down_bitmap2,SC_CURSOR_UP);\n")) { kk in
            kk.post(.key(ch: cu, sc: su, down: true))
        }
        XCTAssertEqual(last(k), "1 1 0")
    }

    func testCtrlAltLettersAreTheSystems() throws {
        let x = Keys.forChar(120).1, b = Keys.forChar(98).1
        let k = try runHolyC(latin1("I64 c=GetChar(,FALSE);\"%d\\n\",c;\n")) { kk in
            kk.post(.key(ch: 120, sc: x | Keys.SCF_CTRL | Keys.SCF_ALT, down: true))
            kk.post(.key(ch: 98, sc: b, down: true))
        }
        XCTAssertEqual(last(k), "98")
    }

    private let clicker = "U0 Clicker(U8 *) {Sleep(100);MsSet(100,100,,1);Sleep(60);MsSet(,,,0);Sleep(60);MsSet(,,,1);Sleep(60);MsSet(,,,0);}\n"

    func testDoubleClickIsEsc() throws {
        let k = try runHolyC(latin1(clicker + "Spawn(&Clicker);I64 sc,ch=GetKey(&sc);\"%d %d\\n\",ch,sc;\n"))
        XCTAssertEqual(last(k), "27 0")
    }

    func testDblClickInhibitGivesPlainClicks() throws {
        let k = try runHolyC(latin1(clicker + "Fs->win_inhibit=WIG_TASK_DFT;Spawn(&Clicker);I64 n=0,a,b,c,keys=0;F64 t0=tS;" +
            "while (tS-t0<1.0) {while (c=ScanMsg(&a,&b,1<<MSG_MS_L_DOWN|1<<MSG_MS_L_D_DOWN|1<<MSG_KEY_DOWN)) {if (c==MSG_MS_L_DOWN) n++; else keys++;} Sleep(1);}" +
            "\"%d %d\\n\",n,keys;\n"))
        XCTAssertEqual(last(k), "2 0")
    }

    func testSingleClickWaitsForTheDoubleClickTime() throws {
        let one = "U0 Clicker(U8 *) {Sleep(100);MsSet(100,100,,1);Sleep(60);MsSet(,,,0);}\n"
        let k = try runHolyC(latin1(one + "Spawn(&Clicker);F64 t0=tS;I64 a,b;GetMsg(&a,&b,1<<MSG_MS_L_DOWN);\"%d\\n\",ToI64((tS-t0)*1000);\n"))
        let ms = Int(last(k)) ?? -1
        XCTAssertTrue((440...520).contains(ms), "left down after \(ms) ms (press at 100 ms + 350 ms)")
        let k2 = try runHolyC(latin1(one + "Fs->win_inhibit=WIG_TASK_DFT;Spawn(&Clicker);F64 t0=tS;I64 a,b;GetMsg(&a,&b,1<<MSG_MS_L_DOWN);\"%d\\n\",ToI64((tS-t0)*1000);\n"))
        let ms2 = Int(last(k2)) ?? -1
        XCTAssertTrue((95...160).contains(ms2), "left down after \(ms2) ms (press at 100 ms)")
    }

    func testCtrlDragScrollsTheWindow() throws {
        let drag = "U0 Drag(U8 *) {Sleep(50);MsSet(100,100,,1);Sleep(50);MsSet(140,120);Sleep(50);MsSet(,,,0);}\n"
        let k = try runHolyC(latin1(drag + "Spawn(&Drag);I64 n=0,a,b;F64 t0=tS;" +
            "while (tS-t0<0.5) {while (ScanMsg(&a,&b,1<<MSG_MS_L_DOWN|1<<MSG_MS_MOVE)) n++; Sleep(1);}" +
            "\"%d %d %d\\n\",Fs->scroll_x,Fs->scroll_y,n;\n")) { kk in
            kk.post(.key(ch: 0, sc: Int64(Keys.SC_CTRL), down: true))
        }
        XCTAssertEqual(last(k), "40 16 0")
    }
}

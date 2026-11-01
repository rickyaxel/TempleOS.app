import Foundation
import XCTest
@testable import TempleCore

/**
 * Programs see TempleOS's window coordinates (docs/fidelity-audit, FA-01). The values below follow
 * from the original arithmetic: Kernel/Display.HC WinDerivedValsUpdate (pix = FONT_WIDTH * text
 * cell) and Adam/Win.HC WinMax (text columns 1..TEXT_COLS-2 and rows 2..TEXT_ROWS-2 with a border,
 * 0..TEXT_COLS-1 and 1..TEXT_ROWS-1 without one). Port of WindowGeometryTest.kt.
 */
final class WindowGeometryTests: XCTestCase {
    private func lastLine(_ k: Kernel) -> String? { k.console.plainText().trimmed().components(separatedBy: "\n").last }

    private func geom(_ setup: String) throws -> String? {
        lastLine(try runHolyC(latin1(setup + "\"%d %d %d %d\\n\",Fs->pix_left,Fs->pix_top,Fs->pix_width,Fs->pix_height;\n")))
    }

    func testInitialWindowIsAMaximizedTerminalWithBorder() throws { XCTAssertEqual(try geom(""), "8 16 624 456") }

    func testBorderlessMaximizedGameWindow() throws { XCTAssertEqual(try geom("WinBorder;WinMax;"), "0 8 640 472") }

    func testBorderedMaximizedWindow() throws { XCTAssertEqual(try geom("WinBorder(ON);WinMax;"), "8 16 624 456") }

    /** Demo/Games/FlapBat.HC: WinBorder(ON); WinHorz(1,TEXT_COLS/2); WinVert(2,TEXT_ROWS/2); */
    func testFlapBatHalfWindow() throws {
        XCTAssertEqual(try geom("WinBorder(ON);WinHorz(1,TEXT_COLS/2);WinVert(2,TEXT_ROWS/2);"), "8 16 320 232")
    }

    func testWindowRestoredBySettingsPop() throws {
        XCTAssertEqual(try geom("SettingsPush;WinBorder;WinMax;SettingsPop;"), "8 16 624 456")
    }

    /** SettingsPop restores the palette ("SettingsPop() restores original palette", Demo/Graphics/Palette.HC). */
    func testSettingsPopRestoresPalette() throws {
        let k = try runHolyC(latin1("SettingsPush;GrPaletteColorSet(WHITE,0);SettingsPop;\"%X\\n\",GrPaletteColorGet(WHITE);\n"))
        XCTAssertEqual(lastLine(k), "FFFFFFFFFFFF")
    }

    func testDrawingAndPublishedWindowFollowTheWindow() throws {
        let k = try runHolyC(latin1("WinBorder;WinMax;CDC *dc=DCAlias;dc->color=RED;GrPlot(dc,0,0);DCDel(dc);Refresh;Refresh;\n"))
        // client (0,0) is screen (0,8): the borderless maximized window starts below the system bar row
        XCTAssertEqual(Int(k.published[8 * Kernel.W]), Palette.RED)
        XCTAssertEqual(k.publishedWindow, [0, 8, 640, 472])
    }

    /** Adam/WinMgr.HC WinQueIPMsgs: msg args are ms.pos minus the window's pix_left/pix_top; ms.pos is the screen. */
    func testMouseMessagesAreWindowRelative() throws {
        let k = try runHolyC(latin1("WinBorder(ON);WinMax;I64 a1,a2,c;do c=GetMsg(&a1,&a2,1<<MSG_MS_L_DOWN); while (!c);" +
            "\"%d %d %d %d\\n\",a1,a2,ms.pos.x,ms.pos.y;\n")) { kk in
            kk.post(.mouse(x: 100, y: 116, lb: true, rb: false))
        }
        XCTAssertEqual(lastLine(k), "92 100 100 116")
    }
}

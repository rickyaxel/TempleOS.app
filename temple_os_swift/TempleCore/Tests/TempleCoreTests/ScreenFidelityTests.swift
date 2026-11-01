import Foundation
import XCTest
@testable import TempleCore

/**
 * The TempleOS screen and program end (docs/fidelity-audit, FA-11..FA-16). References:
 * Adam/Gr/GrScrn.HC (GrUpdateTextBG/FG: text.font, pan_text, blink), Demo/Games/ElephantWalk.HC
 * and Demo/Graphics/MouseDemo.HC (drawing only on gr.dc), Demo/Graphics/CharAnimation.HC (a task
 * that outlives the program's code), Demo/Graphics/Extents.HC (output printed just before the end).
 * Port of ScreenFidelityTest.kt.
 */
final class ScreenFidelityTests: XCTestCase {
    private func run(_ src: String, _ vtMs: Int64 = 3000, setup: (Kernel) -> Void = { _ in }) throws -> Kernel {
        let k = Kernel(TestEnv(), "test")
        k.virtualTime = true
        try k.boot()
        setup(k)
        try k.runProgram("C:/Home/Test.HC", latin1(src))
        let deadline = Date().addingTimeInterval(20)
        k.virtualStopAt = vtMs * 1_000_000
        while Date() < deadline && k.now() < k.virtualStopAt { if try k.step(50_000_000) < 0 { break } }
        return k
    }

    private func px(_ k: Kernel, _ x: Int, _ y: Int) -> Int { Int(k.published[y * Kernel.W + x]) }

    func testDrawingOnlyOnGrDcIsGraphics() throws {
        let k = try run("GrPlot(gr.dc,10,10);while (TRUE) Refresh;", 500)
        XCTAssertTrue(k.graphicsUsed, "a program that only draws on gr.dc (ElephantWalk, MouseDemo, SunMoon) is shown as graphics")
    }

    func testPaletteChangeShowsTheScreen() throws {
        let k = try run("\"colors\\n\";GrPaletteColorSet(WHITE,0);while (TRUE) Refresh;", 500)
        XCTAssertTrue(k.graphicsUsed, "Demo/Graphics/Palette.HC changes what the whole screen looks like")
    }

    func testTextLayerUsesTextFont() throws {
        let k = try run("U64 *f=MAlloc(256*8);MemCpy(f,text.font,256*8);f['A']=-1;text.font=f;" +
            "WinBorder;WinMax;DocClear;\"A\";GrPlot(gr.dc,600,400);while (TRUE) Refresh;", 600)
        for y in 8..<16 { for x in 0..<8 { XCTAssertEqual(px(k, x, y), Palette.BLUE, "pixel \(x),\(y) of the replaced glyph") } }
    }

    func testPanTextMovesTheTextLayer() throws {
        let k = try run("WinBorder;WinMax;DocClear;\"$BG,RED$ \";gr.pan_text_x=3;gr.pan_text_y=2;GrPlot(gr.dc,600,400);while (TRUE) Refresh;", 600)
        XCTAssertEqual(px(k, 3, 10), Palette.RED)
        XCTAssertEqual(px(k, 10, 17), Palette.RED)
        XCTAssertEqual(px(k, 1, 12), Palette.BLACK)
    }

    func testBlinkSwapsColors() throws {
        let src = "WinBorder;WinMax;DocClear;\"$BK,1$$BG,RED$$FG,YELLOW$ \";GrPlot(gr.dc,600,400);while (TRUE) Refresh;"
        var seen = Set<Int>()
        for t: Int64 in [300, 500, 700, 900] { seen.insert(px(try run(src, t), 4, 12)) }
        XCTAssertEqual(seen, [Palette.RED, Palette.YELLOW], "the cell alternates between its background and its foreground color")
    }

    func testSpawnedTasksOutliveTheProgramsCode() throws {
        let k = try run("U0 Child(U8 *) {Sleep(500);\"child done\\n\";}\nSpawn(&Child,NULL,\"Child\",,Fs);\"main done\\n\";", 2000)
        let out = k.console.plainText()
        XCTAssertTrue(out.contains("main done") && out.contains("child done"), out)
        XCTAssertTrue(k.finished, "ended once the last task ended")
    }

    func testStopEndsEverySpawnedTask() throws {
        let k = try run("U0 Child(U8 *) {while (TRUE) Sleep(10);}\nSpawn(&Child,NULL,\"Child\",,Fs);while (TRUE) Sleep(10);", 300)
        k.post(.breakKey)
        k.virtualStopAt = 2_000_000_000
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline && !k.finished { _ = try k.step(50_000_000) }
        XCTAssertTrue(k.finished, "Stop ended the program and its Child task")
    }

    func testLastOutputIsOnTheFinalFrame() throws {
        let k = try run("WinBorder;WinMax;DocClear;GrPlot(gr.dc,600,400);Refresh;\"$BG,RED$ \";", 1000)
        XCTAssertTrue(k.finished)
        XCTAssertEqual(px(k, 4, 12), Palette.RED)
    }
}

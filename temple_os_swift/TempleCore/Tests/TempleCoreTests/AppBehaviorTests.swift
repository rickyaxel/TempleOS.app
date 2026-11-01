import Foundation
import XCTest
@testable import TempleCore

/** Editor undo/redo and save, Stop Program, and sound release on close (headless shell). Port of AppBehaviorTest.kt. */
final class AppBehaviorTests: XCTestCase {
    private func waitFor(_ sh: Shell, _ ms: Int, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(Double(ms) / 1000)
        while Date() < end { _ = sh.tick(); if cond() { return true }; Thread.sleep(forTimeInterval: 0.02) }
        _ = sh.tick(); return cond()
    }

    private func shell() -> (Shell, HeadlessEnv, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apps-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let env = HeadlessEnv(dir)
        let sh = Shell(env); sh.resize(360, 640); _ = sh.tick()
        return (sh, env, dir)
    }

    /** V-25: a 120-column line in a 360 px window, like nano's '$' markers. */
    func testEditorMarksTextHiddenPastTheEdges() throws {
        let (sh, _, dir) = shell()
        defer { try? FileManager.default.removeItem(at: dir) }
        try sh.fs.writeFile("C:/Home/Wide.HC", latin1("//" + String(repeating: "a", count: 118) + "\nU0 Short;\n"))
        Launch.editor(sh, "C:/Home/Wide.HC")
        let ed = sh.focused!.app as! EditorApp
        let c = sh.clientRect(sh.focused!)
        let gutter = 3 * 8 + 4
        let y0 = c.y + EditorApp.HEADER
        func grayIn(_ x: Int, _ y: Int) -> Int {
            sh.invalidate(); _ = sh.tick()
            var n = 0
            for yy in y..<(y + 8) { for xx in x..<(x + 8) where Int(sh.surface.px[yy * sh.surface.width + xx]) == Palette.DKGRAY { n += 1 } }
            return n
        }
        let lastCol = c.x + gutter + ((c.w - gutter) / 8 - 1) * 8
        XCTAssertGreaterThan(grayIn(lastCol, y0), 16, "right marker on the long line")
        XCTAssertEqual(grayIn(lastCol, y0 + 8), 0, "no marker on the short line")
        XCTAssertEqual(grayIn(c.x + gutter, y0), 0, "no left marker before scrolling")
        ed.restoreCursor(0, 120)
        XCTAssertGreaterThan(grayIn(c.x + gutter, y0), 16, "left marker after scrolling right")
        XCTAssertGreaterThan(grayIn(c.x + gutter, y0 + 8), 16, "short line hidden to the left is marked too")
        for w in sh.windows { sh.close(w, force: true) }
    }

    func testEditorUndoRedoSave() throws {
        let (sh, _, dir) = shell()
        defer { try? FileManager.default.removeItem(at: dir) }
        try sh.fs.writeFile("C:/Home/Ed.HC", latin1("\"one\\n\";"))
        Launch.editor(sh, "C:/Home/Ed.HC")
        let ed = sh.focused!.app as! EditorApp
        XCTAssertEqual(ed.text(), "\"one\\n\";")
        ed.insert("A")
        Thread.sleep(forTimeInterval: 0.9) // separate undo steps (edits within 800 ms are grouped)
        ed.insert("B")
        XCTAssertEqual(ed.text(), "AB\"one\\n\";")
        XCTAssertTrue(ed.modified)
        ed.undo(); XCTAssertEqual(ed.text(), "A\"one\\n\";")
        ed.undo(); XCTAssertEqual(ed.text(), "\"one\\n\";")
        ed.undo(); XCTAssertEqual(ed.text(), "\"one\\n\";", "nothing left to undo")
        ed.redo(); XCTAssertEqual(ed.text(), "A\"one\\n\";")
        ed.redo(); XCTAssertEqual(ed.text(), "AB\"one\\n\";")
        ed.undo(); ed.undo()
        ed.insert("\"two\\n\";")
        ed.redo(); XCTAssertEqual(ed.text(), "\"two\\n\";\"one\\n\";", "a new edit clears redo")
        XCTAssertTrue(ed.save())
        XCTAssertFalse(ed.modified)
        XCTAssertEqual(latin1(sh.fs.readFile("C:/Home/Ed.HC")!), "\"two\\n\";\"one\\n\";")
        sh.windows.forEach { sh.close($0, force: true) }
        Launch.editor(sh, "C:/Home/Ed.HC")
        XCTAssertEqual((sh.focused!.app as! EditorApp).text(), "\"two\\n\";\"one\\n\";")
        sh.windows.forEach { sh.close($0, force: true) }
    }

    func testStopEndsBusyProgram() throws {
        let (sh, _, dir) = shell()
        defer { try? FileManager.default.removeItem(at: dir) }
        try sh.fs.writeFile("C:/Home/Busy.HC", latin1("I64 n=0; \"spinning\\n\"; while (TRUE) n++;"))
        Launch.program(sh, "C:/Home/Busy.HC", nil)
        let prog = sh.focused!.app as! ProgramApp
        XCTAssertTrue(waitFor(sh, 20000) { prog.kernel.console.plainText().contains("spinning") }, "program started")
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(prog.kernel.finished)
        prog.stop()
        XCTAssertTrue(waitFor(sh, 3000) { prog.kernel.finished }, "Stop ends a busy loop within 3 s")
        sh.windows.forEach { sh.close($0, force: true) }
    }

    /** Landscape: a program picture covered by another window is not composited over it (z-order). */
    func testCoveredProgramPictureRespectsStacking() throws {
        let (sh, _, dir) = shell()
        defer { try? FileManager.default.removeItem(at: dir) }
        sh.resize(640, 360); _ = sh.tick()
        Launch.program(sh, "C:/Home/Examples/Graphics.HC", nil)
        let progWin = sh.focused!
        let prog = progWin.app as! ProgramApp
        XCTAssertTrue(waitFor(sh, 30000) { prog.kernel.graphicsUsed && !sh.overlays().isEmpty }, "program draws")
        let doc = DocViewerApp(sh, "C:/Home/Welcome.DD")
        _ = sh.open(doc, maximized: true); _ = sh.tick()
        let mine = prog.overlays(sh.clientRect(progWin)).map { ObjectIdentifier($0.source) }
        XCTAssertTrue(sh.overlays().allSatisfy { !mine.contains(ObjectIdentifier($0.source)) }, "covered: its picture is not an overlay")
        XCTAssertTrue(sh.drawsFrameInSurface(prog))
        sh.focus(progWin); _ = sh.tick()
        XCTAssertTrue(waitFor(sh, 3000) { !sh.overlays().isEmpty && !sh.drawsFrameInSurface(prog) }, "on top again: overlay back")
        sh.windows.forEach { sh.close($0, force: true) }
    }

    /** An idle desktop (terminal + a program waiting for a key) does not ask for redraws every tick. */
    func testIdleDesktopDoesNotRedraw() throws {
        let (sh, _, dir) = shell()
        defer { try? FileManager.default.removeItem(at: dir) }
        try sh.fs.writeFile("C:/Home/Wait.HC", latin1("\"waiting\\n\"; GetChar;"))
        Launch.terminal(sh)
        let term = sh.focused!.app as! TerminalApp
        Launch.program(sh, "C:/Home/Wait.HC", nil)
        let prog = sh.focused!.app as! ProgramApp
        XCTAssertTrue(waitFor(sh, 30000) { prog.kernel.console.plainText().contains("waiting") && term.kernel.console.plainText().contains("C:/Home>") })
        Thread.sleep(forTimeInterval: 0.5); _ = sh.tick()
        var changed = 0, ticks = 0
        let end = Date().addingTimeInterval(2)
        while Date() < end { if sh.tick() { changed += 1 }; ticks += 1; Thread.sleep(forTimeInterval: 0.016) }
        XCTAssertLessThanOrEqual(changed, 3, "idle redraws: \(changed) of \(ticks)")
        sh.windows.forEach { sh.close($0, force: true) }
    }

    func testClosingProgramSilencesSound() throws {
        let (sh, env, dir) = shell()
        defer { try? FileManager.default.removeItem(at: dir) }
        try sh.fs.writeFile("C:/Home/Beep.HC", latin1("Snd(62); while (TRUE) Sleep(10);"))
        Launch.program(sh, "C:/Home/Beep.HC", nil)
        XCTAssertTrue(waitFor(sh, 20000) { env.tones.contains { $0 > 0 } }, "tone started")
        let win = sh.focused!
        sh.close(win, force: true)
        XCTAssertTrue(waitFor(sh, 3000) { env.tones.last == 0.0 }, "silence after close")
        let prog = win.app as! ProgramApp
        XCTAssertTrue(waitFor(sh, 3000) { prog.isFinished }, "closed program's kernel stops")
    }
}

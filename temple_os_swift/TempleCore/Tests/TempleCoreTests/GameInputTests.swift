import Foundation
import XCTest
@testable import TempleCore

/**
 * Arrow keys reach programs as TempleOS delivers them: sc.u8[0]==SC_CURSOR_UP (no E0 bit,
 * Kernel/SerialDev/Keyboard.HC scan_code_map) and bit SC_CURSOR_UP of kbd.down_bitmap while
 * held; a held on-screen d-pad walks the player in Demo/Games/CastleFrankenstein.HC.
 * Port of GameInputTest.kt (+ the d-pad repeat test of AppBehaviorTest.kt).
 */
final class GameInputTests: XCTestCase {
    func testArrowKeysHaveTempleOsScanCodes() throws {
        let (cu, su) = Keys.special(Keys.SC_CURSOR_UP)
        let k = try runHolyC(latin1("I64 sc,ch; ch=GetKey(&sc); \"%d %d %d\\n\",ch,sc.u8[0]==SC_CURSOR_UP,Bt(kbd.down_bitmap,SC_CURSOR_UP);\n")) { kk in
            kk.post(.key(ch: cu, sc: su, down: true))
        }
        XCTAssertEqual(k.console.plainText().trimmed().components(separatedBy: "\n").last, "0 1 1")
    }

    func testHeldDpadWalksCastleFrankenstein() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cf-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sh = Shell(HeadlessEnv(dir)); sh.resize(360, 640); _ = sh.tick()
        Launch.program(sh, "C:/Demo/Games/CastleFrankenstein.HC", sh.catalog.byPath("C:/Demo/Games/CastleFrankenstein.HC"))
        let k = (sh.focused!.app as! ProgramApp).kernel!
        let end = Date().addingTimeInterval(30)
        while Date() < end && !(k.graphicsUsed && k.frameCount >= 20) { _ = sh.tick(); Thread.sleep(forTimeInterval: 0.02) }
        func g(_ n: String) -> Int64 { k.mem.ld8((k.prog.globals[n] as! GlobalSym).addr) }
        let x0 = g("man_xx"), y0 = g("man_yy")
        // portrait 360x640: the d-pad "up" button of the controls below the picture
        sh.invalidate(); _ = sh.tick()
        let up = sh.accessibilityNodes().first { $0.label == "Up arrow" }!.rect
        let ux = up.x + up.w / 2, uy = up.y + up.h / 2
        sh.pointer(PointerEvent(Ptr.DOWN, ux, uy, id: 1))
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 2 { _ = sh.tick(); Thread.sleep(forTimeInterval: 0.016) }
        sh.pointer(PointerEvent(Ptr.UP, ux, uy, id: 1))
        Thread.sleep(forTimeInterval: 0.3); _ = sh.tick()
        let moved = abs(g("man_xx") - x0) + abs(g("man_yy") - y0)
        sh.windows.forEach { sh.close($0, force: true) }
        XCTAssertGreaterThan(moved, 1000, "the player walked")
    }

    /** A held d-pad button auto-repeats like a PC key (TempleOS KbdTypeMatic(0): 250 ms, then 30/s). */
    func testHeldDpadAutoRepeats() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gc-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sh = Shell(HeadlessEnv(dir))
        var sent: [KInput] = []
        let gc = GameControls { sent.append($0) }
        gc.draw(Surface(300, 300, sh.font), Rect(0, 0, 300, 300), [], vertical: true, showDpad: true)
        func downs() -> Int { sent.filter { if case .key(_, _, true) = $0 { return true } else { return false } }.count }
        XCTAssertTrue(gc.pointer(PointerEvent(Ptr.DOWN, 4 + 44 + 20, 4 + 20, id: 7)), "press hits the up button")
        XCTAssertEqual(downs(), 1)
        gc.tick(1000)
        gc.tick(1200); XCTAssertEqual(downs(), 1, "no repeat before 250 ms")
        gc.tick(1260); XCTAssertEqual(downs(), 2, "first repeat after 250 ms")
        for t in stride(from: 1293, through: 2260, by: 33) { gc.tick(Int64(t)) }
        let n = downs()
        XCTAssertTrue((28...34).contains(n), "about 30 repeats per second: \(n)")
        _ = gc.pointer(PointerEvent(Ptr.UP, 4 + 44 + 20, 4 + 20, id: 7))
        if case .key(_, _, let down) = sent.last! { XCTAssertFalse(down, "release sends key up") } else { XCTFail() }
        gc.tick(3000); gc.tick(4000)
        XCTAssertEqual(downs(), n, "no repeats after release")
    }

    /**
     * Every on-screen control is visible (outside the program picture, which the platform draws on
     * top of the shell) and reaches the game: BomberGolf counts each key in key_cnt. Landscape used
     * to put SPACE/ENTER/ESC under the picture (the left gutter is too narrow for pad + buttons).
     * Port of GameInputTest.bomberGolfControlsAreVisibleAndWork.
     */
    func testBomberGolfControlsAreVisibleAndWork() throws {
        defer { Touch.large = false }
        for (w, h, large) in [(640, 360, false), (852, 393, false), (852, 393, true), (360, 640, false), (360, 640, true)] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bg-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let sh = Shell(HeadlessEnv(dir)); sh.settings.largeTouch = large; Touch.large = large; sh.resize(w, h); _ = sh.tick()
            Launch.program(sh, "C:/Demo/Games/BomberGolf.HC", sh.catalog.byPath("C:/Demo/Games/BomberGolf.HC"))
            let k = (sh.focused!.app as! ProgramApp).kernel!
            let end = Date().addingTimeInterval(30)
            while Date() < end && !(k.graphicsUsed && k.frameCount >= 10) { _ = sh.tick(); Thread.sleep(forTimeInterval: 0.02) }
            sh.invalidate(); _ = sh.tick()
            let wh = "\(w)x\(h) large=\(large)"
            let nodes = sh.accessibilityNodes()
            let pic = nodes.first { $0.label.hasPrefix("Program picture") }!.rect
            for l in ["Up arrow", "Left arrow", "Right arrow", "Down arrow", "Space", "Enter", "Escape", "Touch is left click"] {
                guard let c = nodes.first(where: { $0.label == l }) else { XCTFail("\(wh): no control \(l)"); continue }
                let r = c.rect
                let overlap = r.x < pic.right && pic.x < r.right && r.y < pic.bottom && pic.y < r.bottom
                XCTAssertFalse(overlap, "\(wh): \(l) \(r) is under the picture \(pic)")
                XCTAssertTrue(r.x >= 0 && r.y >= 0 && r.right <= w && r.bottom <= h, "\(wh): \(l) \(r) is on screen")
            }
            func keys() -> Int64 { k.mem.ld8((k.prog.globals["key_cnt"] as! GlobalSym).addr) }
            for l in ["Left arrow", "Space"] {
                let before = keys()
                let r = nodes.first { $0.label == l }!.rect
                sh.pointer(PointerEvent(Ptr.DOWN, r.x + r.w / 2, r.y + r.h / 2, id: 1, timeMs: 1)); _ = sh.tick()
                sh.pointer(PointerEvent(Ptr.UP, r.x + r.w / 2, r.y + r.h / 2, id: 1, timeMs: 60))
                let t0 = Date()
                while Date().timeIntervalSince(t0) < 3 && keys() == before { _ = sh.tick(); Thread.sleep(forTimeInterval: 0.02) }
                XCTAssertEqual(keys(), before + 1, "\(wh): \(l) reached the game")
            }
            sh.windows.forEach { sh.close($0, force: true) }
            Touch.large = false
        }
    }

    /**
     * docs/ui-normalization/TEMPLEOS_PROGRAM_LIFECYCLE_AUTHENTICITY_AUDIT.md: TempleOS never ends a task
     * because of a click outside its window (Adam/WinMgr.HC). A layout with no room for touch controls
     * (landscape gutters under 96 px: split screen, Tile, small windows) kept the previous layout's buttons
     * hit-testable but invisible, so a tap on the black bar beside the picture sent Abort (Shift-Esc) and
     * FlapBat showed "Program ended. Restart from the menu.".
     */
    func testTapsOutsideThePictureDoNotEndTheProgram() throws {
        let controlLabels: Set<String> = ["Space", "Enter", "Escape", "Abort", "Exit", "Touch is left click", "Touch is right click"]
        // (name, start size, layout change)
        let cases: [(String, [Int], (Shell) -> Void)] = [
            ("portrait, then a landscape window with narrow gutters", [390, 844, 47, 34], { $0.resize(1100, 834, 24, 20, 0, 0, 0) }),
            ("phone landscape, then window menu > Tile", [800, 360, 0, 16], { $0.tile() }),
        ]
        for (name, size, change) in cases {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tap-outside-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let sh = Shell(HeadlessEnv(dir)); sh.resize(size[0], size[1], size[2], size[3], 0, 0, 0); _ = sh.tick()
            func waitFor(_ s: Double, _ c: () -> Bool) -> Bool {
                let end = Date().addingTimeInterval(s)
                while Date() < end { _ = sh.tick(); if c() { return true }; Thread.sleep(forTimeInterval: 0.02) }
                _ = sh.tick(); return c()
            }
            Launch.doc(sh, "C:/Home/Welcome.DD"); _ = sh.tick() // a second window (Tile, focus)
            Launch.program(sh, "C:/Demo/Games/FlapBat.HC", sh.catalog.byPath("C:/Demo/Games/FlapBat.HC"))
            let win = sh.focused!
            let p = win.app as! ProgramApp
            XCTAssertTrue(waitFor(30) { sh.dialogOpen }, "\(name): FlapBat's PopUpOk")
            let (ch, sc) = Keys.forChar(10)
            sh.key(ch, sc, true) // OKAY
            XCTAssertTrue(waitFor(30) { p.kernel.graphicsUsed && p.kernel.frameCount >= 10 }, "\(name): playing")
            sh.invalidate(); _ = sh.tick()
            let before = sh.accessibilityNodes().filter { $0.button && controlLabels.contains($0.label) }.map { $0.rect }
            XCTAssertFalse(before.isEmpty, "\(name): controls shown before the change")

            change(sh); _ = sh.tick()
            let nodes = sh.accessibilityNodes()
            let pic = nodes.first { $0.label.hasPrefix("Program picture") }!.rect
            let client = sh.clientRect(win)
            let shown = nodes.filter { $0.button && controlLabels.contains($0.label) }
            for c in shown {
                let r = c.rect
                XCTAssertFalse(r.x < pic.right && pic.x < r.right && r.y < pic.bottom && pic.y < r.bottom, "\(name): \(c.label) \(r) is under the picture \(pic)")
                XCTAssertTrue(r.x >= client.x && r.y >= client.y && r.right <= client.right && r.bottom <= client.bottom, "\(name): \(c.label) \(r) is inside the window \(client)")
            }
            // taps on the window outside the picture (black bars, empty gutters), then where the old buttons were
            var t: Int64 = 1000
            func tap(_ x: Int, _ y: Int) {
                sh.pointer(PointerEvent(Ptr.DOWN, x, y, id: 1, timeMs: t)); sh.pointer(PointerEvent(Ptr.UP, x, y, id: 1, timeMs: t + 50)); t += 100
            }
            // the 8 px under the chrome row are the window buttons' touch slop (Shell.click), not the program's
            let top = client.y + 8
            func free(_ x: Int, _ y: Int) -> Bool { y >= top && client.contains(x, y) && !shown.contains { $0.rect.contains(x, y) } }
            for y in stride(from: top, to: client.bottom, by: 6) { for x in stride(from: client.x, to: client.right, by: 6) where !pic.contains(x, y) && free(x, y) { tap(x, y) } }
            for r in before where free(r.x + r.w / 2, r.y + r.h / 2) { tap(r.x + r.w / 2, r.y + r.h / 2) }
            XCTAssertFalse(waitFor(1.5) { p.isFinished }, "\(name): a tap outside the picture ended FlapBat (\(p.kernel.exitMessage ?? "nil"))")
            XCTAssertTrue(sh.focused === win, "\(name): the program keeps the focus")

            // the program's own exit still works: FlapBat's menu File > Exit is Esc (MenuPush in FlapBat.HC)
            let fileMenu = p.menu().first { $0.label == "File" }; XCTAssertNotNil(fileMenu); fileMenu?.action()
            _ = sh.tick()
            let exit = sh.accessibilityNodes().first { $0.button && $0.label == "Exit" }; XCTAssertNotNil(exit)
            if let r = exit?.rect { tap(r.x + r.w / 2, r.y + r.h / 2) }
            XCTAssertTrue(waitFor(5) { p.isFinished }, "\(name): Exit ends FlapBat")
            XCTAssertNil(p.kernel.exitMessage, "\(name): a normal end")
            sh.invalidate(); _ = sh.tick()
            let msg = sh.accessibilityNodes().first { $0.label == tr("program.ended") }?.rect
            XCTAssertNotNil(msg, "\(name): the end is announced")
            if let m = msg {
                XCTAssertFalse(sh.overlays().contains { o in o.rect.x < m.right && m.x < o.rect.right && o.rect.y < m.bottom && m.y < o.rect.bottom },
                               "\(name): the end message \(m) is under the picture")
            }
            sh.windows.forEach { sh.close($0, force: true) }
        }
    }
}

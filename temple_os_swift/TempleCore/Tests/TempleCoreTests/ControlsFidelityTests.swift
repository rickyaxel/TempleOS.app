import Foundation
import XCTest
@testable import TempleCore

/**
 * The on-screen game controls through the real touch path (Shell -> GameControls -> kernel),
 * docs/fidelity-audit FA-17..FA-20, on the original programs. Port of ControlsFidelityTest.kt.
 */
final class ControlsFidelityTests: XCTestCase {
    private final class Run {
        let sh: Shell, k: Kernel, dir: URL
        init(_ sh: Shell, _ k: Kernel, _ dir: URL) { self.sh = sh; self.k = k; self.dir = dir }
        func nodes() -> [A11yNode] { sh.accessibilityNodes() }
        func node(_ label: String) -> Rect { nodes().first { $0.label == label }!.rect }
        @discardableResult func waitFor(_ s: Double, _ c: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(s)
            while Date() < end { _ = sh.tick(); if c() { return true }; Thread.sleep(forTimeInterval: 0.016) }
            _ = sh.tick(); return c()
        }
        func down(_ label: String, _ id: Int) { let r = node(label); sh.pointer(PointerEvent(Ptr.DOWN, r.x + r.w / 2, r.y + r.h / 2, id: id)); _ = sh.tick() }
        func up(_ id: Int, _ r: Rect) { sh.pointer(PointerEvent(Ptr.UP, r.x + r.w / 2, r.y + r.h / 2, id: id)); _ = sh.tick() }
        func bit(_ bitmap: String, _ b: Int) -> Bool {
            let a = k.o.kbdAddr + k.o.member("CKbdStateGlbls", bitmap)
            return (k.mem.ld1(a + (b >> 3)) >> Int64(b & 7)) & 1 != 0
        }
        func close() { sh.windows.forEach { sh.close($0, force: true) }; try? FileManager.default.removeItem(at: dir) }
    }

    private func launch(_ path: String, popupOk: Bool = false, pressAKey: Bool = false, menuItem: String? = nil) -> Run {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctl-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sh = Shell(HeadlessEnv(dir)); sh.resize(360, 640); _ = sh.tick()
        Launch.program(sh, path, sh.catalog.byPath(path))
        let p = sh.focused!.app as! ProgramApp
        let r = Run(sh, p.kernel, dir)
        if popupOk { XCTAssertTrue(r.waitFor(30) { sh.dialogOpen }, "\(path) popup"); sh.key(10, Keys.forChar(10).1, true) }
        if pressAKey {
            XCTAssertTrue(r.waitFor(30) { p.kernel.console.plainText().contains("PRESS A KEY") }, "\(path) waits for a key")
            let (ch, sc) = Keys.forChar(10); sh.key(ch, sc, true); sh.key(ch, sc | Keys.SCF_KEY_UP, false)
        }
        XCTAssertTrue(r.waitFor(30) { p.kernel.graphicsUsed && p.kernel.frameCount >= 10 }, "\(path) runs")
        sh.invalidate(); _ = sh.tick()
        if let m = menuItem { XCTAssertTrue(r.waitFor(8) { sh.invalidate(); return r.nodes().contains { $0.label == m } }, "\(path) menu") }
        return r
    }

    func testRainDropsValveButtonHoldsItsKey() {
        let r = launch("C:/Demo/Games/RainDrops.HC", menuItem: "OpenUpper")
        defer { r.close() }
        let sc1 = Keys.char2ScanCode(49)
        let rect = r.node("OpenUpper")
        r.down("OpenUpper", 1)
        XCTAssertTrue(r.waitFor(0.6) { r.bit("down_bitmap", sc1) }, "'1' is down while the button is held")
        Thread.sleep(forTimeInterval: 0.4); _ = r.sh.tick()
        XCTAssertTrue(r.bit("down_bitmap", sc1), "still down after 0.4 s")
        r.up(1, rect)
        XCTAssertTrue(r.waitFor(0.5) { !r.bit("down_bitmap", sc1) }, "released with the finger")
    }

    func testTwoFingersReleaseTwoKeys() {
        let r = launch("C:/Demo/Games/Halogen.HC")
        defer { r.close() }
        let up = r.node("Up arrow"), left = r.node("Left arrow")
        r.down("Up arrow", 1); r.down("Left arrow", 2)
        XCTAssertTrue(r.waitFor(0.5) { r.bit("down_bitmap", Keys.SC_CURSOR_UP) && r.bit("down_bitmap", Keys.SC_CURSOR_LEFT) })
        r.up(1, up); r.up(2, left)
        XCTAssertTrue(r.waitFor(0.5) { !r.bit("down_bitmap", Keys.SC_CURSOR_UP) && !r.bit("down_bitmap", Keys.SC_CURSOR_LEFT) }, "both arrows released")
    }

    func testBattleLinesWheelButtons() {
        let r = launch("C:/Demo/Games/BattleLines.HC", popupOk: true)
        defer { r.close() }
        func z() -> Int64 { r.k.mem.ld8(r.k.o.msAddr + r.k.o.msPos + 16) }
        XCTAssertTrue(r.waitFor(3) { z() == 25 }, "MsSet(,,25) at start")
        let wu = r.node("Mouse wheel up")
        r.down("Mouse wheel up", 1); r.up(1, wu)
        XCTAssertTrue(r.waitFor(1) { z() == 26 }, "one notch up")
        let wd = r.node("Mouse wheel down")
        r.down("Mouse wheel down", 1); r.up(1, wd)
        r.down("Mouse wheel down", 1); r.up(1, wd)
        XCTAssertTrue(r.waitFor(1) { z() == 24 }, "two notches down")
    }

    func testTitaniumCtrlIsAHeldKey() {
        let r = launch("C:/Apps/Titanium/Run.HC", pressAKey: true)
        defer { r.close() }
        let c = r.node("Control")
        r.down("Control", 1)
        XCTAssertTrue(r.waitFor(0.5) { r.bit("down_bitmap", Keys.SC_CTRL) }, "SC_CTRL is down")
        r.up(1, c)
        XCTAssertTrue(r.waitFor(3) { !r.bit("down_bitmap", Keys.SC_CTRL) }, "SC_CTRL is up (a short press is latched for 2 frames)")
    }

    func testMoveModeMovesThePointerWithoutAButton() {
        let r = launch("C:/Demo/Games/BattleLines.HC", popupOk: true)
        defer { r.close() }
        for _ in 0..<2 {
            let t = r.nodes().first { $0.label.hasPrefix("Touch ") }!.rect
            r.sh.pointer(PointerEvent(Ptr.DOWN, t.x + 2, t.y + 2, id: 3)); r.sh.pointer(PointerEvent(Ptr.UP, t.x + 2, t.y + 2, id: 3)); _ = r.sh.tick()
        }
        r.sh.invalidate(); _ = r.sh.tick()
        XCTAssertNotNil(r.nodes().first { $0.label == "Touch moves the pointer" })
        let pic = r.nodes().first { $0.label.hasPrefix("Program picture") }!.rect
        let x = pic.x + pic.w / 2, y = pic.y + pic.h / 2
        r.sh.pointer(PointerEvent(Ptr.DOWN, x, y, id: 4)); _ = r.sh.tick()
        r.sh.pointer(PointerEvent(Ptr.MOVE, x + 20, y + 10, id: 4)); _ = r.sh.tick()
        XCTAssertTrue(r.waitFor(0.5) { r.k.mem.ld8(r.k.o.msAddr + r.k.o.msPos) > 300 }, "pointer moved")
        XCTAssertEqual(r.k.mem.ld1(r.k.o.msAddr + r.k.o.msLb), 0, "no button")
        r.sh.pointer(PointerEvent(Ptr.UP, x + 20, y + 10, id: 4)); _ = r.sh.tick()
    }
}

import Foundation
import XCTest
@testable import TempleCore

/**
 * Port of MenuMetricsTest.kt: the responsive menu layer's sizing invariants over real and edge viewports, and
 * the menus driven through the shell as a user does (touch, drag, keys, submenus, rotation).
 */
final class MenuMetricsTests: XCTestCase {
    private let viewports: [(String, Int, Int, Double, Double)] = [
        ("iphone17pro-portrait", 402, 778, 1.0, 44.0), ("iphone17pro-landscape", 750, 381, 1.0, 44.0),
        ("iphonese-portrait", 375, 647, 1.0, 44.0), ("iphonese-landscape", 667, 375, 1.0, 44.0),
        ("android-portrait", 360, 763, 3 / 2.625, 48.0), ("android-landscape", 784, 339, 3 / 2.625, 48.0),
        ("oppo-portrait", 360, 760, 1.0, 48.0), ("ipad-portrait", 417, 575, 2.0, 44.0), ("ipad-landscape", 597, 395, 2.0, 44.0),
        ("tablet-landscape", 640, 376, 2.0, 48.0), ("split-300", 300, 723, 1.0, 48.0), ("tiny", 160, 160, 1.0, 48.0),
        ("display-scale-1", 1080, 2300, 1 / 2.625, 48.0), ("display-scale-6", 180, 380, 6 / 2.625, 48.0),
    ]

    private func mm(_ n: String, large: Bool = false, typing: Bool = false) -> MenuMetrics {
        let v = viewports.first { $0.0 == n }!
        return MenuMetrics.compute(v.1, v.2, v.3, v.4, large, typing)
    }

    func testInvariantsOverViewports() {
        for v in viewports { for large in [false, true] { for typing in [false, true] {
            let m = MenuMetrics.compute(v.1, v.2, v.3, v.4, large, typing)
            let tag = "\(v.0) large=\(large) typing=\(typing) \(m)"
            XCTAssertTrue((1...MenuMetrics.MAX_SCALE).contains(m.textScale), tag)
            XCTAssertTrue(m.rowH >= m.glyphH + 8, "a row holds its text \(tag)")
            XCTAssertTrue(m.barH >= m.glyphH + 6 && m.chromeH >= m.glyphH + 4, tag)
            XCTAssertTrue(m.rowH > 0 && m.barH > 0 && m.chromeH > 0 && m.chromeBtnW > 0, tag)
            if m.textScale > 1 { XCTAssertTrue((v.1 - 16) / m.charW >= MenuMetrics.MIN_ROW_CHARS, tag) }
            if !m.compact { XCTAssertTrue(Double(m.rowH) * v.3 >= v.4 - 0.5, "touch-sized rows \(tag)") }
        } } }
    }

    func testPhonesGetTwiceTheGlyphTabletsKeepTheirs() {
        for n in ["iphone17pro-portrait", "iphone17pro-landscape", "iphonese-portrait", "android-portrait", "android-landscape", "oppo-portrait", "split-300"] {
            XCTAssertEqual(2, mm(n).textScale, n)
        }
        for n in ["ipad-portrait", "ipad-landscape", "tablet-landscape"] { XCTAssertEqual(1, mm(n).textScale, n) }
        XCTAssertEqual(4, mm("display-scale-1").textScale)
        XCTAssertEqual(1, mm("display-scale-6").textScale)
        for v in viewports where v.0 != "tiny" && !v.0.hasPrefix("display") {
            XCTAssertEqual(16.0, Double(mm(v.0).glyphH) * v.3, accuracy: 2.3, v.0)
        }
    }

    func testLandscapePhonesAreCompactPortraitIsNot() {
        XCTAssertTrue(mm("iphone17pro-landscape").compact)
        XCTAssertTrue(mm("android-landscape").compact)
        XCTAssertFalse(mm("iphone17pro-portrait").compact)
        XCTAssertFalse(mm("ipad-landscape").compact)
        XCTAssertTrue(mm("iphone17pro-landscape", large: true).rowH >= 44)
        XCTAssertTrue(mm("iphone17pro-landscape", large: true, typing: true).rowH < 44)
    }

    func testNoJumpsBetweenNeighbouringSizes() {
        var prev: MenuMetrics?
        for w in stride(from: 230, through: 440, by: 2) {
            let m = MenuMetrics.compute(w, 760, 1.0, 48.0, false, false)
            if let p = prev { XCTAssertTrue(abs(p.textScale - m.textScale) <= 1 && abs(p.rowH - m.rowH) <= 16, "w=\(w)") }
            prev = m
        }
        for h in 480...560 { XCTAssertEqual(2, MenuMetrics.compute(800, h, 1.0, 48.0, false, false).textScale) }
    }

    // ------------------------------------------------------------ driven through the shell

    private func withShell(_ w: Int, _ h: Int, _ top: Int, _ bottom: Int, _ dp: Double, _ body: (Shell) throws -> Void) rethrows {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tosm-mm-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sh = Shell(HeadlessEnv(dir)); sh.resize(w, h, top, bottom, 0, 0, 0, dpPerPx: dp); _ = sh.tick()
        Launch.doc(sh, "C:/Home/Welcome.DD"); _ = sh.tick()
        try body(sh)
        sh.windows.forEach { $0.app.close() }
    }

    private var t: Int64 = 1000
    private func tap(_ sh: Shell, _ x: Int, _ y: Int) {
        sh.pointer(PointerEvent(Ptr.DOWN, x, y, id: 1, timeMs: t)); t += 50
        sh.pointer(PointerEvent(Ptr.UP, x, y, id: 1, timeMs: t)); t += 50
        _ = sh.tick()
    }
    private func node(_ sh: Shell, _ label: String) -> Rect? {
        _ = sh.tick()
        let r = sh.accessibilityNodes().first { $0.label == label }?.rect
        if r == nil { XCTFail("no '\(label)' in \(sh.accessibilityNodes().map { $0.label })") }
        return r
    }
    private func tapNode(_ sh: Shell, _ label: String) { if let r = node(sh, label) { tap(sh, r.x + r.w / 2, r.y + r.h / 2) } }
    private func key(_ sh: Shell, _ sc: Int, _ ch: Int = 0) { sh.key(ch, Int64(sc), true); sh.key(ch, Int64(sc) | Keys.SCF_KEY_UP, false); _ = sh.tick() }

    func testDrawnMenusMatchTheMetricsAndStayOnScreen() {
        for (w, h, dp) in [(402, 874, 1.0), (874, 402, 1.0), (360, 800, 3 / 2.625), (300, 760, 1.0), (597, 417, 2.0)] {
            withShell(w, h, 20, 20, dp) { sh in
                let m = sh.metrics
                sh.showStartMenu(); _ = sh.tick()
                let menu = sh.openMenu!
                let b = menu.bounds
                XCTAssertTrue(b.x >= 0 && b.y >= 20 && b.right <= w && b.bottom <= h - 20, "\(w)x\(h) \(b)")
                let rows = sh.accessibilityNodes().filter { $0.button && b.contains($0.rect.x + 1, $0.rect.y + 1) }
                XCTAssertEqual(menu.items.count, 14)
                XCTAssertTrue(!rows.isEmpty && rows.count <= menu.items.count + 2)
                for r in rows {
                    XCTAssertTrue(r.rect.h >= m.rowH, "\(r.label)")
                    XCTAssertTrue(Double(r.rect.h) * dp >= (m.compact ? MenuMetrics.COMPACT_ROW_DP : 44.0) - 0.5, "\(r.label)")
                }
                for a in rows { for c in rows where a !== c {
                    let i = a.rect.intersect(c.rect); XCTAssertFalse(i.w > 0 && i.h > 0, "\(a.label) overlaps \(c.label)")
                } }
                tapNode(sh, tr("menu.start.examples"))
                let sub = sh.openMenu!
                XCTAssertTrue(sub.parent === menu)
                XCTAssertTrue(sub.bounds.y >= 20 && sub.bounds.bottom <= h - 20, "\(w)x\(h) \(sub.bounds)")
                sh.back(); XCTAssertTrue(sh.openMenu === menu)
                sh.back(); XCTAssertNil(sh.openMenu)
            }
        }
    }

    func testTouchKeysScrollAndSubmenus() {
        withShell(402, 874, 62, 34, 1.0) { sh in
            tapNode(sh, tr("topbar.menu")); XCTAssertTrue(sh.popupOpen)
            if let files = node(sh, tr("menu.start.files")) { tap(sh, files.x + 2, files.bottom - 2) }
            XCTAssertEqual("files", sh.focused?.app.kind)
            XCTAssertEqual(2, sh.windows.count)
            tapNode(sh, tr("topbar.menu")); tap(sh, 395, 860)
            XCTAssertFalse(sh.popupOpen); XCTAssertEqual(2, sh.windows.count); XCTAssertEqual("files", sh.focused?.app.kind)
            tapNode(sh, tr("topbar.menu"))
            key(sh, Keys.SC_CURSOR_DOWN); XCTAssertEqual(0, sh.openMenu!.selected)
            key(sh, Keys.SC_CURSOR_DOWN); key(sh, Keys.SC_CURSOR_UP); XCTAssertEqual(0, sh.openMenu!.selected)
            key(sh, Keys.SC_END); XCTAssertEqual(sh.openMenu!.items.count - 1, sh.openMenu!.selected)
            key(sh, Keys.SC_ESC, Keys.CH_ESC); XCTAssertFalse(sh.popupOpen)
            tapNode(sh, tr("topbar.menu")); tapNode(sh, tr("menu.start.examples"))
            // A deliberately long fixture exercises overflow independently of catalog size.
            let bounce = sh.catalog.byId("demo.bounce")!
            sh.showMenu([MenuItem("Overflow") {
                sh.showMenu((0..<30).map { i in MenuItem("Entry \(i)") { Launch.program(sh, bounce.path, bounce) } }, 4, sh.insetTop + sh.barH, "Overflow fixture")
            }], 4, sh.insetTop + sh.barH, "Fixture parent")
            _ = sh.tick(); tapNode(sh,"Overflow")
            let games = sh.openMenu!
            XCTAssertNotNil(games.parent)
            key(sh, Keys.SC_END); XCTAssertEqual(games.items.count - 1, games.selected)
            _ = node(sh, games.items.last!.label)
            let firstShown = games.scroll
            let b = games.bounds, rh = sh.metrics.rowH
            sh.pointer(PointerEvent(Ptr.DOWN, b.x + 40, b.y + b.h / 2, id: 1, timeMs: t)); t += 20
            sh.pointer(PointerEvent(Ptr.MOVE, b.x + 40, b.y + b.h / 2 + 3 * rh, id: 1, timeMs: t)); t += 20
            sh.pointer(PointerEvent(Ptr.UP, b.x + 40, b.y + b.h / 2 + 3 * rh, id: 1, timeMs: t)); t += 20; _ = sh.tick()
            XCTAssertTrue(games.scroll < firstShown, "a drag scrolls")
            XCTAssertTrue(sh.openMenu === games, "a drag runs nothing")
            tapNode(sh, tr("a11y.scroll_menu_up")); XCTAssertTrue(games.scroll < firstShown)
            key(sh, Keys.SC_CURSOR_LEFT); XCTAssertTrue(sh.openMenu === games.parent)
            key(sh, Keys.SC_ESC, Keys.CH_ESC)
            sh.showStartMenu(); tapNode(sh, tr("menu.start.demos"))
            XCTAssertEqual("programs", sh.focused?.app.kind)
            XCTAssertTrue(sh.accessibilityNodes().contains { $0.button && $0.label == "Games: Beginner" })
            sh.showMenu([MenuItem("Bounce") { Launch.program(sh, bounce.path, bounce) }], 4, sh.insetTop + sh.barH, "Launch fixture")
            tapNode(sh, "Bounce")
            XCTAssertFalse(sh.popupOpen)
            XCTAssertEqual("program", sh.focused?.app.kind)
            XCTAssertEqual(4, sh.windows.count)
        }
    }

    func testRotationRecomputesOpenMenus() {
        withShell(402, 874, 62, 34, 1.0) { sh in
            sh.showStartMenu(); _ = sh.tick()
            let portrait = sh.openMenu!.bounds
            XCTAssertEqual(1, sh.openMenu!.cols)
            sh.resize(874, 402, 0, 21, 62, 62, 0); _ = sh.tick()
            let m = sh.metrics
            XCTAssertTrue(m.compact)
            let land = sh.openMenu!.bounds
            XCTAssertTrue(land != portrait && land.bottom <= 402 - 21 && land.x >= 62, "\(portrait) -> \(land)")
            let rows = sh.accessibilityNodes().filter { $0.button && land.contains($0.rect.x + 1, $0.rect.y + 1) }
            XCTAssertTrue(rows.allSatisfy { $0.rect.h == m.rowH })
            sh.resize(402, 874, 62, 34, 0, 0, 0); _ = sh.tick()
            XCTAssertEqual(portrait, sh.openMenu!.bounds)
            sh.back()
            sh.resize(874, 402, 0, 21, 62, 62, 0); _ = sh.tick()
            sh.showStartMenu(); _ = sh.tick()
            XCTAssertEqual(2, sh.openMenu!.cols)
        }
    }

    func testLegacyAndResponsiveScaleRatio() {
        let m = MenuMetrics.compute(402, 778, 1.0, 44.0, false, false)
        let l = MenuMetrics.LEGACY_STANDARD
        XCTAssertEqual(2.0, Double(m.glyphH) / Double(l.glyphH))
        XCTAssertTrue(Double(m.rowH) / Double(l.rowH) >= 2.0)
        XCTAssertEqual(2.0, Double(m.barH) / Double(l.barH))
    }
}

import Foundation
import XCTest
@testable import TempleCore

/**
 * The shared layout policy (DisplayLayout) and the shell laid out for synthetic screens: phones, the
 * iPhone Duo's displays and postures as the iOS 27.1 simulator reports them (logical px at the AUTO scale,
 * docs/foldable/IPHONE_DUO_ADAPTATION.md), multitasking windows and degenerate sizes. These are fixtures,
 * not a device database: the production code never sees a device model.
 */
final class DisplayLayoutTests: XCTestCase {
    /** Synthetic geometries. Duo values were measured on the simulator (pt = logical px at scale 3). */
    static let fixtures: [(String, DisplayGeometry)] = [
        ("phone-portrait", DisplayGeometry(width: 402, height: 874, top: 62, bottom: 34)),
        ("phone-landscape", DisplayGeometry(width: 874, height: 402, bottom: 21, left: 62, right: 62)),
        ("duo-outer-portrait", DisplayGeometry(width: 466, height: 678, bottom: 34, right: 84, barLeft: 3, barRight: 84,
                                               occlusions: [Rect(399, 29, 37, 37), Rect(384, 0, 82, 84)])),
        ("duo-outer-landscape-left", DisplayGeometry(width: 678, height: 466, bottom: 34, left: 84, barLeft: 84, barRight: 18,
                                                     occlusions: [Rect(29, 29, 37, 37), Rect(0, 0, 84, 82)])),
        ("duo-outer-landscape-right", DisplayGeometry(width: 678, height: 466, bottom: 34, right: 84, barLeft: 18, barRight: 84,
                                                      occlusions: [Rect(611, 399, 37, 37), Rect(594, 384, 84, 82)])),
        ("duo-open-wide", DisplayGeometry(width: 951, height: 669, bottom: 34, right: 84, barLeft: 16, barRight: 134,
                                          occlusions: [Rect(867, 0, 84, 120)])),
        ("duo-open-wide-bottom-status", DisplayGeometry(width: 951, height: 669, bottom: 34, right: 84, barLeft: 16, barRight: 84,
                                                        occlusions: [Rect(831, 585, 120, 84)])),
        ("duo-open-tall", DisplayGeometry(width: 669, height: 951, top: 82, bottom: 34, occlusions: [Rect(535, 0, 134, 82)])),
        ("duo-book", DisplayGeometry(width: 951, height: 669, bottom: 34, right: 84, barLeft: 16, barRight: 134,
                                     divisions: [Rect(455, 0, 41, 669)], occlusions: [Rect(867, 0, 84, 120)])),
        ("duo-tabletop", DisplayGeometry(width: 669, height: 951, top: 82, bottom: 34,
                                         divisions: [Rect(0, 455, 669, 41)], occlusions: [Rect(535, 0, 134, 82)])),
        ("near-square", DisplayGeometry(width: 700, height: 720, top: 24, bottom: 20)),
        ("asymmetric-insets", DisplayGeometry(width: 800, height: 380, top: 3, bottom: 30, left: 70, right: 10)),
        ("edge-occlusion", DisplayGeometry(width: 402, height: 874, top: 20, bottom: 34, barLeft: 20, barRight: 20,
                                           occlusions: [Rect(0, 0, 60, 60)])),
        ("split-narrow", DisplayGeometry(width: 320, height: 669, top: 24, bottom: 20)),
        ("smallest-surface", DisplayGeometry(width: 320, height: 240)),
    ]

    private var dir: URL!
    private var sh: Shell!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("layout-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sh = Shell(HeadlessEnv(dir))
    }

    override func tearDown() {
        for w in sh.windows { sh.close(w, force: true) }
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: pure policy

    func testAutoScaleKeepsPhonesAndShowsMoreOnAnUnfoldedDisplay() {
        // every phone keeps the scale of the old rule (shorter side / 360)
        for (w, h, s) in [(1206, 2622, 3.0), (1320, 2868, 3.0), (1179, 2556, 3.0), (750, 1334, 2.0), (1080, 2400, 2.625), (1398, 2034, 3.0)] {
            XCTAssertEqual(DisplayLayout.scale(pxW: w, pxH: h, displayScale: s), max(1, min(w, h) / 360), "\(w)x\(h)")
            XCTAssertEqual(DisplayLayout.scale(pxW: h, pxH: w, displayScale: s), max(1, min(w, h) / 360), "\(h)x\(w)")
        }
        // the unfolded Duo: one logical px per pt (669x951 logical, not the 401x570 a phone rule gives)
        XCTAssertEqual(3, DisplayLayout.scale(pxW: 2007, pxH: 2853, displayScale: 3))
        XCTAssertEqual(3, DisplayLayout.scale(pxW: 2853, pxH: 2007, displayScale: 3))
        // tablets magnify, keeping the shorter side within MAX_AUTO_SHORT
        let ipad = DisplayLayout.scale(pxW: 2064, pxH: 2752, displayScale: 2)
        XCTAssertLessThanOrEqual(2064 / ipad, DisplayLayout.MAX_AUTO_SHORT)
        // the user's setting wins; tiny windows never go below MIN_W x MIN_H when a smaller scale helps
        XCTAssertEqual(4, DisplayLayout.scale(pxW: 2007, pxH: 2853, displayScale: 3, chosen: 4))
        XCTAssertEqual(2, DisplayLayout.scale(pxW: 900, pxH: 1500, displayScale: 3))
        for (w, h) in [(0, 0), (-5, 10), (1, 1), (100, 4000)] {
            let s = DisplayLayout.scale(pxW: w, pxH: h, displayScale: .nan)
            XCTAssertGreaterThanOrEqual(s, 1, "\(w)x\(h)")
        }
    }

    func testWindowedFollowsTheUsableSpaceNotTheOrientation() {
        XCTAssertFalse(DisplayLayout.windowed(402, 874, usableW: 402, usableH: 778), "phone portrait: the deck")
        XCTAssertTrue(DisplayLayout.windowed(874, 402, usableW: 750, usableH: 381), "phone landscape")
        XCTAssertFalse(DisplayLayout.windowed(466, 678, usableW: 382, usableH: 644), "Duo closed portrait")
        XCTAssertTrue(DisplayLayout.windowed(669, 951, usableW: 669, usableH: 835), "Duo open, held tall")
        XCTAssertFalse(DisplayLayout.windowed(320, 669, usableW: 320, usableH: 625), "narrow split view")
    }

    func testRegionsSplitAtFoldsOnly() {
        let r = Rect(0, 40, 867, 595)
        XCTAssertEqual([r], DisplayLayout.regions(r, []))
        XCTAssertEqual([Rect(0, 40, 455, 595), Rect(496, 40, 371, 595)], DisplayLayout.regions(r, [Rect(455, 0, 41, 669)]))
        let t = Rect(0, 126, 669, 791)
        XCTAssertEqual([Rect(0, 126, 669, 329), Rect(0, 496, 669, 421)], DisplayLayout.regions(t, [Rect(0, 455, 669, 41)]))
        // a division that does not run across, or leaves a sliver, does not split
        XCTAssertEqual([r], DisplayLayout.regions(r, [Rect(455, 300, 41, 100)]))
        XCTAssertEqual([r], DisplayLayout.regions(r, [Rect(800, 0, 41, 669)]))
    }

    func testRowSpansSkipOcclusions() {
        XCTAssertEqual(DisplayLayout.rowSpan(0, 40, 0, 466, [Rect(384, 0, 82, 84)]).1, 384)
        XCTAssertEqual(DisplayLayout.rowSpan(0, 40, 84, 678, [Rect(0, 0, 84, 82)]).0, 84)
        XCTAssertEqual(DisplayLayout.rowSpan(100, 140, 0, 466, [Rect(384, 0, 82, 84)]).1, 466, "below the occlusion")
    }

    func testKeyColumnsMatchTheOldSplitAndAvoidTheFold() {
        let weights = [10, 10, 10, 10, 15, 20, 10, 15]
        let r = Rect(0, 500, 867, 40)
        var acc = 0
        let total = weights.reduce(0, +)
        let old = weights.map { k -> (Int, Int) in let a = acc * r.w / total; acc += k; return (a, acc * r.w / total) }
        XCTAssertTrue(zip(old, DisplayLayout.keyColumns(weights, r, gap: nil)).allSatisfy { $0.0 == $0.1 }, "no fold: unchanged")
        let gap = Rect(455, 500, 41, 40)
        let cols = DisplayLayout.keyColumns(weights, r, gap: gap)
        XCTAssertEqual(cols.count, weights.count)
        for (a, b) in cols {
            XCTAssertLessThan(a, b)
            XCTAssertFalse(a < gap.right && b > gap.x, "key \(a)..<\(b) on the hinge")
            XCTAssertTrue(a >= r.x && b <= r.right)
        }
    }

    // MARK: the shell on synthetic screens

    /** Accessibility nodes (what can be tapped) in the current state. */
    private func nodes() -> [A11yNode] { sh.invalidate(); _ = sh.tick(); return sh.accessibilityNodes() }

    private func assertSane(_ tag: String, _ g: DisplayGeometry, modalOnly: Bool, file: StaticString = #filePath, line: UInt = #line) {
        for n in nodes() where n.button {
            let r = n.rect
            XCTAssertTrue(r.w > 0 && r.h > 0, "\(tag): \(n.label) has a size \(r)", file: file, line: line)
            XCTAssertTrue(r.x >= 0 && r.y >= 0 && r.right <= sh.width && r.bottom <= sh.height, "\(tag): \(n.label) on screen \(r)", file: file, line: line)
        }
        // popups, the TempleOS keyboard and the key row never lie on a fold
        let interactive = modalOnly ? sh.accessibilityNodes() : sh.accessibilityNodes().filter { $0.rect.y >= sh.height - sh.reservedBottom - 1 }
        for n in interactive where n.button {
            for d in g.divisions {
                let i = n.rect.intersect(d)
                XCTAssertFalse(i.w > 0 && i.h > 0, "\(tag): \(n.label) \(n.rect) lies on the fold \(d)", file: file, line: line)
            }
        }
    }

    func testEveryFixtureLaysOutMenusDialogsAndTheKeyboardOnScreenAndOffTheFold() throws {
        for (name, g) in DisplayLayoutTests.fixtures {
            XCTAssertTrue(sh.apply(g), name)
            XCTAssertFalse(sh.apply(g), "\(name): the same geometry again changes nothing")
            _ = sh.tick()
            // top bar: MENU and the clock inside the corner-adapted span and off every occlusion
            for n in nodes() where n.rect.y < sh.insetTop + sh.barH && n.rect.h > 0 {
                for o in g.occlusions where o.y < sh.insetTop + sh.barH && o.bottom > sh.insetTop {
                    let i = n.rect.intersect(o)
                    XCTAssertFalse(i.w > 0 && i.h > 0, "\(name): top bar '\(n.label)' \(n.rect) under occlusion \(o)")
                }
                if g.width >= 320 {
                    XCTAssertGreaterThanOrEqual(n.rect.x, max(g.left, g.barLeft) - 0, "\(name): '\(n.label)' inside the rounded corner")
                    XCTAssertLessThanOrEqual(n.rect.right, g.width - max(g.right, g.barRight) + 4, "\(name): '\(n.label)' inside the rounded corner")
                }
            }
            sh.showStartMenu()
            assertSane("\(name) start menu", g, modalOnly: true)
            if let m = sh.openMenu {
                for d in g.divisions { let i = m.bounds.intersect(d); XCTAssertFalse(i.w > 0 && i.h > 0, "\(name): menu on the fold") }
            }
            _ = sh.back()
            sh.showDialog(Dialog.confirm("Title", "A message that is long enough to wrap onto more lines in a dialog.", "OK") {})
            assertSane("\(name) dialog", g, modalOnly: true)
            _ = sh.back()
            Launch.terminal(sh); _ = sh.tick()
            sh.requestKeyboard()
            assertSane("\(name) terminal + keyboard", g, modalOnly: false)
            if sh.templeKeyboardShown {
                let k = sh.keyboardRect()
                XCTAssertTrue(k.y >= 0 && k.bottom <= sh.height - sh.insetBottom, "\(name): keyboard \(k) above the home indicator")
            }
            for w in sh.windows { sh.close(w, force: true) }
        }
    }

    func testTabletopPutsTheKeyboardBelowTheFoldAndTheDesktopAbove() {
        let g = DisplayLayoutTests.fixtures.first { $0.0 == "duo-tabletop" }!.1
        sh.apply(g)
        Launch.terminal(sh); _ = sh.tick()
        sh.requestKeyboard(); _ = sh.tick()
        XCTAssertTrue(sh.templeKeyboardShown)
        let fold = g.divisions[0]
        XCTAssertGreaterThanOrEqual(sh.keyboardRect().y, fold.bottom, "keyboard below the hinge")
        XCTAssertLessThanOrEqual(sh.desktopRect().bottom, fold.y, "desktop above the hinge")
        XCTAssertGreaterThanOrEqual(sh.keyboard.rowHeight(), Touch.kbdRow, "rows at least touch size")
        // windows stay above the hinge: the focused one is never under the keyboard
        Launch.about(sh); _ = sh.tick()
        for w in sh.windows where !w.maximized { XCTAssertLessThanOrEqual(w.y + w.h, fold.y, "\(w.app.title) above the fold") }
        sh.tile()
        for w in sh.windows { XCTAssertLessThanOrEqual(w.y + w.h, fold.y, "tiled \(w.app.title) above the fold") }
        // without the fold the same screen keeps the keyboard at its usual height
        sh.apply(DisplayLayoutTests.fixtures.first { $0.0 == "duo-open-tall" }!.1)
        XCTAssertEqual(sh.keyboard.rowHeight(), Touch.kbdRow)
    }

    func testBookPostureOpensWindowsOnEitherSideAndTilesPerSide() {
        let g = DisplayLayoutTests.fixtures.first { $0.0 == "duo-book" }!.1
        sh.apply(g)
        XCTAssertTrue(sh.windowed)
        Launch.terminal(sh); Launch.about(sh); _ = sh.tick()
        let fold = g.divisions[0]
        for w in sh.windows {
            XCTAssertFalse(w.x < fold.right && w.x + w.w > fold.x, "window \(w.app.title) \(w.x),\(w.w) on the fold")
        }
        XCTAssertNotEqual(sh.windows[0].x < fold.x, sh.windows[1].x < fold.x, "one window on each side")
        sh.tile()
        for w in sh.windows { XCTAssertFalse(w.x < fold.right && w.x + w.w > fold.x, "tiled \(w.app.title) on the fold") }
    }

    func testFoldingKeepsEveryWindowAndItsApp() {
        let fixtures = DisplayLayoutTests.fixtures.filter { $0.0.hasPrefix("duo") }
        sh.apply(fixtures[0].1)
        Launch.terminal(sh); Launch.about(sh); Launch.doc(sh, "C:/Home/Welcome.DD"); _ = sh.tick()
        let apps = sh.windows.map { ObjectIdentifier($0.app) }
        let focused = sh.focused.map { ObjectIdentifier($0.app) }
        // 20 cycles through every posture: same windows, same apps, same focus, sane layout
        for cycle in 0..<20 {
            for (name, g) in fixtures {
                sh.apply(g); _ = sh.tick()
                XCTAssertEqual(apps, sh.windows.map { ObjectIdentifier($0.app) }, "cycle \(cycle) \(name)")
                XCTAssertEqual(focused, sh.focused.map { ObjectIdentifier($0.app) }, "cycle \(cycle) \(name)")
                for w in sh.windows { XCTAssertTrue(w.w > 0 && w.h > 0 && w.x >= 0 && w.y >= 0, "cycle \(cycle) \(name)") }
            }
        }
    }

    /** A menu opened on the closed display (no top inset) follows the unfold below the new status bar. */
    func testMenuOpenBeforeATransitionStaysInTheNewUsableArea() {
        let f = Dictionary(uniqueKeysWithValues: DisplayLayoutTests.fixtures)
        sh.apply(f["duo-outer-portrait"]!)
        sh.showStartMenu(); _ = nodes()
        for name in ["duo-open-tall", "duo-tabletop", "duo-book", "duo-outer-landscape-left", "duo-outer-portrait"] {
            let g = f[name]!
            sh.apply(g); _ = nodes()
            guard let m = sh.openMenu else { return XCTFail("\(name): the menu closed") }
            XCTAssertGreaterThanOrEqual(m.bounds.y, sh.insetTop, "\(name): menu \(m.bounds) under the status bar")
            XCTAssertLessThanOrEqual(m.bounds.bottom, sh.height - sh.insetBottom, name)
            for d in g.divisions { let i = m.bounds.intersect(d); XCTAssertFalse(i.w > 0 && i.h > 0, "\(name): menu on the fold") }
        }
    }

    /**
     * The cost of a transition on the UI thread: apply a new geometry and render the desktop with four
     * windows (terminal, doc, about, editor), alternating closed / open / book / tabletop. Printed for the
     * report (docs/foldable); the bound only catches a pathological regression (debug build, shared CPU).
     */
    func testTransitionCostOnTheUiThread() {
        let f = Dictionary(uniqueKeysWithValues: DisplayLayoutTests.fixtures)
        let cycle = ["duo-outer-portrait", "duo-open-wide", "duo-book", "duo-tabletop", "duo-open-tall"].map { f[$0]! }
        sh.apply(cycle[0])
        Launch.terminal(sh); Launch.doc(sh, "C:/Home/Welcome.DD"); Launch.about(sh); Launch.editor(sh, nil)
        for _ in 0..<5 { _ = sh.tick() }
        var worst = 0.0, total = 0.0
        let n = 100
        for i in 0..<n {
            let t0 = DispatchTime.now().uptimeNanoseconds
            sh.apply(cycle[(i + 1) % cycle.count]); _ = sh.tick()
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            worst = max(worst, ms); total += ms
        }
        let unchanged0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<n { sh.apply(cycle[0]) }
        let unchangedUs = Double(DispatchTime.now().uptimeNanoseconds - unchanged0) / 1e3 / Double(n)
        print("TRANSITIONCOST mean_ms=\(String(format: "%.2f", total / Double(n))) worst_ms=\(String(format: "%.2f", worst)) unchanged_apply_us=\(String(format: "%.1f", unchangedUs))")
        XCTAssertLessThan(total / Double(n), 100, "a transition re-lays out and renders in well under a frame budget's multiple")
    }

    func testDegenerateGeometryNeverProducesNegativeSizes() {
        for g in [DisplayGeometry(width: 0, height: 0), DisplayGeometry(width: -10, height: 50, dpPerPx: .nan),
                  DisplayGeometry(width: 160, height: 160, top: 200, bottom: 200, left: 100, right: 100),
                  DisplayGeometry(width: 300, height: 300, divisions: [Rect(140, 0, 20, 300)], occlusions: [Rect(0, 0, 300, 300)])] {
            sh.apply(g)
            sh.showStartMenu()
            for n in nodes() { XCTAssertTrue(n.rect.w >= 0 && n.rect.h >= 0, "\(g): \(n.label) \(n.rect)") }
            _ = sh.back()
            XCTAssertTrue(sh.desktopRect().w > 0 && sh.desktopRect().h > 0, "\(g)")
            XCTAssertTrue(sh.width >= 160 && sh.height >= 160 && sh.insetLeft + sh.insetRight < sh.width, "\(g)")
        }
    }
}

import Foundation
import XCTest
@testable import TempleCore

/**
 * The TempleOS keyboard's lifecycle across fold transitions (docs/foldable/KEYBOARD_LIFECYCLE.md): its visibility
 * is the user's intent and the focused program's needs, never the screen's geometry. Every change is attributed
 * (Shell.KeyboardReason). Geometries are the iPhone Duo postures as the simulator measures them (DisplayLayoutTests).
 */
final class KeyboardLifecycleTests: XCTestCase {
    private var dir: URL!
    private var sh: Shell!
    private let postures = DisplayLayoutTests.fixtures.filter { $0.0.hasPrefix("duo") }.map(\.1)
    private var closed: DisplayGeometry { DisplayLayoutTests.fixtures.first { $0.0 == "duo-outer-portrait" }!.1 }
    private var open: DisplayGeometry { DisplayLayoutTests.fixtures.first { $0.0 == "duo-open-wide" }!.1 }

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("kblife-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sh = Shell(HeadlessEnv(dir))
        sh.apply(closed)
        Launch.terminal(sh); _ = sh.tick()
        sh.requestKeyboard(); _ = sh.tick()
    }

    override func tearDown() {
        for w in sh.windows { sh.close(w, force: true) }
        try? FileManager.default.removeItem(at: dir)
    }

    private func fold(_ g: DisplayGeometry) { sh.apply(g); _ = sh.tick() }

    /** 1-3, 9, 10: a visible keyboard stays visible through closing, opening, every posture, duplicates and rapid changes. */
    func testFoldsNeverChangeTheKeyboard() {
        XCTAssertTrue(sh.templeKeyboardShown)
        let seq = sh.keyboardTransitionCount
        for _ in 0..<40 { fold(open); fold(closed) }
        for g in postures { fold(g); fold(g) } // duplicates
        for g in postures + postures.reversed() { sh.apply(g) } // rapid: no tick in between
        _ = sh.tick()
        XCTAssertTrue(sh.templeKeyboardShown)
        XCTAssertEqual(seq, sh.keyboardTransitionCount, "no visibility change from geometry: \(sh.keyboardTransitions)")
    }

    /** 4: an explicit dismissal is respected through fold cycles; the user's show brings it back. */
    func testExplicitDismissalSurvivesFolds() {
        sh.hideKeyboard(); _ = sh.tick()
        XCTAssertEqual(sh.keyboardTransitions.last?.reason, .userHide)
        for _ in 0..<20 { fold(open); fold(closed) }
        XCTAssertFalse(sh.templeKeyboardShown, "folding did not reopen a keyboard the user dismissed")
        sh.requestKeyboard(); _ = sh.tick()
        XCTAssertTrue(sh.templeKeyboardShown)
        XCTAssertEqual(sh.keyboardTransitions.last?.reason, .userShow)
    }

    /** 5: typing on a physical keyboard puts it away, attributed to that. */
    func testPhysicalTypingLeavesSoftwareInputAvailable() {
        sh.hardwareKeyUsed(); _ = sh.tick()
        XCTAssertTrue(sh.templeKeyboardShown)
        fold(open); fold(closed)
        XCTAssertTrue(sh.templeKeyboardShown)
    }

    /** 6: a genuine back action closes a menu first, then the keyboard, attributed to back. */
    func testBackClosesMenuThenKeyboard() {
        sh.showStartMenu()
        XCTAssertTrue(sh.back())
        XCTAssertNil(sh.openMenu)
        XCTAssertTrue(sh.templeKeyboardShown, "back closed the menu only")
        XCTAssertTrue(sh.back()); _ = sh.tick()
        XCTAssertFalse(sh.templeKeyboardShown)
        XCTAssertEqual(sh.keyboardTransitions.last?.reason, .back)
    }

    /** 7, 8: neither a lost focus on the platform side nor a rebuilt layout is a dismissal: only the shell's own state counts. */
    func testRelayoutAndKeyboardHeightChangesKeepIt() {
        let seq = sh.keyboardTransitionCount
        var g = closed
        g.keyboard = 300; fold(g) // the device keyboard's frame notifications (another window) do not touch it
        g.keyboard = 0; fold(g)
        sh.relayout(); _ = sh.tick() // settings change: full relayout
        XCTAssertTrue(sh.templeKeyboardShown)
        XCTAssertEqual(seq, sh.keyboardTransitionCount)
    }

    /** 11: the latest explicit intent wins over an older one, whatever order layout passes arrive in. */
    func testLatestIntentWins() {
        sh.hideKeyboard()
        fold(open)
        sh.requestKeyboard()
        fold(closed); fold(closed)
        XCTAssertTrue(sh.templeKeyboardShown)
        XCTAssertEqual(sh.keyboardTransitions.last?.reason, .userShow)
    }

    /** 12: the program keeps running and keeps its window while the keyboard shows, hides and the screen folds. */
    func testProgramStateIsIndependentOfTheKeyboard() {
        let app = ObjectIdentifier(sh.focused!.app)
        for i in 0..<10 {
            if i % 3 == 0 { sh.hideKeyboard() } else { sh.requestKeyboard() }
            fold(i % 2 == 0 ? open : closed)
            XCTAssertEqual(app, ObjectIdentifier(sh.focused!.app))
            XCTAssertEqual(1, sh.windows.count)
        }
    }

    /** A program that needs text gets the keyboard on focus; one that does not lets it go (reason: program). */
    func testFocusFollowsTheProgramsNeeds() {
        Launch.about(sh); _ = sh.tick()
        XCTAssertFalse(sh.templeKeyboardShown)
        XCTAssertEqual(sh.keyboardTransitions.last?.reason, .program)
        sh.focus(sh.windows.first { $0.app.kind == "terminal" }); _ = sh.tick()
        XCTAssertTrue(sh.templeKeyboardShown)
        XCTAssertEqual(sh.keyboardTransitions.last?.reason, .program)
    }
}

import Foundation
import XCTest
@testable import TempleCore

/**
 * The joystick that can stand in for the d-pad (GameControls, Settings.directional): it exists only where the
 * program has the d-pad, it holds the same arrow keys through the same key path (down, typematic repeat, up), it
 * sends only what changes, and nothing it holds outlives its finger, its mode or its place on the screen.
 * Port of JoystickTest.kt.
 */
final class JoystickTests: XCTestCase {
    private let U = Joystick.UP, D = Joystick.DOWN, L = Joystick.LEFT, R = Joystick.RIGHT

    func testPushesMapToArrows() {
        let t = 36
        XCTAssertEqual(R, Joystick.keys(30, 0, t, 0))
        XCTAssertEqual(L, Joystick.keys(-30, 0, t, 0))
        XCTAssertEqual(U, Joystick.keys(0, -30, t, 0), "y grows downwards")
        XCTAssertEqual(D, Joystick.keys(0, 30, t, 0))
        XCTAssertEqual(U | R, Joystick.keys(20, -20, t, 0))
        XCTAssertEqual(U | L, Joystick.keys(-20, -20, t, 0))
        XCTAssertEqual(D | L, Joystick.keys(-20, 20, t, 0))
        XCTAssertEqual(D | R, Joystick.keys(20, 20, t, 0))
        // arrows own 30 degrees either side of their axis, diagonals the 30 between
        XCTAssertEqual(R, Joystick.keys(100, -50, t, 0), "27 degrees: still right")
        XCTAssertEqual(U | R, Joystick.keys(100, -80, t, 0), "39 degrees: a diagonal")
        XCTAssertEqual(U, Joystick.keys(50, -100, t, 0), "63 degrees: up")
        XCTAssertEqual(L, Joystick.keys(-200, 1, t, 0), "far beyond the rim: still the direction of the push")
    }

    func testDeadZoneAndHysteresis() {
        let t = 40 // engages at 24 px, lets go below 17.6 px
        XCTAssertEqual(0, Joystick.keys(0, 0, t, 0))
        XCTAssertEqual(0, Joystick.keys(23, 0, t, 0), "inside the dead zone")
        XCTAssertEqual(R, Joystick.keys(24, 0, t, 0), "at its edge")
        XCTAssertEqual(R, Joystick.keys(18, 0, t, R), "a held push stays down a little inside the edge")
        XCTAssertEqual(0, Joystick.keys(17, 0, t, R), "and lets go further in")
        XCTAssertEqual(0, Joystick.keys(20, 0, t, 0), "a new push needs the full distance")
        // a held direction is kept 6 degrees past its sector's edge
        let a33 = (Int(100 * cos(33 * Double.pi / 180)), -Int(100 * sin(33 * Double.pi / 180)))
        XCTAssertEqual(U | R, Joystick.keys(a33.0, a33.1, t, 0), "33 degrees is a diagonal")
        XCTAssertEqual(R, Joystick.keys(a33.0, a33.1, t, R), "but right stays right there")
        let a40 = (Int(100 * cos(40 * Double.pi / 180)), -Int(100 * sin(40 * Double.pi / 180)))
        XCTAssertEqual(U | R, Joystick.keys(a40.0, a40.1, t, R), "until the push is past the margin")
        let a26 = (Int(100 * cos(26 * Double.pi / 180)), -Int(100 * sin(26 * Double.pi / 180)))
        XCTAssertEqual(U | R, Joystick.keys(a26.0, a26.1, t, U | R), "a diagonal is kept 6 degrees into the arrow's sector")
        XCTAssertEqual(R, Joystick.keys(a26.0, a26.1, t, 0))
    }

    /** Settings > Joystick sensitivity: each level up holds from a shorter push; the default needs twice the highest level's. */
    func testTheSensitivitySetsTheDeadZone() {
        let t = 40
        // level -> the shortest push that holds, and the shortest held push that stays (90/66 ... 30/22 % of the travel)
        let edges = [1: (36, 27), 2: (30, 22), 3: (24, 18), 4: (18, 14), 5: (12, 9)]
        for (level, edge) in edges {
            let (engage, keep) = edge
            XCTAssertEqual(0, Joystick.keys(engage - 1, 0, t, 0, level), "level \(level)")
            XCTAssertEqual(R, Joystick.keys(engage, 0, t, 0, level), "level \(level)")
            XCTAssertEqual(R, Joystick.keys(keep, 0, t, R, level), "level \(level)")
            XCTAssertEqual(0, Joystick.keys(keep - 1, 0, t, R, level), "level \(level)")
        }
        XCTAssertEqual(3, Joystick.SENSITIVITY_DEFAULT)
        XCTAssertEqual(2 * Joystick.engagePercent(Joystick.SENSITIVITY_MAX), Joystick.engagePercent(Joystick.SENSITIVITY_DEFAULT), "the default needs twice the push of the highest level")
        for push in 0...45 { XCTAssertEqual(Joystick.keys(push, 0, t, 0, 3), Joystick.keys(push, 0, t, 0), "no level given: the default") }
        XCTAssertEqual(R, Joystick.keys(12, 0, t, 0, 9), "above the levels: the highest")
        XCTAssertEqual(0, Joystick.keys(35, 0, t, 0, 0), "below them: the lowest")
        XCTAssertEqual(U | L, Joystick.keys(-40, -40, t, 0, 1), "the direction is the push's at every level")
    }

    // ------------------------------------------------------------ GameControls

    private let area = Rect(0, 300, 360, 200)
    private var shell: Shell!
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("joy-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        shell = Shell(HeadlessEnv(dir))
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    /** Controls in [area] that record what they send as "<key> down|up", and the mode the toggle asks for. */
    private final class Log { var items: [String] = [] }
    private final class Rig {
        let gc: GameControls, s: Surface, area: Rect
        private let log = Log()
        var directional = DirectionalControl.dpad
        var showDpad = true
        var sensitivity = Joystick.SENSITIVITY_DEFAULT
        init(_ s: Surface, _ area: Rect) {
            self.s = s; self.area = area
            let log = self.log
            gc = GameControls { e in
                if case let .key(_, sc, down) = e { log.items.append("\(Rig.name(Int(sc & 0x7F))) \(down ? "down" : "up")") }
            }
            gc.onDirectional = { [unowned self] in directional = $0 }
            gc.stickSensitivity = { [unowned self] in sensitivity }
        }
        /** What was sent since the last take. */
        func take() -> [String] { defer { log.items.removeAll() }; return log.items }
        static func name(_ sc: Int) -> String {
            switch sc {
            case Keys.SC_CURSOR_UP: return "UP"; case Keys.SC_CURSOR_DOWN: return "DOWN"
            case Keys.SC_CURSOR_LEFT: return "LEFT"; case Keys.SC_CURSOR_RIGHT: return "RIGHT"
            default: return "sc\(sc)"
            }
        }
        func draw() { gc.draw(s, area, [], vertical: true, showDpad: showDpad, directional: directional) }
        func nodes() -> [(Rect, String)] { var n: [(Rect, String)] = []; gc.accessibility { r, l, _ in n.append((r, l)) }; return n }
        func node(_ label: String) -> Rect? { nodes().first { $0.1 == label }?.0 }
        func tap(_ label: String, id: Int = 9) {
            let r = node(label)!
            _ = gc.pointer(PointerEvent(Ptr.DOWN, r.x + r.w / 2, r.y + r.h / 2, id: id)); _ = gc.pointer(PointerEvent(Ptr.UP, r.x + r.w / 2, r.y + r.h / 2, id: id))
            draw()
        }
        /** A finger [id] at ([dx], [dy]) from the joystick's centre. */
        func stick(_ action: Int, _ dx: Int, _ dy: Int, id: Int = 1) -> Bool {
            gc.pointer(PointerEvent(action, gc.joystick.cx + dx, gc.joystick.cy + dy, id: id))
        }
    }

    private func rig() -> Rig { L10n.use("en-US"); let r = Rig(shell.surface, area); r.draw(); return r }

    func testTheJoystickExistsOnlyWhereTheDpadDoes() {
        let r = rig()
        XCTAssertEqual(["\u{18}", "\u{1B}", "\u{1A}", "\u{19}"], Array(r.gc.labels.prefix(4)), "the d-pad by default")
        XCTAssertEqual("JOYSTICK", r.gc.labels.last, "the switch names the mode it switches to")
        XCTAssertNotNil(r.node("Switch to the joystick"))
        XCTAssertFalse(r.gc.joystick.shown)
        r.directional = .joystick; r.draw()
        XCTAssertFalse(r.gc.labels.contains("\u{18}"), "the joystick replaces the four buttons")
        XCTAssertTrue(r.gc.joystick.shown)
        XCTAssertEqual("D-PAD", r.gc.labels.last)
        XCTAssertNotNil(r.node("Joystick: drag to move"))
        XCTAssertNotNil(r.node("Switch to the arrow buttons"))
        // the joystick takes the d-pad's square, and the buttons beside it keep their places
        let pad = Rect(area.x + 4, area.y + 4, 132, 132)
        XCTAssertTrue(r.gc.joystick.rect.x >= pad.x && r.gc.joystick.rect.right <= pad.right && r.gc.joystick.rect.bottom <= pad.bottom, "\(r.gc.joystick.rect)")
        let stickNodes = r.nodes().filter { $0.1 != "Joystick: drag to move" }.map { $0.0 }
        r.directional = .dpad; r.draw()
        let padNodes = Array(r.nodes().dropFirst(4).map { $0.0 })
        XCTAssertEqual(padNodes, stickNodes, "SPACE, ENTER, ESC, the touch mode and the switch stay where they were")
        // no d-pad: no joystick and no switch, whatever the setting says
        for mode in [DirectionalControl.dpad, .joystick] {
            r.showDpad = false; r.directional = mode; r.draw()
            XCTAssertFalse(r.gc.joystick.shown)
            XCTAssertNil(r.node("Switch to the joystick")); XCTAssertNil(r.node("Switch to the arrow buttons")); XCTAssertNil(r.node("Joystick: drag to move"))
            XCTAssertEqual(["SPACE", "ENTER", "ESC", "L-CLICK"], r.gc.labels)
        }
    }

    func testTheSwitchIsTheAppsAndNeverReachesTheProgram() {
        let r = rig()
        for _ in 0..<3 {
            r.tap("Switch to the joystick")
            XCTAssertEqual(.joystick, r.directional)
            XCTAssertEqual(1, r.gc.labels.filter { $0 == "D-PAD" }.count, "one switch, no duplicate controls")
            r.tap("Switch to the arrow buttons")
            XCTAssertEqual(.dpad, r.directional)
            XCTAssertEqual(4, r.gc.labels.filter { ["\u{18}", "\u{19}", "\u{1A}", "\u{1B}"].contains($0) }.count)
        }
        XCTAssertEqual([], r.take(), "switching sends no key")
        XCTAssertFalse(r.gc.anyHeld)
    }

    func testAPushHoldsArrowsAndSendsOnlyWhatChanges() {
        let r = rig(); r.directional = .joystick; r.draw()
        XCTAssertTrue(r.stick(Ptr.DOWN, 0, 3)); XCTAssertEqual([], r.take(), "a touch in the dead zone holds nothing")
        XCTAssertTrue(r.stick(Ptr.MOVE, 0, -30)); XCTAssertEqual(["UP down"], r.take())
        XCTAssertTrue(r.stick(Ptr.MOVE, 2, -34)); XCTAssertEqual([], r.take(), "a wobble inside the same direction sends nothing")
        XCTAssertTrue(r.stick(Ptr.MOVE, 25, -25)); XCTAssertEqual(["RIGHT down"], r.take(), "up stays down on the diagonal")
        XCTAssertTrue(r.stick(Ptr.MOVE, 30, 0)); XCTAssertEqual(["UP up"], r.take())
        XCTAssertTrue(r.stick(Ptr.MOVE, 300, 280)); XCTAssertEqual(["DOWN down"], r.take(), "far outside the joystick it still steers")
        let j = r.gc.joystick
        XCTAssertLessThanOrEqual(j.knobX * j.knobX + j.knobY * j.knobY, (j.travel + 1) * (j.travel + 1), "the knob stays inside")
        XCTAssertTrue(r.stick(Ptr.MOVE, 0, 30)); XCTAssertEqual(["RIGHT up"], r.take())
        XCTAssertTrue(r.stick(Ptr.MOVE, -30, 0)); XCTAssertEqual(["DOWN up", "LEFT down"], r.take(), "a jump across releases first")
        XCTAssertTrue(r.stick(Ptr.MOVE, -4, 0)); XCTAssertEqual(["LEFT up"], r.take(), "back to the centre: nothing held")
        XCTAssertTrue(r.stick(Ptr.MOVE, -30, 0)); XCTAssertEqual(["LEFT down"], r.take())
        XCTAssertTrue(r.stick(Ptr.UP, -30, 0)); XCTAssertEqual(["LEFT up"], r.take())
        XCTAssertFalse(r.gc.anyHeld)
        XCTAssertTrue(r.stick(Ptr.DOWN, 40, 0)); XCTAssertEqual(["RIGHT down"], r.take(), "a touch away from the centre pushes at once")
        XCTAssertTrue(r.stick(Ptr.CANCEL, 40, 0)); XCTAssertEqual(["RIGHT up"], r.take(), "a cancelled touch releases too")
    }

    /** The setting is read at each push: the same finger holds its arrow sooner or later with the level. */
    func testThePushThatHoldsFollowsTheSensitivity() {
        let r = rig(); r.directional = .joystick; r.draw()
        func at(_ percent: Int) -> Int { r.gc.joystick.travel * percent / 100 }
        XCTAssertTrue(r.stick(Ptr.DOWN, at(50), 0)); XCTAssertEqual([], r.take(), "the default: half the travel holds nothing")
        XCTAssertTrue(r.stick(Ptr.MOVE, at(70), 0)); XCTAssertEqual(["RIGHT down"], r.take())
        XCTAssertTrue(r.stick(Ptr.UP, at(70), 0)); XCTAssertEqual(["RIGHT up"], r.take())
        r.sensitivity = Joystick.SENSITIVITY_MAX
        XCTAssertTrue(r.stick(Ptr.DOWN, at(40), 0)); XCTAssertEqual(["RIGHT down"], r.take(), "the highest level holds from a short push")
        XCTAssertTrue(r.stick(Ptr.UP, at(40), 0)); XCTAssertEqual(["RIGHT up"], r.take())
        r.sensitivity = Joystick.SENSITIVITY_MIN
        XCTAssertTrue(r.stick(Ptr.DOWN, at(80), 0)); XCTAssertEqual([], r.take(), "the lowest needs nearly the whole travel")
        XCTAssertTrue(r.stick(Ptr.MOVE, at(95), 0)); XCTAssertEqual(["RIGHT down"], r.take())
        XCTAssertTrue(r.stick(Ptr.MOVE, at(70), 0)); XCTAssertEqual([], r.take(), "held a little inside the edge")
        XCTAssertTrue(r.stick(Ptr.MOVE, at(50), 0)); XCTAssertEqual(["RIGHT up"], r.take())
        XCTAssertTrue(r.stick(Ptr.UP, at(50), 0)); XCTAssertEqual([], r.take())
        XCTAssertFalse(r.gc.anyHeld)
    }

    /** A held push repeats like a held d-pad button (TempleOS KbdTypeMatic(0): 250 ms, then 30/s). */
    func testAHeldPushRepeatsLikeTheDpad() {
        let r = rig(); r.directional = .joystick; r.draw()
        _ = r.stick(Ptr.DOWN, 30, 0)
        var log = r.take()
        r.gc.tick(1000); r.gc.tick(1200); log += r.take()
        XCTAssertEqual(["RIGHT down"], log, "no repeat before 250 ms")
        r.gc.tick(1260); XCTAssertEqual(["RIGHT down"], r.take(), "first repeat after 250 ms")
        for t in stride(from: 1293, through: 2260, by: 33) { r.gc.tick(Int64(t)) }
        let n = r.take().count
        XCTAssertTrue((28...34).contains(n), "about 30 repeats per second: \(n)")
        _ = r.stick(Ptr.MOVE, 25, -25); XCTAssertEqual(["UP down"], r.take())
        for t in stride(from: 2293, through: 2800, by: 33) { r.gc.tick(Int64(t)) }
        XCTAssertTrue(r.take().allSatisfy { $0 == "UP down" }, "the arrow pressed last repeats, as on a PC keyboard")
        _ = r.stick(Ptr.UP, 25, -25); XCTAssertEqual(["UP up", "RIGHT up"], r.take())
        r.gc.tick(4000); r.gc.tick(5000)
        XCTAssertEqual([], r.take(), "nothing repeats after the release")
    }

    func testTheJoystickAndButtonsAreSeparateFingers() {
        let r = rig(); r.directional = .joystick; r.draw()
        let space = r.node("Space")!
        _ = r.stick(Ptr.DOWN, 0, -30, id: 1); XCTAssertEqual(["UP down"], r.take())
        _ = r.gc.pointer(PointerEvent(Ptr.DOWN, space.x + 4, space.y + 4, id: 2)); XCTAssertEqual(["sc57 down"], r.take(), "SPACE with the joystick held")
        XCTAssertTrue(r.stick(Ptr.DOWN, 30, 0, id: 3), "a second finger on the joystick is taken")
        _ = r.stick(Ptr.MOVE, 30, 0, id: 3); XCTAssertEqual([], r.take(), "and ignored")
        XCTAssertEqual(0, r.gc.joystick.knobX, "it does not move the knob")
        _ = r.stick(Ptr.UP, 30, 0, id: 3); XCTAssertEqual([], r.take())
        _ = r.gc.pointer(PointerEvent(Ptr.UP, space.x + 4, space.y + 4, id: 2)); XCTAssertEqual(["sc57 up"], r.take(), "SPACE goes up alone")
        _ = r.stick(Ptr.MOVE, 30, 0, id: 1); XCTAssertEqual(["UP up", "RIGHT down"], r.take(), "the joystick still steers")
        _ = r.gc.pointer(PointerEvent(Ptr.DOWN, space.x + 4, space.y + 4, id: 2)); _ = r.take()
        _ = r.stick(Ptr.UP, 30, 0, id: 1); XCTAssertEqual(["RIGHT up"], r.take(), "the joystick lets go alone")
        XCTAssertTrue(r.gc.anyHeld, "SPACE is still held")
        _ = r.gc.pointer(PointerEvent(Ptr.UP, space.x + 4, space.y + 4, id: 2)); XCTAssertEqual(["sc57 up"], r.take())
    }

    func testSwitchingReleasesTheArrowsAndNothingElse() {
        let r = rig(); r.directional = .joystick; r.draw()
        let space = r.node("Space")!
        _ = r.gc.pointer(PointerEvent(Ptr.DOWN, space.x + 4, space.y + 4, id: 2))
        _ = r.stick(Ptr.DOWN, 30, 0, id: 1); _ = r.take()
        r.tap("Switch to the arrow buttons")
        XCTAssertEqual(["RIGHT up"], r.take(), "the joystick's arrow goes up with the joystick")
        XCTAssertEqual(.dpad, r.directional)
        _ = r.stick(Ptr.MOVE, 0, 30, id: 1); _ = r.stick(Ptr.UP, 0, 30, id: 1)
        XCTAssertEqual([], r.take(), "its finger holds nothing more")
        // and back: a finger on a d-pad button lets go of its arrow too
        let up = r.node("Up arrow")!
        _ = r.gc.pointer(PointerEvent(Ptr.DOWN, up.x + 4, up.y + 4, id: 4)); XCTAssertEqual(["UP down"], r.take())
        r.tap("Switch to the joystick")
        XCTAssertEqual(["UP up"], r.take())
        _ = r.gc.pointer(PointerEvent(Ptr.UP, up.x + 4, up.y + 4, id: 4)); XCTAssertEqual([], r.take())
        XCTAssertTrue(r.gc.anyHeld, "SPACE stays held through both switches")
        _ = r.gc.pointer(PointerEvent(Ptr.UP, space.x + 4, space.y + 4, id: 2)); XCTAssertEqual(["sc57 up"], r.take())
    }

    func testNothingTheJoystickHoldsOutlivesIt() {
        let r = rig(); r.directional = .joystick; r.draw()
        func hold() { _ = r.stick(Ptr.DOWN, 0, 30); XCTAssertEqual(["DOWN down"], r.take()) }
        func lifted(_ why: String) { _ = r.stick(Ptr.MOVE, 30, 0); _ = r.stick(Ptr.UP, 30, 0); XCTAssertEqual([], r.take(), "\(why): the finger holds nothing more") }
        hold(); r.showDpad = false; r.draw(); XCTAssertEqual(["DOWN up"], r.take(), "the program has no d-pad"); lifted("no d-pad")
        r.showDpad = true; r.draw()
        hold(); r.gc.clearLayout(); XCTAssertEqual(["DOWN up"], r.take(), "no control area"); lifted("no control area")
        r.draw()
        hold(); r.gc.draw(r.s, Rect(0, 200, 360, 200), [], vertical: true, showDpad: true, directional: .joystick)
        XCTAssertEqual(["DOWN up"], r.take(), "the joystick moved under the finger (rotation)"); lifted("moved")
        r.draw()
        hold(); r.gc.draw(r.s, Rect(0, 0, 30, 30), [], vertical: true, showDpad: true, directional: .joystick)
        XCTAssertEqual(["DOWN up"], r.take(), "too small for controls"); lifted("too small")
        r.draw()
        hold(); r.gc.releaseAll(); XCTAssertEqual(["DOWN up"], r.take(), "focus loss, background, pause, stop"); lifted("released")
        r.draw(); hold(); _ = r.stick(Ptr.MOVE, 0, 32)
        r.draw(); r.draw(); XCTAssertEqual([], r.take(), "redrawing changes nothing")
        // the knob eases back after a release; the keys are already up
        _ = r.stick(Ptr.UP, 0, 32); XCTAssertEqual(["DOWN up"], r.take())
        XCTAssertNotEqual(0, r.gc.joystick.knobY)
        XCTAssertTrue(r.gc.tick(10_000)); XCTAssertTrue(r.gc.tick(10_040))
        XCTAssertTrue(r.gc.tick(10_100)); XCTAssertEqual(0, r.gc.joystick.knobY, "home after 80 ms")
        XCTAssertFalse(r.gc.tick(10_116), "and then nothing to redraw")
    }

    func testTheSettingIsKeptAndOldSessionsKeepTheDpad() {
        XCTAssertEqual(.dpad, Settings().directional)
        XCTAssertEqual(.dpad, Settings.decode("d=8;s=1;o=2;u=0;c=0;t=0;k=0;g=;e=0").directional, "a session from before the joystick")
        let st = Settings(); st.directional = .joystick
        XCTAssertTrue(st.encode().contains(";j=1;"))
        XCTAssertEqual(.joystick, Settings.decode(st.encode()).directional)
        XCTAssertEqual(.dpad, Settings.decode("j=7").directional)
    }

    func testTheSensitivityIsKeptAndOldSessionsGetTheDefault() {
        XCTAssertEqual(Joystick.SENSITIVITY_DEFAULT, Settings().joystickSensitivity)
        let old = Settings.decode("d=8;s=1;o=2;u=0;c=0;t=0;k=0;g=;e=0;j=1;i=1")
        XCTAssertEqual(Joystick.SENSITIVITY_DEFAULT, old.joystickSensitivity, "a session from before the setting")
        XCTAssertEqual(.joystick, old.directional, "its other settings stay"); XCTAssertTrue(old.importIntroSeen)
        let st = Settings(); st.joystickSensitivity = 5; st.directional = .joystick
        XCTAssertTrue(st.encode().contains(";j=1;js=5;"), st.encode())
        XCTAssertEqual(5, Settings.decode(st.encode()).joystickSensitivity)
        XCTAssertEqual(.joystick, Settings.decode(st.encode()).directional)
        XCTAssertEqual(5, Settings.decode("js=9").joystickSensitivity, "out of range: the nearest level")
        XCTAssertEqual(1, Settings.decode("js=0").joystickSensitivity)
        XCTAssertEqual(Joystick.SENSITIVITY_DEFAULT, Settings.decode("js=high").joystickSensitivity, "not a number: the default")
    }

    /** Settings > Joystick sensitivity: a tap goes to the next level and round again, saved with the session. */
    func testTheSettingsRowCyclesThroughTheLevels() {
        L10n.use("en-US")
        let env = HeadlessEnv(dir)
        let sh = Shell(env); sh.resize(360, 640); _ = sh.tick()
        Launch.settings(sh); sh.invalidate(); _ = sh.tick()
        func row(_ level: Int) -> Rect? { sh.accessibilityNodes().first { $0.label == "Joystick sensitivity: \(level)/5" }?.rect }
        func tap(_ r: Rect) {
            sh.pointer(PointerEvent(Ptr.DOWN, r.x + r.w / 2, r.y + r.h / 2, id: 1)); sh.pointer(PointerEvent(Ptr.UP, r.x + r.w / 2, r.y + r.h / 2, id: 1))
            sh.invalidate(); _ = sh.tick()
        }
        for next in [4, 5, 1, 2, 3] {
            let before = sh.settings.joystickSensitivity
            tap(row(before)!)
            XCTAssertEqual(next, sh.settings.joystickSensitivity)
            XCTAssertNotNil(row(next), "the row shows level \(next)"); XCTAssertNil(row(before))
            XCTAssertTrue(env.session!.contains(";js=\(next);"), "saved: \(env.session ?? "")")
        }
        tap(row(3)!); tap(row(4)!)
        let again = Shell(env); again.resize(360, 640); again.restoreSession(); _ = again.tick()
        XCTAssertEqual(5, again.settings.joystickSensitivity, "kept across a relaunch")
    }

    // ------------------------------------------------------------ programs, through the shell

    private final class Run {
        let sh: Shell, p: ProgramApp, dir: URL
        /** Where the joystick is (a finger keeps steering it while a menu hides it from the screen reader). */
        private var stickRect: Rect?
        var k: Kernel { p.kernel }
        init(_ sh: Shell, _ p: ProgramApp, _ dir: URL) { self.sh = sh; self.p = p; self.dir = dir }
        func nodes() -> [A11yNode] { sh.invalidate(); _ = sh.tick(); return sh.accessibilityNodes() }
        func node(_ label: String) -> Rect? { nodes().first { $0.label == label }?.rect }
        @discardableResult func waitFor(_ s: Double, _ c: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(s)
            while Date() < end { _ = sh.tick(); if c() { return true }; Thread.sleep(forTimeInterval: 0.016) }
            _ = sh.tick(); return c()
        }
        func bit(_ b: Int) -> Bool {
            let a = k.o.kbdAddr + k.o.member("CKbdStateGlbls", "down_bitmap")
            return (k.mem.ld1(a + (b >> 3)) >> Int64(b & 7)) & 1 != 0
        }
        func tap(_ label: String) {
            let r = node(label)!
            sh.pointer(PointerEvent(Ptr.DOWN, r.x + r.w / 2, r.y + r.h / 2, id: 50)); sh.pointer(PointerEvent(Ptr.UP, r.x + r.w / 2, r.y + r.h / 2, id: 50)); _ = sh.tick()
        }
        func stick(_ action: Int, _ dx: Int, _ dy: Int, id: Int = 1) {
            if stickRect == nil { stickRect = node("Joystick: drag to move") }
            let r = stickRect!
            sh.pointer(PointerEvent(action, r.x + r.w / 2 + dx, r.y + r.h / 2 + dy, id: id)); _ = sh.tick()
        }
        func close() { sh.windows.forEach { sh.close($0, force: true) }; try? FileManager.default.removeItem(at: dir) }
    }

    private func launch(_ path: String, _ directional: DirectionalControl = .dpad, popupOk: Bool = false) -> Run {
        L10n.use("en-US")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("joyrun-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sh = Shell(HeadlessEnv(dir)); sh.resize(360, 640); _ = sh.tick()
        sh.settings.directional = directional
        sh.settings.engine = Settings.ENGINE_TERRY
        Launch.program(sh, path, sh.catalog.byPath(path))
        let r = Run(sh, sh.focused!.app as! ProgramApp, dir)
        if popupOk { XCTAssertTrue(r.waitFor(30) { sh.dialogOpen }, "\(path) popup"); sh.key(10, Keys.forChar(10).1, true) }
        XCTAssertTrue(r.waitFor(30) { r.k.graphicsUsed && r.k.frameCount >= 10 }, "\(path) runs")
        return r
    }

    /** Halogen holds its arrows down (Bt(kbd.down_bitmap)): the joystick holds them, beside SPACE, and lets them go. */
    func testTheJoystickDrivesAProgramThroughTheShell() {
        let r = launch("C:/Demo/Games/Halogen.HC")
        defer { r.close() }
        XCTAssertNotNil(r.node("Up arrow"))
        let kernel = r.k, frames = r.k.frameCount
        r.tap("Switch to the joystick")
        XCTAssertEqual(.joystick, r.sh.settings.directional, "the choice is the user's setting")
        XCTAssertNil(r.node("Up arrow")); XCTAssertNotNil(r.node("Switch to the arrow buttons"))
        XCTAssertTrue(r.waitFor(2) { r.k.frameCount > frames + 5 }, "the program kept running")
        XCTAssertTrue(r.p.kernel === kernel && !r.p.isFinished, "the same program, not restarted")
        r.stick(Ptr.DOWN, 0, -40)
        XCTAssertTrue(r.waitFor(1) { r.bit(Keys.SC_CURSOR_UP) }, "up is held")
        let space = r.node("Space")!
        r.sh.pointer(PointerEvent(Ptr.DOWN, space.x + 4, space.y + 4, id: 2)); _ = r.sh.tick()
        XCTAssertTrue(r.waitFor(1) { r.bit(Keys.SC_SPACE) && r.bit(Keys.SC_CURSOR_UP) }, "SPACE with the joystick")
        r.stick(Ptr.MOVE, 40, -40)
        XCTAssertTrue(r.waitFor(1) { r.bit(Keys.SC_CURSOR_UP) && r.bit(Keys.SC_CURSOR_RIGHT) }, "a diagonal holds two arrows")
        r.sh.pointer(PointerEvent(Ptr.UP, space.x + 4, space.y + 4, id: 2)); _ = r.sh.tick()
        XCTAssertTrue(r.waitFor(1) { !r.bit(Keys.SC_SPACE) && r.bit(Keys.SC_CURSOR_RIGHT) }, "SPACE goes up alone")
        r.stick(Ptr.UP, 40, -40)
        XCTAssertTrue(r.waitFor(1) { !r.bit(Keys.SC_CURSOR_UP) && !r.bit(Keys.SC_CURSOR_RIGHT) }, "released with the finger")
        // a menu takes the input: a held push is let go
        r.stick(Ptr.DOWN, -40, 0)
        XCTAssertTrue(r.waitFor(1) { r.bit(Keys.SC_CURSOR_LEFT) })
        r.sh.showMenu([MenuItem("x") {}], 0, 0)
        XCTAssertTrue(r.waitFor(1) { !r.bit(Keys.SC_CURSOR_LEFT) }, "a menu releases the joystick")
        r.stick(Ptr.UP, -40, 0); _ = r.sh.back()
        r.tap("Switch to the arrow buttons")
        XCTAssertEqual(.dpad, r.sh.settings.directional)
        XCTAssertNotNil(r.node("Up arrow")); XCTAssertNil(r.node("Joystick: drag to move"))
        let up = r.node("Up arrow")!
        r.sh.pointer(PointerEvent(Ptr.DOWN, up.x + 4, up.y + 4, id: 3)); _ = r.sh.tick()
        XCTAssertTrue(r.waitFor(1) { r.bit(Keys.SC_CURSOR_UP) }, "the d-pad works again")
        r.sh.pointer(PointerEvent(Ptr.UP, up.x + 4, up.y + 4, id: 3)); _ = r.sh.tick()
        XCTAssertTrue(r.waitFor(1) { !r.bit(Keys.SC_CURSOR_UP) })
        XCTAssertTrue(Settings.decode(r.sh.settings.encode()).directional == .dpad)
    }

    /** A running program's joystick follows the setting from its next push on (Halogen holds its arrows down). */
    func testARunningProgramFollowsTheSensitivity() {
        let r = launch("C:/Demo/Games/Halogen.HC", .joystick)
        defer { r.close() }
        XCTAssertEqual(Joystick.SENSITIVITY_DEFAULT, r.sh.settings.joystickSensitivity)
        r.stick(Ptr.DOWN, 0, -15)
        XCTAssertFalse(r.waitFor(0.3) { r.bit(Keys.SC_CURSOR_UP) }, "the default: a short push holds nothing")
        r.stick(Ptr.MOVE, 0, -28)
        XCTAssertTrue(r.waitFor(1) { r.bit(Keys.SC_CURSOR_UP) }, "a longer one holds up")
        r.stick(Ptr.UP, 0, -28)
        XCTAssertTrue(r.waitFor(1) { !r.bit(Keys.SC_CURSOR_UP) })
        r.sh.settings.joystickSensitivity = Joystick.SENSITIVITY_MAX
        r.stick(Ptr.DOWN, 0, -15)
        XCTAssertTrue(r.waitFor(1) { r.bit(Keys.SC_CURSOR_UP) }, "the highest level: the short push holds up")
        r.stick(Ptr.UP, 0, -15)
        XCTAssertTrue(r.waitFor(1) { !r.bit(Keys.SC_CURSOR_UP) })
        r.sh.settings.joystickSensitivity = Joystick.SENSITIVITY_MIN
        r.stick(Ptr.DOWN, 0, -28)
        XCTAssertFalse(r.waitFor(0.3) { r.bit(Keys.SC_CURSOR_UP) }, "the lowest level: the longer push holds nothing")
        r.stick(Ptr.MOVE, 0, -40)
        XCTAssertTrue(r.waitFor(1) { r.bit(Keys.SC_CURSOR_UP) }, "the whole travel does")
        r.stick(Ptr.UP, 0, -40)
        XCTAssertTrue(r.waitFor(1) { !r.bit(Keys.SC_CURSOR_UP) })
    }

    /** Android keeps its back gesture out of the joystick: the shell reports its square while it is on screen and focused. */
    func testTheSystemEdgeGesturesStayOutOfTheJoystick() {
        let r = launch("C:/Demo/Games/Halogen.HC", .joystick)
        defer { r.close() }
        let stick = r.node("Joystick: drag to move")!
        XCTAssertEqual([stick], r.sh.systemChrome.gestureExclusion)
        r.sh.showMenu([MenuItem("x") {}], 0, 0); _ = r.sh.tick()
        XCTAssertEqual([], r.sh.systemChrome.gestureExclusion, "a menu takes the touches")
        _ = r.sh.back(); r.sh.invalidate(); _ = r.sh.tick()
        XCTAssertEqual([stick], r.sh.systemChrome.gestureExclusion)
        r.tap("Switch to the arrow buttons"); r.sh.invalidate(); _ = r.sh.tick()
        XCTAssertEqual([], r.sh.systemChrome.gestureExclusion, "the d-pad's buttons are tapped, not dragged")
    }

    /** CastleFrankenstein walks one step per key message: a held push walks it like a held d-pad button. */
    func testAHeldPushWalksCastleFrankenstein() {
        let r = launch("C:/Demo/Games/CastleFrankenstein.HC", .joystick)
        defer { r.close() }
        func g(_ n: String) -> Int64 { r.k.mem.ld8((r.k.prog.globals[n] as! GlobalSym).addr) }
        XCTAssertTrue(r.waitFor(30) { r.k.frameCount >= 20 })
        let x0 = g("man_xx"), y0 = g("man_yy")
        r.stick(Ptr.DOWN, 0, -45)
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 2 { _ = r.sh.tick(); Thread.sleep(forTimeInterval: 0.016) }
        r.stick(Ptr.UP, 0, -45)
        Thread.sleep(forTimeInterval: 0.3); _ = r.sh.tick()
        XCTAssertGreaterThan(abs(g("man_xx") - x0) + abs(g("man_yy") - y0), 1000, "the player walked")
        XCTAssertFalse(r.bit(Keys.SC_CURSOR_UP))
    }

    /** FlapBat has no d-pad: it never gets the joystick or its switch, even when the user chose the joystick. */
    func testAProgramWithoutTheDpadNeverGetsTheJoystick() {
        let r = launch("C:/Demo/Games/FlapBat.HC", .joystick, popupOk: true)
        defer { r.close() }
        let labels = r.nodes().map { $0.label }
        XCTAssertTrue(labels.contains("Space"), "\(labels)")
        for l in ["Joystick: drag to move", "Switch to the joystick", "Switch to the arrow buttons", "Up arrow"] { XCTAssertFalse(labels.contains(l), l) }
        XCTAssertEqual([], r.sh.systemChrome.gestureExclusion)
    }
}

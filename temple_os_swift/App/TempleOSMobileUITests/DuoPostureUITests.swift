import XCTest

/**
 * The iPhone Duo campaign (docs/foldable/IPHONE_DUO_ADAPTATION.md): real fold and rotation transitions on the
 * iPhone Duo simulator in the middle of running tests, with the app's state checked across them.
 *
 * The transitions are DeviceHub's own fold buttons and orientation menu (simctl has none), pressed by
 * tools/foldable/posture_server.sh on the host: the test writes a request file into the directory named by
 * DUO_CTL (TEST_RUNNER_DUO_CTL for xcodebuild) and waits for the answer. The server also takes masked
 * screenshots of whichever display is lit and samples the app's memory. tools/foldable/run_duo_campaign.sh
 * runs everything; without DUO_CTL these tests are skipped (other devices).
 *
 * The layout is read from the TempleOS view's accessibility value (size, insets, folds and occlusions in
 * logical px, published by TempleView) and from one accessibility snapshot per checkpoint.
 */
final class DuoPostureUITests: XCTestCase {
    private var app: XCUIApplication!
    private var ctlDir: URL!
    private var seq = 0
    /** The menu's "scroll down" row, in the UI language of the running app. */
    private var scrollDown = "Scroll menu down"
    /** The repository (this file is temple_os_swift/App/TempleOSMobileUITests/DuoPostureUITests.swift). */
    private static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    override func setUpWithError() throws {
        // a campaign: every failing checkpoint is recorded, not only the first
        continueAfterFailure = true
        guard let d = ProcessInfo.processInfo.environment["DUO_CTL"] else {
            throw XCTSkip("needs the host posture server (tools/foldable/run_duo_campaign.sh)")
        }
        ctlDir = URL(fileURLWithPath: d)
        // several tests share one server: continue its numbering
        while FileManager.default.fileExists(atPath: ctlDir.appendingPathComponent("req-\(seq + 1)").path) { seq += 1 }
        app = XCUIApplication()
    }

    // MARK: host control

    /** Runs one tools/foldable/duo.sh command on the host (fold, rotation, shot, mem) and returns its output. */
    @discardableResult private func ctl(_ cmd: String, timeout: TimeInterval = 120) -> String {
        seq += 1
        let ack = ctlDir.appendingPathComponent("ack-\(seq)")
        try? cmd.write(to: ctlDir.appendingPathComponent("req-\(seq)"), atomically: true, encoding: .utf8)
        let t0 = Date()
        while Date().timeIntervalSince(t0) < timeout {
            if let s = try? String(contentsOf: ack, encoding: .utf8) {
                print("DUOCTL \(cmd) -> \(s.trimmingCharacters(in: .whitespacesAndNewlines))")
                return s
            }
            usleep(200_000)
        }
        XCTFail("the posture server did not answer '\(cmd)'")
        return ""
    }

    // MARK: layout

    private struct Layout: Equatable {
        var ppl = 1.0, w = 0, h = 0, top = 0, left = 0, bottom = 0, right = 0, barLeft = 0, barRight = 0
        var windowed = false
        /** The TempleOS keyboard: shown, its transition count and the last transition's reason (Shell.KeyboardReason). */
        var kb = false, kbSeq = 0, kbWhy = ""
        var div: [CGRect] = [], occ: [CGRect] = []
        var perf: [String: String] = [:]
        static func == (a: Layout, b: Layout) -> Bool {
            a.ppl == b.ppl && a.w == b.w && a.h == b.h && a.top == b.top && a.left == b.left && a.bottom == b.bottom
                && a.right == b.right && a.div == b.div && a.occ == b.occ && a.windowed == b.windowed
        }
        var wide: Bool { w > h }
        /** The inner display (its shorter side is over 600 pt) rather than the outer one. */
        var inner: Bool { Double(min(w, h)) * ppl > 600 }
        func pt(_ r: CGRect) -> CGRect { CGRect(x: r.minX * ppl, y: r.minY * ppl, width: r.width * ppl, height: r.height * ppl) }
    }

    private var view: XCUIElement { app.descendants(matching: .any)["templeView"] }

    private func layout() -> Layout {
        var l = Layout()
        let s = (view.value as? String) ?? ""
        func rects(_ v: Substring) -> [CGRect] {
            v.split(separator: "|").compactMap { r in
                let n = r.split(separator: ",").compactMap { Double($0) }
                return n.count == 4 ? CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) : nil
            }
        }
        for kv in s.split(separator: ";") {
            guard let eq = kv.firstIndex(of: "=") else { continue }
            let k = kv[..<eq], v = kv[kv.index(after: eq)...]
            switch k {
            case "pointsPerLogical": l.ppl = Double(v) ?? 1
            case "width": l.w = Int(v) ?? 0
            case "height": l.h = Int(v) ?? 0
            case "top": l.top = Int(v) ?? 0
            case "left": l.left = Int(v) ?? 0
            case "bottom": l.bottom = Int(v) ?? 0
            case "right": l.right = Int(v) ?? 0
            case "barLeft": l.barLeft = Int(v) ?? 0
            case "barRight": l.barRight = Int(v) ?? 0
            case "windowed": l.windowed = v == "1"
            case "kb": l.kb = v == "1"
            case "kbSeq": l.kbSeq = Int(v) ?? 0
            case "kbWhy": l.kbWhy = String(v)
            case "div": l.div = rects(v)
            case "occ": l.occ = rects(v)
            case "perf":
                for f in v.split(separator: " ") where f.contains("=") {
                    let p = f.split(separator: "=", maxSplits: 1); l.perf[String(p[0])] = String(p[1])
                }
            default: break
            }
        }
        return l
    }

    /** Waits until the published layout satisfies [ok] and holds still for a moment (the end of a transition). */
    @discardableResult private func settle(timeout: TimeInterval = 20, _ ok: (Layout) -> Bool = { _ in true }) -> Layout? {
        let t0 = Date()
        var last: Layout?
        while Date().timeIntervalSince(t0) < timeout {
            let l = layout()
            if ok(l), let p = last, p == l { return l }
            last = ok(l) ? l : nil
            usleep(700_000)
        }
        return nil
    }

    // MARK: postures

    enum Posture: String, CaseIterable {
        case closedPortrait = "closed-portrait", closedLeft = "closed-landleft", closedRight = "closed-landright"
        case openWide = "open-wide", openTall = "open-tall", book, tabletop
    }

    private func matches(_ p: Posture, _ l: Layout) -> Bool {
        let foldVertical = l.div.first.map { $0.height > $0.width }
        switch p {
        case .closedPortrait: return !l.inner && !l.wide
        // the camera block marks the side: Landscape Left puts it on the left, Landscape Right on the right
        case .closedLeft: return !l.inner && l.wide && (l.occ.map { $0.midX < Double(l.w) / 2 }.contains(true))
        case .closedRight: return !l.inner && l.wide && (l.occ.map { $0.midX >= Double(l.w) / 2 }.contains(true))
        case .openWide: return l.inner && l.wide && l.div.isEmpty
        case .openTall: return l.inner && !l.wide && l.div.isEmpty
        case .book: return l.inner && foldVertical == true
        case .tabletop: return l.inner && foldVertical == false
        }
    }

    /**
     * Brings the simulator into [p] with DeviceHub's controls, verified against the app's own measurement
     * (display, shape, fold side). The orientation is turned with DeviceHub's Rotate Right button, pressed
     * until the app measures the wanted shape: unlike the Orientation menu it needs no app switch on the Mac
     * (switching apps can deliver host keyboard events to the simulator, which put away the on-screen
     * TempleOS keyboard as any hardware key does). Returns the layout.
     */
    @discardableResult private func posture(_ p: Posture, file: StaticString = #filePath, line: UInt = #line) -> Layout? {
        let fold: String
        switch p {
        case .closedPortrait, .closedLeft, .closedRight: fold = "closed"
        case .openWide, .openTall: fold = "open"
        case .book, .tabletop: fold = "partial"
        }
        if let l = settle(timeout: 2, { self.matches(p, $0) }) { return l } // already there
        ctl(fold)
        for _ in 0..<5 {
            if let l = settle(timeout: 8, { self.matches(p, $0) }) { print("POSTURE \(p.rawValue) ok \(l.w)x\(l.h) div=\(l.div)"); return l }
            ctl("rotright")
        }
        XCTFail("could not reach the \(p.rawValue) posture (layout \(view.value ?? ""))", file: file, line: line)
        return nil
    }

    // MARK: checkpoints

    /**
     * One checkpoint: the TempleOS view fills the window; every tappable element is on screen with a size;
     * top-bar items keep out of occlusions and the rounded corners; menus, dialogs, keys and the key row are
     * off the fold (window content may span it, as a canvas does); then a screenshot. Returns the layout.
     */
    @discardableResult private func checkpoint(_ tag: String, file: StaticString = #filePath, line: UInt = #line) -> Layout {
        let l = settle() ?? layout()
        guard let snap = try? app.snapshot() else { XCTFail("\(tag): no snapshot", file: file, line: line); return l }
        // the application element keeps the display's portrait bounds on the Duo; the window and every element
        // are in the interface orientation
        var screen = view.frame
        func window(_ e: XCUIElementSnapshot) -> CGRect? { e.elementType == .window ? e.frame : e.children.lazy.compactMap(window).first }
        if let w = window(snap) {
            XCTAssertEqual(screen.width, w.width, accuracy: 1, "\(tag): the TempleOS view fills the window", file: file, line: line)
            XCTAssertEqual(screen.height, w.height, accuracy: 1, "\(tag): the TempleOS view fills the window", file: file, line: line)
            screen = w
        }
        XCTAssertEqual(Double(l.w) * l.ppl, Double(screen.width), accuracy: 3 * l.ppl, "\(tag): published width", file: file, line: line)
        var buttons: [(String, CGRect)] = []
        func walk(_ e: XCUIElementSnapshot) {
            if e.elementType == .keyboard { return } // the device keyboard is the system's, not TempleOS UI
            if e.elementType == .button { buttons.append((e.label, e.frame)) }
            e.children.forEach(walk)
        }
        walk(snap)
        let menuY = buttons.first { $0.0 == "MENU" }?.1
        let div = l.div.map(l.pt), occ = l.occ.map(l.pt)
        // the bottom bars (keyboard, key row) start at the first row of keys from the bottom
        let keyTop = buttons.filter { ["Enter", "Escape", "Show or hide keyboard"].contains($0.0) }.map { $0.1.minY }.min() ?? .infinity
        let popupOpen = app.buttons[scrollDown].exists || buttons.contains { ["CANCEL", "OK", "TERMINAL"].contains($0.0.uppercased()) }
        for (label, f) in buttons where !f.isEmpty {
            XCTAssertTrue(screen.insetBy(dx: -1, dy: -1).contains(f), "\(tag): '\(label)' \(f) off screen \(screen)", file: file, line: line)
            let topBar = menuY.map { abs(f.minY - $0.minY) < 1 } ?? false
            if topBar {
                for o in occ where o.intersection(f).width > 1 && o.intersection(f).height > 1 {
                    XCTFail("\(tag): top bar '\(label)' \(f) under the occlusion \(o)", file: file, line: line)
                }
                XCTAssertGreaterThanOrEqual(f.minX + 1, Double(max(l.left, l.barLeft)) * l.ppl, "\(tag): '\(label)' in the rounded corner", file: file, line: line)
                XCTAssertLessThanOrEqual(f.maxX - 1, Double(l.w - max(l.right, l.barRight)) * l.ppl, "\(tag): '\(label)' in the rounded corner", file: file, line: line)
            }
            if topBar || popupOpen || f.minY >= keyTop - 1 {
                for d in div where d.intersection(f).width > 1 && d.intersection(f).height > 1 {
                    XCTFail("\(tag): '\(label)' \(f) on the fold \(d)", file: file, line: line)
                }
            }
        }
        XCTAssertFalse(app.staticTexts["Program ended. Restart from the menu."].exists, "\(tag): a program ended", file: file, line: line)
        ctl("shot \(tag)")
        return l
    }

    // MARK: app helpers

    private func launch(_ extra: [String] = [], lang: String = "en-US") {
        app.launchArguments = ["-uitest-reset", "-perflog", "-AppleLanguages", "(\(lang))"] + extra
        app.launch()
        XCTAssertTrue(view.waitForExistence(timeout: 30))
        settle()
    }

    /** Every test starts closed, in portrait, with a fresh app. */
    private func begin(_ extra: [String] = []) {
        ctl("closed")
        launch(extra)
        posture(.closedPortrait)
    }

    private func tapButton(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let b = app.buttons[label]
        var tries = 0
        while !b.exists && tries < 15 && app.buttons[scrollDown].exists { app.buttons[scrollDown].tap(); usleep(300_000); tries += 1 }
        XCTAssertTrue(b.waitForExistence(timeout: 8), "button '\(label)'", file: file, line: line)
        if b.exists { b.tap() }
        usleep(700_000)
    }

    private func startMenu() { tapButton("MENU") }

    /**
     * Closes an open menu with a tap outside it: at the right edge, half way down (the start menu and its
     * submenus open at the left; while a menu is open only its own items are accessibility elements).
     */
    private func dismissMenu() {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.985, dy: 0.5)).tap()
        usleep(600_000)
    }

    private func closeAllWindows() {
        for _ in 0..<8 {
            let c = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Close '")).firstMatch
            if !c.exists { break }
            c.tap(); usleep(700_000)
            let cancel = app.buttons.matching(NSPredicate(format: "label ==[c] 'cancel'")).firstMatch
            if cancel.exists { cancel.tap(); break }
        }
    }

    /** The highest CNT<n> the terminal shows (the counter loop below), or -1. */
    private func counter() -> Int {
        var best = -1
        for t in app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'CNT'")).allElementsBoundByIndex {
            let s = t.label
            var i = s.startIndex
            while let r = s.range(of: "CNT", range: i..<s.endIndex) {
                let digits = s[r.upperBound...].prefix { $0.isNumber }
                if let n = Int(digits) { best = max(best, n) }
                i = r.upperBound
            }
        }
        return best
    }

    /** Starts a HolyC loop in a new Terminal that prints CNT0, CNT1, ... four times a second. */
    private func startCounter() {
        startMenu(); tapButton("Terminal"); sleep(4)
        app.typeTempleText("I64 i;for(i=0;i<1000000;i++){\"CNT%d\\n\",i;Sleep(250);}\n")
        sleep(3)
        XCTAssertGreaterThanOrEqual(counter(), 0, "the counter loop runs")
    }

    /** kernel_frames of the focused program (perf line, -perflog), or -1. */
    private func kernelFrames() -> Int { Int(layout().perf["kernel_frames"] ?? "") ?? -1 }

    // MARK: D01-D10: every posture, the main screens

    /** D01-D05, D08-D10: desktop, start menu, a long submenu, About and Documentation in every posture. */
    func testD01_PostureMatrix() {
        begin()
        for p in Posture.allCases {
            guard posture(p) != nil else { continue }
            checkpoint("\(p.rawValue)-01-desktop")
            // XCUITest on the iOS 27.1 simulator does not deliver its taps to the Duo's outer display in
            // Landscape Left (camera top-left): element taps have no effect and the runner can hang (a host
            // click through DeviceHub did reach the app). The layout is still checked above.
            if p == .closedLeft { print("DUOLIMIT closed-landleft: taps skipped (XCUITest limitation)"); continue }
            startMenu()
            checkpoint("\(p.rawValue)-02-start-menu")
            tapButton("Games...")
            checkpoint("\(p.rawValue)-03-games-menu")
            dismissMenu()
            startMenu(); tapButton("About & Credits"); sleep(1)
            checkpoint("\(p.rawValue)-04-about")
            startMenu(); tapButton("Documentation"); sleep(2)
            checkpoint("\(p.rawValue)-05-documentation")
            startMenu(); tapButton("Language..."); sleep(1)
            checkpoint("\(p.rawValue)-06-language")
            closeAllWindows()
        }
    }

    // MARK: D06, D07, D11, D12, D27: transitions with menus open

    func testD11_MenusAcrossTransitions() {
        begin()
        let order: [Posture] = [.closedPortrait, .openWide, .closedPortrait, .book, .closedLeft, .tabletop, .openTall, .closedPortrait]
        startMenu(); tapButton("Examples...")
        for (i, p) in order.enumerated() {
            posture(p)
            XCTAssertTrue(app.buttons["Scroll menu down"].exists || app.buttons["Sound"].exists, "\(p.rawValue): the Examples menu is still open")
            checkpoint("menu-\(i)-\(p.rawValue)")
        }
        // the menu still works after all of it: its item opens a program
        tapButton("Sound")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Scale with'")).firstMatch.waitForExistence(timeout: 30), "Sound runs")
        closeAllWindows()
        // D27: dismissed and reopened in every posture, the menu opens where it belongs
        for p in [Posture.book, .tabletop, .closedRight] {
            posture(p)
            startMenu(); checkpoint("menu-reopen-\(p.rawValue)")
            dismissMenu()
            XCTAssertFalse(app.buttons["Terminal"].exists, "\(p.rawValue): the menu closed")
        }
    }

    // MARK: D13, D14, D15, D28: programs and the keyboard across transitions

    func testD13_TerminalAndKeyboardAcrossFolds() {
        begin()
        startCounter()
        tapButton("Control") // a latched modifier must survive the fold
        XCTAssertTrue(app.buttons["Control"].isSelected, "CTRL latched")
        var last = counter()
        for p in [Posture.openWide, .book, .tabletop, .openTall, .closedLeft, .closedPortrait] {
            posture(p)
            sleep(2)
            let n = counter()
            XCTAssertGreaterThan(n, last, "\(p.rawValue): the HolyC loop kept counting (\(last) -> \(n)): no restart")
            last = n
            XCTAssertTrue(app.buttons["Enter"].exists, "\(p.rawValue): the TempleOS keyboard stayed up")
            XCTAssertTrue(app.buttons["Control"].isSelected, "\(p.rawValue): CTRL still latched")
            let l = checkpoint("terminal-\(p.rawValue)")
            if p == .tabletop, let fold = l.div.first.map(l.pt) {
                XCTAssertGreaterThanOrEqual(app.buttons["Enter"].frame.minY, fold.maxY - 1, "tabletop: the keyboard is below the fold")
            }
        }
        tapButton("Control")
        XCTAssertFalse(app.buttons["Control"].isSelected)
    }

    /** D14, D15, D28: a game keeps running (kernel frames keep rising), keeps its 4:3 picture and its controls. */
    func testD14_GameAcrossFolds() {
        begin()
        startMenu(); tapButton("Games..."); tapButton("BomberGolf")
        let pic = app.staticTexts["Program picture: BomberGolf"]
        XCTAssertTrue(pic.waitForExistence(timeout: 30), "BomberGolf runs")
        sleep(3)
        var frames = kernelFrames()
        XCTAssertGreaterThan(frames, 0, "perf line: \(layout().perf)")
        for p in [Posture.openWide, .closedPortrait, .book, .tabletop, .openTall, .closedRight, .openWide] {
            posture(p)
            sleep(3)
            let f = kernelFrames()
            XCTAssertGreaterThan(f, frames, "\(p.rawValue): the same game kept running (\(frames) -> \(f))")
            frames = f
            XCTAssertTrue(pic.exists, "\(p.rawValue): the picture is there")
            let r = pic.frame
            XCTAssertEqual(r.width / max(1, r.height), 4.0 / 3.0, accuracy: 0.03, "\(p.rawValue): 640x480 not stretched (\(r))")
            let l = checkpoint("game-\(p.rawValue)")
            // a tap on the picture is a TempleOS mouse click: the game keeps running and the controls answer
            pic.tap(); usleep(500_000)
            XCTAssertFalse(app.staticTexts["Program ended. Restart from the menu."].exists)
            if p == .tabletop, let fold = l.div.first.map(l.pt) {
                XCTAssertLessThanOrEqual(r.maxY, fold.minY + 1, "tabletop: the picture is above the fold")
            }
        }
    }

    /** D16: Examples > Sound with a fold in the middle; the recording is checked on the host (run_duo_campaign.sh). */
    func testD16_SoundAcrossFold() {
        begin(["-soundcapture"])
        startMenu(); tapButton("Examples..."); tapButton("Sound")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Scale with'")).firstMatch.waitForExistence(timeout: 30))
        usleep(800_000)
        ctl("open") // unfold while it plays
        let done = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Done.'")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 60), "Sound finished")
        XCTAssertEqual(1, app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Close Sound'")).count, "one Sound window")
        checkpoint("sound-after-unfold")
        // leave: the engine idles and closes the recording for the host to pull
        XCUIDevice.shared.press(.home); sleep(4)
    }

    // MARK: D17, D18: documentation position and a dialog across transitions

    func testD17_DocumentationAndDialogAcrossFolds() {
        begin()
        startMenu(); tapButton("Documentation"); sleep(2)
        let w = app.windows.firstMatch
        w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).press(forDuration: 0.05, thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
        sleep(1)
        // the top line's words (lines rewrap at another width, the words stay)
        func words(_ labels: [String]) -> Set<String> { Set(labels.joined(separator: " ").split(separator: " ").map(String.init).filter { $0.count > 3 }) }
        let top = app.staticTexts.allElementsBoundByIndex.filter { $0.frame.minY > 60 }.min { $0.frame.minY < $1.frame.minY }?.label ?? ""
        let before = words([top])
        posture(.openWide); checkpoint("doc-open-wide")
        let after = words(app.staticTexts.allElementsBoundByIndex.prefix(80).map(\.label))
        XCTAssertGreaterThanOrEqual(Double(before.intersection(after).count), Double(before.count) * 0.6,
                                    "the documentation still shows where it was: \(before) in \(after.prefix(30))")
        posture(.closedPortrait); checkpoint("doc-closed-again")
        // D18: an unsaved editor's close dialog through folds
        closeAllWindows()
        startMenu(); tapButton("HolyC Editor"); sleep(2)
        for k in ["x", "y", "z"] { tapButton(k) } // TempleOS keyboard: the editor has unsaved text
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Close '")).firstMatch.tap(); sleep(1)
        let cancel = app.buttons.matching(NSPredicate(format: "label ==[c] 'cancel'")).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "the close-unsaved dialog")
        for p in [Posture.openWide, .book, .tabletop, .closedPortrait] {
            posture(p)
            XCTAssertTrue(cancel.exists, "\(p.rawValue): the dialog is still there")
            checkpoint("dialog-\(p.rawValue)")
        }
        cancel.tap(); sleep(1)
        XCTAssertFalse(cancel.exists, "the dialog closed")
    }

    // MARK: D22: repeated cycles

    /**
     * D22: CYCLES (default 20) times closed, open, tall, wide, book, open, tabletop, open, closed with the
     * terminal loop running and the TempleOS keyboard up; memory sampled every 5 cycles.
     */
    func testD22_RepeatedCycles() {
        let cycles = max(1, Int(ProcessInfo.processInfo.environment["DUO_CYCLES"] ?? "") ?? 20)
        begin()
        startCounter()
        var last = counter()
        print("DUOMEM cycle=0 \(ctl("mem").trimmingCharacters(in: .whitespacesAndNewlines))")
        let steps: [Posture] = [.openWide, .openTall, .openWide, .book, .openWide, .tabletop, .openTall, .closedPortrait]
        for c in 1...cycles {
            for p in steps {
                guard let l = posture(p) else { continue }
                XCTAssertTrue(app.buttons["Enter"].exists, "cycle \(c) \(p.rawValue): keyboard up")
                XCTAssertEqual(l.div.isEmpty, p != .book && p != .tabletop, "cycle \(c) \(p.rawValue): fold state")
            }
            sleep(1)
            let n = counter()
            XCTAssertGreaterThan(n, last, "cycle \(c): the HolyC loop kept counting (\(last) -> \(n))")
            last = n
            XCTAssertEqual(1, app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Close Terminal'")).count, "cycle \(c): one terminal")
            if c % 5 == 0 || c == 1 {
                checkpoint("cycle-\(c)")
                print("DUOMEM cycle=\(c) \(ctl("mem").trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
    }

    // MARK: D23: localized layouts across folds

    private func ui(_ lang: String, _ key: String) -> String {
        func load(_ c: String) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: Self.repo.appendingPathComponent("shared/runtime/l10n/\(c).json")))) as? [String: Any] ?? [:]
        }
        let base = lang.split(separator: "-").first.map(String.init) ?? lang
        let cat = ["zh-Hans", "zh-Hant", "pt-BR"].contains(lang) ? lang : base
        return (load(cat)[key] as? String) ?? (load("en")[key] as? String) ?? key
    }

    /**
     * D23: God Words' 10 WORDS (localized vocabulary) and the start menu in each language, closed, in book and
     * in tabletop posture. DUO_LANGS overrides the list (comma-separated).
     */
    func testD23_LanguagesAcrossFolds() {
        let given = ProcessInfo.processInfo.environment["DUO_LANGS"] ?? ""
        let langs = (given.isEmpty ? "en-US,es-ES,de-DE,fr-FR,ar,he-IL,ja-JP,zh-Hans,ko-KR,hi-IN,fi-FI,th,my-MM" : given)
            .split(separator: ",").map(String.init)
        ctl("closed")
        for lang in langs {
            launch(lang: lang)
            scrollDown = ui(lang, "a11y.scroll_menu_down")
            let menu = ui(lang, "topbar.menu")
            for p in [Posture.closedPortrait, .book, .tabletop] {
                posture(p)
                tapButton(app.buttons[menu].exists ? menu : "MENU"); tapButton(ui(lang, "menu.start.god_words")); sleep(1)
                tapButton(ui(lang, "god.button.ten_words")); sleep(1)
                checkpoint("lang-\(lang)-\(p.rawValue)-godwords")
                tapButton(menu); checkpoint("lang-\(lang)-\(p.rawValue)-menu")
                dismissMenu()
            }
            app.terminate()
        }
    }

    // MARK: D24, D26: background, rotation and fold combinations

    func testD24_BackgroundChangePostureForeground() {
        begin()
        startMenu(); tapButton("Games..."); tapButton("CharDemo")
        let pic = app.staticTexts["Program picture: CharDemo"]
        XCTAssertTrue(pic.waitForExistence(timeout: 30))
        sleep(2)
        let frames = kernelFrames()
        XCUIDevice.shared.press(.home); sleep(2)
        ctl("open")
        app.activate(); sleep(3)
        let l = posture(.openWide)
        XCTAssertNotNil(l)
        XCTAssertTrue(pic.waitForExistence(timeout: 10), "the game is back")
        sleep(2)
        XCTAssertGreaterThan(kernelFrames(), frames, "the same game continues after the background")
        checkpoint("background-then-open")
        XCUIDevice.shared.press(.home); sleep(2)
        ctl("partial")
        app.activate(); sleep(3)
        posture(.tabletop)
        checkpoint("background-then-tabletop")
    }

    func testD26_RotationAndFoldCombinations() {
        begin()
        startMenu(); tapButton("Terminal"); sleep(3)
        for (i, p) in [Posture.closedLeft, .openWide, .closedRight, .book, .closedPortrait, .tabletop, .openTall, .closedLeft, .openWide, .closedPortrait].enumerated() {
            posture(p)
            checkpoint("combo-\(i)-\(p.rawValue)")
        }
        // D26: four Rotate Right presses on the open display bring it back to the start without stale layout
        posture(.openWide)
        let start = layout()
        for k in 1...4 { ctl("rotright"); let l = settle(); XCTAssertNotNil(l, "rotation \(k) settles") }
        let end = settle() ?? layout()
        XCTAssertEqual(start.w, end.w); XCTAssertEqual(start.h, end.h)
        checkpoint("combo-after-four-rotations")
    }

    // MARK: keyboard lifecycle across close/open cycles (docs/foldable/KEYBOARD_LIFECYCLE.md)

    /** Waits until the lit display is the outer (closed) or inner one and the layout holds still. */
    @discardableResult private func foldTo(_ closed: Bool) -> Layout? {
        ctl(closed ? "closed" : "open")
        return settle(timeout: 20) { closed ? !$0.inner : $0.inner }
    }

    /**
     * DUO_KB_CYCLES (default 40) close/open cycles with the TempleOS keyboard up and no input at all: the keyboard's
     * visibility must not change (no transition, so no unexplained dismissal and no back action), the terminal
     * session stays. Then, with input: the same HolyC session answers through the TempleOS keyboard, an explicit
     * dismissal survives more folds, and the key row brings the keyboard back. One line per cycle: DUOCYCLE.
     */
    func testD30_KeyboardAcrossCloseOpenCycles() {
        let cycles = max(1, Int(ProcessInfo.processInfo.environment["DUO_KB_CYCLES"] ?? "") ?? 40)
        begin()
        startMenu(); tapButton("Terminal"); sleep(4)
        for k in ["6", "Shift", "asterisk", "7", "semicolon", "Enter"] { tapButton(k) } // 6*7;
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "=42")).firstMatch.waitForExistence(timeout: 15))
        sleep(1)
        let start = layout()
        XCTAssertTrue(start.kb, "the TempleOS keyboard is up (\(start.kbWhy))")
        var seq = start.kbSeq, failures = 0
        // phase 1: no input
        for c in 1...cycles {
            let before = layout()
            let afterClose = foldTo(true) ?? layout()
            let afterOpen = foldTo(false) ?? layout()
            let terminals = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Close Terminal'")).count
            let ended = app.staticTexts["Program ended. Restart from the menu."].exists
            let changed = afterOpen.kbSeq != seq
            print("DUOCYCLE n=\(c) beforeClose=\(before.kb ? 1 : 0) afterClose=\(afterClose.kb ? 1 : 0) afterOpen=\(afterOpen.kb ? 1 : 0) transitions=\(afterOpen.kbSeq - seq) lastReason=\(afterOpen.kbWhy) back=\(afterOpen.kbWhy == "back" ? 1 : 0) terminal=\(terminals) programEnded=\(ended ? 1 : 0)")
            if !afterClose.kb || !afterOpen.kb || changed || terminals != 1 || ended { failures += 1 }
            XCTAssertTrue(afterClose.kb && afterOpen.kb, "cycle \(c): the keyboard stayed up (closed \(afterClose.kb), open \(afterOpen.kb), reason \(afterOpen.kbWhy))")
            XCTAssertFalse(changed, "cycle \(c): no keyboard transition without input (\(afterOpen.kbWhy))")
            XCTAssertEqual(1, terminals, "cycle \(c): the terminal is there"); XCTAssertFalse(ended, "cycle \(c)")
            seq = afterOpen.kbSeq
            if c == 1 || c == cycles { checkpoint("kb-cycle-\(c)-open") }
        }
        print("DUOKB phase1 cycles=\(cycles) failures=\(failures)")
        // phase 2: the same terminal session (its earlier answer still in its output) takes TempleOS keyboard input
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "=42")).firstMatch.exists,
                      "the terminal's output from before the cycles is still there: the same session")
        for k in ["3", "Shift", "asterisk", "5", "semicolon", "Enter"] { tapButton(k) } // 3*5;
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "=15")).firstMatch.waitForExistence(timeout: 15),
                      "the TempleOS keyboard still types into the running terminal after the cycles")
        checkpoint("kb-after-cycles-typed")
        // an explicit dismissal is respected through folds; the key row brings it back
        tapButton("Hide keyboard")
        XCTAssertEqual(layout().kbWhy, "user-hide")
        for _ in 0..<3 { foldTo(true); foldTo(false) }
        XCTAssertFalse(layout().kb, "a dismissed keyboard stays dismissed after folding")
        tapButton("Show or hide keyboard")
        XCTAssertTrue(layout().kb); XCTAssertEqual(layout().kbWhy, "user-show")
        checkpoint("kb-reshown")
    }
}

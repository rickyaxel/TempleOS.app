import Compression
import XCTest
import UIKit

/**
 * End-to-end UI test of the iOS app, following the acceptance flow: desktop,
 * terminal command, rotation, editor save + run, a game, relaunch with
 * session restore. The desktop is one custom view, so taps use TempleOS
 * logical-pixel coordinates converted with the layout the view publishes in
 * its accessibility value. Screenshots are attached to the test result and,
 * when TEMPLEOS_SHOTS is set (TEST_RUNNER_TEMPLEOS_SHOTS for xcodebuild),
 * also written there as PNG files.
 */
final class TempleOSMobileUITests: XCTestCase {
    private var app: XCUIApplication!
    private var ppl = 1.0, top = 0.0, left = 0.0, bottom = 0.0

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() {
        if app?.state == .runningForeground { app.assertTempleInputInvariant() }
        super.tearDown()
    }

    private func readLayout() {
        let v = app.descendants(matching: .any)["templeView"]
        XCTAssertTrue(v.waitForExistence(timeout: 20))
        let s = (v.value as? String) ?? ""
        for kv in s.split(separator: ";") {
            let p = kv.split(separator: "=")
            guard p.count == 2, let d = Double(p[1]) else { continue }
            switch p[0] { case "pointsPerLogical": ppl = d; case "top": top = d; case "left": left = d; case "bottom": bottom = d; default: break }
        }
    }

    /** Taps at TempleOS logical coordinates (x from the left inset, y below the safe-area top). */
    private func tap(_ x: Double, _ y: Double) {
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        origin.withOffset(CGVector(dx: (left + x) * ppl, dy: (top + y) * ppl)).tap()
        sleep(1)
    }

    private var shotDirectory: URL? {
        guard let dir = ProcessInfo.processInfo.environment["TEMPLEOS_SHOTS"] else { return nil }
        // Physical runners cannot write a Mac path. Export their own Documents
        // directory with devicectl after the run; simulator paths still work.
        let output = dir == "documents"
            ? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("TempleOSScreenshots", isDirectory: true)
            : URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        return output
    }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        if let output = shotDirectory {
            try? s.pngRepresentation.write(to: output.appendingPathComponent("\(name).png"))
            let state=app.descendants(matching:.any)["templeView"].value as? String ?? ""
            try? state.write(to:output.appendingPathComponent("\(name)-layout.txt"),atomically:true,encoding:.utf8)
        }
    }

    private func backgroundApp() {
        // A program may defer the first system gesture. Verify the transition,
        // rather than treating a requested Home action as proof of backgrounding.
        for _ in 0..<2 {
            XCUIDevice.shared.press(.home)
            let end = Date().addingTimeInterval(2)
            while app.state == .runningForeground && Date() < end { usleep(100_000) }
            if app.state == .runningBackground || app.state == .runningBackgroundSuspended { return }
        }
        XCTFail("Home did not background the app; actual state: \(app.state.rawValue)")
    }

    /** Taps the first dialog item: the shell draws dialog items on LTCYAN (0x55FFFF). */
    @discardableResult private func tapDialogItem() -> Bool {
        guard let cg = XCUIScreen.main.screenshot().image.cgImage else { return false }
        let w = cg.width, h = cg.height
        guard let data = cg.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return false }
        let bpr = cg.bytesPerRow, bpp = cg.bitsPerPixel / 8
        let x = w / 2
        for y in stride(from: h / 8, to: h, by: 2) {
            let o = y * bpr + x * bpp
            // BGRA or RGBA: cyan has a low red/blue-swapped channel and two high ones
            let c = (p[o], p[o + 1], p[o + 2])
            let isCyan = (c.0 == 0xFF && c.1 == 0xFF && c.2 == 0x55) || (c.0 == 0x55 && c.1 == 0xFF && c.2 == 0xFF)
            if isCyan {
                let scale = Double(w) / Double(app.windows.firstMatch.frame.width)
                app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: Double(x) / scale, dy: Double(y + 6) / scale)).tap()
                return true
            }
        }
        return false
    }

    /**
     * Taps a menu item by its label (menus are sized by MenuMetrics, so never by coordinates); an item
     * below the visible rows is scrolled to with the menu's "Scroll menu down" row.
     */
    private func menuItem(_ label: String, locale: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let plain = label.replacingOccurrences(of: " (partial)", with: "")
        let b = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", label, plain)).firstMatch
        let down = locale.map { ui($0, "a11y.scroll_menu_down") } ?? "Scroll menu down"
        let more = locale.map { ui($0, "games.catalog") } ?? "More programs"
        func scrollToItem() {
            var tries = 0
            while !b.exists && tries < 20 && app.buttons[down].exists {
                app.buttons[down].tap(); usleep(200_000); tries += 1
            }
        }
        scrollToItem()
        if !b.exists && app.buttons[more].exists { app.buttons[more].tap(); scrollToItem() }
        XCTAssertTrue(b.waitForExistence(timeout: 5), "menu item '\(label)'", file: file, line: line)
        b.tap(); usleep(500_000)
    }

    /** A system notification can cover the top bar. Wait without reading or dismissing its contents. */
    private func waitForSystemBanner() {
        let banner = XCUIApplication(bundleIdentifier: "com.apple.springboard").descendants(matching: .any)["NotificationShortLookView"].firstMatch
        let end = Date().addingTimeInterval(30)
        while banner.exists && Date() < end { usleep(500_000) }
        XCTAssertFalse(banner.exists, "system banner still covers application controls")
        if app.state != .runningForeground { app.activate() }
    }

    private func startMenu() {
        waitForSystemBanner()
        let m = app.buttons["MENU"]; XCTAssertTrue(m.waitForExistence(timeout: 10)); m.tap(); usleep(500_000)
    }

    /** The window menu button of the focused window titled [title] (its title may carry a state suffix). */
    private func windowMenu(_ title: String) {
        let b = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Window menu: \(title)")).firstMatch
        XCTAssertTrue(b.waitForExistence(timeout: 5), "window menu of \(title)"); b.tap(); usleep(500_000)
    }

    /** Software input always uses the app-owned keyboard. */
    private func useTempleKeyboard() {
        if !app.buttons["Hide keyboard"].exists, app.buttons["Show or hide keyboard"].exists {
            app.buttons["Show or hide keyboard"].tap()
        }
        XCTAssertTrue(app.buttons["Hide keyboard"].waitForExistence(timeout: 10))
        app.assertTempleInputInvariant()
    }

    /** Taps a TempleOS keyboard key through its accessibility element. */
    private func key(_ label: String) {
        let b = app.buttons[label]
        XCTAssertTrue(b.waitForExistence(timeout: 5), "key '\(label)'")
        b.tap()
    }

    /**
     * Most common color (0xRRGGBB) of the screenshot pixels in [x0, x1) x [y0, y1), leaving out the
     * middle third along the edge (where the home indicator is drawn).
     */
    private func modeColor(_ cg: CGImage, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, alongX: Bool) -> UInt32 {
        guard let data = cg.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return 0 }
        let bpr = cg.bytesPerRow, bpp = cg.bitsPerPixel / 8
        let bgra = cg.bitmapInfo.contains(.byteOrder32Little)
        var n: [UInt32: Int] = [:]
        for y in max(0, y0)..<min(cg.height, y1) {
            if !alongX && y > cg.height / 3 && y < 2 * cg.height / 3 { continue }
            for x in max(0, x0)..<min(cg.width, x1) {
                if alongX && x > cg.width / 3 && x < 2 * cg.width / 3 { continue }
                let o = y * bpr + x * bpp
                let (r, g, b) = bgra ? (p[o + 2], p[o + 1], p[o]) : (p[o], p[o + 1], p[o + 2])
                n[UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b), default: 0] += 1
            }
        }
        return n.max { $0.value < $1.value }?.key ?? 0
    }

    /**
     * The region under the home indicator (the bottom safe area) has the color of the TempleOS surface
     * right above it (SystemChrome): no strip of another color, no black. Attaches the screenshot.
     * Screenshots keep the portrait pixel layout: in landscape-left the app's bottom edge is the image's
     * left side, in landscape-right its right side.
     */
    private func assertBottomContinuity(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        usleep(700_000)
        readLayout()
        shot("chrome-\(name)")
        guard let cg = XCUIScreen.main.screenshot().image.cgImage else { return XCTFail("no screenshot") }
        let o = XCUIDevice.shared.orientation
        let landscape = o == .landscapeLeft || o == .landscapeRight
        let shortSide = Double(min(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height))
        let scale = Double(cg.width) / shortSide
        let inset = Int((bottom * ppl * scale).rounded())
        app.assertTempleInputInvariant(file: file, line: line)
        XCTAssertGreaterThanOrEqual(inset, 0, "\(name): nonnegative bottom safe area", file: file, line: line)
        // Home-button iPhones legitimately have no home-indicator region to compare.
        if inset == 0 { print("CHROME \(name) no bottom safe area on this device"); return }
        let w = cg.width, h = cg.height
        let under: UInt32, above: UInt32
        if !landscape {
            under = modeColor(cg, 0, h - inset + 2, w, h, alongX: true)
            above = modeColor(cg, 0, h - inset - 3, w, h - inset, alongX: true)
        } else if o == .landscapeLeft {
            under = modeColor(cg, 0, 0, inset - 2, h, alongX: false)
            above = modeColor(cg, inset, 0, inset + 3, h, alongX: false)
        } else {
            under = modeColor(cg, w - inset + 2, 0, w, h, alongX: false)
            above = modeColor(cg, w - inset - 3, 0, w - inset, h, alongX: false)
        }
        print("CHROME \(name) under=\(String(under, radix: 16)) above=\(String(above, radix: 16)) insetPx=\(inset)")
        XCTAssertEqual(String(under, radix: 16), String(above, radix: 16), "\(name): home-indicator region continues the surface above it", file: file, line: line)
    }

    /**
     * SystemChrome on iOS: the home-indicator region follows the active screen through navigation,
     * menus, the keyboards, a game, rotation and background/foreground (docs/ui-normalization/SYSTEM_CHROME.md).
     * Screenshots: attachments "chrome-*" (and TEMPLEOS_SHOTS).
     */
    func testSystemChromeFollowsTheScreen() throws {
        app.launchArguments = ["-uitest-reset", "-AppleLanguages", "(en-US)"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        readLayout(); sleep(2)
        assertBottomContinuity("01-welcome-doc")
        startMenu()
        assertBottomContinuity("02-start-menu")
        menuItem("Terminal"); sleep(1)
        assertBottomContinuity("03-terminal-templeos-keyboard")
        key("Hide keyboard")
        assertBottomContinuity("04-terminal-key-row")
        app.buttons["Close Terminal"].tap()
        assertBottomContinuity("05-terminal-closed")
        startMenu(); menuItem("Documentation"); sleep(1)
        assertBottomContinuity("06-documentation")
        startMenu(); menuItem("Games..."); menuItem("CharDemo"); sleep(4)
        assertBottomContinuity("07-game")
        XCUIDevice.shared.orientation = .landscapeLeft; sleep(2)
        assertBottomContinuity("08-game-landscape")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Close CharDemo")).firstMatch.tap()
        assertBottomContinuity("09-landscape-game-closed")
        XCUIDevice.shared.orientation = .portrait; sleep(2)
        assertBottomContinuity("10-portrait-again")
        XCUIDevice.shared.press(.home); sleep(2)
        app.activate(); sleep(2)
        assertBottomContinuity("11-background-resume")
        startMenu(); menuItem("Terminal"); sleep(1)
        useTempleKeyboard()
        app.assertTempleInputInvariant()
        assertBottomContinuity("12-templeos-keyboard")
        key("Hide keyboard"); key("Show or hide keyboard")
        assertBottomContinuity("13-reopened-templeos-keyboard")
    }

    /// Mobile wrapper regression only: this is not historical SpriteMainEd engine parity.
    /// Runs without resetting the installed app's data.
    func testPaintRestorationWorkflow() throws {
        app.launchArguments = ["-AppleLanguages", "(en-US)"]
        let paintPath = "P\(UUID().uuidString.prefix(8)).GR"
        let replacePath = String(repeating: XCUIKeyboardKey.delete.rawValue, count: "C:/Home/Picture.GR".count) + paintPath + "\n"
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        readLayout()
        startMenu(); menuItem("Paint")
        let picture = app.staticTexts["Program picture: Paint"]
        XCTAssertTrue(picture.waitForExistence(timeout: 10))
        shot("paint-01-initial")

        func coloredPixels() -> Int {
            let screenshot = XCUIScreen.main.screenshot()
            guard let cg = screenshot.image.cgImage else { return 0 }
            let scale = Double(cg.width) / Double(app.windows.firstMatch.frame.width)
            let box = picture.frame.insetBy(dx: 4, dy: 4)
            guard let crop = cg.cropping(to: CGRect(x: box.minX * scale, y: box.minY * scale,
                width: box.width * scale, height: box.height * scale)),
                let data = crop.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return 0 }
            let bpp = crop.bitsPerPixel / 8
            var count = 0
            for y in 0..<crop.height { for x in 0..<crop.width {
                let o = y * crop.bytesPerRow + x * bpp
                // White canvas: all RGB channels are 255, regardless of RGBA/BGRA byte order.
                if p[o] < 250 || p[o+1] < 250 || p[o+2] < 250 { count += 1 }
            } }
            return count
        }
        let initial = coloredPixels()
        app.buttons["Tool PEN"].tap(); app.buttons["Color Red"].tap()
        picture.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: picture.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.7)))
        usleep(500_000)
        XCTAssertGreaterThan(coloredPixels(), initial + 30, "drag must visibly mutate the canvas")
        shot("paint-02-drawn")
        windowMenu("Paint"); menuItem("Save as...")
        // Use a fresh virtual filename so reruns cannot overwrite existing artwork.
        app.typeTempleText(replacePath); sleep(1)
        shot("paint-03-saved")
        XCUIDevice.shared.orientation = .landscapeLeft; sleep(1); readLayout()
        XCTAssertTrue(picture.exists); shot("paint-04-landscape")
        XCUIDevice.shared.press(.home); sleep(1); app.activate(); sleep(1)
        XCTAssertTrue(picture.exists)
        XCUIDevice.shared.orientation = .portrait; sleep(1); readLayout()
        let filename = String(paintPath.split(separator: "/").last!)
        let closeSaved = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Close Paint " + filename)).firstMatch
        XCTAssertTrue(closeSaved.exists); closeSaved.tap(); sleep(1)
        XCTAssertFalse(closeSaved.exists, "the saved window closed; older Paint windows may remain")
        startMenu(); menuItem("Paint")
        XCTAssertTrue(picture.waitForExistence(timeout: 10))
        windowMenu("Paint"); menuItem("Open file...")
        app.typeTempleText(replacePath); sleep(1)
        XCTAssertTrue(picture.exists)
        XCTAssertGreaterThan(coloredPixels(), initial + 30, "saved strokes must survive reopen")
        shot("paint-05-reloaded")
        app.assertTempleInputInvariant()
    }

    func testAcceptanceFlow() throws {
        app.launchArguments = ["-uitest-reset"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        readLayout()
        sleep(2)
        shot("01-first-launch-welcome")

        // Terminal: Dir and an expression
        startMenu(); shot("02-start-menu")
        menuItem("Terminal"); sleep(4)
        useTempleKeyboard()
        app.typeTempleText("Dir;\n"); sleep(2)
        app.typeTempleText("\"6*7=%d\\n\",6*7;\n"); sleep(2)
        shot("03-terminal")

        // Rotation keeps everything running
        XCUIDevice.shared.orientation = .landscapeLeft; sleep(2); readLayout()
        shot("04-landscape")
        XCUIDevice.shared.orientation = .portrait; sleep(2); readLayout()

        // Editor: the new-file template, save as C:/Home/MyTest.HC, run it
        startMenu(); menuItem("HolyC Editor"); sleep(2)
        app.typeTempleText("\"Edited on iOS\\n\";\n"); sleep(1)
        app.buttons["SAVE"].tap()       // new file -> Save as dialog
        sleep(1)
        let del = String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40)
        app.typeTempleText(del + "C:/Home/MyTest.HC\n"); sleep(2)
        shot("05-editor-saved")
        app.buttons["RUN"].tap(); sleep(5)
        shot("06-editor-run-output")

        // A game from the Games menu: pause and resume it from its window menu
        startMenu(); shot("07a-start-menu")
        menuItem("Games..."); shot("07b-games-menu")
        menuItem("BattleLines"); sleep(12)
        shot("07c-battlelines-popup")
        XCTAssertTrue(tapDialogItem(), "the game's PopUp shows an OKAY item")
        sleep(4)
        // drag across the battlefield (mouse with the left button held)
        let w = app.windows.firstMatch
        let from = w.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: (left + 60) * ppl, dy: (top + 150) * ppl))
        let to = w.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: (left + 300) * ppl, dy: (top + 200) * ppl))
        from.press(forDuration: 0.1, thenDragTo: to)
        sleep(2)
        shot("08-battlelines-playing")
        // window menu -> Pause, then Resume
        windowMenu("BattleLines"); shot("08a-window-menu")
        menuItem("Pause"); sleep(2); shot("08b-paused")
        windowMenu("BattleLines"); menuItem("Resume"); sleep(2); shot("08c-resumed")

        // Relaunch: session and saved file come back
        app.terminate()
        app.launchArguments = []
        app.launch()
        readLayout(); sleep(6)
        shot("09-relaunch-restored")
    }

    /** Frame-rate readout for two heavy games (screenshots show "NN FPS" under the frame). */
    func testFrameRates() throws {
        app.launchArguments = ["-uitest-reset"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        readLayout(); sleep(2)
        startMenu(); menuItem("Games..."); menuItem("BattleLines"); sleep(10)
        tapDialogItem(); sleep(2)
        windowMenu("BattleLines"); menuItem("Show frame rate"); sleep(15)
        shot("fps-battlelines")
        // Varoom (BattleLines is paused while hidden)
        startMenu(); menuItem("Games..."); menuItem("Varoom"); sleep(10)
        windowMenu("Varoom"); menuItem("Show frame rate"); sleep(15)
        shot("fps-varoom")
    }

    /**
     * The responsive menu layer on the real iOS layout (docs/ui-normalization/TEMPLEOS_RESPONSIVE_MENU_UI.md):
     * menu rows and the MENU button measured in points from their accessibility frames, in portrait and
     * landscape; a long submenu (Games) with its back row and scrolling; a game opened from it; its window
     * menu kept open through a rotation; and a tap outside that closes the menu without ending the game.
     * Measurements: attachment "menu-sizing.json" (and TEMPLEOS_SHOTS).
     */
    func testMenuSizing() throws {
        app.launchArguments = ["-uitest-reset", "-perflog", "-AppleLanguages", "(en-US)"]
        app.launch()
        var report: [String] = []
        for (name, o) in [("portrait", UIDeviceOrientation.portrait), ("landscape", UIDeviceOrientation.landscapeLeft)] {
            XCUIDevice.shared.orientation = o; sleep(2); readLayout()
            let menu = app.buttons["MENU"]
            XCTAssertTrue(menu.waitForExistence(timeout: 10))
            let menuFrame = menu.frame // read before opening: an open menu is modal (only its rows are exposed)
            XCTAssertGreaterThanOrEqual(menuFrame.height, name == "portrait" ? 39.5 : 29.5, "\(name): MENU \(menuFrame)")
            startMenu()
            let terminal = app.buttons["Terminal"], about = app.buttons["About & Credits"]
            XCTAssertTrue(terminal.waitForExistence(timeout: 5), name)
            let win = app.windows.firstMatch.frame
            for b in [terminal, about] {
                XCTAssertGreaterThanOrEqual(b.frame.height, name == "portrait" ? 43.5 : 33.5, "\(name): \(b.label) \(b.frame)")
                XCTAssertTrue(win.contains(b.frame), "\(name): \(b.label) \(b.frame) on screen \(win)")
            }
            report.append("{\"orientation\": \"\(name)\", \"menuButtonPt\": [\(menuFrame.width), \(menuFrame.height)], \"rowPt\": [\(terminal.frame.width), \(terminal.frame.height)], \"pointsPerLogical\": \(ppl)}")
            shot("menu-\(name)-start")
            menuItem("Games...")
            XCTAssertTrue(app.buttons["More programs"].exists, "\(name): native Games gallery")
            shot("menu-\(name)-games")
            app.buttons["More programs"].tap()
            menuItem("Zing") // supplementary original program, reached by scrolling
            let pic = app.staticTexts["Program picture: Zing"]
            XCTAssertTrue(pic.waitForExistence(timeout: 30), "\(name): Zing opened from the menu")
            sleep(2)
            windowMenu("Zing")
            XCTAssertTrue(app.buttons["Pause"].exists, "\(name): window menu")
            shot("menu-\(name)-window-menu")
            XCUIDevice.shared.orientation = name == "portrait" ? .landscapeLeft : .portrait; sleep(2)
            XCTAssertTrue(app.buttons["Pause"].exists, "the menu stays open through a rotation")
            XCTAssertTrue(app.windows.firstMatch.frame.contains(app.buttons["Pause"].frame), "and is laid out on screen")
            shot("menu-\(name)-window-menu-rotated")
            XCUIDevice.shared.orientation = o; sleep(2)
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: name == "portrait" ? 0.88 : 0.8)).tap(); sleep(1) // beside the menu, clear of the home indicator
            XCTAssertFalse(app.buttons["Pause"].exists, "a tap outside closes the menu")
            XCTAssertFalse(app.staticTexts["Program ended. Restart from the menu."].exists, "\(name): dismissing the menu did not end the program")
            XCTAssertTrue(pic.exists)
            app.buttons["Close Zing"].tap(); sleep(2)
        }
        let json = "[" + report.joined(separator: ", ") + "]"
        let a = XCTAttachment(string: json); a.name = "menu-sizing.json"; a.lifetime = .keepAlways; add(a)
        if let output = shotDirectory {
            try? json.write(to: output.appendingPathComponent("menu-sizing.json"), atomically: true, encoding: .utf8)
        }
        print("MENU-SIZING " + json)
        XCUIDevice.shared.orientation = .portrait
    }

    /**
     * Performance run (docs/performance): launches with -perflog, opens a program from the start menu
     * and plays it by tapping its buttons on a fixed schedule while reading the app's one-per-second perf
     * line (ProgramApp.perfLine) from the view. TEMPLEOS_PERF_PROGRAM (default BomberGolf),
     * TEMPLEOS_PERF_MENU (Games...), TEMPLEOS_PERF_SECONDS (20), TEMPLEOS_PERF_TAPS (comma separated
     * button labels), TEMPLEOS_PERF_LANDSCAPE=1. Results: attachment "perf-<program>.json" and, with
     * TEMPLEOS_SHOTS, that file. The time each tap takes is recorded too: XCUITest waits for the app
     * to be idle, so a flooded main thread shows up there.
     */
    /**
     * A program with the debug sound capture (default Examples > Sound): it plays and, for Sound, prints Done.
     * The recording (Documents/sound-capture.wav, closed when the engine idles) is pulled and checked by
     * tools/audio/check_ios_sound.sh (tools/audio/analyze_capture.py). Other programs:
     * TEMPLEOS_SOUND_PROGRAM, TEMPLEOS_SOUND_MENU, TEMPLEOS_SOUND_TAPS (button labels), TEMPLEOS_SOUND_SECONDS.
     */
    func testWaterFowlAudioCapture() throws {
        let engine = ProcessInfo.processInfo.environment["TEMPLEOS_GAMES_ENGINE"] ?? "terry"
        app.launchArguments = ["-uitest-reset", "-soundcapture", "-engine", engine, "-AppleLanguages", "(en-US)"]
        XCUIDevice.shared.orientation = .portrait
        app.launch(); readLayout(); sleep(2)
        startMenu(); menuItem("Games..."); app.buttons["More programs"].tap(); menuItem("WaterFowl")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label BEGINSWITH %@", "Program picture: WaterFowl")).firstMatch.waitForExistence(timeout:30))
        sleep(7); shot("waterfowl-audio-\(engine)")
        app.assertTempleInputInvariant()
        app.buttons["Space"].tap()
        sleep(3) // capture the program's silence before the platform engine idles
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label CONTAINS[c] %@", "ended")).firstMatch.exists)
        XCUIDevice.shared.press(.home); sleep(3)
    }

    /** Preservation integration: real bundled sources and independent engines in the simulator. */
    func testGamesPreservation() throws {
        for engine in ["terry", "native"] {
            app.terminate()
            app.launchArguments = ["-uitest-reset", "-soundcapture", "-engine", engine, "-AppleLanguages", "(en-US)"]
            XCUIDevice.shared.orientation = .portrait
            app.launch(); readLayout(); sleep(2)
            startMenu(); menuItem("Games...")
            XCTAssertTrue(app.buttons["Original menu"].waitForExistence(timeout: 10))
            shot("games-\(engine)-portrait")
            XCUIDevice.shared.orientation = .landscapeLeft; sleep(2)
            shot("games-\(engine)-landscape")
            XCUIDevice.shared.orientation = .portrait; sleep(2)
            app.buttons["More programs"].tap()
            menuItem("WaterFowl")
            let pic = app.staticTexts.matching(NSPredicate(format:"label BEGINSWITH %@", "Program picture: WaterFowl")).firstMatch
            XCTAssertTrue(pic.waitForExistence(timeout: 30))
            sleep(4); shot("waterfowl-\(engine)-portrait")
            if engine == "native" {
                XCTAssertTrue(app.buttons.matching(NSPredicate(format:"label CONTAINS %@", "WaterFowl · Pure Swift")).firstMatch.exists)
            }
            app.assertTempleInputInvariant()
            XCUIDevice.shared.orientation = .landscapeLeft; sleep(3)
            XCTAssertTrue(pic.exists); shot("waterfowl-\(engine)-landscape")
            XCUIDevice.shared.press(.home); sleep(2); app.activate(); sleep(2)
            XCUIDevice.shared.orientation = .portrait; sleep(2)
            key("Space"); sleep(2)
            XCTAssertTrue(app.buttons.matching(NSPredicate(format:"label CONTAINS %@", "(ended)")).firstMatch.waitForExistence(timeout:10))
            shot("waterfowl-\(engine)-ended")
            let close = app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@", "Close WaterFowl")).firstMatch
            XCTAssertTrue(close.exists); close.tap(); sleep(2)
            XCTAssertTrue(app.buttons["More programs"].exists)
            menuItem("WaterFowl"); XCTAssertTrue(pic.waitForExistence(timeout: 30)); sleep(3)
            shot("waterfowl-\(engine)-reopened")
            app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@", "Close WaterFowl")).firstMatch.tap()
            app.assertTempleInputInvariant()
            XCUIDevice.shared.press(.home); sleep(3)
        }
    }

    /** Source-only restoration: actual historical entries, engines, custom input, rotation and reopening. */
    func testInterfaceRotation() throws {
        app.launchArguments=["-uitest-reset","-AppleLanguages","(en-US)"]
        XCUIDevice.shared.orientation = .portrait;app.launch();readLayout();sleep(2)
        XCTAssertLessThan(app.frame.width,app.frame.height)
        XCUIDevice.shared.orientation = .landscapeLeft;sleep(3)
        XCTAssertGreaterThan(app.frame.width,app.frame.height,"actual interface must rotate; device orientation alone is insufficient")
        shot("simulator-landscape-verified")
        XCUIDevice.shared.orientation = .portrait;sleep(2)
        XCTAssertLessThan(app.frame.width,app.frame.height)
    }

    /** Central MENU, original gallery, typed groups and contextual menus on iOS. */
    func testDistributionMenuSystem() throws {
        let copy=["TempleOS.app","Tap MENU to begin.","TempleOS by Terry A. Davis","Mobile adaptation by Ricky Axel"]
        func close(_ title:String) {
            let button=app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@","Close "+title)).firstMatch
            XCTAssertTrue(button.waitForExistence(timeout:10));button.tap();usleep(300_000)
        }
        for engine in ["terry","native"] {
            app.terminate();app.launchArguments=["-uitest-reset","-perflog","-engine",engine,"-AppleLanguages","(en-US)"]
            XCUIDevice.shared.orientation = .portrait;app.launch();readLayout()
            for line in copy {XCTAssertTrue(app.staticTexts[line].waitForExistence(timeout:10),line)}
            shot("distribution-intro-\(engine)-portrait")
            XCUIDevice.shared.orientation = .landscapeLeft;usleep(500_000)
            for line in copy {XCTAssertTrue(app.staticTexts[line].exists,line)}
            shot("distribution-intro-\(engine)-landscape")
            XCUIDevice.shared.orientation = .portrait;usleep(500_000)
            startMenu();shot("distribution-main-menu-\(engine)");menuItem("Games...")
            var seen=Set<String>()
            let groups=["Fun Games","Unfun Games","Code Scraps","Nongames"]
            for i in 0..<6 {
                for group in groups where app.staticTexts[group].exists {seen.insert(group)}
                shot("distribution-games-\(engine)-\(i)")
                app.buttons["Scroll menu down"].tap();usleep(200_000)
            }
            XCTAssertEqual(seen,Set(groups))
            for _ in 0..<6 {app.buttons["Scroll menu up"].tap()}
            app.buttons["More programs"].tap();menuItem("WaterFowl")
            let picture=app.staticTexts.matching(NSPredicate(format:"label BEGINSWITH %@","Program picture: WaterFowl")).firstMatch
            XCTAssertTrue(picture.waitForExistence(timeout:30));sleep(2)
            shot("distribution-waterfowl-\(engine)-animated")
            if engine=="native" {XCTAssertTrue(app.buttons.matching(NSPredicate(format:"label CONTAINS %@","WaterFowl · Pure Swift")).firstMatch.exists)}
            backgroundApp();usleep(500_000);app.activate();usleep(500_000)
            key("Space");XCTAssertTrue(app.buttons.matching(NSPredicate(format:"label CONTAINS %@","(ended)")).firstMatch.waitForExistence(timeout:10))
            close("WaterFowl");XCTAssertTrue(app.buttons["More programs"].exists)
            startMenu();menuItem("Demos...");shot("distribution-demo-index-\(engine)")
            menuItem("Non-Game");menuItem("DateTime")
            let run=engine=="native" ? "RUN IN Pure Swift" : "RUN IN Pure Terry"
            menuItem(run)
            XCTAssertTrue(app.buttons.matching(NSPredicate(format:"label CONTAINS %@","DateTime")).firstMatch.waitForExistence(timeout:20))
            sleep(2);shot("distribution-datetime-\(engine)");close("DateTime")
            XCTAssertTrue(app.buttons["Edit source"].exists)
            app.buttons["Back"].tap();usleep(200_000)
            XCTAssertTrue(app.staticTexts["Non-Game"].exists)
            startMenu();menuItem("Applications");shot("distribution-applications-\(engine)")
            XCTAssertTrue(app.buttons["Budget"].exists)
            startMenu();menuItem("Programs");menuItem("Original menus");menuItem("Pull-down menus")
            menuItem("EdPullDown  [Doc/EdPullDown.DD]");shot("distribution-editor-menu-reference-\(engine)")
            XCTAssertFalse(app.buttons[run].exists)
            startMenu();menuItem("HolyC Editor");windowMenu("Untitled.HC");menuItem("Program")
            XCTAssertTrue(app.buttons["Include"].exists)
            XCTAssertTrue(app.descendants(matching:.any)["AdamInclude, unavailable"].exists)
            shot("distribution-editor-context-\(engine)");app.assertTempleInputInvariant()
        }
    }

    func testModelsOriginalLaunchViewAndAnimation() throws {
        for engine in ["terry","native"] {
            app.terminate();app.launchArguments=["-uitest-reset","-engine",engine,"-AppleLanguages","(en-US)"]
            XCUIDevice.shared.orientation = .portrait;app.launch();readLayout()
            startMenu();menuItem("Games...");menuItem("GrModels")
            let man=app.buttons["Man"];XCTAssertTrue(man.waitForExistence(timeout:30));man.tap();sleep(1)
            if !app.buttons["q"].exists {windowMenu("GrModels");menuItem("Show keyboard")}
            app.buttons.matching(identifier:"Escape").firstMatch.tap()
            for part in ["Shirt","Pants","Skin","Shoes"] {
                let header=app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@",part)).firstMatch
                let visible=header.waitForExistence(timeout:20)
                if !visible {shot("models-missing-\(part)-\(engine)")}
                XCTAssertTrue(visible,"\(engine): original \(part) chooser")
                app.buttons.matching(NSPredicate(format:"label CONTAINS %@","__CYAN")).firstMatch.tap()
            }
            if !app.buttons["q"].exists {windowMenu("GrModels");menuItem("Show keyboard")}
            key("n");sleep(1)
            let pic=app.staticTexts.matching(NSPredicate(format:"label BEGINSWITH %@","Program picture: GrModels")).firstMatch
            XCTAssertTrue(pic.waitForExistence(timeout:20))
            let before=try XCTUnwrap(pic.screenshot().image.cgImage?.dataProvider?.data) as Data;shot("models-view-\(engine)-before");sleep(1)
            let after=try XCTUnwrap(pic.screenshot().image.cgImage?.dataProvider?.data) as Data
            XCTAssertNotEqual(before,after);shot("models-view-\(engine)-after")
            XCTAssertFalse(app.buttons.matching(NSPredicate(format:"label CONTAINS %@","(ended)")).firstMatch.exists)
            app.buttons.matching(identifier:"Escape").firstMatch.tap();XCTAssertTrue(app.buttons.matching(NSPredicate(format:"label CONTAINS %@","(ended)")).firstMatch.waitForExistence(timeout:10))
            app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@","Close GrModels")).firstMatch.tap()
            XCTAssertTrue(app.buttons["More programs"].exists);app.assertTempleInputInvariant()
        }
    }

    func testDistributionSmallDisplay() throws {
        app.launchArguments=["-uitest-reset","-AppleLanguages","(ja-JP)"]
        XCUIDevice.shared.orientation = .portrait;app.launch();readLayout()
        for orientation in [UIDeviceOrientation.portrait,.landscapeLeft] {
            XCUIDevice.shared.orientation=orientation;usleep(500_000)
            for line in ["TempleOS.app","Tap MENU to begin.","TempleOS by Terry A. Davis","Mobile adaptation by Ricky Axel"] {
                let text=app.staticTexts[line];XCTAssertTrue(text.exists)
                XCTAssertTrue(app.windows.firstMatch.frame.contains(text.frame),line)
            }
            shot("small-intro-\(orientation.rawValue)")
        }
        // The copy and its MENU action stay verbatim even when the rest of the UI is Japanese.
        app.buttons["MENU"].tap()
        app.assertTempleInputInvariant()
        shot("small-menu")
    }

    func testOriginalMenuMeshAnimation() throws {
        app.launchArguments=["-uitest-reset","-AppleLanguages","(en-US)"]
        XCUIDevice.shared.orientation = .portrait;app.launch();readLayout();sleep(2)
        startMenu();menuItem("Games...")
        let mesh=app.buttons["Varoom"],still=app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@","Titanium")).firstMatch
        XCTAssertTrue(mesh.waitForExistence(timeout:10));XCTAssertTrue(still.exists)
        func pixels(_ element:XCUIElement) throws -> Data {
            let image=try XCTUnwrap(element.screenshot().image.cgImage)
            return try XCTUnwrap(image.dataProvider?.data) as Data
        }
        let meshBefore=try pixels(mesh),stillBefore=try pixels(still);shot("original-animation-before")
        sleep(1)
        XCTAssertNotEqual(meshBefore,try pixels(mesh),"original mesh rotation changes actual displayed pixels")
        XCTAssertEqual(stillBefore,try pixels(still),"static original artwork stays identical")
        shot("original-animation-after")
    }

    func testSoundKeyboardPrograms() throws {
        let engines=ProcessInfo.processInfo.environment["TEMPLEOS_SOUND_KEYBOARD_ENGINE"].map {[$0]} ?? ["terry","native"]
        for engine in engines {
            for title in ["ASCIIOrgan","Psalmody","JukeBox","WaterFowl","OhGreat","MorseCode"] {
                app.terminate();app.launchArguments=["-uitest-reset","-soundcapture","-engine",engine,"-AppleLanguages","(en-US)"]
                XCUIDevice.shared.orientation = .portrait;app.launch();readLayout();sleep(1)
                startMenu();menuItem("Games...");menuItem(title)
                XCTAssertTrue(app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@","Window menu: \(title)")).firstMatch.waitForExistence(timeout:30))
                if title=="WaterFowl" || title=="OhGreat" {
                    if !app.buttons["q"].exists {windowMenu(title);menuItem("Show keyboard")}
                }
                XCTAssertTrue(app.buttons["q"].waitForExistence(timeout:10),"full TempleOS keyboard opens for \(title)")
                app.assertTempleInputInvariant()
                if engine=="native" {XCTAssertTrue(app.buttons.matching(NSPredicate(format:"label CONTAINS %@","\(title) · Pure Swift")).firstMatch.exists)}
                shot("sound-\(title)-\(engine)-portrait")
                if title=="JukeBox" {key("7");key("Space");sleep(1)}
                else if title=="WaterFowl" {key("a");sleep(1)}
                else if title=="OhGreat" {key("a")}
                else {app.buttons["a"].press(forDuration:0.35);sleep(1)}
                if title=="MorseCode" {
                    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","-T")).firstMatch.waitForExistence(timeout:10),"held custom key decodes a dash into T")
                }
                XCUIDevice.shared.orientation = .landscapeLeft
                let rotated=expectation(for:NSPredicate {_,_ in self.app.frame.width>self.app.frame.height},evaluatedWith:app)
                wait(for:[rotated],timeout:10);XCTAssertTrue(app.buttons["q"].exists)
                app.assertTempleInputInvariant();shot("sound-\(title)-\(engine)-landscape")
                XCUIDevice.shared.orientation = .portrait;sleep(1)
                if title=="MorseCode" || title=="ASCIIOrgan" {key("Shift");key("Escape");sleep(1)}
                app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@","Close \(title)")).firstMatch.tap();sleep(1)
                XCTAssertTrue(app.buttons["Original menu"].exists)
                if title=="ASCIIOrgan" || title=="MorseCode" {
                    menuItem(title);XCTAssertTrue(app.buttons["q"].waitForExistence(timeout:15));sleep(1)
                    app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@","Close \(title)")).firstMatch.tap()
                }
                XCUIDevice.shared.press(.home);sleep(3)
            }
        }
    }

    func testRestoredOriginalPrograms() throws {
        func keyboard(_ title:String) {
            if !app.buttons["q"].exists {windowMenu(title);menuItem("Show keyboard")}
            XCTAssertTrue(app.buttons["q"].waitForExistence(timeout:10));app.assertTempleInputInvariant()
        }
        for engine in ["terry","native"] {
            for title in ["JukeBox","Psalmody","Budget","GrModels","ToTheFront","Vocabulary"] {
                app.terminate();app.launchArguments=["-uitest-reset","-soundcapture","-engine",engine,"-AppleLanguages","(en-US)"]
                XCUIDevice.shared.orientation = .portrait;app.launch();readLayout();sleep(2)
                startMenu();menuItem("Games...");menuItem(title)
                if title=="GrModels" {let man=app.buttons["Man"];XCTAssertTrue(man.waitForExistence(timeout:30));man.tap();sleep(2)}
                let window=app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@","Window menu: \(title)")).firstMatch
                XCTAssertTrue(window.waitForExistence(timeout:30));sleep(3)
                if title=="ToTheFront" {
                    keyboard(title);key("Enter");sleep(3)
                    for _ in 0..<2 {let human=app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@","Human")).firstMatch;XCTAssertTrue(human.waitForExistence(timeout:30));human.tap();sleep(2)}
                    let okay=app.buttons["OKAY"];XCTAssertTrue(okay.waitForExistence(timeout:10));okay.tap();sleep(3)
                }
                if engine=="native" {XCTAssertTrue(app.buttons.matching(NSPredicate(format:"label CONTAINS %@","\(title) · Pure Swift")).firstMatch.exists)}
                keyboard(title);app.assertTempleInputInvariant();shot("restored-\(title)-\(engine)-portrait")
                if title=="JukeBox" {key("Space");sleep(3)}
                if title=="Vocabulary" {key("1");sleep(1)}
                if title=="Psalmody" {key("z");key("a");key("s");sleep(1)}
                XCUIDevice.shared.orientation = .landscapeLeft;sleep(2)
                XCTAssertGreaterThan(app.frame.width,app.frame.height,"actual interface rotates")
                shot("restored-\(title)-\(engine)-landscape")
                XCUIDevice.shared.press(.home);sleep(1);app.activate();sleep(1);app.assertTempleInputInvariant()
                XCUIDevice.shared.orientation = .portrait;sleep(1)
                let close=app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@","Close \(title)")).firstMatch
                XCTAssertTrue(close.exists);close.tap();sleep(1);XCTAssertTrue(app.buttons["Original menu"].exists)
                menuItem(title)
                if title=="GrModels" {let man=app.buttons["Man"];XCTAssertTrue(man.waitForExistence(timeout:30));man.tap()}
                XCTAssertTrue(window.waitForExistence(timeout:30));sleep(2)
                shot("restored-\(title)-\(engine)-reopened")
                // Closing also cancels any source-created form/menu and its audio tasks.
                if app.buttons["Cancel"].exists {app.buttons["Cancel"].tap();sleep(1)}
                app.terminate()
            }
        }
    }

    func testSoundExample() throws {
        let envv = ProcessInfo.processInfo.environment
        let program = envv["TEMPLEOS_SOUND_PROGRAM"] ?? "Sound"
        app.launchArguments = ["-uitest-reset", "-soundcapture", "-AppleLanguages", "(en-US)"]
        app.launch()
        readLayout(); sleep(2)
        app.buttons["MENU"].tap(); sleep(1)
        app.buttons[envv["TEMPLEOS_SOUND_MENU"] ?? "Examples..."].tap(); sleep(1)
        menuItem(program) // scrolls a long menu (Games... > Whap)
        if program == "Sound" {
            let done = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Done.")).firstMatch
            XCTAssertTrue(done.waitForExistence(timeout: 60), "the program printed Done.")
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "60 62 64 66 68 70 72")).firstMatch.exists)
        } else {
            sleep(3)
            if app.buttons["OKAY"].exists { app.buttons["OKAY"].tap(); sleep(1) }
            let taps = (envv["TEMPLEOS_SOUND_TAPS"] ?? "").split(separator: ",").map(String.init)
            let t0 = Date(), seconds = Double(envv["TEMPLEOS_SOUND_SECONDS"] ?? "") ?? 15
            var i = 0
            while Date().timeIntervalSince(t0) < seconds {
                if !taps.isEmpty { let e = app.buttons[taps[i % taps.count]]; if e.exists { e.tap() }; i += 1 }
                usleep(500_000)
            }
        }
        shot("sound-\(program)")
        // a task that died with an unhandled exception prints it to the program's output (e.g. the Whap BadMem,
        // docs/audio/TEMPLEOS_AUDIO_FIDELITY.md §15.1)
        let fault = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Unhandled exception")).firstMatch
        XCTAssertFalse(fault.exists, fault.exists ? fault.label : "")
        // leave the program: the engine stops after its idle time (or at once in the background) and closes the recording
        XCUIDevice.shared.press(.home)
        sleep(4)
    }

    /**
     * Sound stops with the app: Examples > Sound goes to the background 1.5 s in (the recording, closed by
     * ToneGenerator.suspend, must hold about that much sound, not the whole 2.6 s example).
     */
    func testSoundStopsInBackground() throws {
        app.launchArguments = ["-uitest-reset", "-soundcapture", "-AppleLanguages", "(en-US)"]
        app.launch()
        readLayout(); sleep(2)
        app.buttons["MENU"].tap(); sleep(1)
        app.buttons["Examples..."].tap(); sleep(1)
        XCTAssertTrue(app.buttons["Sound"].waitForExistence(timeout: 5))
        app.buttons["Sound"].tap()
        // the program boots (Starting...) before its first note: wait for its first line
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Scale with")).firstMatch.waitForExistence(timeout: 30))
        usleep(1_500_000)
        XCUIDevice.shared.press(.home)
        sleep(6)
    }

    /** An indefinite original MenuBttn tone avoids the short Sound example ending before Home. */
    func testSustainedSoundStopsInBackground() throws {
        let engine = ProcessInfo.processInfo.environment["TEMPLEOS_ENGINE"] ?? "terry"
        app.launchArguments = ["-uitest-reset", "-soundcapture", "-engine", engine, "-AppleLanguages", "(en-US)"]
        XCUIDevice.shared.orientation = .portrait
        app.launch(); readLayout()
        startMenu(); menuItem("Demos..."); menuItem("TempleOS Specific"); menuItem("MenuBttn")
        menuItem(engine == "native" ? "RUN IN Pure Swift" : "RUN IN Pure Terry")
        let on = app.buttons["Snd On"]
        XCTAssertTrue(on.waitForExistence(timeout:30))
        app.buttons["Set Freq"].tap(); app.buttons["400 Hz"].tap(); on.tap()
        XCTAssertTrue(app.buttons["Snd Off"].waitForExistence(timeout:10))
        sleep(1); shot("sustained-sound-\(engine)-before-background")
        app.assertTempleInputInvariant()
        backgroundApp(); sleep(3)
        XCTAssertTrue(app.state == .runningBackground || app.state == .runningBackgroundSuspended)
        // The host exports the closed WAV twice to check that background capture no longer grows.
    }

    func testPerfProgram() throws {
        let envv = ProcessInfo.processInfo.environment
        let program = envv["TEMPLEOS_PERF_PROGRAM"] ?? "BomberGolf"
        let menu = envv["TEMPLEOS_PERF_MENU"] ?? "Games..."
        let seconds = Double(envv["TEMPLEOS_PERF_SECONDS"] ?? "") ?? 20
        let taps = (envv["TEMPLEOS_PERF_TAPS"] ?? "Space,Left arrow,Space,Right arrow").split(separator: ",").map(String.init)
        // TEMPLEOS_PERF_ENGINE=terry|native: Settings > Engine for this run (Pure Terry or Pure Swift)
        let engine = envv["TEMPLEOS_PERF_ENGINE"] ?? "terry"
        app.launchArguments = ["-uitest-reset", "-perflog", "-engine", engine, "-AppleLanguages", "(en-US)"]
        app.launch()
        XCUIDevice.shared.orientation = envv["TEMPLEOS_PERF_LANDSCAPE"] == "1" ? .landscapeLeft : .portrait
        readLayout(); sleep(2)
        app.buttons["MENU"].tap(); sleep(1)
        app.buttons[menu].tap(); sleep(1)
        // the menu row's label (e.g. "PredatorPrey (partial)"); long submenus scroll until it is on screen
        let b = app.buttons[envv["TEMPLEOS_PERF_LABEL"] ?? program]
        for _ in 0..<12 where !(b.exists && b.isHittable) {
            let down = app.buttons["Scroll menu down"]
            guard down.exists else { break }
            down.tap(); usleep(400_000)
        }
        XCTAssertTrue(b.waitForExistence(timeout: 5), program)
        b.tap()
        _ = app.staticTexts["Program picture: \(program)"].waitForExistence(timeout: 30)
        sleep(3)
        if app.buttons["OKAY"].exists { app.buttons["OKAY"].tap(); sleep(1) }
        let view = app.descendants(matching: .any)["templeView"]
        var lines: [String] = [], tapTimes: [Double] = []
        var last = ""
        let t0 = Date()
        var i = 0
        while Date().timeIntervalSince(t0) < seconds {
            if !taps.isEmpty {
                let e = app.buttons[taps[i % taps.count]]
                let s0 = Date()
                if e.exists { e.tap() }
                tapTimes.append(Date().timeIntervalSince(s0))
                i += 1
            }
            let v = (view.value as? String) ?? ""
            if let r = v.range(of: ";perf=") {
                let l = String(v[r.upperBound...])
                if l != last { lines.append(l); last = l }
            }
            usleep(300_000)
        }
        shot("perf-\(program)-\(engine)")
        let json = "{\"program\": \"\(program)\", \"engine\": \"\(engine)\", \"seconds\": \(seconds), \"tapSeconds\": [\(tapTimes.map { String(format: "%.3f", $0) }.joined(separator: ", "))], \"lines\": [\(lines.map { "\"\($0)\"" }.joined(separator: ", "))]}"
        let a = XCTAttachment(string: json); a.name = "perf-\(program).json"; a.lifetime = .keepAlways; add(a)
        if let output = shotDirectory {
            try? json.write(to: output.appendingPathComponent("perf-\(program)-\(engine).json"), atomically: true, encoding: .utf8)
        }
        print("PERF-RESULT " + json)
        XCTAssertFalse(lines.isEmpty, "the app published perf lines")
        XCUIDevice.shared.orientation = .portrait
    }

    /** Fraction of pixels on screenshot row [yPt] (points) in the key row's colors: LTCYAN key faces or their BLACK frames. */
    private func grayFraction(atPoints yPt: Double) -> Double {
        guard let cg = XCUIScreen.main.screenshot().image.cgImage,
              let data = cg.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return 0 }
        let scale = Double(cg.width) / Double(app.windows.firstMatch.frame.width)
        let y = Int(yPt * scale), bpr = cg.bytesPerRow, bpp = cg.bitsPerPixel / 8
        var gray = 0
        for x in 0..<cg.width {
            let o = y * bpr + x * bpp
            let c = (p[o], p[o + 1], p[o + 2]) // BGRA or RGBA
            let ltcyan = (c.0 == 0x55 && c.1 == 0xFF && c.2 == 0xFF) || (c.0 == 0xFF && c.1 == 0xFF && c.2 == 0x55)
            if ltcyan { gray += 1 }
        }
        return Double(gray) / Double(cg.width)
    }

    /** The soft keyboard is on screen and the row just above it is the shell's gray key row. */
    private func assertKeyRowAboveKeyboard(_ kb: XCUIElement, _ mode: String) {
        app.assertTempleInputInvariant()
        XCTAssertTrue(kb.exists, "app-owned keyboard (\(mode))")
        XCTAssertTrue(app.windows.firstMatch.frame.contains(kb.frame), "custom key remains inside safe layout")
    }

    /** V-32 LARGE touch targets through the real UI, and V-33: the key row sits above the keyboard. */
    func testLargeTouchTargetsAndKeyRow() throws {
        app.launchArguments = ["-uitest-reset"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        readLayout(); sleep(2)
        // STANDARD Terminal: the key row is visible directly above the soft keyboard
        startMenu(); menuItem("Terminal"); sleep(4)
        useTempleKeyboard()
        let kb = app.buttons["Hide keyboard"]
        XCTAssertTrue(kb.waitForExistence(timeout: 10), "terminal shows the keyboard")
        sleep(3)
        app.typeTempleText("Dir;\n"); sleep(2)
        assertKeyRowAboveKeyboard(kb, "standard")
        shot("10-terminal-key-row")
        // Settings > Touch targets: LARGE
        startMenu(); menuItem("Settings"); sleep(1)
        let touch = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Touch targets'")).firstMatch
        XCTAssertTrue(touch.waitForExistence(timeout: 5)); touch.tap(); sleep(1)
        shot("11-settings-large")
        // menu rows were already touch-sized (MenuMetrics); LARGE keeps them so in landscape too
        startMenu(); shot("12-start-menu-large")
        XCTAssertGreaterThanOrEqual(app.buttons["Terminal"].frame.height, 43.5)
        menuItem("Terminal"); sleep(3)
        XCTAssertTrue(kb.waitForExistence(timeout: 10), "a LARGE start-menu tap opened the terminal")
        sleep(1)
        app.typeTempleText("Dir;\n"); sleep(2)
        shot("13-terminal-large")
        assertKeyRowAboveKeyboard(kb, "large")
    }

    /** The in-app TempleOS keyboard: VoiceOver sees its keys, and typing on them runs HolyC in the terminal. */
    /** Game controls are visible in both orientations: none lies under the program picture (BomberGolf). */
    func testGameControlsAreNotUnderThePicture() throws {
        app.launchArguments = ["-uitest-reset", "-AppleLanguages", "(en-US)"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        readLayout(); sleep(2)
        app.buttons["MENU"].tap(); sleep(1)
        app.buttons["Games..."].tap(); sleep(1)
        let bg = app.buttons["BomberGolf"]
        XCTAssertTrue(bg.waitForExistence(timeout: 5))
        bg.tap(); sleep(8)
        for (name, o) in [("portrait", UIDeviceOrientation.portrait), ("landscape", .landscapeLeft)] {
            XCUIDevice.shared.orientation = o; sleep(3)
            let pic = app.staticTexts["Program picture: BomberGolf"]
            XCTAssertTrue(pic.waitForExistence(timeout: 5), "\(name): picture")
            for l in ["Up arrow", "Left arrow", "Space", "Enter", "Escape", "Touch is left click"] {
                let b = app.buttons[l]
                XCTAssertTrue(b.exists, "\(name): \(l)")
                XCTAssertFalse(b.frame.intersects(pic.frame), "\(name): \(l) \(b.frame) is under the picture \(pic.frame)")
            }
            app.buttons["Space"].tap(); app.buttons["Left arrow"].tap(); sleep(1)
            shot("game-controls-\(name)")
        }
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: fidelity audit (docs/fidelity-audit): the programs its fixes touched, on a device

    /** Launches a clean app and opens [title] from the Games or Demos menu; returns its picture. */
    private func openProgram(_ menu: String, _ title: String, partial: Bool = false) -> XCUIElement {
        app.terminate()
        app.launchArguments = ["-uitest-reset", "-AppleLanguages", "(en-US)"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        readLayout(); sleep(2)
        app.buttons["MENU"].tap(); sleep(1)
        app.buttons[menu].tap(); sleep(1)
        if menu == "Demos..." { menuItem("Games: Intermediate") }
        if menu == "Games...", !app.buttons[partial ? "\(title) (partial)" : title].exists {app.buttons["More programs"].tap()}
        menuItem(partial ? "\(title) (partial)" : title)
        if menu == "Demos..." {menuItem("RUN IN Pure Terry")}
        let pic = app.staticTexts["Program picture: \(title)"]
        _ = pic.waitForExistence(timeout: 30)
        return pic
    }

    /** Taps a TempleOS screen position inside a program picture that shows the screen rect [win]. */
    private func tapScreen(_ pic: XCUIElement, _ x: Double, _ y: Double, win: (Double, Double, Double, Double)) {
        pic.coordinate(withNormalizedOffset: CGVector(dx: (x - win.0) / win.2, dy: (y - win.1) / win.3)).tap()
    }

    /**
     * Screenshots of the programs the audit's fixes touched (TEMPLEOS_SHOTS/TEST_RUNNER_TEMPLEOS_SHOTS
     * collects them): window geometry (FA-01), text-layer programs on the screen (FA-30), scroll bars
     * (FA-28), Cartesian's F64 expression (FA-27), Talons' memory (FA-36) and Titanium.
     */
    func testFidelityAuditPrograms() throws {
        // TicTacToe: a bordered, maximized window (screen 0,8..640,480); cell centres at window
        // (150..350) = screen (158..358, 166..366), as on the reference VM
        var pic = openProgram("Games...", "TicTacToe"); sleep(3)
        let win = (0.0, 8.0, 640.0, 472.0)
        tapScreen(pic, 258, 266, win: win); sleep(1)
        tapScreen(pic, 158, 166, win: win); sleep(1)
        shot("fa-tictactoe-two-moves")

        pic = openProgram("Demos...", "PanText")
        for i in 0..<4 { usleep(400_000); shot("fa-pantext-\(i)") }

        pic = openProgram("Demos...", "CharAnimation"); sleep(3)
        shot("fa-charanimation")

        pic = openProgram("Demos...", "ScrollBars"); sleep(3)
        shot("fa-scrollbars")

        pic = openProgram("Demos...", "Cartesian"); sleep(3)
        useTempleKeyboard()
        app.typeTempleText("x/8+0.5\n"); sleep(8)
        shot("fa-cartesian-x-over-8")

        pic = openProgram("Games...", "Titanium", partial: true); sleep(4)
        shot("fa-titanium-start")
        app.buttons["Space"].tap(); sleep(15)
        shot("fa-titanium-15s")

        pic = openProgram("Games...", "Talons", partial: true)
        for i in 0..<6 { sleep(15); shot("fa-talons-\((i + 1) * 15)s") }
    }

    // ------------------------------------------------------------ native validation on devices (docs/native-validation)

    /** Perf lines the app publishes once a second in the view's accessibility value (Shell.perfLog). */
    private func perfLines(for seconds: Double, taps: [String] = [], during: (() -> Void)? = nil) -> [String] {
        let view = app.descendants(matching: .any)["templeView"]
        var lines: [String] = [], last = ""
        let t0 = Date()
        var i = 0
        var did = false
        while Date().timeIntervalSince(t0) < seconds {
            if !taps.isEmpty { let e = app.buttons[taps[i % taps.count]]; if e.exists { e.tap() }; i += 1 }
            if !did && Date().timeIntervalSince(t0) > seconds / 2 { did = true; during?() }
            let v = (view.value as? String) ?? ""
            if let r = v.range(of: ";perf=") { let l = String(v[r.upperBound...]); if l != last { lines.append(l); last = l } }
            usleep(300_000)
        }
        return lines
    }

    private func report(_ name: String, _ obj: String) {
        let a = XCTAttachment(string: obj); a.name = name; a.lifetime = .keepAlways; add(a)
        print("NATIVE-VALIDATION \(name) \(obj)")
    }

    /** The window's close button (a11y "Close <title>"; the title-bar menu is the program's own menu). */
    private func closeFocusedWindow(_ title: String) {
        waitForSystemBanner()
        let x = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Close \(title)")).firstMatch
        XCTAssertTrue(x.waitForExistence(timeout: 5), "close button of \(title)")
        x.tap(); sleep(1)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Program picture: \(title)")).firstMatch.exists, "\(title) closed")
    }

    /** Opens [label] from the start menu's [menu] (the app keeps running between programs). */
    private func open(_ menu: String, _ label: String, picture: String) -> XCUIElement {
        startMenu()
        menuItem(menu)
        if menu == "Demos..." {menuItem("Games: Intermediate")}
        if menu == "Games...", !app.buttons[label].exists {app.buttons["More programs"].tap()}
        menuItem(label)
        if menu == "Demos..." {
            let engine=ProcessInfo.processInfo.environment["TEMPLEOS_ENGINE"] ?? "native"
            menuItem(engine == "native" ? "RUN IN Pure Swift" : "RUN IN Pure Terry")
        }
        // a program's own modal popup (X-Caliber's "Face away from Sun in solar storm.") hides the picture until answered
        // native windows carry the engine in their title ("X-Caliber · Pure Swift")
        let pic = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Program picture: \(picture)")).firstMatch
        let end = Date().addingTimeInterval(60)
        while !pic.exists && Date() < end {
            if app.buttons["OKAY"].exists { app.buttons["OKAY"].tap(); sleep(1); continue }
            usleep(500_000)
        }
        XCTAssertTrue(pic.exists, "\(picture) opened")
        return pic
    }

    /** Cold and warm launch time of the app on this device (XCTApplicationLaunchMetric). */
    func testNativeLaunchPerformance() throws {
        app.launchArguments = ["-AppleLanguages", "(en-US)"]
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: { let o = XCTMeasureOptions(); o.iterationCount = 7; return o }()) {
            app.launch()
            _ = app.descendants(matching: .any)["templeView"].waitForExistence(timeout: 30)
            app.terminate()
        }
    }

    /**
     * The native engine on a device, end to end: X-Caliber, Talons and Cartesian from the menus with touch keys,
     * rotation, background and foreground, closing and relaunching; every perf line must say engine=native.
     */
    func testNativeProgramsOnDevice() throws {
        let envv = ProcessInfo.processInfo.environment
        let engine = envv["TEMPLEOS_ENGINE"] ?? "native"
        app.launchArguments = ["-perflog", "-engine", engine, "-AppleLanguages", "(en-US)"]
        let l0 = Date()
        app.launch()
        readLayout()
        report("launch-to-desktop", "{\"seconds\": \(String(format: "%.3f", Date().timeIntervalSince(l0)))}")
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        // Release builds restore the previous session (-uitest-reset is debug-only): answer restored programs'
        // popups and close their windows, so the run starts from the desktop
        for title in ["X-Caliber", "Talons", "Cartesian"] {
            for _ in 0..<3 where app.buttons["OKAY"].exists { app.buttons["OKAY"].tap(); sleep(1) }
            let x = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Close \(title)")).firstMatch
            if x.exists { x.tap(); sleep(1) }
        }
        app.windows.firstMatch.swipeUp() // nothing to scroll: proves touch input reaches the desktop without effect
        func check(_ name: String, _ lines: [String]) {
            report("perf-\(name)", "[" + lines.map { "\"\($0)\"" }.joined(separator: ", ") + "]")
            XCTAssertFalse(lines.isEmpty, "\(name): perf lines")
            XCTAssertTrue(lines.allSatisfy { $0.contains("engine=\(engine)") }, "\(name) ran on \(engine): \(lines.first ?? "")")
        }

        // X-Caliber: touch keys, rotation while running, background/foreground
        _ = open("Games...", "X-Caliber", picture: "X-Caliber")
        sleep(2)
        app.buttons["Space"].firstMatch.tap() // leave the level message
        var lines = perfLines(for: 12, taps: ["Space", "Left arrow", "Up arrow", "Right arrow"])
        shot("dev-xcaliber-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft; sleep(3)
        lines += perfLines(for: 8, taps: ["Space", "Left arrow"])
        shot("dev-xcaliber-landscape")
        XCUIDevice.shared.orientation = .portrait; sleep(2)
        XCUIDevice.shared.press(.home); sleep(4)
        app.activate(); sleep(3)
        lines += perfLines(for: 6)
        shot("dev-xcaliber-after-foreground")
        check("xcaliber", lines)
        closeFocusedWindow("X-Caliber")

        // Talons: terrain generation, then flying
        _ = open("Games...", "Talons (partial)", picture: "Talons")
        lines = perfLines(for: 40, taps: ["Up arrow", "Left arrow"])
        shot("dev-talons-40s")
        check("talons", lines)
        closeFocusedWindow("Talons")

        // Cartesian: formulas typed on the device keyboard
        _ = open("Demos...", "Cartesian", picture: "Cartesian")
        sleep(2)
        useTempleKeyboard()
        for (i, f) in ["2*x", "Sin(x/20)*100", "x*x/100"].enumerated() {
            app.typeTempleText(f + "\n"); sleep(6)
            shot("dev-cartesian-\(i)")
            app.typeTempleText("\n"); sleep(2) // any key: next formula
        }
        lines = perfLines(for: 3)
        check("cartesian", lines)
        closeFocusedWindow("Cartesian")

        // relaunch: the app comes back to its desktop
        app.terminate()
        let r0 = Date()
        app.launch()
        readLayout()
        report("relaunch-to-desktop", "{\"seconds\": \(String(format: "%.3f", Date().timeIntervalSince(r0)))}")
        shot("dev-relaunch")
    }

    /** docs/localization.md: device language, in-app choice, persistence, Automatic, right-to-left. */
    // ------------------------------------------------------------ God Words localization

    /** The repository (simulator runs read the shared catalogs and vocabularies from the host). */
    private static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private func catalogOf(_ loc: String) -> String {
        let m = try! JSONSerialization.jsonObject(with: Data(contentsOf: Self.repo.appendingPathComponent("shared/runtime/l10n/locales.json"))) as! [String: Any]
        return ((m["locales"] as! [[String: Any]]).first { $0["id"] as? String == loc }!["catalog"] as! String)
    }

    /**
     * UI string `key` in `loc` (English when the catalog lacks it). A device cannot read the host's catalogs: there
     * TEMPLEOS_UI_STRINGS holds {locale: {key: text}} (tools/ui-audit/ui_strings.py).
     */
    private func ui(_ loc: String, _ key: String) -> String {
        if let j = ProcessInfo.processInfo.environment["TEMPLEOS_UI_STRINGS"],
           let m = (try? JSONSerialization.jsonObject(with: Data(j.utf8))) as? [String: [String: String]] {
            return m[loc]![key]!
        }
        func load(_ c: String) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: Self.repo.appendingPathComponent("shared/runtime/l10n/\(c).json")))) as? [String: Any] ?? [:]
        }
        // {app} is filled in as L10n.tr does (the apps' name, manifest app_name)
        let name = load("locales")["app_name"] as! String
        return ((load(catalogOf(loc))[key] as? String) ?? (load("en")[key] as! String)).replacingOccurrences(of: "{app}", with: name)
    }

    /** The shipped vocabulary display for `loc` (translation, or the English entry), as the apps decode it. */
    private func vocabulary(_ loc: String, english: [String]) -> [String] {
        let c = catalogOf(loc)
        if c == "en" { return english }
        let raw = [UInt8](try! Data(contentsOf: Self.repo.appendingPathComponent("shared/runtime/l10n/vocab/\(c).deflate")))
        var dst = [UInt8](repeating: 0, count: raw.count * 12)
        let n = raw.withUnsafeBufferPointer { s in dst.withUnsafeMutableBufferPointer { d in
            compression_decode_buffer(d.baseAddress!, d.count, s.baseAddress!, raw.count, nil, COMPRESSION_ZLIB) } }
        var lines = String(decoding: dst[0..<n], as: UTF8.self).components(separatedBy: "\n")
        lines.removeFirst()
        return english.indices.map { lines[$0].isEmpty ? english[$0] : lines[$0] }
    }

    /** Terry's entries, split as GodInit splits Adam/God/Vocab.DD (the bundled copy). */
    private func englishEntries() -> [String] {
        let d = [UInt8](try! Data(contentsOf: Self.repo.appendingPathComponent("shared/bundled-fs/Adam/God/Vocab.DD")))
        let end = d.firstIndex(of: 0) ?? d.count
        func w(_ b: UInt8) -> Bool { b == 0x27 || (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || b == 0x5F || (b >= 0x61 && b <= 0x7A) || b >= 0x80 }
        var out: [String] = [], i = 0
        while i < end {
            while i < end && !w(d[i]) { i += 1 }
            let j = i
            while i < end && w(d[i]) { i += 1 }
            if i > j { out.append(String(decoding: d[j..<i], as: UTF8.self)) }
        }
        return out
    }

    private func flat(_ s: String) -> String { s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
    /** Without whitespace: wrapped CJK/Thai lines break at any character, so a line break is not a word break. */
    private func squash(_ s: String) -> String { s.filter { !$0.isWhitespace } }

    /** The God Words body text (whitespace-normalized); found by the intro's source path, which never wraps. */
    private func godText(_ loc: String) -> String {
        let e = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "HolySpirit.HC")).firstMatch
        XCTAssertTrue(e.waitForExistence(timeout: 10), "God Words text in \(loc)")
        return flat(e.label)
    }

    private func chooseLanguage(_ cur: String, _ loc: String) {
        app.buttons[ui(cur, "topbar.menu")].tap(); usleep(500_000)
        menuItem(ui(cur, "menu.start.language"), locale: cur); sleep(1)
        key(ui(cur, "key.escape")); usleep(500_000) // the window keeps its filter: ESC clears it
        if loc.isEmpty {
            let auto = app.buttons[ui(cur, "settings.language.automatic")]
            XCTAssertTrue(auto.waitForExistence(timeout: 5)); auto.tap(); sleep(2); return
        }
        let m = try! JSONSerialization.jsonObject(with: Data(contentsOf: Self.repo.appendingPathComponent("shared/runtime/l10n/locales.json"))) as! [String: Any]
        let l = (m["locales"] as! [[String: Any]]).first { $0["id"] as? String == loc }!
        // four letters of the English name narrow the list to one row (ids such as "ar" match many names)
        for ch in (l["english_name"] as! String).lowercased().prefix(4) { key(String(ch)) }
        let row = app.buttons["\(l["native_name"] as! String) - \(l["english_name"] as! String)"]
        if !row.waitForExistence(timeout: 5) {
            shot("debug-language-\(loc)")
            print("DEBUG buttons: \(app.buttons.allElementsBoundByIndex.prefix(40).map { $0.label })")
        }
        XCTAssertTrue(row.exists, "language row \(loc)")
        row.tap(); sleep(2)
    }

    /**
     * 10 WORDS in English, then the same picks in Spanish (device language), Japanese, Arabic and French
     * (in-app choice): each pick is shown as the shipped translation of the same entry, and no new words
     * appear on a language change. Then About and the documentation notice. Simulator only (reads
     * the repository's files).
     */
    /**
     * Edge steepness of visible ink: the 90th percentile of non-background luminance steps relative to the
     * region's contrast. Text drawn at the display's resolution steps almost its whole contrast in one device pixel
     * (≈0.8–1.0); text rasterized at 1/n resolution and stretched cannot step more than ≈1/n (the iOS defect: 0.27
     * at 3x). docs/typography/TEMPLEOS_TYPOGRAPHY.md.
     */
    private func edgeSteepness(_ cg: CGImage, _ r: CGRect) -> Double? {
        guard let c = cg.cropping(to: r.integral), let d = c.dataProvider?.data, let p = CFDataGetBytePtr(d) else { return nil }
        let w = c.width, h = c.height, bpr = c.bytesPerRow, bpp = c.bitsPerPixel / 8
        if w < 4 || h < 4 { return nil }
        var lum = [Double](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { let o = y * bpr + x * bpp; lum[y * w + x] = 0.299 * Double(p[o]) + 0.587 * Double(p[o + 1]) + 0.114 * Double(p[o + 2]) } }
        let lo = lum.min()!, hi = lum.max()!
        if hi - lo < 40 { return nil }
        var steps: [Double] = []
        for y in 0..<h { for x in 0..<w {
            if x + 1 < w { steps.append(abs(lum[y * w + x + 1] - lum[y * w + x])) }
            if y + 1 < h { steps.append(abs(lum[(y + 1) * w + x] - lum[y * w + x])) }
        } }
        // Whole-button percentiles depend on empty padding, especially for sparse Nastaliq.
        // Ignore near-flat background edges, not weak glyph edges; stretched text stays below 0.42.
        steps = steps.filter { $0 > (hi - lo) * 0.01 }
        guard steps.count >= 8 else { return nil }
        steps.sort()
        return steps[Int(Double(steps.count) * 0.9)] / (hi - lo)
    }

    func testTypographyMetricRejectsStretchingAndIgnoresEmptyPadding() throws {
        func render(_ text: String, width: CGFloat) -> CGImage {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            return UIGraphicsImageRenderer(size: CGSize(width: width, height: 160), format: format).image { c in
                UIColor(red: 0, green: 0, blue: 170.0 / 255, alpha: 1).setFill()
                c.cgContext.fill(CGRect(x: 0, y: 0, width: width, height: 160))
                (text as NSString).draw(at: CGPoint(x: 32, y: 16), withAttributes: [
                    .font: UIFont.boldSystemFont(ofSize: 48), .foregroundColor: UIColor.yellow,
                ])
            }.cgImage!
        }
        func resized(_ image: CGImage, width: Int, height: Int) -> CGImage {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()!
        }
        for text in ["Settings", "ترتیبات", "日本語", "हिन्दी"] {
            let native = render(text, width: 680), padded = render(text, width: 2040)
            let blurred = resized(resized(native, width: native.width / 3, height: native.height / 3), width: native.width, height: native.height)
            let score = try XCTUnwrap(edgeSteepness(native, CGRect(x: 0, y: 0, width: native.width, height: native.height)))
            let paddedScore = try XCTUnwrap(edgeSteepness(padded, CGRect(x: 0, y: 0, width: padded.width, height: padded.height)))
            let badScore = try XCTUnwrap(edgeSteepness(blurred, CGRect(x: 0, y: 0, width: blurred.width, height: blurred.height)))
            XCTAssertGreaterThanOrEqual(score, 0.42, text)
            XCTAssertEqual(score, paddedScore, accuracy: 0.01, text)
            XCTAssertLessThan(badScore, 0.42, "stretched text must fail: \(text)")
        }
    }

    /**
     * Typography matrix (docs/typography/TEMPLEOS_TYPOGRAPHY.md): for one representative locale of each script family,
     * the desktop, the Start menu, God Words (10 WORDS) and About, saved as PNGs (TEMPLEOS_SHOTS) with the edge
     * steepness of the localized MENU button and Start-menu labels in typography.json. Every label must be
     * rasterized near the display's resolution (steepness ≥ 0.42: antialiased thin strokes measure 0.5–0.9, a 3x-stretched label 0.23–0.33).
     */
    func testTypographyMatrix() throws {
        let locales = (ProcessInfo.processInfo.environment["TEMPLEOS_TYPO_LOCALES"] ?? "en-US,es-ES,pl-PL,vi,ru-RU,el-GR,zh-CN,ja-JP,ko-KR,ar,he-IL,fa-IR,hi-IN,bn-BD,ta-IN,th,km-KH,my-MM,am,ka-GE").split(separator: ",").map(String.init)
        var report: [[String: Any]] = []
        var failures: [String] = []
        for loc in locales {
            app.terminate()
            app.launchArguments = ["-uitest-reset", "-AppleLanguages", "(\(loc))", "-AppleLocale", loc.replacingOccurrences(of: "-", with: "_")]
            app.launch()
            XCUIDevice.shared.orientation = .portrait
            readLayout(); sleep(2)
            // The reconstructed four-line intro intentionally has an invariant MENU chip.
            // Once a window is open, the ordinary top bar follows the selected UI language.
            let menu = app.buttons["MENU"]
            XCTAssertTrue(menu.waitForExistence(timeout: 10), "\(loc): intro MENU")
            let introMenuFrame = menu.frame
            shot("typo-\(loc)-1-desktop")
            func measure(_ e: XCUIElement, _ what: String) {
                guard e.exists, let cg = XCUIScreen.main.screenshot().image.cgImage else {
                    failures.append("\(loc) \(what): missing control/screenshot"); return
                }
                let scale = CGFloat(cg.width) / app.windows.firstMatch.frame.width // device pixels per point
                let f = e.frame
                let r = CGRect(x: f.minX * scale, y: f.minY * scale, width: f.width * scale, height: f.height * scale)
                let v = edgeSteepness(cg, r)
                report.append(["locale": loc, "what": what, "label": e.label, "steepness": v ?? -1,
                               "pixelRect": [r.minX, r.minY, r.width, r.height]])
                if v == nil || v! < 0.42 { failures.append("\(loc) \(what) '\(e.label)': \(String(format: "%.2f", v ?? -1))") }
            }
            measure(menu, "intro.menu")
            menu.tap(); usleep(700_000)
            shot("typo-\(loc)-2-start-menu")
            let fullRow = app.buttons[ui(loc, "menu.start.terminal")].frame.height
            var paged = false
            for key in ["menu.start.god_words", "menu.start.settings", "menu.start.about"] {
                let target = app.buttons[ui(loc, key)]
                for _ in 0..<20 {
                    if target.exists && target.frame.height >= fullRow - 0.5 { break }
                    let down = app.buttons[ui(loc, "a11y.scroll_menu_down")]
                    if !down.exists { break }
                    down.tap(); usleep(200_000); paged = true
                }
                measure(target, key)
            }
            // Reset paging before navigating to the first program; measurement may have scrolled.
            if paged {
                // Modal menus intentionally expose only their own accessibility nodes.
                app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: introMenuFrame.midX, dy: introMenuFrame.midY)).tap()
                usleep(150_000); menu.tap(); usleep(250_000)
            }
            menuItem(ui(loc, "menu.start.god_words"), locale: loc); sleep(1)
            XCTAssertTrue(app.buttons[ui(loc, "topbar.menu")].waitForExistence(timeout: 5), "\(loc): localized top bar")
            let ten = app.buttons[ui(loc, "god.button.ten_words")]
            if ten.waitForExistence(timeout: 5) { ten.tap(); sleep(1) }
            shot("typo-\(loc)-3-god-words")
            app.buttons[ui(loc, "topbar.menu")].tap(); usleep(700_000)
            menuItem(ui(loc, "menu.start.about"), locale: loc); sleep(1)
            shot("typo-\(loc)-4-about")
            if loc == "ja-JP" || loc == "ar" {
                XCUIDevice.shared.orientation = .landscapeLeft; sleep(2)
                shot("typo-\(loc)-5-landscape")
                XCUIDevice.shared.orientation = .portrait; sleep(2)
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            // a device run has no TEMPLEOS_SHOTS folder on the Mac: the report is also an attachment
            let a = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); a.name = "typography.json"; a.lifetime = .keepAlways; add(a)
            if let output = shotDirectory {
                try? data.write(to: output.appendingPathComponent("typography.json"))
            }
        }
        XCTAssertTrue(failures.isEmpty, "labels rasterized below the display's resolution:\n" + failures.joined(separator: "\n"))
    }

    func testGodWordsLocalization() throws {
        let english = englishEntries()
        XCTAssertEqual(7569, english.count)
        app.launchArguments = ["-uitest-reset", "-AppleLanguages", "(en-US)", "-AppleLocale", "en_US"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        startMenu(); menuItem("God Words"); sleep(1)
        app.buttons["10 WORDS"].tap(); sleep(1)
        let t = godText("en-US")
        let words = t.components(separatedBy: flat(ui("en-US", "god.intro.entropy"))).last!.split(separator: " ").map(String.init)
        XCTAssertTrue(t.contains(flat(ui("en-US", "god.intro.entropy"))), "intro in \(t)")
        let ids = words.compactMap { w in english.firstIndex(of: w) }
        XCTAssertEqual(10, ids.count, "ten of Terry's entries: \(words)")
        shot("god-01-en-10-words")
        func same(_ loc: String, _ name: String) {
            let tr = vocabulary(loc, english: english)
            let expected = flat(ids.map { tr[$0] }.joined(separator: " "))
            // the language window stays open after a choice; Start > God Words focuses the existing window
            app.buttons[ui(loc, "topbar.menu")].tap(); usleep(500_000)
            menuItem(ui(loc, "menu.start.god_words"), locale: loc); sleep(1)
            let shown = godText(loc)
            XCTAssertTrue(squash(shown).hasSuffix(squash(expected)), "\(loc): expected \(expected) at the end of \(shown) (and no extra words)")
            shot(name)
        }
        chooseLanguage("en-US", "es-ES"); same("es-ES", "god-02-es-same-entries")
        chooseLanguage("es-ES", "ja-JP"); same("ja-JP", "god-03-ja-same-entries")
        chooseLanguage("ja-JP", "ar"); same("ar", "god-04-ar-same-entries")
        chooseLanguage("ar", "fr-FR"); same("fr-FR", "god-05-fr-same-entries")
        app.buttons[ui("fr-FR", "god.button.ten_words")].tap(); sleep(1)
        shot("god-06-fr-10-more")
        XCUIDevice.shared.orientation = .landscapeLeft; sleep(2)
        let land = godText("fr-FR")
        XCTAssertTrue(squash(land).contains(squash(ids.map { vocabulary("fr-FR", english: english)[$0] }.joined(separator: " "))), "landscape keeps the picks")
        shot("god-07-fr-landscape")
        XCUIDevice.shared.orientation = .portrait; sleep(2)
        // About (Japanese) and the documentation notice (Arabic)
        chooseLanguage("fr-FR", "ja-JP")
        app.buttons[ui("ja-JP", "topbar.menu")].tap(); usleep(500_000)
        menuItem(ui("ja-JP", "menu.start.about"), locale: "ja-JP"); sleep(1)
        let about = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", ui("ja-JP", "about.additions.title"))).firstMatch
        XCTAssertTrue(about.waitForExistence(timeout: 5), "About shows the new section")
        XCTAssertTrue(flat(about.label).contains(flat(ui("ja-JP", "about.additions.modern"))))
        XCTAssertTrue(flat(about.label).contains(flat(ui("ja-JP", "about.intro.creator"))))
        shot("god-08-ja-about")
        chooseLanguage("ja-JP", "ar")
        app.buttons[ui("ar", "topbar.menu")].tap(); usleep(500_000)
        menuItem(ui("ar", "menu.start.documentation"), locale: "ar"); sleep(2)
        let notice = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", ui("ar", "doc.notice.original.title"))).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 5), "documentation notice in Arabic")
        XCTAssertTrue(notice.label.contains("Terry A. Davis"))
        shot("god-09-ar-documentation-notice")
        // the in-app choice persists over the device language; Automatic returns to the device's (Spanish)
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(es-ES)", "-AppleLocale", "es_ES"]
        app.launch()
        XCTAssertTrue(app.buttons[ui("ar", "topbar.menu")].waitForExistence(timeout: 15), "in-app choice persists")
        chooseLanguage("ar", "")
        XCTAssertTrue(app.buttons[ui("es-ES", "topbar.menu")].waitForExistence(timeout: 5), "Automatic: device language")
        // an unsupported device language (Welsh) falls back to English
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(cy-GB)", "-AppleLocale", "cy_GB"]
        app.launch()
        XCTAssertTrue(app.buttons["MENU"].waitForExistence(timeout: 15), "unsupported device language: English")
        shot("god-10-cy-fallback-en")
    }

    func testLanguageFollowsDeviceAndInAppChoice() throws {
        app.launchArguments = ["-uitest-reset", "-AppleLanguages", "(de-DE)", "-AppleLocale", "de_DE"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let menuDe = app.buttons["MENU"]
        XCTAssertTrue(menuDe.waitForExistence(timeout: 15), "German device: intro MENU")
        shot("l10n_de_device")
        menuDe.tap(); sleep(1)
        app.buttons["Sprache..."].tap(); sleep(2)
        key("j"); key("a"); sleep(1)
        let ja = app.buttons["日本語 - Japanese"]
        XCTAssertTrue(ja.waitForExistence(timeout: 5), "filtered language list")
        ja.tap(); sleep(1)
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 5), "in-app choice applies at once")
        shot("l10n_ja_chosen")
        // the choice is saved: still Japanese on a German device after a restart
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(de-DE)", "-AppleLocale", "de_DE"]
        app.launch()
        let menuJa = app.buttons["メニュー"]
        XCTAssertTrue(menuJa.waitForExistence(timeout: 15), "choice persists")
        menuJa.tap(); sleep(1)
        app.buttons["言語..."].tap(); sleep(2)
        let auto = app.buttons["自動（デバイスの言語）"]
        XCTAssertTrue(auto.waitForExistence(timeout: 5))
        auto.tap(); sleep(1)
        XCTAssertTrue(app.buttons["MENÜ"].waitForExistence(timeout: 5), "Automatic follows the device again")
        // right-to-left
        app.terminate()
        app.launchArguments = ["-uitest-reset", "-AppleLanguages", "(ar-EG)", "-AppleLocale", "ar_EG"]
        app.launch()
        let menuAr = app.buttons["MENU"]
        XCTAssertTrue(menuAr.waitForExistence(timeout: 15), "Arabic device: intro MENU")
        menuAr.tap(); sleep(1)
        XCTAssertTrue(app.buttons[ui("ar", "menu.start.settings")].exists, "Arabic device: translated menu")
        shot("l10n_ar_menu")
    }

    /** Manifest rows of the Language window: label -> locale id (labels are "native - English", LanguageList). */
    private func languageRows() -> [String: String] {
        let m = try! JSONSerialization.jsonObject(with: Data(contentsOf: Self.repo.appendingPathComponent("shared/runtime/l10n/locales.json"))) as! [String: Any]
        var out: [String: String] = [:]
        for l in m["locales"] as! [[String: Any]] { out["\(l["native_name"] as! String) - \(l["english_name"] as! String)"] = (l["id"] as! String) }
        return out
    }

    /**
     * The Language window's rows top to bottom (the special Automatic row as ""), read from the accessibility tree
     * while dragging the list up; and the selected row's id.
     */
    private func readLanguageWindow(_ loc: String, _ rows: [String: String]) -> ([String], String?) {
        let auto = ui(loc, "settings.language.automatic")
        func visible() -> [XCUIElement] {
            app.buttons.allElementsBoundByIndex.filter { $0.exists && (rows[$0.label] != nil || $0.label == auto) && $0.frame.height > 0 }
                .sorted { $0.frame.minY < $1.frame.minY }
        }
        key(ui(loc, "key.escape")); usleep(600_000) // clears the filter and returns to the top of the list
        var out: [String] = [], selected: String? = nil
        for _ in 0..<40 {
            let v = visible()
            if let s = v.first(where: { $0.isSelected }) { selected = s.label == auto ? "" : rows[s.label] }
            let fresh = v.map { $0.label == auto ? "" : rows[$0.label]! }.drop { out.contains($0) }
            if fresh.isEmpty { break }
            out += fresh
            guard v.count >= 3 else { break }
            // drag the last visible row up to the first one
            let from = v[v.count - 1].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let to = v[0].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            from.press(forDuration: 0.05, thenDragTo: to); usleep(600_000)
        }
        return (out, selected)
    }

    /**
     * Language lists (docs/localization.md, "Language lists"): for each device language the Language window shows
     * Automatic, then all 89 languages exactly once, in the device language's collation of their visible names. Then
     * an in-app choice re-sorts the open window and keeps the choice selected, through rotation and a restart.
     * TEMPLEOS_ORDER_OUT (TEST_RUNNER_TEMPLEOS_ORDER_OUT for xcodebuild): directory for ios.json, the orders as ids,
     * compared with Android's by tools/l10n/language_order.py. Simulator only (reads the repository's files).
     */
    func testLanguageListOrder() throws {
        let rows = languageRows()
        let locales = (ProcessInfo.processInfo.environment["TEMPLEOS_ORDER_LOCALES"] ?? "en-US,ru-RU,ar,ja-JP,es-ES").split(separator: ",").map(String.init)
        let names = Dictionary(uniqueKeysWithValues: rows.map { ($0.value, String($0.key[..<$0.key.range(of: " - ")!.lowerBound])) })
        var orders: [String: [String]] = [:]
        XCUIDevice.shared.orientation = .portrait
        for loc in locales {
            app.terminate()
            app.launchArguments = ["-uitest-reset", "-AppleLanguages", "(\(loc))", "-AppleLocale", loc.replacingOccurrences(of: "-", with: "_")]
            app.launch()
            let menu = app.buttons["MENU"] // invariant branded intro; subsequent UI is localized
            XCTAssertTrue(menu.waitForExistence(timeout: 15), "\(loc) intro")
            menu.tap(); usleep(500_000)
            menuItem(ui(loc, "menu.start.language"), locale: loc); sleep(1)
            shot("language-order-\(loc)")
            let (order, selected) = readLanguageWindow(loc, rows)
            XCTAssertEqual("", order.first, "\(loc): Automatic first")
            XCTAssertEqual("", selected, "\(loc): Automatic is the current choice")
            let langs = Array(order.dropFirst())
            XCTAssertEqual(89, langs.count, "\(loc): \(langs)")
            XCTAssertEqual(Set(rows.values), Set(langs), "\(loc): every language once")
            let l = Locale(identifier: loc)
            for (a, b) in zip(langs, langs.dropFirst()) {
                XCTAssertNotEqual(.orderedDescending, names[a]!.compare(names[b]!, options: [], range: nil, locale: l), "\(loc): \(a) before \(b)")
            }
            orders[loc] = langs
        }
        if let dir = ProcessInfo.processInfo.environment["TEMPLEOS_ORDER_OUT"] {
            let j = try JSONSerialization.data(withJSONObject: ["platform": "ios", "orders": orders], options: [.prettyPrinted, .sortedKeys])
            try j.write(to: URL(fileURLWithPath: dir).appendingPathComponent("ios.json"))
        }
        // in-app choice while the window is open: the list re-sorts for Russian and Russian stays selected
        guard let en = orders["en-US"], let ru = orders["ru-RU"] else { return }
        app.terminate()
        app.launchArguments = ["-uitest-reset", "-AppleLanguages", "(en-US)", "-AppleLocale", "en_US"]
        app.launch()
        chooseLanguage("en-US", "ru-RU")
        var (order, selected) = readLanguageWindow("ru-RU", rows)
        XCTAssertEqual(ru, Array(order.dropFirst()), "in-app Russian: same order as a Russian device")
        XCTAssertNotEqual(en, ru)
        XCTAssertEqual("ru-RU", selected)
        shot("language-order-inapp-ru")
        XCUIDevice.shared.orientation = .landscapeLeft; sleep(2)
        (order, selected) = readLanguageWindow("ru-RU", rows)
        XCTAssertEqual(ru, Array(order.dropFirst()), "landscape")
        XCTAssertEqual("ru-RU", selected, "landscape")
        shot("language-order-inapp-ru-landscape")
        XCUIDevice.shared.orientation = .portrait; sleep(1)
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(en-US)", "-AppleLocale", "en_US"]
        app.launch()
        let menuRu = app.buttons[ui("ru-RU", "topbar.menu")]
        XCTAssertTrue(menuRu.waitForExistence(timeout: 15), "the choice persists")
        if !app.buttons["Русский - Russian"].exists { menuRu.tap(); usleep(500_000); menuItem(ui("ru-RU", "menu.start.language"), locale: "ru-RU"); sleep(1) }
        (order, selected) = readLanguageWindow("ru-RU", rows)
        XCTAssertEqual("ru-RU", selected, "restored")
        XCTAssertEqual(ru, Array(order.dropFirst()), "restored")
    }

    /**
     * The apps' name (README, "Names"): TempleOS.app in About, in English and in Spanish (the name is not translated),
     * with Terry A. Davis credited for TempleOS. The label under the icon is CFBundleDisplayName (checked by BrandTests
     * and on the home screen). Simulator only (reads the repository's files).
     */
    func testPrivacyPolicyOpensInSystemBrowser() throws {
        app.launchArguments = ["-uitest-reset", "-AppleLanguages", "(en-US)"]
        app.launch()
        startMenu(); menuItem("About & Credits")
        let privacy = app.buttons["Privacy: https://templeos.app/privacy"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 10))
        shot("privacy-action")
        privacy.tap()
        let browser = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(browser.wait(for: .runningForeground, timeout: 15), "the system browser handles the policy URL")
        app.activate()
        XCTAssertTrue(privacy.waitForExistence(timeout: 10), "About remains available after returning")
    }

    func testAppNameInAbout() throws {
        for loc in ["en-US", "es-ES"] {
            app.terminate()
            app.launchArguments = ["-uitest-reset", "-AppleLanguages", "(\(loc))", "-AppleLocale", loc.replacingOccurrences(of: "-", with: "_")]
            app.launch()
            XCUIDevice.shared.orientation = .portrait
            let menu = app.buttons["MENU"] // invariant branded intro
            XCTAssertTrue(menu.waitForExistence(timeout: 15), loc)
            menu.tap(); usleep(500_000)
            menuItem(ui(loc, "menu.start.about"), locale: loc); sleep(1)
            let page = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "TempleOS.app")).firstMatch
            XCTAssertTrue(page.waitForExistence(timeout: 5), "\(loc): About starts with the apps' name")
            XCTAssertTrue(page.label.contains("Terry A. Davis"), "\(loc): TempleOS credited to Terry A. Davis")
            XCTAssertFalse(page.label.contains("TempleOS Mobile"), "\(loc): no retired name")
            XCTAssertTrue(page.label.contains(ui(loc, "about.credits.native")), "\(loc): credits line with {app} filled in")
            shot("brand-about-\(loc)")
        }
    }

    func testTempleOSKeyboardTypesIntoTerminal() throws {
        app.launchArguments = ["-uitest-reset"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        readLayout(); sleep(2)
        // the start menu through accessibility elements, not coordinates
        let menu = app.buttons["MENU"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        app.buttons["Terminal"].tap(); sleep(4)
        XCTAssertFalse(app.keyboards.firstMatch.exists, "no device keyboard: TempleOS keyboard mode")
        for k in ["6", "Shift", "asterisk", "7", "semicolon", "Enter"] { key(k) } // 6*7;
        let answer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "ans=0x0000002A=42")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 15), "terminal answered 42")
        shot("14-templeos-keyboard-terminal")
        // landscape keeps the keyboard and the compact typing layout
        XCUIDevice.shared.orientation = .landscapeLeft; sleep(2)
        XCTAssertTrue(app.buttons["Enter"].exists, "keyboard still there after rotation")
        shot("15-templeos-keyboard-landscape")
        XCUIDevice.shared.orientation = .portrait; sleep(2)
        // HIDE, then the key row brings it back
        key("Hide keyboard"); sleep(1)
        XCTAssertFalse(app.buttons["Enter"].exists, "keyboard hidden")
        key("Show or hide keyboard"); sleep(1)
        XCTAssertTrue(app.buttons["Enter"].waitForExistence(timeout: 5), "keyboard back")
    }

    /**
     * docs/ui-normalization/TEMPLEOS_PROGRAM_LIFECYCLE_AUTHENTICITY_AUDIT.md: taps beside a running program
     * (black bars, empty gutters, edges, chrome, another window) never end it. After Tile, the buttons of
     * the maximized layout used to stay hit-testable over the picture: a tap there sent Esc and FlapBat
     * showed "Program ended. Restart from the menu.". Its own Exit still ends it with that message.
     */
    func testTapsOutsideTheProgramKeepItRunning() throws {
        app.launchArguments = ["-uitest-reset", "-AppleLanguages", "(en-US)"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        readLayout(); sleep(2)
        app.buttons["MENU"].tap(); sleep(1)
        app.buttons["Games..."].tap(); sleep(1)
        app.buttons["FlapBat"].tap()
        let okay = app.buttons["OKAY"]
        XCTAssertTrue(okay.waitForExistence(timeout: 20), "FlapBat's PopUpOk")
        let w = app.windows.firstMatch
        func at(_ x: Double, _ y: Double) { w.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y)).tap(); usleep(400_000) }
        let ended = app.staticTexts["Program ended. Restart from the menu."]
        at(w.frame.width / 2, w.frame.height * 0.85) // outside the popup: it stays
        XCTAssertTrue(okay.exists, "a tap outside the PopUp does not dismiss it")
        okay.tap(); sleep(3)
        let pic = app.staticTexts["Program picture: FlapBat"]
        XCTAssertTrue(pic.waitForExistence(timeout: 10), "playing")
        let below = app.buttons.allElementsBoundByIndex.filter { $0.frame.minY > pic.frame.maxY }.map { $0.frame.maxY }.max() ?? pic.frame.maxY
        for (name, x, y) in [("below the controls", w.frame.width / 2, (below + w.frame.height) / 2), ("left edge", 2.0, w.frame.height * 0.6),
                             ("right edge", w.frame.width - 2, w.frame.height * 0.6), ("home indicator", w.frame.width / 2, w.frame.height - 6),
                             ("top bar", w.frame.width * 0.75, (top + 10) * ppl), ("window chrome", w.frame.width / 2, (top + 30) * ppl)] {
            at(x, y)
            if app.buttons["Terminal"].exists { app.buttons["MENU"].tap(); sleep(1) } // a top-bar tap may open the start menu
            XCTAssertFalse(ended.exists, "portrait, \(name): the program ended")
            XCTAssertTrue(pic.exists, "portrait, \(name): the picture is gone")
        }
        shot("tap-outside-portrait")

        XCUIDevice.shared.orientation = .landscapeLeft; sleep(3); readLayout()
        let esc = app.buttons["Escape"].frame
        XCTAssertFalse(esc.isEmpty, "landscape: the action buttons are shown")
        for (name, x, y) in [("left gutter", pic.frame.minX / 2, w.frame.height * 0.9), ("below the buttons", esc.midX, w.frame.height - (w.frame.height - esc.maxY) / 3)] {
            at(x, y)
            XCTAssertFalse(ended.exists, "landscape, \(name): the program ended")
        }
        // Tile with the Welcome window: the picture now covers where the Escape button was
        app.buttons["Window menu: FlapBat"].tap(); sleep(1)
        app.buttons["Tile windows"].tap(); sleep(2)
        XCTAssertTrue(pic.frame.contains(CGPoint(x: esc.midX, y: esc.midY)), "tiled: \(esc) is now on the picture \(pic.frame)")
        at(esc.midX, esc.midY); sleep(1)
        shot("tap-outside-tiled")
        XCTAssertFalse(ended.exists, "tiled: a tap on the picture where Escape was ended the program")
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertFalse(app.buttons["Escape"].exists, "tiled: no controls fit, none are reachable")
        } else if app.buttons["Escape"].exists { // a large iPad has room for the tiled window's controls: real ones, laid out anew
            XCTAssertFalse(pic.frame.intersects(app.buttons["Escape"].frame), "tiled: Escape \(app.buttons["Escape"].frame) overlaps the picture \(pic.frame)")
        }

        // the program's own exit (File > Exit in FlapBat.HC's MenuPush) still ends it
        app.buttons["Window menu: FlapBat"].tap(); sleep(1)
        app.buttons.matching(NSPredicate(format: "label ENDSWITH 'Exit'")).firstMatch.tap()
        XCTAssertTrue(ended.waitForExistence(timeout: 10), "Exit ends FlapBat and says so")
        shot("tap-outside-exit")
        XCUIDevice.shared.orientation = .portrait
    }

    /**
     * Content moderation (docs/content-moderation/CONTENT_MODERATION.md) as a user meets it: God Words' "Holy Spirit
     * instructions" opens Terry's notes with the redaction markers and the adapted-document notice; rotation and
     * another UI language show the same moderated document; About states the editorial changes.
     */
    func testModeratedDocumentsShowRedactionMarkers() throws {
        app.launchArguments = ["-uitest-reset", "-AppleLanguages", "(en-US)", "-AppleLocale", "en_US"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        readLayout(); sleep(2)
        startMenu(); menuItem("God Words"); sleep(1)
        windowMenu("God Words"); menuItem("Holy Spirit instructions"); sleep(2)
        func has(_ s: String) -> Bool { app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch.waitForExistence(timeout: 5) }
        XCTAssertTrue(has("Adapted TempleOS Documentation"), "the adapted-document notice")
        XCTAssertTrue(has("censored or redacted by the TempleOS.app project"), "the notice names the project's edits")
        // the Q/A table is further down: scroll until a marker is on screen
        let w = app.windows.firstMatch
        var found = false
        for _ in 0..<25 where !found {
            found = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "redacted]")).firstMatch.exists
            if !found { w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).press(forDuration: 0.05, thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))) }
        }
        XCTAssertTrue(found, "a redaction marker is shown in the document")
        shot("moderation-hsnotes-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft; sleep(2)
        XCTAssertTrue(has("redacted]"), "landscape: the same moderated text")
        shot("moderation-hsnotes-landscape")
        XCUIDevice.shared.orientation = .portrait; sleep(2)
        // another UI language: the notice is translated, the document stays the same moderated English text
        app.terminate()
        app.launchArguments = ["-uitest-reset", "-AppleLanguages", "(de-DE)", "-AppleLocale", "de_DE"]
        app.launch(); readLayout(); sleep(2)
        let de = { (k: String) in self.ui("de-DE", k) }
        app.buttons[de("topbar.menu")].tap(); usleep(500_000)
        menuItem(de("menu.start.god_words")); sleep(1)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", de("a11y.window_menu").replacingOccurrences(of: "{title}", with: de("menu.start.god_words")))).firstMatch.tap()
        usleep(500_000)
        menuItem(de("god.menu.instructions")); sleep(2)
        XCTAssertTrue(has(de("doc.notice.adapted.title")), "German notice")
        var foundDe = false
        for _ in 0..<25 where !foundDe {
            foundDe = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "redacted]")).firstMatch.exists
            if !foundDe { w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).press(forDuration: 0.05, thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))) }
        }
        XCTAssertTrue(foundDe, "the moderated document with a German UI")
        shot("moderation-hsnotes-de")
        app.terminate()
        app.launchArguments = ["-uitest-reset", "-AppleLanguages", "(en-US)", "-AppleLocale", "en_US"]
        app.launch(); readLayout(); sleep(2)
        startMenu(); menuItem("About & Credits"); sleep(2)
        XCTAssertTrue(has("censored or redacted by this project"), "About states the editorial changes")
        shot("moderation-about")
    }

    /**
     * The TempleOS keyboard's visibility follows only attributed actions (docs/foldable/KEYBOARD_LIFECYCLE.md),
     * read from the view's accessibility value (kb, kbSeq, kbWhy): a modifier pressed alone on a physical keyboard
     * is not typing and leaves it up; typing puts it away; Cmd-. is back; HIDE and the key row's keyboard key are
     * the user's; and the keyboard still types into the running program afterwards.
     */
    func testKeyboardVisibilityFollowsOnlyAttributedActions() throws {
        app.launchArguments = ["-uitest-reset", "-input-diagnostics", "-AppleLanguages", "(en-US)", "-AppleLocale", "en_US"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        readLayout(); sleep(2)
        let v = app.descendants(matching: .any)["templeView"]
        func kb() -> (shown: Bool, seq: Int, why: String) {
            var r = (false, 0, "")
            for kv in ((v.value as? String) ?? "").split(separator: ";") {
                let p = kv.split(separator: "=", maxSplits: 1); guard p.count == 2 else { continue }
                if p[0] == "kb" { r.0 = p[1] == "1" } else if p[0] == "kbSeq" { r.1 = Int(p[1]) ?? 0 } else if p[0] == "kbWhy" { r.2 = String(p[1]) }
            }
            return r
        }
        startMenu(); menuItem("Terminal"); sleep(4)
        XCTAssertTrue(kb().shown, "the TempleOS keyboard is up for the terminal")
        // a modifier alone: not typing (UIKit delivers it to pressesBegan; it used to count as a physical keyboard)
        let before = kb().seq
        app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: []); sleep(1)
        XCTAssertTrue(kb().shown, "Shift alone does not put the TempleOS keyboard away")
        XCTAssertEqual(before, kb().seq, "no transition from a modifier alone")
        // typing on a physical keyboard: it steps aside, attributed to that
        app.typeKey("a", modifierFlags: []); sleep(1)
        XCTAssertTrue(kb().shown, "physical typing keeps software input available")
        app.assertTempleInputInvariant()
        key("Backspace") // remove the "a" typed above
        // the keyboard's own HIDE key, and back
        key("Hide keyboard"); sleep(1)
        XCTAssertFalse(kb().shown); XCTAssertEqual("user-hide", kb().why)
        key("Show or hide keyboard"); sleep(1)
        app.typeKey(".", modifierFlags: .command); sleep(1)
        print("PHYSICAL-INPUT " + ((v.value as? String) ?? ""))
        XCTAssertFalse(kb().shown, "Cmd-. backs out of the keyboard")
        XCTAssertEqual("back", kb().why)
        key("Show or hide keyboard"); sleep(1)
        // and it still types into the running terminal
        for k in ["6", "Shift", "asterisk", "7", "semicolon", "Enter"] { key(k) }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "ans=0x0000002A=42")).firstMatch.waitForExistence(timeout: 15), "the terminal answered 42")
        shot("keyboard-attributed-actions")
    }
    func testTextOwnersSaveReopenAndNoNativeKeyboard() throws {
        app.launchArguments = ["-uitest-reset", "-engine", "native", "-AppleLanguages", "(en-US)"]
        app.launch(); readLayout(); sleep(2)
        startMenu(); menuItem("Terminal"); useTempleKeyboard(); sleep(2)
        app.typeTempleText("6*7;\n")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "ans=0x0000002A=42")).firstMatch.waitForExistence(timeout: 20))
        key("Hide keyboard"); key("Show or hide keyboard")
        app.typeTempleText("8*8;\n")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "ans=0x00000040=64")).firstMatch.waitForExistence(timeout: 20))
        shot("input-terminal-answers")
        startMenu(); menuItem("HolyC Editor"); useTempleKeyboard()
        key("Control"); app.typeTempleText("a")
        app.typeTempleText("\"OK\\n\";")
        app.buttons["SAVE"].tap(); sleep(1)
        for _ in 0..<40 { key("Backspace") }
        app.typeTempleText("C:/Home/Kbd.HC\n"); sleep(1)
        if app.buttons["REPLACE"].exists { app.buttons["REPLACE"].tap() }
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Close Kbd.HC")).firstMatch.exists)
        app.assertTempleInputInvariant()
        shot("input-editor-saved")
        closeFocusedWindow("Kbd.HC")
        startMenu(); menuItem("Terminal"); useTempleKeyboard(); sleep(2)
        app.typeTempleText("Ed(\"C:/Home/Kbd.HC\");\n")
        let saved = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "OK\\n")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 20), "saved source reopens through the terminal")
        app.assertTempleInputInvariant()
        shot("input-editor-reopened")
        XCUIDevice.shared.orientation = .landscapeLeft; sleep(2)
        app.assertTempleInputInvariant()
        shot("input-editor-landscape")
        XCUIDevice.shared.orientation = .portrait; sleep(2)
        XCUIDevice.shared.press(.home); sleep(2); app.activate(); sleep(2)
        app.assertTempleInputInvariant()
        useTempleKeyboard(); app.typeTempleText(" ")
    }

    func testKeyboardLocaleMatrixWithoutSystemKeyboard() throws {
        let locales = ["en-US", "es-ES", "fr-FR", "de-DE", "ja-JP", "zh-CN", "zh-TW", "ar"]
        #if !targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment["TEMPLEOS_UI_STRINGS"] != nil else {
            throw XCTSkip("provide the repository locale dictionaries as TEMPLEOS_UI_STRINGS")
        }
        #endif
        for locale in locales {
            app.terminate()
            app.launchArguments = ["-uitest-reset", "-AppleLanguages", "(\(locale))", "-AppleLocale", locale.replacingOccurrences(of: "-", with: "_")]
            app.launch(); readLayout(); sleep(1)
            waitForSystemBanner()
            app.buttons["MENU"].tap(); menuItem(ui(locale, "menu.start.terminal"), locale: locale); sleep(2)
            XCTAssertTrue(app.buttons["q"].waitForExistence(timeout: 10), "US TempleOS keys under \(locale)")
            for label in ["6", ui(locale, "key.shift"), ui(locale, "char.asterisk"), "7", ui(locale, "char.semicolon"), ui(locale, "key.enter")] {
                key(label); app.assertTempleInputInvariant()
            }
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "ans=0x0000002A=42")).firstMatch.waitForExistence(timeout: 20), locale)
            app.assertTempleInputInvariant(); shot("input-locale-\(locale)")
        }
    }

    /// The audit's adaptive Settings and bounded dialog fixes on real simulator layouts.
    func testLocalizedSettingsAndProgramDialogs() throws {
        let locales = (ProcessInfo.processInfo.environment["TEMPLEOS_LAYOUT_LOCALES"] ?? "de-DE,ar,ja-JP")
            .split(separator: ",").map(String.init)
        for locale in locales {
            app.terminate()
            app.launchArguments = ["-uitest-reset", "-engine", "native", "-AppleLanguages", "(\(locale))"]
            XCUIDevice.shared.orientation = .portrait
            app.launch(); readLayout(); sleep(1)
            func select(_ label: String) {
                let button = app.buttons[label]
                for _ in 0..<24 {
                    if button.exists { break }
                    let down = app.buttons[ui(locale, "a11y.scroll_menu_down")]
                    if !down.exists { break }
                    down.tap(); usleep(200_000)
                }
                XCTAssertTrue(button.waitForExistence(timeout: 5), "\(locale): \(label)")
                if button.exists { button.tap(); usleep(500_000) }
            }
            app.buttons["MENU"].tap(); select(ui(locale, "menu.start.settings"))
            shot("layout-\(locale)-settings-portrait")
            XCUIDevice.shared.orientation = .landscapeLeft; sleep(1)
            let closeAll = app.buttons[ui(locale, "settings.close_all")]
            for _ in 0..<4 {
                if closeAll.exists && closeAll.isHittable { break }
                let window = app.windows.firstMatch
                window.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.63))
                    .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.28)))
                usleep(500_000)
            }
            XCTAssertTrue(closeAll.exists && closeAll.isHittable, "\(locale): last Settings action after scrolling")
            if closeAll.exists { XCTAssertTrue(app.windows.firstMatch.frame.contains(closeAll.frame)) }
            shot("layout-\(locale)-settings-landscape-scrolled")
            app.buttons[ui(locale, "topbar.menu")].tap(); select(ui(locale, "menu.start.games"))
            select(ui(locale, "games.catalog")); select("WaterFowl"); sleep(2)
            let title = "WaterFowl · Pure Swift"
            let template = ui(locale, "a11y.window_menu")
            let prefix = template.components(separatedBy: "{title}")[0]
            let windowMenu = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", prefix, title)).firstMatch
            XCTAssertTrue(windowMenu.waitForExistence(timeout: 10), "\(locale): native WaterFowl window")
            if windowMenu.exists { windowMenu.tap() }
            select(ui(locale, "program.menu.about"))
            let okay = app.buttons[ui(locale, "button.ok")], cancel = app.buttons[ui(locale, "button.cancel")]
            XCTAssertTrue(okay.waitForExistence(timeout: 5) && cancel.exists)
            for action in [okay, cancel] where action.exists {
                XCTAssertTrue(app.windows.firstMatch.frame.contains(action.frame), "\(locale): dialog action within display")
            }
            shot("layout-\(locale)-program-dialog-landscape")
            if cancel.exists { cancel.tap() }
            app.assertTempleInputInvariant()
        }
    }

}

extension XCUIApplication {
    /** Notification count catches transient native keyboards; the hierarchy independently catches visible ones. */
    func assertTempleInputInvariant(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(keyboards.firstMatch.exists, "Apple software keyboard must never appear", file: file, line: line)
        let view = descendants(matching: .any)["templeView"]
        if view.exists {
            XCTAssertTrue(((view.value as? String) ?? "").contains("nativeKeyboardViolations=0"),
                          "native keyboard appearance/frame notification violated input invariant", file: file, line: line)
        }
    }

    /** Real custom-key taps, including symbol-layer transitions; no native text-input injection. */
    func typeTempleText(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let names: [String: String] = [" ": "Space", "\n": "Enter", "\t": "Tab", "\u{8}": "Backspace",
            "\"": "quote", "'": "apostrophe", "`": "backtick", ";": "semicolon", ":": "colon", ",": "comma", ".": "period",
            "(": "left parenthesis", ")": "right parenthesis", "{": "left brace", "}": "right brace", "[": "left bracket", "]": "right bracket",
            "<": "less than", ">": "greater than", "=": "equals", "+": "plus", "-": "minus", "_": "underscore", "/": "slash",
            "\\": "backslash", "|": "vertical bar", "~": "tilde", "!": "exclamation mark", "@": "at", "#": "number sign", "$": "dollar",
            "%": "percent", "^": "caret", "&": "ampersand", "*": "asterisk", "?": "question mark"]
        assertTempleInputInvariant(file: file, line: line)
        for character in text {
            let value = String(character)
            let label = value == XCUIKeyboardKey.delete.rawValue ? "Backspace" : names[value] ?? value
            if !buttons[label].exists {
                if buttons["Letters"].exists { buttons["Letters"].tap() }
                if !buttons[label].exists && character.isLetter { buttons["Shift"].tap() }
                if !buttons[label].exists && !character.isLetter && buttons["Symbols"].exists { buttons["Symbols"].tap() }
            }
            let key = buttons[label].firstMatch
            XCTAssertTrue(key.waitForExistence(timeout: 5), "TempleOS key \(label)", file: file, line: line)
            guard key.exists else { return }
            key.tap()
            assertTempleInputInvariant(file: file, line: line)
        }
    }
}

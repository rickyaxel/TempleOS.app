import Foundation
import XCTest
@testable import TempleCore

/** Headless shell: real bundled drive, temp overlay, in-memory session store (port of HeadlessEnv). */
final class HeadlessEnv: ShellEnv {
    let fs: LayeredFs
    var session: String?
    var tones: [Double] = []
    lazy var stateStore: StateStore = MemStore(self)
    final class MemStore: StateStore {
        unowned let env: HeadlessEnv
        init(_ e: HeadlessEnv) { env = e }
        func load() throws -> String? { env.session }
        func save(_ text: String) throws { env.session = text }
    }
    init(_ overlay: URL) {
        fs = LayeredFs(DirBundle(SHARED.appendingPathComponent("bundled-fs"), SHARED.appendingPathComponent("bundled-fs.index")), overlay)
    }
    func runtimeFile(_ name: String) -> [UInt8]? {
        readFileBytes(name == "catalog.json" ? SHARED.appendingPathComponent("program-manifests/catalog.json") : SHARED.appendingPathComponent("runtime/\(name)"))
    }
    func tone(_ freq: Double, at atNs: Int64) { tones.append(freq) }
    /** Whether the device keyboard is requested. */
    var systemKeyboard = false
    func showKeyboard(_ show: Bool) { systemKeyboard = show }
}

/** Port of ShellUiTest.kt: every app opens, HolyC runs, a graphics program publishes frames, the session restores. */
final class ShellUiTests: XCTestCase {
    private let outDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/ui-shots")

    private func tmp() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("tosm-ui-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func waitFor(_ sh: Shell, _ ms: Int, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(Double(ms) / 1000)
        while Date() < end { _ = sh.tick(); if cond() { return true }; Thread.sleep(forTimeInterval: 0.02) }
        _ = sh.tick(); return cond()
    }

    /** Writes the surface plus program overlays as a PNG for manual inspection. */
    private func shot(_ sh: Shell, _ name: String) {
        _ = sh.tick()
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let s = sh.surface
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: s.width * s.height)
        defer { buf.deallocate() }
        buf.update(from: s.px, count: s.width * s.height)
        for o in sh.overlays() {
            let src = o.source
            let frame = UnsafeMutablePointer<UInt8>.allocate(capacity: src.frameW * src.frameH)
            defer { frame.deallocate() }
            _ = src.copyFrame(frame)
            for y in 0..<o.rect.h { for x in 0..<o.rect.w {
                let px = o.rect.x + x, py = o.rect.y + y
                if px >= 0 && px < s.width && py >= 0 && py < s.height {
                    buf[py * s.width + px] = frame[(y * src.frameH / o.rect.h) * src.frameW + x * src.frameW / o.rect.w]
                }
            } }
        }
        writePNG(buf, s.width, s.height, Palette.STD, to: outDir.appendingPathComponent("\(name).png"))
    }

    private func newShell(_ env: HeadlessEnv, _ w: Int, _ h: Int) -> Shell {
        let sh = Shell(env)
        sh.resize(w, h)
        sh.restoreSession()
        _ = sh.tick()
        return sh
    }

    /** A pause before the platform has read the saved session (OPPO: a system overlay before the first frame) must not overwrite it. */
    func testBackgroundBeforeRestoreKeepsTheSavedSession() throws {
        let dir = tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = HeadlessEnv(dir)
        let first = newShell(env, 360, 640)
        Launch.editor(first, nil); _ = first.tick()
        first.saveSession()
        let saved = try XCTUnwrap(env.session)
        XCTAssertTrue(saved.contains("win\teditor"), saved)
        first.windows.forEach { $0.app.close() }

        let sh = Shell(env); sh.awaitingRestore = true // as MainActivity / AppDelegate create it
        sh.resize(360, 640)
        sh.onBackground(); sh.onForeground()           // paused before the first layout
        XCTAssertEqual(env.session, saved, "the stored session is untouched")
        sh.restoreSession(); _ = sh.tick()
        XCTAssertTrue(sh.windows.contains { $0.app is EditorApp }, "and restores afterwards")
        sh.onBackground()                              // after the restore, saving works as before
        XCTAssertTrue(env.session?.contains("win\teditor") == true)
        sh.windows.forEach { $0.app.close() }
    }

    func testPortraitAppsOpenAndSessionRestores() throws {
        let dir = tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = HeadlessEnv(dir)
        let sh = newShell(env, 360, 640)
        shot(sh, "00-empty-desktop")
        XCTAssertTrue(sh.catalog.programs.count > 50, "catalog loads")

        Launch.files(sh, "C:/Home/Examples"); _ = sh.tick(); shot(sh, "01-files")
        Launch.doc(sh, "C:/Doc/HelpIndex.DD"); _ = sh.tick(); shot(sh, "02-doc")
        Launch.editor(sh, "C:/Home/Examples/Hello.HC"); _ = sh.tick(); shot(sh, "03-editor")
        Launch.god(sh); _ = sh.tick(); shot(sh, "04-god")
        Launch.about(sh); _ = sh.tick(); shot(sh, "05-about")
        Launch.settings(sh); _ = sh.tick(); shot(sh, "06-settings")
        Launch.paint(sh); _ = sh.tick(); shot(sh, "07-paint")
        sh.showStartMenu(); _ = sh.tick(); shot(sh, "08-start-menu")
        _ = sh.back()

        Launch.terminal(sh, "C:/Home", "\"Hello from the terminal %d\\n\", 6*7;")
        let term = sh.focused!.app as! TerminalApp
        XCTAssertTrue(waitFor(sh, 20000) { term.kernel.console.plainText().contains("Hello from the terminal 42") },
                      "terminal runs HolyC: " + term.kernel.console.plainText().takeLast(400))
        shot(sh, "09-terminal")

        let info = sh.catalog.byPath("C:/Home/Examples/Graphics.HC")
        Launch.program(sh, "C:/Home/Examples/Graphics.HC", info)
        let prog = sh.focused!.app as! ProgramApp
        // frames keep running; the published frame holds the drawing (static pictures are
        // published once, not every frame)
        let pk = prog.kernel!
        func drawn() -> Int { var n = 0; pk.publishLock.sync { for i in 0..<(640 * 480) where pk.published[i] != 0 { n += 1 } }; return n }
        XCTAssertTrue(waitFor(sh, 20000) { !sh.overlays().isEmpty && pk.frameCount > 2 && pk.publishedVersion >= 1 && drawn() > 1000 }, "graphics program publishes frames")
        Thread.sleep(forTimeInterval: 0.5); shot(sh, "10-program")

        let kinds = sh.windows.map { $0.app.kind }
        sh.saveSession()
        XCTAssertNotNil(env.session)
        sh.windows.forEach { $0.app.close() }

        let sh2 = newShell(env, 360, 640)
        XCTAssertEqual(kinds, sh2.windows.map { $0.app.kind }, "session restores the same windows")
        XCTAssertEqual("program", sh2.focused?.app.kind)
        sh2.windows.forEach { $0.app.close() }

        let sh3 = newShell(env, 800, 360)
        sh3.tile(); _ = sh3.tick(); shot(sh3, "11-landscape")
        sh3.windows.forEach { $0.app.close() }
    }

    func testPaintSavesGrThatRoundTrips() throws {
        let dir = tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = HeadlessEnv(dir)
        let sh = newShell(env, 360, 640)
        let p = PaintApp(sh); sh.open(p); _ = sh.tick()
        p.pix[10 * 320 + 10] = UInt8(Palette.RED)
        p.menu().first { $0.label == "Save as..." }!.action()
        let (ch, sc) = Keys.forChar(10)
        sh.key(ch, sc, true); _ = sh.tick()
        XCTAssertNotNil(env.fs.readFile("C:/Home/Picture.GR"), "picture saved")
        let p2 = PaintApp(sh, "C:/Home/Picture.GR")
        XCTAssertEqual(UInt8(Palette.RED), p2.pix[10 * 320 + 10])
        XCTAssertEqual(UInt8(Palette.WHITE), p2.pix[11 * 320 + 10])
    }

    /** Editor RUN of a quick console program, then the start menu must still open (iOS UI test regression). */
    func testMenuOpensAfterEditorRun() throws {
        let dir = tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = HeadlessEnv(dir)
        let sh = newShell(env, 402, 874)
        Launch.editor(sh, nil); _ = sh.tick()
        let ed = sh.focused!.app as! EditorApp
        ed.text("\"Edited\\n\";\n")
        _ = ed.save("C:/Home/MyTest.HC")
        ed.run()
        XCTAssertTrue(waitFor(sh, 20000) { (sh.focused?.app as? ProgramApp)?.isFinished == true }, "program ran")
        var t: Int64 = 1000
        func tap(_ x: Int, _ y: Int) {
            sh.pointer(PointerEvent(Ptr.DOWN, x, y, timeMs: t)); t += 50
            sh.pointer(PointerEvent(Ptr.UP, x, y, timeMs: t)); t += 50
            _ = sh.tick()
        }
        tap(20, 10)
        XCTAssertTrue(sh.popupOpen, "start menu opens after the program ended")
        shot(sh, "12-menu-after-run")
    }

    /** A finger drag on a program's canvas reaches the program as a held mouse button moving (Maze draws walls). */
    func testDragDrawsInMaze() throws {
        let dir = tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = HeadlessEnv(dir)
        let sh = newShell(env, 360, 640)
        Launch.program(sh, "C:/Demo/Games/Maze.HC", sh.catalog.byPath("C:/Demo/Games/Maze.HC"))
        let prog = sh.focused!.app as! ProgramApp
        XCTAssertTrue(waitFor(sh, 15000) { prog.kernel.frameCount >= 10 })
        let c = sh.overlays().first!.rect
        var t: Int64 = 1000
        let y = c.y + c.h / 3
        sh.pointer(PointerEvent(Ptr.DOWN, c.x + 10, y, timeMs: t))
        Thread.sleep(forTimeInterval: 0.2); _ = sh.tick()
        for x in stride(from: c.x + 10, through: c.right - 10, by: 4) {
            t += 16; sh.pointer(PointerEvent(Ptr.MOVE, x, y, timeMs: t)); _ = sh.tick(); Thread.sleep(forTimeInterval: 0.016)
        }
        sh.pointer(PointerEvent(Ptr.UP, c.right - 10, y, timeMs: t + 16))
        Thread.sleep(forTimeInterval: 0.3); _ = sh.tick()
        let k = prog.kernel!
        var lit = 0
        let ty = (y - c.y) * 480 / c.h
        k.publishLock.sync {
            // Maze copies its cell array one text row down (gr.text_base+TEXT_COLS): scan a band
            for yy in ty..<min(480, ty + 16) { for x in 0..<640 where k.published[yy * 640 + x] != 0 { lit += 1 } }
        }
        sh.windows.forEach { $0.app.close() }
        XCTAssertTrue(lit > 500, "a drawn wall spans the row (one cell is 64 px) (lit=\(lit))")
    }

    /** Demo/Graphics/Life.HC: cells drawn with a drag evolve (its animate task completes generations). Port of LifeTest.kt. */
    func testLifeDrawnCellsEvolve() throws {
        let dir = tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = HeadlessEnv(dir)
        let sh = newShell(env, 360, 640)
        Launch.program(sh, "C:/Demo/Graphics/Life.HC", sh.catalog.byPath("C:/Demo/Graphics/Life.HC"))
        let prog = sh.focused!.app as! ProgramApp
        let k = prog.kernel!
        XCTAssertTrue(waitFor(sh, 15000) { k.graphicsUsed && k.frameCount >= 10 })
        let c = sh.overlays().first!.rect
        var t: Int64 = 1000
        let y0 = c.y + c.h / 3
        sh.pointer(PointerEvent(Ptr.DOWN, c.x + 20, y0, timeMs: t)); Thread.sleep(forTimeInterval: 0.1); _ = sh.tick()
        for x in stride(from: c.x + 20, through: c.right - 20, by: 4) {
            t += 16; sh.pointer(PointerEvent(Ptr.MOVE, x, y0 + (x - c.x) / 4, timeMs: t)); _ = sh.tick(); Thread.sleep(forTimeInterval: 0.016)
        }
        sh.pointer(PointerEvent(Ptr.UP, c.right - 20, y0, timeMs: t + 16))
        func green() -> Int { var n = 0; k.publishLock.sync { for i in 0..<(640 * 480) where k.published[i] == 2 { n += 1 } }; return n }
        func g(_ name: String) -> Int64 { k.mem.ld8((k.prog.globals[name] as! GlobalSym).addr) }
        // Publication is asynchronous; a fixed sleep can sample the old empty frame
        // when other build/device suites contend for the host. Keep the pixel assertion.
        XCTAssertTrue(waitFor(sh, 15000) { green() > 100 }, "drawn cells were published")
        let before = green()
        var flips = 0; var last = g("cur_dc")
        // one generation is ~66M VM instructions: ~1 s in release, much longer in debug builds
        let until = Date().addingTimeInterval(60)
        while Date() < until && flips < 1 {
            _ = sh.tick(); Thread.sleep(forTimeInterval: 0.05)
            let cur = g("cur_dc"); if cur != last { flips += 1; last = cur }
        }
        _ = sh.tick(); Thread.sleep(forTimeInterval: 0.2); _ = sh.tick()
        let after = green()
        sh.windows.forEach { $0.app.close() }
        XCTAssertGreaterThan(before, 100, "drawing made green cells")
        XCTAssertGreaterThanOrEqual(flips, 1, "a generation completed")
        XCTAssertNotEqual(after, before, "the pattern changed")
    }

    /** A tap whose press and release arrive together still registers in programs that poll ms.lb (TicTacToe). */
    func testQuickTapRegisters() throws {
        let dir = tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = HeadlessEnv(dir)
        let sh = newShell(env, 360, 640)
        Launch.program(sh, "C:/Demo/Games/TicTacToe.HC", sh.catalog.byPath("C:/Demo/Games/TicTacToe.HC"))
        let prog = sh.focused!.app as! ProgramApp
        XCTAssertTrue(waitFor(sh, 15000) { prog.kernel.graphicsUsed && prog.kernel.frameCount >= 10 })
        let c = sh.overlays().first!.rect
        let x = c.x + 250 * c.w / 640, y = c.y + 250 * c.h / 480
        sh.pointer(PointerEvent(Ptr.DOWN, x, y, timeMs: 1000)); sh.pointer(PointerEvent(Ptr.UP, x, y, timeMs: 1001))
        let k = prog.kernel!
        let board = (k.prog.globals["board"] as! GlobalSym).addr
        XCTAssertTrue(waitFor(sh, 5000) { k.mem.ld1(board + 4) != 0 }, "centre cell taken by the first player")
        sh.windows.forEach { $0.app.close() }
    }

    /** The iOS acceptance flow with iOS-style touch ids (a new id per touch): menus must keep working. */
    func testIOSStyleTouchIds() throws {
        let dir = tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = HeadlessEnv(dir)
        let sh = newShell(env, 402, 874)
        sh.resize(402, 874, 62, 34, 0, 0, 0)
        var t: Int64 = 1000, id = 1
        func tap(_ x: Int, _ y: Int) {
            sh.pointer(PointerEvent(Ptr.DOWN, x, y + 62, id: id, timeMs: t)); t += 60
            sh.pointer(PointerEvent(Ptr.UP, x, y + 62, id: id, timeMs: t)); t += 60
            id += 1
            _ = sh.tick()
        }
        // taps go where the layout puts things (MenuMetrics), found through the accessibility nodes
        func tapNode(_ label: String) {
            _ = sh.tick() // the nodes are what the last render drew
            guard let r = sh.accessibilityNodes().first(where: { $0.label == label })?.rect else {
                XCTFail("no '\(label)' in \(sh.accessibilityNodes().map { $0.label })"); return
            }
            tap(r.x + r.w / 2, r.y + r.h / 2 - 62)
        }
        tapNode(tr("topbar.menu")); XCTAssertTrue(sh.popupOpen, "start menu")
        tapNode(tr("menu.start.editor")); XCTAssertEqual("editor", sh.focused?.app.kind)
        sh.text("\"Edited\\n\";\n")
        tapNode(tr("editor.button.save")); XCTAssertTrue(sh.dialogOpen, "save-as dialog")
        for _ in 0..<40 { sh.key(Keys.CH_BACKSPACE, Int64(Keys.SC_BACKSPACE), true) }
        sh.text("C:/Home/MyTest.HC\n")
        XCTAssertFalse(sh.dialogOpen, "dialog closed")
        tapNode(tr("editor.button.run"))
        XCTAssertTrue(waitFor(sh, 20000) { (sh.focused?.app as? ProgramApp)?.isFinished == true }, "program ran")
        tapNode(tr("topbar.menu"))
        XCTAssertTrue(sh.popupOpen, "start menu opens after RUN")
        sh.windows.forEach { $0.app.close() }
    }

    /** V-32: at the AUTO scale (1170x2532 px iPhone -> 390x844 logical) one logical px is 1 pt. */
    func testLargeTouchTargetsMeetMinimumSizeAndPersist() throws {
        let dir = tmp()
        defer { Touch.large = false; try? FileManager.default.removeItem(at: dir) }
        let env = HeadlessEnv(dir)
        let sh = Shell(env); sh.resize(390, 844, 47, 34, 0, 0, 0); _ = sh.tick()
        sh.settings.largeTouch = true; Touch.large = true; sh.relayout()
        let mm = sh.metrics
        XCTAssertTrue(ROW_H >= 44 && mm.rowH >= 44 && mm.barH >= 40 && Shell.KEY_ROW >= 44 && mm.chromeH + 8 >= 40, "\(mm)")
        var t: Int64 = 1000, id = 1
        func tap(_ x: Int, _ y: Int) {
            sh.pointer(PointerEvent(Ptr.DOWN, x, y, id: id, timeMs: t)); t += 60
            sh.pointer(PointerEvent(Ptr.UP, x, y, id: id, timeMs: t)); t += 60
            id += 1
            _ = sh.tick()
        }
        // start menu rows are metrics.rowH tall: the title row, then Terminal, HolyC Editor, Files...
        tap(20, 47 + mm.barH / 2); XCTAssertTrue(sh.popupOpen, "start menu")
        let editor = try XCTUnwrap(sh.accessibilityNodes().first {$0.button && $0.label == tr("menu.start.editor")}).rect
        XCTAssertGreaterThanOrEqual(editor.h,44)
        tap(editor.x + 30, editor.y + 2); XCTAssertEqual("editor", sh.focused?.app.kind, "editor row near its top edge")
        tap(20, 47 + mm.barH / 2)
        let files = try XCTUnwrap(sh.accessibilityNodes().first {$0.button && $0.label == tr("menu.start.files")}).rect
        XCTAssertGreaterThanOrEqual(files.h,44)
        tap(files.x + 30, files.bottom - 2); XCTAssertEqual("files", sh.focused?.app.kind, "files row near its bottom edge")
        XCTAssertTrue(EditorApp.HEADER >= 40 && FilesApp.HEADER >= 40)
        sh.saveSession()
        Touch.large = false
        let sh2 = Shell(env); sh2.resize(390, 844, 47, 34, 0, 0, 0); sh2.restoreSession()
        XCTAssertTrue(sh2.settings.largeTouch && Touch.large, "setting persists")
        sh.windows.forEach { $0.app.close() }; sh2.windows.forEach { $0.app.close() }
    }

    /** V-31: 2400x1080 px phone in landscape = 800x360 logical; the soft keyboard leaves ~90 px. */
    func testLandscapeKeyboardKeepsWindowSizeAndLeavesRoomToType() throws {
        let dir = tmp()
        defer { Touch.large = false; Touch.compact = false; try? FileManager.default.removeItem(at: dir) }
        let env = HeadlessEnv(dir)
        let sh = Shell(env); sh.resize(800, 360, 23, 16, 0, 0, 0); _ = sh.tick()
        sh.hideKeyboard() // explicit dismissal is separate from window geometry
        sh.settings.largeTouch = true; Touch.large = true; sh.relayout()
        Launch.editor(sh, "C:/Home/Examples/Hello.HC"); _ = sh.tick()
        let win = sh.focused!
        let before = [win.x, win.y, win.w, win.h]
        sh.hideKeyboard(); _ = sh.tick()
        XCTAssertFalse(sh.typingCompact)
        sh.requestKeyboard()
        sh.resize(800, 360, 23, 16, 0, 0, 246); _ = sh.tick() // keyboard up (height measured on the emulator)
        XCTAssertTrue(sh.typingCompact, "compact typing layout")
        XCTAssertTrue(Touch.compact && Shell.KEY_ROW == 24, "LARGE sizes give way while typing in landscape")
        let client = sh.clientRect(win)
        XCTAssertEqual(client.y, 23, "no top bar: the editor starts under the status bar")
        let textRows = (client.h - EditorApp.HEADER) / 8
        XCTAssertGreaterThanOrEqual(textRows, 6, "text rows above the keyboard")
        sh.pointer(PointerEvent(Ptr.DOWN, 20, 25, id: 1, timeMs: 1000)); sh.pointer(PointerEvent(Ptr.UP, 20, 25, id: 1, timeMs: 1050)); _ = sh.tick()
        XCTAssertFalse(sh.popupOpen, "the top bar is hidden: no start menu")
        sh.hideKeyboard()
        sh.resize(800, 360, 23, 16, 0, 0, 0); _ = sh.tick() // application keyboard dismissed
        XCTAssertFalse(sh.typingCompact); XCTAssertFalse(Touch.compact)
        XCTAssertEqual(before, [win.x, win.y, win.w, win.h], "floating window keeps its size")
        for w in sh.windows { w.app.close() }
    }
}

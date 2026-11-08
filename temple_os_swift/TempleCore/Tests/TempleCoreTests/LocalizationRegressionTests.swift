import Foundation
import XCTest
@testable import TempleCore

final class LocalizationRegressionTests: XCTestCase {
    private var directory: URL!
    private var shell: Shell!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tos-l10n-regression-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        shell = Shell(HeadlessEnv(directory)); shell.resize(320, 480)
        L10n.use("en-US")
    }

    override func tearDown() {
        shell.windows.forEach { $0.app.close() }
        L10n.use("en-US"); Touch.large = false
        try? FileManager.default.removeItem(at: directory)
    }

    func testEveryAppOwnedCatalogNoteAndHeadingHasALocalizedPresentation() {
        for locale in L10n.resolver!.locales {
            L10n.use(locale.id)
            for program in shell.catalog.programs where !program.note.isEmpty {
                XCTAssertNotNil(program.noteLocalizationKey, "\(locale.id): \(program.id)")
                if let key = program.noteLocalizationKey { XCTAssertTrue(L10n.has(key), key) }
                if program.note.hasPrefix("compile error: ") {
                    XCTAssertTrue(program.localizedNote.contains(String(program.note.dropFirst(15))), "technical diagnostic changed")
                }
            }
            for group in shell.catalog.groups {
                if ["dir.", "help.", "index."].contains(where: { group.id.hasPrefix($0) }) {
                    XCTAssertEqual(group.localizedTitle, group.title, "original directory/help identity")
                } else {
                    XCTAssertTrue(L10n.has("catalog.group.\(group.id)"), group.id)
                    XCTAssertEqual(group.localizedTitle, tr("catalog.group.\(group.id)"))
                }
            }
        }
    }

    func testOpenPresentationsRefreshWithoutDiscardingInputOrCallbacks() {
        let item = MenuItem(tr("menu.save")) {}
        let menu = PopupMenu([item], 4, 20, tr("app.settings.title"))
        var result: String?
        let dialog = Dialog.input(tr("editor.dialog.save_as"), "caf\u{82}.HC") { result = $0 }
        _ = dialog.key(65, 0, shell)
        L10n.use("ja-JP")
        XCTAssertEqual(item.label, tr("menu.save"))
        XCTAssertEqual(menu.title, tr("app.settings.title"))
        XCTAssertEqual(dialog.title, tr("editor.dialog.save_as"))
        XCTAssertEqual(dialog.items[1].0, tr("button.cancel"))
        XCTAssertNil(result)
        _ = dialog.key(10, 0, shell)
        XCTAssertEqual(result, "caf\u{82}.HCA")
        shell.open(FilesApp(shell, "C:/Home"))
        shell.showToast(tr("input.unsupported"))
        L10n.use("ar"); shell.invalidate(); _ = shell.tick()
        XCTAssertTrue(shell.accessibilityNodes().contains { $0.label == tr("input.unsupported") })
    }

    func testNarrowLocalizedToolbarsKeepAllActionsInsideTheWindow() {
        for editor in [false, true] {
            let app: App = editor ? EditorApp(shell, nil) : FilesApp(shell, "C:/Home")
            shell.open(app); shell.resize(240, 480)
            for locale in L10n.resolver!.locales {
                L10n.use(locale.id); shell.invalidate(); _ = shell.tick()
                let rect = shell.clientRect(shell.focused!)
                let keys = editor ? ["editor.button.run", "editor.button.save", "editor.button.undo", "editor.button.redo"]
                                  : ["files.a11y.up", "files.a11y.new", "files.a11y.new_folder", "files.a11y.home"]
                for key in keys {
                    let node = shell.accessibilityNodes().first { $0.label == tr(key) }
                    XCTAssertNotNil(node, "\(locale.id): \(key)")
                    if let node { XCTAssertTrue(node.rect.x >= rect.x && node.rect.right <= rect.right && node.rect.bottom <= rect.bottom, "\(locale.id): \(key)") }
                }
            }
            if let win = shell.focused { shell.close(win, force: true) }
        }
    }

    func testAccentedFilenameDisplayPreservesTheStoredBytePath() throws {
        let bytes = "caf\u{82}.HC", path = "C:/Home/" + bytes
        try shell.fs.writeFile(path, Array("\"OK\\n\";".utf8))
        let files = FilesApp(shell, "C:/Home"); shell.open(files); _ = shell.tick()
        XCTAssertTrue(shell.accessibilityNodes().contains { $0.label.contains("café.HC") })
        let editor = EditorApp(shell, path); shell.open(editor); _ = shell.tick()
        XCTAssertEqual(editor.title, "café.HC")
        XCTAssertEqual(editor.path, path)
        XCTAssertNotNil(shell.fs.readFile(path))
        let error = FsError("missing", "fs.error.not_found", ["path": path])
        XCTAssertTrue(error.localized().contains("café.HC"))
    }

    func testFilteredLanguageNamesWrapWithoutLosingTheirSelectionTarget() {
        let app = LanguageApp(shell); shell.open(app); shell.resize(240, 480)
        for locale in L10n.resolver!.locales {
            L10n.use(locale.id)
            _ = app.key(Keys.CH_ESC, 0, true)
            for ch in locale.id.utf8 { _ = app.key(Int(ch), 0, true) }
            shell.invalidate(); _ = shell.tick()
            let label = LanguageList.current().first { $0.id == locale.id }!.label
            let rect = shell.clientRect(shell.focused!)
            let needed = max(ROW_H, shell.surface.wrapUi(label, max(8, rect.w - 20)).count * 12 + 8) - 2
            var node = shell.accessibilityNodes().first { $0.label == label }
            for _ in 0..<90 {
                if let value = node, value.rect.h >= needed { break }
                app.scroll(0, -ROW_H, rect); _ = shell.tick()
                node = shell.accessibilityNodes().first { $0.label == label }
            }
            XCTAssertNotNil(node, locale.id)
            if let node {
                let rect = shell.clientRect(shell.focused!)
                XCTAssertTrue(node.rect.x >= rect.x && node.rect.right <= rect.right && node.rect.bottom <= rect.bottom, locale.id)
                XCTAssertGreaterThanOrEqual(node.rect.h, shell.surface.wrapUi(label, max(8, rect.w - 20)).count * 12 + 6, locale.id)
            }
        }
    }

    func testFileSizesUseAUnitWithoutEnglishPluralAssumptions() {
        for locale in L10n.resolver!.locales {
            L10n.use(locale.id)
            for size in [0, 1, 2, 11, 1001] {
                let label = tr("files.a11y.file_item", ("name", "Test.HC"), ("size", size))
                XCTAssertTrue(label.contains("\(size) B"), "\(locale.id): \(label)")
                XCTAssertTrue(label.contains("Test.HC"))
            }
        }
    }

    func testDraggingWrappedLanguageRowsDoesNotSkipAnyLocale() {
        shell.resize(240, 480)
        for locale in ["en-US", "ru-RU", "ar", "ja-JP", "es-ES"] {
            L10n.use(locale)
            let app = LanguageApp(shell); shell.open(app)
            let labels = Set(LanguageList.current().map { $0.label } + [tr("settings.language.automatic")])
            for direction in [-1, 1] {
                var seen = Set<String>()
                for _ in 0..<180 {
                    shell.invalidate(); _ = shell.tick()
                    let visible = shell.accessibilityNodes().filter { labels.contains($0.label) }.sorted { $0.rect.y < $1.rect.y }
                    seen.formUnion(visible.map { $0.label })
                    if seen == labels { break }
                    guard let first = visible.first, let last = visible.last else { break }
                    let distance = max(ROW_H, last.rect.y + last.rect.h / 2 - first.rect.y - first.rect.h / 2)
                    app.scroll(0, direction * distance, shell.clientRect(shell.focused!))
                }
                XCTAssertEqual(labels, seen, "\(locale), direction \(direction): skipped language row")
            }
            if let win = shell.focused { shell.close(win, force: true) }
        }
    }

    func testEveryLocaleResolvesItsOwnCatalogWithoutHiddenEnglishFallback() throws {
        let root = SHARED.appendingPathComponent("runtime/l10n")
        for locale in L10n.resolver!.locales {
            let data = try Data(contentsOf: root.appendingPathComponent("\(locale.catalog).json"))
            let catalog = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            L10n.use(locale.id)
            XCTAssertEqual(L10n.locale?.id, locale.id)
            for (key, value) in catalog where !key.hasPrefix("$") {
                let expected = (value as! String).replacingOccurrences(of: "{app}", with: Brand.appName)
                XCTAssertEqual(tr(key), expected, "\(locale.id): \(key)")
            }
        }
    }

    func testArgumentsAreLiteralEvenWhenTheyContainAnotherPlaceholder() {
        for locale in L10n.resolver!.locales {
            L10n.use(locale.id)
            let text = tr("engine.unavailable.message", ("title", "C:/Home/{engine}/{reason}.HC"),
                          ("engine", "Pure Terry"), ("reason", "detail {title}"))
            XCTAssertTrue(text.contains("C:/Home/{engine}/{reason}.HC"), locale.id)
            XCTAssertTrue(text.contains("detail {title}"), locale.id)
        }
    }

    func testNarrowWrappingKeepsGraphemesIntact() {
        let surface = shell.surface
        surface.measureNative = { $0.unicodeScalars.count * 10 }
        for cluster in ["a\u{301}", "कि", "ก้", "👩‍💻", "🇯🇵", "😊"] {
            XCTAssertEqual(surface.wrapUi(cluster + cluster, 8), [cluster, cluster], cluster)
        }
        XCTAssertEqual(surface.wrapUi("abc def\n\nxyz", 24), ["abc", "def", "", "xyz"])
    }

    func testInputDialogSpeaksDecodedCp437Characters() {
        let dialog = Dialog.input("File", "caf\u{82}.HC") { _ in }
        shell.showDialog(dialog); _ = shell.tick()
        XCTAssertTrue(shell.accessibilityNodes().contains { $0.label == tr("a11y.text_field", ("text", "café.HC")) })
    }

    func testSettingsCanScrollToLastActionInEveryLocale() {
        let app = SettingsApp(shell); shell.open(app)
        for locale in L10n.resolver!.locales {
            L10n.use(locale.id)
            shell.resize(480, 240); shell.invalidate(); _ = shell.tick()
            let rect = shell.clientRect(shell.focused!)
            app.scroll(0, -10000, rect); _ = shell.tick()
            let last = shell.accessibilityNodes().first { $0.label == tr("settings.close_all") }
            XCTAssertNotNil(last, locale.id)
            if let last = last {
                XCTAssertTrue(last.rect.y >= rect.y && last.rect.bottom <= rect.bottom, "\(locale.id): last Settings action is reachable")
            }
        }
    }

    func testLongLocalizedDialogStaysWithinItsUsableArea() {
        shell.resize(320, 240)
        for locale in L10n.resolver!.locales {
            L10n.use(locale.id)
            let message = tr("engine.unavailable.message", ("title", String(repeating: "filename", count: 20)),
                             ("engine", "Pure Swift"), ("reason", tr("engine.reason.runtime_compile")))
            let dialog = Dialog.confirm(tr("engine.unavailable.title", ("engine", "Pure Swift")), message, tr("button.ok")) {}
            shell.showDialog(dialog); _ = shell.tick()
            let area = shell.dialogArea()
            XCTAssertGreaterThan(dialog.bounds.h, 0)
            XCTAssertTrue(dialog.bounds.y >= area.y && dialog.bounds.bottom <= area.bottom,
                          "\(locale.id): dialog \(dialog.bounds) in \(area)")
            XCTAssertTrue(shell.accessibilityNodes().contains { $0.label == message }, "full recovery text remains accessible")
            XCTAssertTrue(shell.accessibilityNodes().contains { $0.label == tr("button.cancel") })
        }
    }

    /**
     * The game controls' own labels (touch mode, wheel) are translated and fit their buttons, the key caps stay as
     * they are, and every button sends exactly what it sends in English: the same key codes, wheel notches and touch
     * modes, in the same order. The labels never decide what a button does.
     */
    func testGameControlsAreTranslatedWithoutChangingTheirInput() {
        shell.resize(720, 720)
        let info = ProgramInfo("test", "Test", "game", "C:/Test.HC", "interpreted_holyc", "Terry A. Davis", "Public domain (TempleOS)",
                               "TempleOS V5.03 ISO", ["arrows", "ctrl", "shift", "wheel", "mouse"], ["graphics"], "any", "")
        let portrait = Rect(0, 300, 360, 360)
        let landscape = (Rect(0, 0, 100, 360), Rect(544, 0, 96, 360))
        struct Result { var events: [String] = [], labels: [[String]] = [], spoken: [[String]] = [], rects: [[Rect]] = [], modes: [Int] = [] }
        func press(_ locale: String, _ gutter: Bool) -> Result {
            L10n.use(locale)
            var sent: [String] = []
            let controls = GameControls { e in if case let .key(ch, sc, down) = e { sent.append("key \(ch) \(sc) \(down)") } }
            controls.onWheel = { sent.append("wheel \($0)") }
            var result = Result()
            func layout() {
                if gutter { controls.draw(shell.surface, landscape.0, [], vertical: false, showDpad: true, actionArea: landscape.1, info: info) }
                else { controls.draw(shell.surface, portrait, [], vertical: true, showDpad: true, info: info) }
                var s: [String] = [], r: [Rect] = []
                controls.accessibility { rect, label, _ in r.append(rect); s.append(label) }
                result.labels.append(controls.labels); result.spoken.append(s); result.rects.append(r); result.modes.append(controls.clickMode)
            }
            layout()
            // every button once, then the touch-mode toggle until it is back where it started
            let count = result.rects[0].count
            for i in Array(0..<count) + [count - 1, count - 1] {
                let r = result.rects.last![i]
                _ = controls.pointer(PointerEvent(Ptr.DOWN, r.x + r.w / 2, r.y + r.h / 2, id: 1))
                _ = controls.pointer(PointerEvent(Ptr.UP, r.x + r.w / 2, r.y + r.h / 2, id: 1))
                result.events.append("\(i): \(sent) mode \(controls.clickMode)"); sent.removeAll()
                layout()
            }
            return result
        }
        let modeKeys = ["left_click", "right_click", "hover"]
        for gutter in [false, true] {
            let english = press("en-US", gutter)
            let keyCaps = Array(english.labels[0].dropLast(3)) // arrows, SPACE ENTER ESC, CTRL SHIFT
            XCTAssertEqual(["\u{18}", "\u{1B}", "\u{1A}", "\u{19}", "SPACE", "ENTER", "ESC", "CTRL", "SHIFT"], keyCaps)
            XCTAssertEqual([1, 2, 0], Array(english.modes.suffix(3)), "the toggle cycles through all three modes")
            for locale in L10n.resolver!.locales {
                let result = press(locale.id, gutter)
                L10n.use(locale.id)
                XCTAssertEqual(english.events, result.events, "\(locale.id): input")
                for (step, labels) in result.labels.enumerated() {
                    let mode = modeKeys[result.modes[step]]
                    XCTAssertEqual(keyCaps, Array(labels.dropLast(3)), "\(locale.id): key caps")
                    XCTAssertEqual([tr("controls.button.wheel_up"), tr("controls.button.wheel_down"), tr("controls.button.\(mode)")], Array(labels.suffix(3)))
                    XCTAssertEqual([tr("controls.a11y.wheel_up"), tr("controls.a11y.wheel_down"), tr("controls.a11y.\(mode)")], Array(result.spoken[step].suffix(3)))
                    let rects = result.rects[step]
                    XCTAssertEqual(result.rects[0].last, rects.last, "\(locale.id): the toggle keeps its place and size while it cycles")
                    let area = gutter ? landscape.1 : portrait
                    for (i, r) in rects.enumerated() {
                        if i >= 4 { XCTAssertTrue(r.x >= area.x && r.right <= area.right && r.bottom <= area.bottom, "\(locale.id): \(labels[i]) \(r) inside \(area)") }
                        for o in rects.dropFirst(i + 1) { let x = r.intersect(o); XCTAssertTrue(x.w <= 0 || x.h <= 0, "\(locale.id): \(r) overlaps \(o)") }
                        if !gutter || Cp437.representable(labels[i]) {
                            XCTAssertLessThanOrEqual(shell.surface.measureUi(labels[i]), r.w - 4, "\(locale.id): \"\(labels[i])\" fits")
                        }
                    }
                }
            }
        }
    }

    /**
     * Stop is the app's command: the end line is the app's own, while the engine's message stays for the console.
     * The program catches nothing, so Break ends it with the engine's message (a game with its own catch ends normally).
     */
    func testStoppingAProgramEndsWithALocalizedLine() throws {
        shell.resize(360, 640)
        let source = latin1("U0 DrawIt(CTask *,CDC *dc) { dc->color=RED; GrRect(dc,10,10,50,50); }\nFs->draw_it=&DrawIt;\nwhile (TRUE) Sleep(20);\n")
        let app = ProgramApp(shell, "C:/Home/StopTest.HC", nil, source)
        _ = shell.open(app, maximized: true)
        let end = Date().addingTimeInterval(20)
        while Date() < end && !(app.kernel.graphicsUsed && app.kernel.frameCount >= 5) { _ = shell.tick(); Thread.sleep(forTimeInterval: 0.016) }
        XCTAssertTrue(app.kernel.graphicsUsed, "the program draws")
        L10n.use("es-ES")
        app.stop()
        let stopped = Date().addingTimeInterval(10)
        while Date() < stopped && !app.isFinished { _ = shell.tick(); Thread.sleep(forTimeInterval: 0.016) }
        XCTAssertTrue(app.isFinished)
        shell.invalidate(); _ = shell.tick()
        let labels = shell.accessibilityNodes().map(\.label)
        XCTAssertTrue(labels.contains(tr("program.ended")), "\(labels)")
        XCTAssertFalse(labels.contains { $0.hasPrefix(tr("program.ended_with", ("reason", ""))) }, "\(labels)")
        let engine = try XCTUnwrap(app.kernel.exitMessage, "the engine's own message is kept")
        XCTAssertFalse(labels.contains { $0.contains(String(engine.prefix(40))) }, "\(labels)")
        XCTAssertEqual(ExitCategory.STOPPED, app.kernel.exitCategory)
    }

    func testProgramAuthorsArePeopleOrTheProject() {
        for locale in ["en-US", "es-ES", "ja-JP", "ar"] {
            L10n.use(locale)
            for p in shell.catalog.programs {
                XCTAssertTrue(p.author == "Terry A. Davis" || p.author == ProgramInfo.projectAuthor, "\(p.id): \(p.author)")
                if p.author == ProgramInfo.projectAuthor { XCTAssertEqual(tr("catalog.author.project"), p.localizedAuthor) }
                else { XCTAssertEqual(p.author, p.localizedAuthor, "a person's name is never translated") }
            }
        }
        L10n.use("es-ES")
        XCTAssertTrue(tr("catalog.author.project").contains(Brand.appName))
    }

    /** The Terminal banner is console text: translated where the TempleOS font can show it, otherwise English. */
    func testTerminalBannerNamesTheTerminalInTheUiLanguage() {
        for (locale, expected) in [("it-IT", "Terminale"), ("ja-JP", "Terminal")] {
            L10n.use(locale)
            Launch.terminal(shell)
            let term = shell.focused!.app as! TerminalApp
            let end = Date().addingTimeInterval(10)
            while Date() < end && !(term.kernel?.console.plainText().contains(Brand.appName) ?? false) { _ = shell.tick(); Thread.sleep(forTimeInterval: 0.02) }
            let banner = term.kernel.console.plainText()
            XCTAssertTrue(banner.contains("\(Brand.appName) \(expected) - "), banner)
            shell.close(shell.focused!, force: true)
        }
    }

    func testDialogTextScrollReachesTheEndWithoutActivatingAnAction() throws {
        shell.resize(320, 240)
        let message = String(repeating: "日本語の説明 ", count: 80) + "終端"
        var confirmed = false
        let dialog = Dialog.confirm("Dialog", message, tr("button.ok")) { confirmed = true }
        shell.showDialog(dialog); _ = shell.tick()
        let rect = try XCTUnwrap(shell.accessibilityNodes().first { $0.label == message }?.rect)
        _ = dialog.pointer(PointerEvent(Ptr.DOWN, rect.x + 8, rect.bottom - 4), shell)
        _ = dialog.pointer(PointerEvent(Ptr.MOVE, rect.x + 8, rect.y + 4), shell)
        XCTAssertFalse(dialog.pointer(PointerEvent(Ptr.UP, rect.x + 8, rect.y + 4), shell))
        for _ in 0..<80 { _ = dialog.key(0, Int64(Keys.SC_PAGE_DOWN), shell); shell.invalidate(); _ = shell.tick() }
        XCTAssertFalse(confirmed)
        XCTAssertTrue(shell.surface.runs.contains { $0.text.contains("終端") }, "last line is reachable")
        XCTAssertTrue(shell.accessibilityNodes().contains { $0.label == tr("button.cancel") })
    }
}

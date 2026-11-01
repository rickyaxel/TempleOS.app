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

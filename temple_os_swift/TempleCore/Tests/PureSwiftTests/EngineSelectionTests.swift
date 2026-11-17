import Foundation
import XCTest
import TempleCore
import PureSwift

// Port of the default-engine tests in purekotlin/.../EngineSelectionTest.kt.

/** The rules behind Settings > Engine: what runs natively by default, and when the app must ask. */
final class EngineSelectionTests: XCTestCase {
    private final class Env: ShellEnv {
        let fs: LayeredFs
        let stateStore: StateStore = Store()
        private final class Store: StateStore {
            private var text: String?
            func load() -> String? { text }
            func save(_ value: String) { text = value }
        }
        init(_ dir: URL) { fs = LayeredFs(DirBundle(SHARED.appendingPathComponent("bundled-fs"), SHARED.appendingPathComponent("bundled-fs.index")), dir) }
        func runtimeFile(_ name: String) -> [UInt8]? { readFileBytes(SHARED.appendingPathComponent(name == "catalog.json" ? "program-manifests/catalog.json" : "runtime/" + name)) }
    }

    private func shell(_ test: (Shell) throws -> Void) throws {
        NativePrograms.catalog = NativeCatalog.source
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("engine-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sh = Shell(Env(dir)); sh.resize(402, 874); _ = sh.tick()
        defer { sh.windows.forEach { sh.close($0, force: true) }; try? FileManager.default.removeItem(at: dir) }
        try test(sh)
    }

    private func waitFor(_ sh: Shell, _ seconds: Double, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { _ = sh.tick(); if cond() { return true }; Thread.sleep(forTimeInterval: 0.02) }
        _ = sh.tick(); return cond()
    }

    /** No engine chosen (a fresh install): a program runs natively where its translation can run, in Pure Terry otherwise, and nothing asks. */
    func testDefaultRunsTranslationsNativelyAndTheRestInPureTerryWithoutAsking() throws {
        try shell { sh in
            XCTAssertEqual(Settings.ENGINE_DEFAULT, sh.settings.engine)
            func launch(_ path: String) throws -> ProgramApp {
                Launch.program(sh, path, nil); _ = sh.tick()
                XCTAssertFalse(sh.dialogOpen, path)
                return try XCTUnwrap(sh.focused?.app as? ProgramApp)
            }
            let golf = "C:/Demo/Games/BomberGolf.HC"
            let native = try launch(golf)
            XCTAssertNotNil(native.native)
            XCTAssertTrue(waitFor(sh, 30) { native.kernel.frameCount > 10 }, "BomberGolf runs")
            XCTAssertNil(native.kernel.exitMessage, native.kernel.console.plainText())
            XCTAssertEqual(0, native.kernel.vm.instructionsExecuted)
            sh.close(try XCTUnwrap(sh.focused), force: true)
            // the user's own HolyC has no translation
            try sh.fs.writeFile("C:/Home/Mine.HC", latin1("\"mine\\n\";\n"))
            let mine = try launch("C:/Home/Mine.HC")
            XCTAssertNil(mine.native)
            XCTAssertTrue(waitFor(sh, 30) { mine.kernel.console.plainText().contains("mine") }, "the user's program runs")
            sh.close(try XCTUnwrap(sh.focused), force: true)
            // an edited bundled file no longer matches its translation
            try sh.fs.writeFile(golf, try XCTUnwrap(sh.fs.readFile(golf)) + latin1("\n// edited\n"))
            XCTAssertNil(try launch(golf).native)
        }
    }

    /** A chosen Pure Swift is explicit: what it cannot run is offered in Pure Terry, never run there quietly. */
    func testChosenPureSwiftAsksBeforeRunningInPureTerry() throws {
        try shell { sh in
            sh.settings.engine = Settings.ENGINE_NATIVE
            try sh.fs.writeFile("C:/Home/Mine.HC", latin1("\"mine\\n\";\n"))
            Launch.program(sh, "C:/Home/Mine.HC", nil); _ = sh.tick()
            XCTAssertTrue(sh.dialogOpen)
            XCTAssertFalse(sh.windows.contains { $0.app is ProgramApp })
            sh.key(10, Keys.forChar(10).1, true); _ = sh.tick()
            XCTAssertFalse(sh.dialogOpen)
            XCTAssertNil(try XCTUnwrap(sh.focused?.app as? ProgramApp).native)
        }
    }

    /** Settings > Engine shows Pure Swift before any choice; a tap chooses Pure Terry, the next one Pure Swift. */
    func testSettingsRowShowsTheDefaultAndChooses() throws {
        try shell { sh in
            Launch.settings(sh); _ = sh.tick()
            func tapRow(_ name: String) throws {
                let r = try XCTUnwrap(sh.accessibilityNodes().first { $0.label == tr("settings.engine", ("value", name)) }?.rect)
                sh.focused!.app.tap(r.x + r.w / 2, r.y + r.h / 2, r); _ = sh.tick()
            }
            XCTAssertTrue(Engines.selectsNative(sh.settings))
            try tapRow(Engines.NATIVE_NAME); XCTAssertEqual(Settings.ENGINE_TERRY, sh.settings.engine)
            try tapRow(Engines.TERRY_NAME); XCTAssertEqual(Settings.ENGINE_NATIVE, sh.settings.engine)
            try tapRow(Engines.NATIVE_NAME); XCTAssertEqual(Settings.ENGINE_TERRY, sh.settings.engine)
        }
    }
}

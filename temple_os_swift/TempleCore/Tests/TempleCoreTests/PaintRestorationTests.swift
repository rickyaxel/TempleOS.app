import Foundation
import CryptoKit
import XCTest
@testable import TempleCore

final class PaintRestorationTests: XCTestCase {
    private func withApp(_ body: (PaintApp, Shell, HeadlessEnv) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = HeadlessEnv(dir), shell = Shell(env)
        shell.resize(640, 700)
        let app = PaintApp(shell); shell.open(app); _ = shell.tick()
        try body(app, shell, env)
    }

    func testOriginalCompressedGRIsNotCropped() throws {
        try withApp { _, sh, env in
            let bytes = try XCTUnwrap(env.fs.readFile("C:/Demo/Games/Stadium/StadiumBG.GR"))
            let image = try GRImage.decode(bytes)
            XCTAssertEqual(image.width, 641); XCTAssertEqual(image.height, 473)
            let golden = try JSONSerialization.jsonObject(with: Data(contentsOf: SHARED.appendingPathComponent("test-vectors/paint/gr-golden.json"))) as! [String: Any]
            let hash = SHA256.hash(data: Data(image.body)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hash, golden["body_sha256"] as? String)
            let app = PaintApp(sh, "C:/Demo/Games/Stadium/StadiumBG.GR")
            XCTAssertEqual(app.w, 641); XCTAssertEqual(app.h, 473)
            XCTAssertTrue(app.pix == image.pixels, "decoded pixels differ")
        }
    }

    func testCancelDoesNotDrawToCancelPosition() throws {
        try withApp { app, sh, _ in
            let r = Rect(0, 0, 640, 600); app.draw(sh.surface, r)
            _ = app.pointer(PointerEvent(Ptr.DOWN, 200, 280, id: 7), r)
            let before = app.pix
            _ = app.pointer(PointerEvent(Ptr.CANCEL, 500, 400, id: 7), r)
            XCTAssertTrue(app.pix == before, "unexpected pixel mutation")
            _ = app.pointer(PointerEvent(Ptr.MOVE, 400, 380, id: 7), r)
            XCTAssertTrue(app.pix == before, "unexpected pixel mutation")
        }
    }

    func testExtraFingerCannotDrawOrChangeTool() throws {
        try withApp { app, sh, _ in
            let r = Rect(0, 0, 640, 600); app.draw(sh.surface, r)
            _ = app.pointer(PointerEvent(Ptr.DOWN, 200, 280, id: 7), r)
            let before = app.pix
            _ = app.pointer(PointerEvent(Ptr.DOWN, 500, 400, id: 8), r)
            _ = app.pointer(PointerEvent(Ptr.UP, 520, 420, id: 8), r)
            XCTAssertTrue(app.pix == before, "unexpected pixel mutation")
            _ = app.pointer(PointerEvent(Ptr.MOVE, 220, 300, id: 7), r)
            XCTAssertFalse(app.pix == before, "stroke did not change pixels")
        }
    }

    func testFocusReleaseEndsStroke() throws {
        try withApp { app, sh, _ in
            let r = Rect(0, 0, 640, 600); app.draw(sh.surface, r)
            _ = app.pointer(PointerEvent(Ptr.DOWN, 200, 280, id: 7), r)
            app.releaseInput(); let before = app.pix
            _ = app.pointer(PointerEvent(Ptr.UP, 500, 400, id: 7), r)
            XCTAssertTrue(app.pix == before, "unexpected pixel mutation")
        }
    }

    func testInvalidFilesCannotBeSavedOver() throws {
        try withApp { _, sh, env in
            let path = "C:/Home/Bad.GR", bytes: [UInt8] = [1, 2, 3]
            try env.fs.writeFile(path, bytes)
            let app = PaintApp(sh, path)
            app.menu().first { $0.label == "Save" }!.action()
            XCTAssertEqual(env.fs.readFile(path), bytes)
        }
    }

    func testUndoAfterSavingMarksDocumentModified() throws {
        try withApp { app, _, _ in
            app.path = "C:/Home/Undo.GR"; app.pix[0] = 4
            app.menu().first { $0.label == "Save" }!.action()
            app.menu().first { $0.label == "Clear" }!.action()
            app.menu().first { $0.label == "Save" }!.action()
            XCTAssertFalse(app.unsaved)
            app.menu().first { $0.label == "Undo" }!.action()
            XCTAssertTrue(app.unsaved); XCTAssertEqual(app.pix[0], 4)
        }
    }

    func testMalformedGRAndRecordedFuzzCases() throws {
        let dir = SHARED.appendingPathComponent("test-vectors/fuzz-repro")
        for name in ["kotlin-paint-ArrayIndexOutOfBoundsException_SmallApps.kt_36.GR", "kotlin-paint-ArrayIndexOutOfBoundsException__.GR"] {
            let bytes = try XCTUnwrap(readFileBytes(dir.appendingPathComponent(name)))
            XCTAssertThrowsError(try GRImage.decode(bytes))
        }
        let good = GRImage(width: 9, height: 3).encode()
        for n in 0..<good.count { XCTAssertThrowsError(try GRImage.decode(Array(good.prefix(n)))) }
        var seed: UInt64 = 0x5041494e54
        for _ in 0..<1000 {
            var bytes = good
            for i in 16..<32 { seed = seed &* 6364136223846793005 &+ 1; bytes[i] = UInt8(truncatingIfNeeded: seed >> 32) }
            XCTAssertThrowsError(try GRImage.decode(bytes))
        }
    }

    func testMetadataTransparencyAndPaddingRoundTrip() throws {
        var bytes = [UInt8](repeating: 0, count: 32 + 128 + 16 * 3)
        func put(_ o: Int, _ v: Int) { for i in 0..<4 { bytes[o+i] = UInt8(truncatingIfNeeded: v >> (8*i)) } }
        put(0, 123); put(8, -4); put(12, 9); put(16, 9); put(20, 16); put(24, 3); put(28, 2)
        for i in 32..<bytes.count { bytes[i] = UInt8(truncatingIfNeeded: i) }
        bytes[160] = 255
        XCTAssertTrue(bytes == readFileBytes(SHARED.appendingPathComponent("test-vectors/paint/metadata.GR")))
        let image = try GRImage.decode(bytes)
        XCTAssertEqual(image.pixels[0], 255)
        XCTAssertEqual(image.encode(), bytes)
        try withApp { _, sh, env in
            let p = "C:/Home/Metadata.GR"; try env.fs.writeFile(p, bytes)
            let app = PaintApp(sh, p)
            app.menu().first { $0.label == "Save" }!.action()
            XCTAssertEqual(env.fs.readFile(p), bytes)
        }
    }

    func testOriginalSevenBitArchiveAndCorruptDictionaries() throws {
        let bytes = try XCTUnwrap(readFileBytes(SHARED.appendingPathComponent("test-vectors/paint/original-source.HC.Z")))
        let original = try XCTUnwrap(readFileBytes(SHARED.appendingPathComponent("bundled-fs/Adam/Gr/SpriteBitMap.HC")))
        XCTAssertTrue(try TempleArc.expand(bytes) == original)
        for n in [0, 16, 17, 20, bytes.count - 10] {
            XCTAssertThrowsError(try TempleArc.expand(Array(bytes.prefix(n))))
        }
        var seed: UInt64 = 0x415243
        for _ in 0..<250 {
            seed = seed &* 6364136223846793005 &+ 1
            var corrupt = bytes
            let pos = 17 + Int(seed % UInt64(bytes.count - 17))
            corrupt[pos] ^= UInt8(truncatingIfNeeded: seed >> 32)
            do {
                let expanded = try TempleArc.expand(corrupt)
                XCTAssertEqual(expanded.count, original.count)
            }
            catch is FsError { /* a malformed dictionary is an expected rejection */ }
        }
    }

    func testHistoricalEditorDependencyProbe() throws {
        let env = TestEnv(HostDirFs(SHARED.appendingPathComponent("bundled-fs")))
        do {
            let k = try runHolyC(Array("#include \"C:/Adam/Gr/SpriteBitMap.HC\"\n".utf8), env: env)
            print("PAINT_HISTORICAL_PROBE Swift: \(k.exitMessage ?? "no exit"); \(k.console.plainText().suffix(700))")
            XCTAssertNotNil(k.exitMessage, "Remove this blocker assertion when the original editor is supported")
        } catch {
            print("PAINT_HISTORICAL_PROBE Swift: \(error)")
        }
    }

    func testFileBrowserReopensGRAndArchive() throws {
        try withApp { _, sh, env in
            let image = GRImage(width: 9, height: 3)
            for suffix in ["GR", "GR.Z"] {
                let path = "C:/Home/Reopen.\(suffix)"
                try env.fs.writeFile(path, suffix == "GR.Z" ? TempleArc.store(image.encode()) : image.encode())
                let files = FilesApp(sh, "C:/Home")
                files.open(try XCTUnwrap(env.fs.stat(path)))
                let app = try XCTUnwrap(sh.focused?.app as? PaintApp)
                XCTAssertEqual(app.path, path); XCTAssertEqual(app.w, 9); XCTAssertEqual(app.h, 3)
                files.open(try XCTUnwrap(env.fs.stat(path)))
                XCTAssertTrue(sh.focused?.app === app, "same file focuses its existing window")
                app.pix[0] = 4
                app.menu().first { $0.label == "Save" }!.action()
                let saved = try XCTUnwrap(env.fs.readFile(path))
                let reloaded = try GRImage.decode(suffix == "GR.Z" ? TempleArc.expand(saved) : saved)
                XCTAssertEqual(reloaded.pixels[0], 4)
            }
        }
    }

    func testLegacyRawGRWithArchiveSuffixRemainsReadable() throws {
        try withApp { _, sh, env in
            let p = "C:/Home/Legacy.GR.Z"
            var image = GRImage(width: 9, height: 3); var pixels = image.pixels
            pixels[0] = 4; image.pixels = pixels
            try env.fs.writeFile(p, image.encode())
            let app = PaintApp(sh, p)
            XCTAssertEqual(app.path, p); XCTAssertEqual(app.w, 9); XCTAssertEqual(app.pix[0], 4)
            app.menu().first { $0.label == "Save" }!.action()
            let saved = try XCTUnwrap(env.fs.readFile(p))
            XCTAssertEqual(try GRImage.decode(TempleArc.expand(saved)).pixels[0], 4)
        }
    }

    func testCustomPaletteAndPreviewFrame() throws {
        try withApp { _, sh, env in
            let p = "C:/Home/Frame.GR"
            let bytes = try XCTUnwrap(readFileBytes(SHARED.appendingPathComponent("test-vectors/paint/metadata.GR")))
            try env.fs.writeFile(p, bytes)
            let app = PaintApp(sh, p)
            XCTAssertEqual(UInt32(bitPattern: app.palette[0]), 0xFF252321)
            let r = Rect(0, 0, 640, 600)
            func draw() { app.a11yItems.removeAll(); app.draw(sh.surface, r) }
            func frame() -> [UInt8] {
                var b = [UInt8](repeating: 0, count: app.w * app.h)
                b.withUnsafeMutableBufferPointer { _ = app.copyFrame($0.baseAddress!) }; return b
            }
            draw()
            XCTAssertTrue(frame() == app.pix)
            let tool = try XCTUnwrap(app.a11yItems.first { $0.label == "Tool LINE" })
            _ = app.pointer(PointerEvent(Ptr.DOWN, tool.rect.x + 1, tool.rect.y + 1), r)
            let c = try XCTUnwrap(app.overlays(r).first?.rect)
            let original = app.pix, version = app.frameVersion
            _ = app.pointer(PointerEvent(Ptr.DOWN, c.x + 2, c.y + 2, id: 7), r)
            _ = app.pointer(PointerEvent(Ptr.MOVE, c.right - 2, c.bottom - 2, id: 7), r)
            draw()
            XCTAssertTrue(app.pix == original)
            XCTAssertFalse(frame() == original, "visible preview must change before commit")
            XCTAssertGreaterThan(app.frameVersion, version)
            _ = app.pointer(PointerEvent(Ptr.CANCEL, 0, 0, id: 7), r); draw()
            XCTAssertTrue(frame() == original)
        }
    }

    func testNarrowToolLayoutAndRotationCancellation() throws {
        try withApp { app, sh, _ in
            let r = Rect(0, 0, 160, 600); app.a11yItems.removeAll(); app.draw(sh.surface, r)
            XCTAssertEqual(app.a11yItems.filter { $0.button }.count, 22)
            for b in app.a11yItems where b.button {
                XCTAssertGreaterThanOrEqual(b.rect.x, r.x); XCTAssertLessThanOrEqual(b.rect.right, r.right)
            }
            let line = try XCTUnwrap(app.a11yItems.first { $0.label == "Tool LINE" })
            _ = app.pointer(PointerEvent(Ptr.DOWN, line.rect.x + 1, line.rect.y + 1), r)
            let before = app.pix
            let canvas = try XCTUnwrap(app.overlays(r).first?.rect)
            _ = app.pointer(PointerEvent(Ptr.DOWN, canvas.x + 10, canvas.y + 10, id: 7), r)
            _ = app.pointer(PointerEvent(Ptr.MOVE, canvas.x + 50, canvas.y + 50, id: 7), r)
            app.draw(sh.surface, Rect(0, 0, 640, 300))
            _ = app.pointer(PointerEvent(Ptr.UP, 200, 200, id: 7), r)
            XCTAssertTrue(app.pix == before, "rotation must discard the pending shape")
        }
    }

    /// The same input fixture as Kotlin. Trace artifacts are optional and explicitly identify the wrapper.
    func testDeterministicWrapperReplay() throws {
        try withApp { initial, sh, env in
            let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: SHARED.appendingPathComponent("test-vectors/paint/wrapper-replay.json"))) as! [String: Any]
            let steps = fixture["steps"] as! [[String: Any]]
            let out = ProcessInfo.processInfo.environment["PAINT_TRACE_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("swift") }
            if let out = out { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }
            var app = initial
            let r = Rect(0, 0, 640, 600)
            func draw() { app.a11yItems.removeAll(); app.draw(sh.surface, r) }
            draw()
            for (i, step) in steps.enumerated() {
                let op = step["op"] as! String
                switch op {
                case "tool", "color":
                    let label = (op == "tool" ? "Tool " : "Color ") + (step["value"] as! String)
                    let b = try XCTUnwrap(app.a11yItems.first { $0.label == label })
                    _ = app.pointer(PointerEvent(Ptr.DOWN, b.rect.x + 1, b.rect.y + 1), r)
                case "pointer":
                    let c = try XCTUnwrap(app.overlays(r).first?.rect)
                    let action = ["down": Ptr.DOWN, "move": Ptr.MOVE, "up": Ptr.UP, "cancel": Ptr.CANCEL][step["action"] as! String]!
                    let x = c.x + (step["x"] as! Int) * c.w / app.w
                    let y = c.y + (step["y"] as! Int) * c.h / app.h
                    _ = app.pointer(PointerEvent(action, x, y, id: 7), r)
                case "release": app.releaseInput()
                case "undo": app.menu().first { $0.label == "Undo" }!.action()
                case "save":
                    app.path = "C:/Home/Replay.GR"; app.menu().first { $0.label == "Save" }!.action()
                    XCTAssertFalse(app.unsaved)
                case "reload":
                    let before = app.pix; app = PaintApp(sh, "C:/Home/Replay.GR")
                    XCTAssertTrue(app.pix == before, "reload changed logical indices")
                default: XCTFail("unknown replay operation \(op)")
                }
                draw()
                if let out = out {
                    var pixels = [UInt8](repeating: 0, count: app.w * app.h)
                    pixels.withUnsafeMutableBufferPointer { _ = app.copyFrame($0.baseAddress!) }
                    try Data(pixels).write(to: out.appendingPathComponent("\(i).idx"))
                    let state: [String: Any] = ["scope": "mobile-wrapper", "width": app.w, "height": app.h,
                        "op": op, "unsaved": app.unsaved, "path": app.path ?? "",
                        "input": app.replayState,
                        "selected": app.a11yItems.filter { $0.selected }.map { $0.label }.sorted()]
                    try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]).write(to: out.appendingPathComponent("\(i).json"))
                }
            }
            XCTAssertGreaterThan(app.pix.filter { $0 != 15 }.count, 100)
            if let out = out { try Data(try XCTUnwrap(env.fs.readFile("C:/Home/Replay.GR"))).write(to: out.appendingPathComponent("saved.GR")) }
        }
    }
}

import Foundation
import XCTest
@testable import TempleCore

/**
 * The shared half of TempleOS Mobile's typography (docs/typography/TEMPLEOS_TYPOGRAPHY.md): which text keeps the
 * TempleOS 8x8 font and which becomes a platform text run, the run geometry, and the toast. Port of TypographyTest.kt.
 */
final class TypographyTests: XCTestCase {
    private lazy var font: [UInt8] = readFileBytes(SHARED.appendingPathComponent("runtime/font8x8.bin"))!
    private func surface() -> Surface { let s = Surface(320, 480, font); s.measureNative = { $0.unicodeScalars.count * 10 }; return s }

    func testEnglishTextIsTheOriginalGlyphsMagnifiedByWholePixels() {
        let text = Array("TempleOS gyp".unicodeScalars)
        for scale in 1...3 {
            let s = surface()
            _ = s.uiText(4, 4, "TempleOS gyp", 14, scale: scale)
            XCTAssertTrue(s.runs.isEmpty)
            for (i, ch) in text.enumerated() { for row in 0..<8 {
                let bits = Int(font[Int(ch.value) * 8 + row])
                for col in 0..<8 {
                    let on = (bits >> col) & 1 != 0 // bit c is column c (Kernel/FontStd.HC layout)
                    for dy in 0..<scale { for dx in 0..<scale {
                        let p = Int(s.px[(4 + row * scale + dy) * s.width + 4 + (i * 8 + col) * scale + dx])
                        XCTAssertEqual(p, on ? 14 : 0, "'\(ch)' row \(row) col \(col) scale \(scale)")
                    } }
                }
            } }
        }
    }

    func testEveryCatalogsLabelsAreGlyphsOrOneUnsplitRun() throws {
        let dir = SHARED.appendingPathComponent("runtime/l10n")
        let keys = ["topbar.menu", "menu.start.god_words", "menu.start.settings", "menu.start.about", "god.button.ten_words"]
        var runs = 0
        for f in try FileManager.default.contentsOfDirectory(atPath: dir.path) where f.hasSuffix(".json") && f != "locales.json" {
            let cat = try XCTUnwrap(try Json.parse(String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)) as? [String: Any?])
            for k in keys {
                guard let text = cat[k] as? String else { continue }
                let s = surface()
                _ = s.uiText(10, 40, text, 1, scale: 2)
                if Cp437.representable(text) { XCTAssertTrue(s.runs.isEmpty, "\(f) \(k)") } else {
                    runs += 1
                    XCTAssertEqual(s.runs.count, 1, "\(f) \(k): one run")
                    guard let r = s.runs.first else { continue }
                    XCTAssertEqual(r.text, text, "\(f) \(k): the whole string, in logical order")
                    XCTAssertEqual([r.clip.y, r.clip.h], [36, 24], "12 rows at scale 2")
                }
            }
        }
        XCTAssertGreaterThan(runs, 150)
    }

    func testARunsInkBoxEndsWhereSomethingDrawnAboveItBegins() throws {
        let s = surface()
        _ = s.uiText(10, 40, "日本語", 1)
        let r = try XCTUnwrap(s.runs.first)
        func box(_ o: [Surface.Occluder]) -> [Int] { let b = Surface.runInkBox(r, o); return [b.0, b.1] }
        XCTAssertEqual(box([]), [38, 50])
        s.layer(Rect(0, 48, 320, 20))
        XCTAssertEqual(box(s.occluders), [38, 48])
        s.layer(Rect(0, 0, 320, 39))
        XCTAssertEqual(box(s.occluders), [39, 48])
        XCTAssertEqual(box([Surface.Occluder(Rect(0, 48, 320, 20), 0), Surface.Occluder(Rect(200, 30, 50, 50), 9)]), [38, 50])
    }

    func testABorderTitleIsFittedToItsBand() throws {
        let s = surface()
        s.border(Rect(8, 100, 200, 80), 1, 15, true, " 神の言葉 ")
        let r = try XCTUnwrap(s.runs.first)
        XCTAssertEqual([r.clip.y, r.clip.bottom], [100, 108], "the 8-row band")
        let e = surface()
        e.border(Rect(8, 100, 200, 80), 1, 15, true, " Sound ")
        XCTAssertTrue(e.runs.isEmpty)
    }

    func testALocalizedToastIsDrawnAsLocalizedText() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tosm-typo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sh = Shell(HeadlessEnv(dir))
        sh.resize(640, 640); sh.restoreSession(); _ = sh.tick()
        let msg = "Guardado: año, łódź, 保存しました"
        sh.showToast(msg); _ = sh.tick()
        XCTAssertTrue(sh.surface.runs.contains { $0.text == msg }, "\(sh.surface.runs.map { $0.text })")
        sh.resize(240, 640); sh.showToast(msg); _ = sh.tick()
        let toast = try! XCTUnwrap(sh.accessibilityNodes().first { $0.label == msg }?.rect)
        XCTAssertTrue(toast.x >= 0 && toast.right <= sh.width)
        XCTAssertTrue(sh.surface.runs.contains { $0.text.contains("łódź") })
        XCTAssertTrue(sh.surface.runs.contains { $0.text.contains("保存しました") })
        XCTAssertTrue(sh.surface.runs.allSatisfy { $0.clip.y >= toast.y && $0.clip.bottom <= toast.bottom })
        sh.showToast("Saved."); _ = sh.tick()
        XCTAssertFalse(sh.surface.runs.contains { $0.text == "Saved." })
    }
}

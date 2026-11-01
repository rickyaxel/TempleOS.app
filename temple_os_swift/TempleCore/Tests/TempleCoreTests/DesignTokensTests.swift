import Foundation
import XCTest
@testable import TempleCore

/**
 * The code must match shared/specifications/templeos-ui/tokens.json, the one visual
 * specification both apps follow (port of DesignTokensTest.kt).
 */
final class DesignTokensTests: XCTestCase {
    private let names = ["BLACK", "BLUE", "GREEN", "CYAN", "RED", "PURPLE", "BROWN", "LTGRAY",
                         "DKGRAY", "LTBLUE", "LTGREEN", "LTCYAN", "LTRED", "LTPURPLE", "YELLOW", "WHITE"]

    private func tokens() throws -> [String: Any] {
        let data = try Data(contentsOf: SHARED.appendingPathComponent("specifications/templeos-ui/tokens.json"))
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    private func obj(_ m: Any?, _ k: String) -> Any? { (m as? [String: Any])?[k] }
    private func int(_ v: Any?) -> Int { (v as! NSNumber).intValue }

    func testPaletteMatchesTokensAndTempleOs() throws {
        let t = try tokens()
        let colors = obj(obj(t, "palette"), "colors") as! [[String: Any]]
        XCTAssertEqual(colors.count, 16)
        for c in colors {
            let i = int(c["index"])
            XCTAssertEqual(c["name"] as? String, names[i])
            let rgb = Int((c["rgb"] as! String).dropFirst(), radix: 16)!
            XCTAssertEqual(rgb, Int(Palette.STD[i]) & 0xFFFFFF, "palette \(i)")
        }
        let src = REFERENCE.appendingPathComponent("original-templeos/Adam/Gr/GrPalette.HC")
        if let text = try? String(contentsOf: src, encoding: .isoLatin1),
           let start = text.range(of: "gr_palette_std[COLORS_NUM]={"), let end = text.range(of: "};", range: start.upperBound..<text.endIndex) {
            let block = String(text[start.upperBound..<end.lowerBound])
            let re = try NSRegularExpression(pattern: "0x([0-9A-Fa-f]{12})")
            let vals = re.matches(in: block, range: NSRange(block.startIndex..., in: block)).map { UInt64(block[Range($0.range(at: 1), in: block)!], radix: 16)! }
            XCTAssertEqual(vals.count, 16)
            for (i, v) in vals.enumerated() {
                let rgb = (((v >> 32) & 0xFFFF) >> 8) << 16 | (((v >> 16) & 0xFFFF) >> 8) << 8 | ((v & 0xFFFF) >> 8)
                XCTAssertEqual(Int(rgb), Int(Palette.STD[i]) & 0xFFFFFF, "GrPalette.HC entry \(i)")
            }
        }
    }

    func testButtonFacesFollowTheTokens() throws {
        let faces = obj(obj(try tokens(), "button"), "faces")
        func face(_ k: String) -> Int { names.firstIndex(of: obj(faces, k) as! String)! }
        XCTAssertEqual(face("normal"), ButtonFace.NORMAL)
        XCTAssertEqual(face("action"), ButtonFace.ACTION)
        XCTAssertEqual(face("selected"), ButtonFace.SELECTED)
        XCTAssertEqual(face("pressed"), ButtonFace.PRESSED)
        XCTAssertEqual(face("character"), ButtonFace.CHARACTER)
        XCTAssertEqual(face("locked"), ButtonFace.LOCKED)
        XCTAssertEqual(face("destructive"), ButtonFace.DESTRUCTIVE)
    }

    func testMetricsFollowTheTokensInBothSizes() throws {
        let metrics = obj(try tokens(), "metrics")
        defer { Touch.large = false }
        for (mode, large) in [("standard", false), ("large", true)] {
            Touch.large = large
            let m = obj(metrics, mode)
            let actual: [String: Int] = ["rowH": Touch.rowH, "topBar": Touch.topBar, "chrome": Touch.chrome, "chromeBtn": Touch.chromeBtn,
                "keyRow": Touch.keyRow, "header": Touch.header, "editorHeader": Touch.editorHeader, "button": Touch.button,
                "toolRow": Touch.toolRow, "kbdRow": Touch.kbdRow]
            for (k, v) in actual { XCTAssertEqual(int(obj(m, k)), v, "\(mode).\(k)") }
        }
        let kb = obj(metrics, "keyboard")
        XCTAssertEqual(Int64(int(obj(kb, "repeatDelayMs"))), TempleKeyboard.REPEAT_DELAY_MS)
        XCTAssertEqual(Int64(int(obj(kb, "repeatMs"))), TempleKeyboard.REPEAT_MS)
        XCTAssertEqual(Int64(int(obj(metrics, "longPressMs"))), Shell.LONG_PRESS_MS)
    }
}

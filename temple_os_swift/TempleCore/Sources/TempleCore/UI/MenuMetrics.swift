import Foundation

// Port of ui/MenuMetrics.kt.

/**
 * Sizes of the TempleOS menu layer (docs/ui-normalization/TEMPLEOS_RESPONSIVE_MENU_UI.md): the top bar,
 * pull-down menus (start menu, Games/Demos/Examples, window and program menus), the window menu row and
 * dialogs. Everything else keeps its density (terminal, editor, lists, program pictures).
 *
 * Why: the desktop is drawn in logical px and scaled by an integer so one logical px is about one dp/pt
 * on a phone (AUTO = shorter side / 360). That makes the 8x8 TempleOS font 8 pt tall and menu rows 20 pt:
 * desktop sizes on a phone. Menus therefore magnify their glyphs by [textScale] (whole logical pixels, so
 * the font stays crisp; TextRuns follow) and size their rows from the physical size of a logical px.
 *
 * One pure function of the usable viewport ([compute]); the shell recomputes it whenever the geometry,
 * the insets, the keyboard or the touch setting change, so no menu ever keeps old sizes.
 */
public final class MenuMetrics: CustomStringConvertible {
    /** Glyph magnification for menu text: 8*textScale logical px per character cell. */
    public let textScale: Int
    /** A pull-down / dialog row (one line of text). */
    public let rowH: Int
    /** The top bar (MENU, window tabs, clock). */
    public let barH: Int
    /** The window menu row inside the border (menu, maximize, close). */
    public let chromeH: Int
    /** Width of a chrome button (maximize, close) and of the menu button's hit area. */
    public let chromeBtnW: Int
    /** Short viewport (a phone in landscape, typing in landscape): denser rows, menus may use columns. */
    public let compact: Bool
    /** Logical px for the platform's minimum touch target (44 pt iOS, 48 dp Android). */
    public let touchPx: Int

    private init(_ textScale: Int, _ rowH: Int, _ barH: Int, _ chromeH: Int, _ chromeBtnW: Int, _ compact: Bool, _ touchPx: Int) {
        self.textScale = textScale; self.rowH = rowH; self.barH = barH; self.chromeH = chromeH
        self.chromeBtnW = chromeBtnW; self.compact = compact; self.touchPx = touchPx
    }

    public var charW: Int { 8 * textScale }
    public var glyphH: Int { 8 * textScale }
    /** Horizontal padding at each side of menu text: one character cell. */
    public var padX: Int { charW }
    /** Extra height of each further line of a wrapped menu label. */
    public var lineH: Int { glyphH + 2 * textScale }
    /** Height of a row holding [lines] lines of text. */
    public func rowFor(_ lines: Int) -> Int { rowH + (max(1, lines) - 1) * lineH }
    /** Top of the text in a row of height [h] starting at [top] (first line). */
    public func textTop(_ top: Int, _ h: Int, _ lines: Int = 1) -> Int { top + (h - glyphH - (max(1, lines) - 1) * lineH) / 2 }

    public var description: String { "MenuMetrics(textScale=\(textScale) rowH=\(rowH) barH=\(barH) chromeH=\(chromeH) compact=\(compact) touchPx=\(touchPx))" }

    /** Menu glyph height aimed for: twice the 8 pt of the font at the AUTO display scale. */
    public static let TARGET_GLYPH_DP = 16.0
    /** Characters a menu row must hold at the chosen scale (longer labels wrap onto a second line). */
    public static let MIN_ROW_CHARS = 14
    /** Usable heights (dp) below this are "short": a phone in landscape. */
    public static let SHORT_DP = 520.0
    /** Compact rows still get at least this height (dp): landscape trades height, not legibility. */
    public static let COMPACT_ROW_DP = 34.0
    public static let MAX_SCALE = 4

    /**
     * [usableW] x [usableH]: logical px inside the safe area (and above the keyboard); [dpPerPx]: dp
     * or pt per logical px (TempleView: display scale / screen scale); [touchDp]: the platform's minimum
     * touch target; [large]: the Touch targets LARGE setting (rows keep touch size in landscape too);
     * [typing]: landscape with a keyboard up (the compact typing layout).
     */
    public static func compute(_ usableW: Int, _ usableH: Int, _ dpPerPx: Double, _ touchDp: Double, _ large: Bool, _ typing: Bool) -> MenuMetrics {
        let dp = (dpPerPx.isFinite && dpPerPx > 0) ? dpPerPx : 1.0
        let w = max(usableW, 1), h = max(usableH, 1)
        // glyph scale for ~16 pt, at least 1, and only as big as a menu row still holds MIN_ROW_CHARS
        var ts = min(max(Int((TARGET_GLYPH_DP / (8 * dp)).rounded()), 1), MAX_SCALE)
        while ts > 1 && (w - 16) / (8 * ts) < MIN_ROW_CHARS { ts -= 1 }
        let glyph = 8 * ts
        let touch = Int((touchDp / dp).rounded(.up))
        let compact = typing || (Double(h) * dp < SHORT_DP && w > h)
        let tight = compact && !(large && !typing)
        let row = tight ? max(glyph + 2 * ts + 8, Int((COMPACT_ROW_DP / dp).rounded(.up))) : max(touch, glyph + 16)
        let bar = tight ? max(glyph + 2 * ts + 6, Int((30 / dp).rounded(.up))) : max(glyph + 12, Int((min(touchDp, 40.0) / dp).rounded(.up)))
        // the 8 px border above the row is part of its touch target
        let chrome = tight ? glyph + 2 * ts + 4 : max(glyph + 8, touch - 8)
        let chromeBtn = max(chrome + 8, glyph * 2)
        return MenuMetrics(ts, row, bar, chrome, chromeBtn, compact, touch)
    }

    /** The sizes before the responsive menus (STANDARD fixed px), for tests and comparisons. */
    public static let LEGACY_STANDARD = MenuMetrics(1, 20, 20, 16, 24, false, 20)
}

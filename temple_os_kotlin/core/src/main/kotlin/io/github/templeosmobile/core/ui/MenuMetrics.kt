package io.github.templeosmobile.core.ui

import kotlin.math.ceil
import kotlin.math.roundToInt

/**
 * Sizes of the TempleOS menu layer (docs/ui-normalization/TEMPLEOS_RESPONSIVE_MENU_UI.md): the top bar,
 * pull-down menus (start menu, Games/Demos/Examples, window and program menus), the window menu row and
 * dialogs. Everything else keeps its density (terminal, editor, lists, program pictures).
 *
 * Why: the desktop is drawn in logical px and scaled by an integer so one logical px is about one dp/pt
 * on a phone (AUTO = shorter side / 360). That makes the 8x8 TempleOS font 8 dp tall and menu rows 20 dp:
 * desktop sizes on a phone. Menus therefore magnify their glyphs by [textScale] (whole logical pixels, so
 * the font stays crisp; TextRuns follow) and size their rows from the physical size of a logical px.
 *
 * One pure function of the usable viewport ([compute]); the shell recomputes it whenever the geometry,
 * the insets, the keyboard or the touch setting change, so no menu ever keeps old sizes.
 */
class MenuMetrics private constructor(
    /** Glyph magnification for menu text: 8*textScale logical px per character cell. */
    val textScale: Int,
    /** A pull-down / dialog row (one line of text). */
    val rowH: Int,
    /** The top bar (MENU, window tabs, clock). */
    val barH: Int,
    /** The window menu row inside the border (menu, maximize, close). */
    val chromeH: Int,
    /** Width of a chrome button (maximize, close) and of the menu button's hit area. */
    val chromeBtnW: Int,
    /** Short viewport (a phone in landscape, typing in landscape): denser rows, menus may use columns. */
    val compact: Boolean,
    /** Logical px for the platform's minimum touch target (44 pt iOS, 48 dp Android). */
    val touchPx: Int,
) {
    val charW get() = 8 * textScale
    val glyphH get() = 8 * textScale
    /** Horizontal padding at each side of menu text: one character cell. */
    val padX get() = charW
    /** Extra height of each further line of a wrapped menu label. */
    val lineH get() = glyphH + 2 * textScale
    /** Height of a row holding [lines] lines of text. */
    fun rowFor(lines: Int) = rowH + (maxOf(1, lines) - 1) * lineH
    /** Top of the text in a row of height [h] starting at [top] (first line). */
    fun textTop(top: Int, h: Int, lines: Int = 1) = top + (h - glyphH - (maxOf(1, lines) - 1) * lineH) / 2

    override fun toString() = "MenuMetrics(textScale=$textScale rowH=$rowH barH=$barH chromeH=$chromeH compact=$compact touchPx=$touchPx)"

    companion object {
        /** Menu glyph height aimed for: twice the 8 dp of the font at the AUTO display scale. */
        const val TARGET_GLYPH_DP = 16.0
        /** Characters a menu row must hold at the chosen scale (longer labels wrap onto a second line). */
        const val MIN_ROW_CHARS = 14
        /** Usable heights (dp) below this are "short": a phone in landscape. */
        const val SHORT_DP = 520.0
        /** Compact rows still get at least this height (dp): landscape trades height, not legibility. */
        const val COMPACT_ROW_DP = 34.0
        const val MAX_SCALE = 4

        /**
         * [usableW] x [usableH]: logical px inside the safe area (and above the keyboard); [dpPerPx]: dp
         * or pt per logical px (TempleView: display scale / density); [touchDp]: the platform's minimum
         * touch target; [large]: the Touch targets LARGE setting (rows keep touch size in landscape too);
         * [typing]: landscape with a keyboard up (the compact typing layout).
         */
        fun compute(usableW: Int, usableH: Int, dpPerPx: Double, touchDp: Double, large: Boolean, typing: Boolean): MenuMetrics {
            val dp = if (dpPerPx.isFinite() && dpPerPx > 0) dpPerPx else 1.0
            val w = maxOf(usableW, 1); val h = maxOf(usableH, 1)
            // glyph scale for ~16 dp, at least 1, and only as big as a menu row still holds MIN_ROW_CHARS
            var ts = (TARGET_GLYPH_DP / (8 * dp)).roundToInt().coerceIn(1, MAX_SCALE)
            while (ts > 1 && (w - 16) / (8 * ts) < MIN_ROW_CHARS) ts--
            val glyph = 8 * ts
            val touch = ceil(touchDp / dp).toInt()
            val compact = typing || (h * dp < SHORT_DP && w > h)
            val tight = compact && !(large && !typing)
            val row = if (tight) maxOf(glyph + 2 * ts + 8, ceil(COMPACT_ROW_DP / dp).toInt()) else maxOf(touch, glyph + 16)
            val bar = if (tight) maxOf(glyph + 2 * ts + 6, ceil(30 / dp).toInt()) else maxOf(glyph + 12, ceil(minOf(touchDp, 40.0) / dp).toInt())
            // the 8 px border above the row is part of its touch target
            val chrome = if (tight) glyph + 2 * ts + 4 else maxOf(glyph + 8, touch - 8)
            val chromeBtn = maxOf(chrome + 8, glyph * 2)
            return MenuMetrics(ts, row, bar, chrome, chromeBtn, compact, touch)
        }

        /** The sizes before the responsive menus (STANDARD/LARGE fixed px), for tests and comparisons. */
        val LEGACY_STANDARD = MenuMetrics(1, 20, 20, 16, 24, false, 20)
    }
}

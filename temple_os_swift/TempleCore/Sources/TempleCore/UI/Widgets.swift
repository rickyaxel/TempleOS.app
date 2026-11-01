import Foundation

// Port of ui/Widgets.kt.

/**
 * Touch-target sizes in logical px. At the AUTO display scale one logical px is about
 * 1 dp / 1 pt, so the LARGE sizes meet the 48 dp / 44 pt minimum (V-32). The 8x8
 * TempleOS glyphs do not change size; only rows, bars and buttons get taller.
 */
public enum Touch {
    public static var large = false
    /** Set by the shell while typing in landscape (V-31): there is no room for LARGE sizes. */
    public static var compact = false
    private static func pick(_ standard: Int, _ big: Int) -> Int { large && !compact ? big : standard }
    public static var rowH: Int { pick(20, 44) }
    public static var topBar: Int { pick(20, 40) }
    public static var chrome: Int { pick(16, 32) }
    public static var chromeBtn: Int { pick(24, 44) }
    public static var keyRow: Int { pick(24, 44) }
    public static var header: Int { pick(20, 40) }
    public static var editorHeader: Int { pick(16, 40) }
    public static var button: Int { pick(22, 40) }
    public static var toolRow: Int { pick(16, 36) }
    /** Row of the TempleOS on-screen keyboard (portrait). */
    public static var kbdRow: Int { pick(34, 44) }
}

/**
 * Button faces (design tokens, shared/specifications/templeos-ui/tokens.json). Labels are drawn
 * in face XOR WHITE as TempleOS's CtrlBttn does: LTCYAN gives RED text, LTGREEN gives PURPLE.
 */
public enum ButtonFace {
    public static let NORMAL = Palette.LTCYAN
    public static let ACTION = Palette.LTGREEN
    public static let SELECTED = Palette.YELLOW
    public static let PRESSED = Palette.BLUE
    public static let CHARACTER = Palette.WHITE
    public static let LOCKED = Palette.RED
    /** Confirm buttons that delete, replace or discard (Delete, Replace, Close unsaved). */
    public static let DESTRUCTIVE = Palette.RED
}

/** List row height (logical px). */
public var ROW_H: Int { Touch.rowH }

/** Y offset that centers an 8 px glyph row in a [ROW_H] row. */
public var ROW_TEXT: Int { (ROW_H - 8) / 2 }

/**
 * A pull-down menu in TempleOS colors (BLUE background, YELLOW text; the keyboard selection is drawn as
 * TempleOS's DrawMenu draws the entry under the mouse: YELLOW background, BLUE text). Sized by the shell's
 * [MenuMetrics]: glyphs magnified by textScale, rows of touch height, labels wider than the menu wrapped
 * onto more lines. On a short (landscape) viewport a list that does not fit in one column is laid out in
 * columns, row by row; otherwise it scrolls by whole rows (drag, the full-width arrow rows, or keys).
 * A menu opened by another menu's item is its submenu: its title row goes back to [parent].
 */
public final class PopupMenu {
    public let items: [MenuItem]
    private let ax: Int
    private let ay: Int
    private let titleText: L10n.Presentation<String?>
    public var title: String? { titleText.value }
    public let parent: PopupMenu?
    private var box = Rect(0, 0, 0, 0)
    /** First visible grid row. */
    public private(set) var scroll = 0
    /** Keyboard selection (item index), or -1. */
    public private(set) var selected = -1
    public private(set) var cols = 1
    private var cellW = 0
    private var gridRows = 0
    private var lines: [[String]] = []
    private var rowLines: [Int] = []
    private var visibleRows = 0
    private var titleRect: Rect?
    private var upRect: Rect?
    private var downRect: Rect?
    private var cells: [(Int, Rect)] = []
    private var metrics = MenuMetrics.LEGACY_STANDARD
    public var bounds: Rect { box }

    /** The menu's background (the color it would show along a screen edge it reached). */
    public static let BG = Palette.BLUE
    public static let HIT_NONE = -1, HIT_UP = -2, HIT_DOWN = -3, HIT_BACK = -4, HIT_OUTSIDE = -5
    public static let KEY_BACK = -6
    /** A label wraps onto at most this many lines (the rest is cut, as before at one line). */
    public static let MAX_LINES = 3

    public init(_ items: [MenuItem], _ ax: Int, _ ay: Int, _ title: @autoclosure @escaping () -> String?, _ parent: PopupMenu? = nil) {
        self.items = items; self.ax = ax; self.ay = ay; titleText = L10n.Presentation(title); self.parent = parent
    }

    /** Lays the menu out for [sh]'s current geometry and metrics (every draw: rotation never leaves old sizes). */
    private func layout(_ s: Surface, _ sh: Shell) {
        let m = sh.metrics; metrics = m
        let ts = m.textScale
        // the usable screen, or on a folded one its part on the anchor's side (Shell.popupArea);
        // menus are modal and may cover the TempleOS keyboard (its keys are unusable meanwhile)
        let area = sh.popupArea(near: ax, ay)
        let left = area.x, right = area.right
        let top = area.y
        // popupArea reserves the four-pixel shadow; leave one content pixel clear too.
        let bottom = max(top + 1, area.bottom - 1)
        let maxW = max(m.charW * 4, right - left)
        let checkW = m.charW + 2 * ts
        let padL = 4 + checkW, padR = m.padX / 2 + 4
        let titleText = titleLabel()
        let labelW = items.map { s.measureUi($0.label, ts) }.max() ?? 0
        let titleW = titleText.map { s.measureUi($0, ts) + 2 * m.padX } ?? 0
        var cw = max(labelW + padL + padR, titleW, 10 * m.charW)
        let titleH = titleText != nil ? m.rowH : 0
        let oneColRows = max(1, (bottom - top - titleH - 8) / m.rowH)
        cols = 1
        if m.compact && items.count > oneColRows {
            let fit = max(1, (maxW - 8) / min(cw, maxW - 8))
            cols = max(1, min(fit, (items.count + oneColRows - 1) / oneColRows, 3))
        }
        cw = min(cw, (maxW - 8) / cols)
        cellW = cw
        let textW = max(m.charW, cw - padL - padR)
        lines = items.map { it in
            let l = Array(s.wrapUi(it.label, textW, ts).prefix(PopupMenu.MAX_LINES))
            return l.isEmpty ? [""] : l
        }
        gridRows = (items.count + cols - 1) / cols
        rowLines = (0..<gridRows).map { r in (0..<cols).map { c in r * cols + c < lines.count ? lines[r * cols + c].count : 1 }.max() ?? 1 }
        // a menu that fits the screen may move up from its anchor; one that must scroll stays under it
        let total = rowLines.reduce(0) { $0 + m.rowFor($1) }
        let fitsScreen = total <= bottom - top - titleH - 8
        // the anchor was taken when the menu opened: after a rotation or a fold it may lie outside the new
        // usable area (above a status bar that appeared), so it is held inside it
        let ay = min(max(self.ay, top), bottom)
        let room = fitsScreen ? bottom - top - titleH - 8 : bottom - max(top, min(ay, bottom - 4 * m.rowH)) - titleH - 8
        let scrolling = !fitsScreen
        let itemRoom = scrolling ? room - 2 * m.rowH : room
        scroll = min(max(scroll, 0), max(0, gridRows - 1))
        // the last page: no empty space after the last row
        var lastFirst = gridRows, acc = 0
        while lastFirst > 0 && acc + m.rowFor(rowLines[lastFirst - 1]) <= itemRoom { acc += m.rowFor(rowLines[lastFirst - 1]); lastFirst -= 1 }
        if scrolling { scroll = min(scroll, lastFirst) }
        visibleRows = 0; acc = 0
        while scroll + visibleRows < gridRows && acc + m.rowFor(rowLines[scroll + visibleRows]) <= max(itemRoom, m.rowFor(rowLines[scroll])) {
            acc += m.rowFor(rowLines[scroll + visibleRows]); visibleRows += 1
        }
        let h = 4 + titleH + (scrolling ? 2 * m.rowH : 0) + acc + 4
        let w = cols * cw + 8
        let x = min(max(ax, left), max(left, right - w))
        let y = ay + h <= bottom ? ay : max(top, bottom - h)
        box = Rect(x, y, w, h)
        var cy = y + 4
        if titleText != nil { titleRect = Rect(x, cy, w, titleH); cy += titleH } else { titleRect = nil }
        if scrolling { upRect = Rect(x, cy, w, m.rowH); cy += m.rowH } else { upRect = nil }
        cells.removeAll(keepingCapacity: true)
        if visibleRows > 0 {
            for r in scroll..<(scroll + visibleRows) {
                let rh = m.rowFor(rowLines[r])
                for c in 0..<cols {
                    let i = r * cols + c
                    if i < items.count { cells.append((i, Rect(x + 4 + c * cw, cy, cw, rh))) }
                }
                cy += rh
            }
        }
        downRect = scrolling ? Rect(x, cy, w, m.rowH) : nil
    }

    private func titleLabel() -> String? {
        if let p = parent { return "\u{11} " + (title ?? p.title ?? "") }
        return title
    }

    public func draw(_ s: Surface, _ sh: Shell) {
        layout(s, sh)
        let m = metrics, ts = m.textScale
        let x = box.x, y = box.y, w = box.w, h = box.h
        s.layer(Rect(x, y, w + 4, h + 4))
        s.fillRect(x + 4, y + 4, w, h, Palette.BLACK) // shadow
        s.fill(box, PopupMenu.BG)
        s.frame(box, Palette.YELLOW)
        let rtl = L10n.rtl
        if let r = titleRect {
            let t = titleLabel() ?? ""
            s.uiText(r.x + m.padX, m.textTop(r.y, r.h), t, Palette.WHITE, r.w - 2 * m.padX, alignEnd: rtl, scale: ts)
            if let p = parent { sh.a11yButton(r, tr("doc.menu.back") + ": " + (p.title ?? "")) } else { sh.a11yText(r, t) }
        }
        if let r = upRect {
            if scroll > 0 { s.text(r.x + (r.w - m.charW) / 2, m.textTop(r.y, r.h), "\u{18}", Palette.WHITE, scale: ts); sh.a11yButton(r, tr("a11y.scroll_menu_up")) }
            s.hline(r.x + 4, r.right - 5, r.bottom - 1, Palette.LTBLUE)
        }
        let checkW = m.charW + 2 * ts
        for (i, r) in cells {
            let it = items[i]
            let sel = i == selected
            if sel { s.fill(r, Palette.YELLOW) }
            let fg = !it.enabled ? Palette.LTGRAY : sel ? Palette.BLUE : Palette.YELLOW
            let ls = lines[i]
            let ty = m.textTop(r.y, r.h, ls.count)
            if it.checked { s.text(rtl ? r.right - 4 - m.charW : r.x + 4, ty, "\u{FB}", sel ? Palette.GREEN : Palette.LTGREEN, scale: ts) }
            let tx = r.x + 4 + checkW, tw = r.w - 4 - checkW - (m.padX / 2 + 4)
            for (li, l) in ls.enumerated() { s.uiText(rtl ? r.x + m.padX / 2 + 4 : tx, ty + li * m.lineH, l, fg, tw, alignEnd: rtl, scale: ts) }
            if it.enabled { sh.a11yButton(r, it.label, selected: it.checked) } else { sh.a11yText(r, tr("a11y.unavailable", ("label", it.label))) }
        }
        if let r = downRect {
            s.hline(r.x + 4, r.right - 5, r.y, Palette.LTBLUE)
            if scroll + visibleRows < gridRows { s.text(r.x + (r.w - m.charW) / 2, m.textTop(r.y, r.h), "\u{19}", Palette.WHITE, scale: ts); sh.a11yButton(r, tr("a11y.scroll_menu_down")) }
        }
    }

    /** What a tap at ([x], [y]) is on: an item index, or one of the HIT_ codes. */
    public func hit(_ x: Int, _ y: Int) -> Int {
        if !box.contains(x, y) { return PopupMenu.HIT_OUTSIDE }
        if let r = titleRect, r.contains(x, y) { return parent != nil ? PopupMenu.HIT_BACK : PopupMenu.HIT_NONE }
        if let r = upRect, r.contains(x, y) { return scroll > 0 ? PopupMenu.HIT_UP : PopupMenu.HIT_NONE }
        if let r = downRect, r.contains(x, y) { return scroll + visibleRows < gridRows ? PopupMenu.HIT_DOWN : PopupMenu.HIT_NONE }
        for (i, r) in cells where r.contains(x, y) { return items[i].enabled ? i : PopupMenu.HIT_NONE }
        return PopupMenu.HIT_NONE
    }

    /** Scrolls by [rows] grid rows (negative: up). Returns true if it moved. */
    @discardableResult public func scrollBy(_ rows: Int) -> Bool {
        let before = scroll
        scroll = min(max(scroll + rows, 0), max(0, gridRows - 1))
        return scroll != before
    }

    /** A page: the rows on screen minus one, at least one. */
    public var page: Int { max(1, visibleRows - 1) }

    /** Height of one row step for drag scrolling (logical px). */
    public var rowStep: Int { metrics.rowH }

    /**
     * Keyboard navigation (TempleOS menus are driven by the mouse; external keyboards get arrows): returns
     * the item to run for Enter, [KEY_BACK] for Left/Backspace in a submenu, or -1 when the key was used here.
     */
    public func key(_ ch: Int, _ sc: Int64) -> Int {
        let code = Int(sc & 0x7F)
        let n = items.count
        if n == 0 { return -1 }
        func step(_ from: Int, _ d: Int) -> Int {
            var i = from
            for _ in 0..<n { i += d; if i < 0 || i >= n { return from }; if items[i].enabled { return i } }
            return from
        }
        if ch == 10 || ch == 32 { return selected >= 0 && selected < n && items[selected].enabled ? selected : -1 }
        else if ch == Keys.CH_BACKSPACE { return parent != nil ? PopupMenu.KEY_BACK : -1 }
        else if code == Keys.SC_CURSOR_DOWN { selected = selected < 0 ? step(-1, 1) : step(selected, cols) }
        else if code == Keys.SC_CURSOR_UP { selected = selected < 0 ? step(n, -1) : step(selected, -cols) }
        else if code == Keys.SC_CURSOR_RIGHT { selected = selected < 0 ? step(-1, 1) : cols > 1 ? step(selected, 1) : selected }
        else if code == Keys.SC_CURSOR_LEFT {
            if (selected < 0 || cols == 1 || selected % cols == 0) && parent != nil { return PopupMenu.KEY_BACK }
            if selected > 0 && cols > 1 { selected = step(selected, -1) }
        }
        else if code == Keys.SC_HOME { selected = step(-1, 1) }
        else if code == Keys.SC_END { selected = step(n, -1) }
        else if code == Keys.SC_PAGE_DOWN { selected = min(step(max(selected, 0) + (page - 1) * cols, cols), n - 1) }
        else if code == Keys.SC_PAGE_UP { selected = max(step(max(selected, 0) - (page - 1) * cols, -cols), 0) }
        else { return -1 }
        // keep the selection on screen
        if selected >= 0 {
            let r = selected / cols
            if r < scroll { scroll = r }
            else if visibleRows > 0 && r >= scroll + visibleRows { scroll = r - visibleRows + 1 }
        }
        return -1
    }
}

/** Modal dialogs: confirmation, list chooser (program PopUps) and text input. */
public final class Dialog {
    private let titleText: L10n.Presentation<String>
    private let messageText: L10n.Presentation<String>
    private let itemText: L10n.Presentation<[(String, Int64)]>
    public var title: String { titleText.value }
    public var message: String { messageText.value }
    public var items: [(String, Int64)] { itemText.value }
    public let itemBg: [Int]
    /** Text being entered (Kotlin StringBuilder; nil for non-input dialogs). */
    public private(set) var input: [Unicode.Scalar]?
    private let onPick: (Int64) -> Void
    private let onText: ((String?) -> Void)?

    private var box = Rect(0, 0, 0, 0)
    private var scroll = 0
    private var listTop = 0
    private var visible = 0
    private var textScroll = 0
    private var textRows = 0
    private var visibleTextRows = 0
    private var textRect = Rect(0, 0, 0, 0)
    private var textLineH = 12
    private var draggingText = false
    private var downY = 0
    private var dragged = false

    private init(_ title: @escaping () -> String, _ message: @escaping () -> String, _ items: @escaping () -> [(String, Int64)], _ itemBg: [Int], _ input: String?,
                 _ onPick: @escaping (Int64) -> Void, _ onText: ((String?) -> Void)?) {
        titleText = L10n.Presentation(title); messageText = L10n.Presentation(message); itemText = L10n.Presentation(items); self.itemBg = itemBg
        self.input = input.map { Array($0.unicodeScalars) }
        self.onPick = onPick; self.onText = onText
    }

    public static func confirm(_ title: @autoclosure @escaping () -> String, _ message: @autoclosure @escaping () -> String, _ ok: @autoclosure @escaping () -> String, _ onOk: @escaping () -> Void) -> Dialog {
        Dialog(title, message, { [(ok(), Int64(1)), (tr("button.cancel"), Int64(0))] }, [-1, -1], nil, { if $0 == 1 { onOk() } }, nil)
    }

    /** A confirmation whose OK deletes, replaces or discards: drawn in [ButtonFace.DESTRUCTIVE]. */
    public static func confirmDestructive(_ title: @autoclosure @escaping () -> String, _ message: @autoclosure @escaping () -> String, _ ok: @autoclosure @escaping () -> String, _ onOk: @escaping () -> Void) -> Dialog {
        Dialog(title, message, { [(ok(), Int64(1)), (tr("button.cancel"), Int64(0))] }, [DESTRUCTIVE_ROW, -1], nil, { if $0 == 1 { onOk() } }, nil)
    }

    /** [itemBg] marker for a destructive choice (other values are colors a program chose). */
    public static let DESTRUCTIVE_ROW = -2

    /** The dialog's background (TempleOS PopUp: white). */
    public static let BG = Palette.WHITE

    public static func choose(_ title: @autoclosure @escaping () -> String, _ footer: @autoclosure @escaping () -> String, _ items: @autoclosure @escaping () -> [(String, Int64)], _ bgs: [Int], _ onPick: @escaping (Int64) -> Void) -> Dialog {
        Dialog(title, footer, items, bgs, nil, onPick, nil)
    }

    public static func input(_ title: @autoclosure @escaping () -> String, _ initial: String, _ onDone: @escaping (String?) -> Void) -> Dialog {
        Dialog(title, { "" }, { [(tr("button.ok"), Int64(1)), (tr("button.cancel"), Int64(0))] }, [-1, -1], initial, { _ in }, onDone)
    }

    public var wantsKeyboard: Bool { input != nil }

    /** Where the last draw put the dialog (logical px, without its shadow). */
    public var bounds: Rect { box }

    private var inputText: String { input.map { String(String.UnicodeScalarView($0)) } ?? "" }

    /** Called instead of the default cancel result when the dialog is dismissed (Esc, back). */
    public var onCancel: (() -> Void)?

    /** Dismisses the dialog without choosing an item. */
    public func cancel() {
        if let c = onCancel { c() } else { finish(input != nil ? 0 : -1) }
    }

    /** Row height of the last layout (the shell's MenuMetrics.rowH): drag and taps use what was drawn. */
    private var rowH = ROW_H

    public func draw(_ s: Surface, _ sh: Shell) {
        // TempleOS PopUp look (white, blue double border) at the menu layer's size (MenuMetrics)
        let m = sh.metrics, ts = m.textScale
        rowH = m.rowH
        // centered in the usable screen between the top bar and the bottom bars, or on a folded screen in one
        // of its parts (Shell.dialogArea): never on the hinge
        let area = sh.dialogArea()
        let usableW = area.w
        let w = min(usableW - 16, max(400, 34 * m.charW + 2 * m.padX))
        let tw = w - 2 * (8 + m.padX / 2)
        let msgLines = wrap(s, message, tw, ts)
        let titleLines = wrap(s, title, tw, ts)
        let lh = m.lineH
        let rtl = L10n.rtl
        let topY = area.y
        let maxH = max(0, area.h - 8)
        textRows = titleLines.count + msgLines.count
        textLineH = lh
        let chrome = 8 + lh / 2 + (input != nil ? rowH + 8 : 0) + 8
        // Reserve the actions first; long translations and filenames scroll inside the dialog.
        visible = min(items.count, max(1, (maxH - chrome - min(textRows, 3) * lh) / rowH))
        visibleTextRows = min(textRows, max(0, (maxH - chrome - visible * rowH) / lh))
        let fixed = chrome + visibleTextRows * lh
        let h = fixed + visible * rowH
        let x = area.x + (usableW - w) / 2
        let y = topY + max(4, (area.h - h) / 2)
        box = Rect(x, y, w, h)
        s.layer(Rect(x, y, w + 4, h + 4))
        s.fillRect(x + 4, y + 4, w, h, Palette.BLACK)
        s.fill(box, Dialog.BG)
        s.border(Rect(x, y, w & ~7, h), Palette.BLUE, Dialog.BG, true)
        let tx = x + 8 + m.padX / 2
        var ty = y + 8 + lh / 2
        textRect = Rect(tx, ty - 2 * ts, tw, visibleTextRows * lh)
        textScroll = min(max(0, textScroll), max(0, textRows - visibleTextRows))
        sh.a11yText(textRect, title)
        if !message.trimmingCharacters(in: .whitespaces).isEmpty { sh.a11yText(textRect, message) }
        let text = titleLines.map { ($0, Palette.BLUE) } + msgLines.map { ($0, Palette.BLACK) }
        s.withClip(textRect) {
            for i in textScroll..<min(textRows, textScroll + visibleTextRows) {
                s.uiText(tx, ty + (i - textScroll) * lh, text[i].0, text[i].1, tw, alignEnd: rtl, scale: ts)
            }
        }
        if textRows > visibleTextRows && visibleTextRows > 0 {
            let thumb = max(4, textRect.h * visibleTextRows / textRows)
            s.fillRect(textRect.right + 2, textRect.y + (textRect.h - thumb) * textScroll / (textRows - visibleTextRows), 2, thumb, Palette.BLUE)
        }
        ty += visibleTextRows * lh
        if input != nil {
            ty += 4
            let fr = Rect(x + 10, ty, w - 20, rowH - 4)
            sh.a11yText(fr, tr("a11y.text_field", ("text", InputCharacterPolicy.display(inputText))))
            s.fill(fr, Palette.LTGRAY)
            let shown = inputText.takeLast(max(1, (fr.w - 8 - 4 * ts) / m.charW))
            let gy = m.textTop(fr.y, fr.h)
            let ex = s.text(fr.x + 4, gy, shown, Palette.BLACK, scale: ts)
            s.fillRect(ex, gy - ts, 2 * ts, m.glyphH + 2 * ts, Palette.BLUE)
            ty += rowH + 4
        }
        listTop = ty
        scroll = min(max(scroll, 0), max(0, items.count - visible))
        if scroll < min(items.count, scroll + visible) {
            for i in scroll..<min(items.count, scroll + visible) {
                let ry = ty + (i - scroll) * rowH
                let bg = itemBg.getOrNil(i) ?? -1
                let br = Rect(x + 10, ry + 1, w - 20, rowH - 2)
                if bg < 0 { s.templeButton(br, items[i].0, bg == Dialog.DESTRUCTIVE_ROW ? ButtonFace.DESTRUCTIVE : ButtonFace.NORMAL, ts) }
                else {
                    // a HolyC program chose this row's color (PopUp lists): program content, kept as is
                    s.fill(br, bg)
                    let fg = [0, 1, 4, 5, 6, 8].contains(bg) ? Palette.WHITE : Palette.BLACK
                    s.uiText(br.x + m.padX / 2, m.textTop(br.y, br.h), items[i].0, fg, br.w - m.padX, alignEnd: rtl, scale: ts)
                }
                sh.a11yButton(Rect(x + 10, ry, w - 20, rowH), items[i].0)
            }
        }
        let ax = x + w - 10 - m.charW - 2
        if scroll > 0 { s.text(ax, m.textTop(listTop, rowH), "\u{18}", Palette.BLUE, scale: ts) }
        if scroll + visible < items.count { s.text(ax, m.textTop(listTop + (visible - 1) * rowH, rowH), "\u{19}", Palette.BLUE, scale: ts) }
    }

    private func wrap(_ s: Surface, _ t: String, _ maxW: Int, _ scale: Int) -> [String] {
        t.isEmpty ? [] : s.wrapUi(t, maxW, scale)
    }

    /** Pointer handling; returns true when the dialog closed. */
    public func pointer(_ e: PointerEvent, _ sh: Shell) -> Bool {
        switch e.action {
        case Ptr.DOWN: downY = e.y; dragged = false; draggingText = textRect.contains(e.x, e.y)
        case Ptr.MOVE:
            let dy = e.y - downY
            let step = draggingText ? textLineH : rowH
            if abs(dy) >= step {
                if draggingText { textScroll -= dy / step } else { scroll -= dy / step }
                downY = e.y; dragged = true
            }
        case Ptr.UP:
            if dragged { return false }
            if !box.contains(e.x, e.y) { return false }
            if e.y >= listTop {
                let i = (e.y - listTop) / rowH + scroll
                if i < items.count && i - scroll < visible { finish(items[i].1); return true }
            }
        default: break
        }
        return false
    }

    private func finish(_ v: Int64) {
        if input != nil { onText?(v == 1 ? inputText : nil) } else { onPick(v) }
    }

    /** Keyboard: text entry, Enter = first item, Esc = cancel. */
    public func key(_ ch: Int, _ sc: Int64, _ sh: Shell) -> Bool {
        if ch == 10 { finish(items.first?.1 ?? 0); return true }
        else if ch == Keys.CH_ESC || ch == Keys.CH_SHIFT_ESC { cancel(); return true }
        else if input != nil && ch == Keys.CH_BACKSPACE { if !input!.isEmpty { input!.removeLast() } }
        else if input != nil && ch >= 32 && ch <= 255 { input!.append(Unicode.Scalar(UInt8(ch))) }
        else if Int(sc & 0x7F) == Keys.SC_PAGE_DOWN { textScroll += max(1, visibleTextRows - 1) }
        else if Int(sc & 0x7F) == Keys.SC_PAGE_UP { textScroll -= max(1, visibleTextRows - 1) }
        else if Int(sc & 0x7F) == Keys.SC_CURSOR_DOWN { if items.count <= visible { textScroll += 1 } else { scroll += 1 } }
        else if Int(sc & 0x7F) == Keys.SC_CURSOR_UP { if items.count <= visible { textScroll -= 1 } else { scroll -= 1 } }
        return false
    }
}

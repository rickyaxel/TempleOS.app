import Foundation

// Port of ui/Keyboard.kt.

/**
 * The in-app TempleOS keyboard (UI normalization pass). The shell draws it in the TempleOS
 * palette and 8x8 font with TempleOS's own button look ([templeButton]) and sends exactly what
 * a hardware keyboard sends: (ch, scan code) pairs through [Shell.key]. The editor, terminal,
 * dialogs and HolyC programs therefore handle caret, selection and undo as before.
 * All software input is owned by this keyboard; CP437 opens its extended-character picker.
 */
public final class TempleKeyboard {
    /** A key: [w] in tenths of a row; [ch] a character, else [sc] a special scan code or an [action]. */
    public final class Key {
        public let label: String, w: Int, ch: Character?, sc: Int, action: Int, a11y: String
        init(_ label: String, _ w: Int = 10, ch: Character? = nil, sc: Int = 0, action: Int = 0, a11y: String? = nil) {
            self.label = label; self.w = w; self.ch = ch; self.sc = sc; self.action = action; self.a11y = a11y ?? label
        }
    }

    public static let LETTERS = 0, SYMBOLS = 1, FUNCTIONS = 2
    static let A_SHIFT = 1, A_CTRL = 2, A_ALT = 3, A_SYM = 4, A_FN = 5, A_HIDE = 6, A_EXT = 7
    static let REPEAT_DELAY_MS: Int64 = 400
    static let REPEAT_MS: Int64 = 60

    private unowned let shell: Shell
    public private(set) var layer = TempleKeyboard.LETTERS
    /** 0 off, 1 next key only, 2 caps lock. */
    public private(set) var shift = 0
    private var lastShiftTap: Int64 = 0

    /** Keys held by each pointer id, and when they were pressed / last repeated. */
    private var held: [Int: Key] = [:]
    private var heldAt: [Int: Int64] = [:]
    private var repeatedAt: [Int: Int64] = [:]
    /** Typematic tickets of raw (PC keyboard) presses: only the key pressed last repeats. */
    private var rawTicket: [Int: Int64] = [:]
    private var keyRects: [(Rect, Key)] = []

    init(_ shell: Shell) { self.shell = shell }

    private static func chars(_ s: String, _ w: Int = 10) -> [Key] { s.map { Key(String($0), w, ch: $0) } }
    private static func sp(_ label: String, _ sc: Int, _ w: Int = 10, _ a11y: String? = nil) -> Key { Key(label, w, sc: sc, a11y: a11y) }
    private static func act(_ label: String, _ a: Int, _ w: Int = 10, _ a11y: String? = nil) -> Key { Key(label, w, action: a, a11y: a11y) }

    private static let CHAR_NAMES: [Character: String] = [" ": "space", "\"": "quote", "'": "apostrophe", "`": "backtick", ";": "semicolon",
        ":": "colon", ",": "comma", ".": "period", "(": "left_parenthesis", ")": "right_parenthesis",
        "{": "left_brace", "}": "right_brace", "[": "left_bracket", "]": "right_bracket", "<": "less_than",
        ">": "greater_than", "=": "equals", "+": "plus", "-": "minus", "_": "underscore", "/": "slash",
        "\\": "backslash", "|": "vertical_bar", "~": "tilde", "!": "exclamation_mark", "@": "at",
        "#": "number_sign", "$": "dollar", "%": "percent", "^": "caret", "&": "ampersand", "*": "asterisk",
        "?": "question_mark"]

    /** Spoken name of a character key (letters and digits speak themselves). */
    static func a11yName(_ c: Character) -> String { CHAR_NAMES[c].map { tr("char.\($0)") } ?? String(c) }

    static let TOP: [Key] = [
        sp("ESC", Keys.SC_ESC, 10, "key.escape"), sp("TAB", Keys.SC_TAB, 10, "key.tab"),
        act("CTRL", A_CTRL, 10, "key.control"), act("ALT", A_ALT, 10, "key.alt"),
        sp("\u{1B}", Keys.SC_CURSOR_LEFT, 10, "key.left"), sp("\u{18}", Keys.SC_CURSOR_UP, 10, "key.up"),
        sp("\u{19}", Keys.SC_CURSOR_DOWN, 10, "key.down"), sp("\u{1A}", Keys.SC_CURSOR_RIGHT, 10, "key.right"),
        act("EXT", A_EXT, 10, "CP437"), act("HIDE", A_HIDE, 10, "key.hide_keyboard"),
    ]
    private static let BKSP = sp("BKSP", Keys.SC_BACKSPACE, 15, "key.backspace")
    private static func bottom(_ toggle: String, _ toggleA11y: String) -> [Key] {
        [act(toggle, A_SYM, 15, toggleA11y), act("FN", A_FN, 10, "key.function_keys")] + chars("()") +
            [sp("SPACE", Keys.SC_SPACE, 20, "key.space")] + chars(",.") + [sp("ENTER", Keys.SC_ENTER, 15, "key.enter")]
    }
    private static let LETTER_ROWS: [[Key]] = [
        chars("1234567890"),
        chars("qwertyuiop"),
        chars("asdfghjkl;\"", 9),
        [act("SHIFT", A_SHIFT, 15, "key.shift")] + chars("zxcvbnm") + [BKSP],
        bottom("SYM", "key.symbols"),
    ]
    private static let SYMBOL_ROWS: [[Key]] = [
        chars("1234567890"),
        chars("!@#$%^&*-+"),
        chars("{}[]<>=_/\\"),
        [sp("DEL", Keys.SC_DELETE, 15, "key.delete")] + chars("|'`~:?", 11) + [BKSP],
        bottom("ABC", "key.letters"),
    ]
    private static let FUNCTION_ROWS: [[Key]] = [
        (1...10).map { sp("F\($0)", Keys.SC_F1 + $0 - 1) },
        [sp("F11", 0x57, 12), sp("F12", 0x58, 12), sp("HOME", Keys.SC_HOME, 13, "key.home"), sp("END", Keys.SC_END, 12, "key.end"),
         sp("PGUP", Keys.SC_PAGE_UP, 13, "key.page_up"), sp("PGDN", Keys.SC_PAGE_DOWN, 13, "key.page_down"),
         sp("INS", Keys.SC_INS, 12, "key.insert"), sp("DEL", Keys.SC_DELETE, 13, "key.delete")],
        LETTER_ROWS[2], LETTER_ROWS[3], bottom("SYM", "key.symbols"),
    ]

    public func rows() -> [[Key]] {
        [TempleKeyboard.TOP] + (layer == TempleKeyboard.SYMBOLS ? TempleKeyboard.SYMBOL_ROWS
            : layer == TempleKeyboard.FUNCTIONS ? TempleKeyboard.FUNCTION_ROWS : TempleKeyboard.LETTER_ROWS)
    }

    /** Row height in logical px: smaller on a short viewport, where height is scarce; taller below a tabletop fold. */
    public func rowHeight() -> Int { shell.keyboardRowHeight(rows().count) }

    public func height() -> Int { rows().count * rowHeight() + 4 }

    /** Clears one-shot state (focus change, keyboard hidden, program closed). */
    public func reset() {
        for id in Array(rawDown.keys) { rawRelease(id) }
        setShift(0); layer = TempleKeyboard.LETTERS
        held.removeAll(); heldAt.removeAll(); repeatedAt.removeAll(); textDown.removeAll()
    }

    private func shifted(_ c: Character) -> Character {
        if shift == 0 { return c }
        if c.isLetter { return Character(c.uppercased()) }
        let from = Array("1234567890-=[];'`\\,./"), to = Array("!@#$%^&*()_+{}:\"~|<>?")
        if let i = from.firstIndex(of: c) { return to[i] }
        return c
    }

    private func label(_ k: Key) -> String {
        if let c = k.ch { return String(shifted(c)) }
        if k.action == TempleKeyboard.A_SHIFT { return shift == 2 ? "CAPS" : "SHIFT" }
        return k.label
    }

    private func face(_ k: Key, _ pressed: Bool) -> Int {
        if pressed { return ButtonFace.PRESSED }
        if k.action == TempleKeyboard.A_SHIFT && shift == 2 { return ButtonFace.LOCKED }
        if (k.action == TempleKeyboard.A_SHIFT && shift == 1) || (k.action == TempleKeyboard.A_CTRL && shell.ctrlLatched)
            || (k.action == TempleKeyboard.A_ALT && shell.altLatched) { return ButtonFace.SELECTED }
        if (k.action == TempleKeyboard.A_SYM && layer == TempleKeyboard.SYMBOLS) || (k.action == TempleKeyboard.A_FN && layer == TempleKeyboard.FUNCTIONS) { return ButtonFace.SELECTED }
        if k.sc == Keys.SC_ENTER { return ButtonFace.ACTION }
        if k.ch != nil || k.sc == Keys.SC_SPACE { return ButtonFace.CHARACTER }
        return ButtonFace.NORMAL
    }

    public func draw(_ s: Surface, _ r: Rect) {
        keyRects.removeAll()
        s.fillRect(r.x, r.y, r.w, r.h, Palette.BLACK)
        let rh = rowHeight()
        let pressed = Set(held.values.map { ObjectIdentifier($0) })
        for (ri, row) in rows().enumerated() {
            let y = r.y + 2 + ri * rh
            // columns skip occlusions and break at a book fold (Shell.keyColumns)
            let cols = shell.keyColumns(row.map { $0.w }, Rect(r.x, y, r.w, rh))
            for (k, (x0, x1)) in zip(row, cols) {
                let kr = Rect(x0, y, x1 - x0, rh)
                s.templeButton(kr, label(k), face(k, pressed.contains(ObjectIdentifier(k))))
                keyRects.append((kr, k))
                let f = face(k, false)
                shell.a11yButton(kr, k.ch.map { TempleKeyboard.a11yName(shifted($0)) } ?? (k.a11y.hasPrefix("key.") ? tr(k.a11y) : k.a11y), selected: f == ButtonFace.SELECTED || f == ButtonFace.LOCKED)
            }
        }
    }

    private func keyAt(_ x: Int, _ y: Int) -> Key? { keyRects.first { $0.0.contains(x, y) }?.1 }

    /** Pointer inside the keyboard: keys commit on release and repeat while held. */
    /**
     * True while a running TempleOS program has the focus: then this is a PC keyboard for it (a key
     * goes down when touched and up when released, and repeats at TempleOS's own rate), so programs
     * that test kbd.down_bitmap (RainDrops' valves, Strut's thrusters, Psalmody's organ) can hold
     * keys. For text (editor, terminal, dialogs) keys commit on release.
     */
    private func raw() -> Bool { !shell.dialogOpen && shell.focused?.app.rawKeys == true }

    /** Keys sent down in raw mode, per pointer. */
    private var rawDown: [Int: (Int, Int64)] = [:]
    private var textDown: [Int: (Int, Int64)] = [:]

    /** Pointer inside the keyboard: keys commit on release and repeat while held (raw: down/up). */
    public func pointer(_ e: PointerEvent, _ now: Int64) {
        let isRaw = raw()
        switch e.action {
        case Ptr.DOWN:
            if let k = keyAt(e.x, e.y) {
                held[e.id] = k; heldAt[e.id] = now; repeatedAt[e.id] = nil
                if isRaw && k.action == 0 { rawPress(e.id, k) }
                else if k.action == 0 { let pair = keyCode(k); textDown[e.id] = shell.resolvedKey(pair.0, pair.1) }
            }
        case Ptr.MOVE:
            if let k = keyAt(e.x, e.y), let h = held[e.id], k !== h {
                held[e.id] = k; heldAt[e.id] = now; repeatedAt[e.id] = nil
                if !isRaw && k.action == 0 { let pair = keyCode(k); textDown[e.id] = shell.resolvedKey(pair.0, pair.1) }
                if rawDown[e.id] != nil { rawRelease(e.id); if k.action == 0 { rawPress(e.id, k) } }
            }
        case Ptr.UP:
            let k = held.removeValue(forKey: e.id)
            let text = textDown.removeValue(forKey: e.id)
            let repeated = repeatedAt.removeValue(forKey: e.id) != nil
            heldAt[e.id] = nil
            if rawDown[e.id] != nil { rawRelease(e.id) }
            else if let k = k, !(isRaw && k.action == 0) {
                if k.action == 0 {
                    if !repeated, let text { shell.key(text.0, text.1, true); shell.key(text.0, text.1 | Keys.SCF_KEY_UP, false) }
                    if shift == 1 { setShift(0) }
                } else if !repeated { press(k, now) }
            }
        default:
            held[e.id] = nil; heldAt[e.id] = nil; repeatedAt[e.id] = nil; textDown[e.id] = nil
            if rawDown[e.id] != nil { rawRelease(e.id) }
        }
        shell.invalidate()
    }

    private func keyCode(_ k: Key) -> (Int, Int64) {
        if let c = k.ch { return Keys.forChar(Int(shifted(c).unicodeScalars.first!.value)) }
        return Keys.special(k.sc, shift: shift != 0)
    }

    private func rawPress(_ id: Int, _ k: Key) {
        let (ch, sc) = keyCode(k)
        rawDown[id] = (ch, sc)
        rawTicket[id] = shell.typematic.pressed()
        shell.key(ch, sc, true)
    }

    private func rawRelease(_ id: Int) {
        rawTicket[id] = nil
        guard let (ch, sc) = rawDown.removeValue(forKey: id) else { return }
        shell.key(ch, sc | Keys.SCF_KEY_UP, false)
        if shift == 1 { setShift(0) }
    }

    private func repeats(_ k: Key) -> Bool { k.action == 0 && k.sc != Keys.SC_ENTER && k.sc != Keys.SC_ESC && k.sc != Keys.SC_TAB }

    /** Typematic repeat for held keys; true if something was typed. */
    public func tick(_ now: Int64) -> Bool {
        var any = false
        for (id, k) in held {
            guard let since = heldAt[id] else { continue }
            let last = repeatedAt[id]
            if let down = rawDown[id] {
                if !shell.typematic.repeats(rawTicket[id] ?? -1) { continue }
                // TempleOS typematic (HomeLocalize.HC KbdTypeMatic(0)): 250 ms, then 30 key-downs per second
                if (last == nil && now - since >= Shell.TYPEMATIC_DELAY_MS) || (last != nil && now - last! >= Shell.TYPEMATIC_PERIOD_MS) {
                    shell.key(down.0, down.1, true); repeatedAt[id] = now; any = true
                }
                continue
            }
            if !repeats(k) { continue }
            if (last == nil && now - since >= TempleKeyboard.REPEAT_DELAY_MS) || (last != nil && now - last! >= TempleKeyboard.REPEAT_MS) {
                if let text = textDown[id] { shell.key(text.0, text.1, true); shell.key(text.0, text.1 | Keys.SCF_KEY_UP, false) }
                repeatedAt[id] = now; any = true
            }
        }
        return any
    }

    /** SHIFT state; a running program sees the SHIFT key go down and up with it. */
    private func setShift(_ v: Int) {
        let was = shift != 0
        shift = v
        if was != (v != 0) && raw() { shell.shiftLatch(v != 0) }
    }

    private func press(_ k: Key, _ now: Int64) {
        switch k.action {
        case TempleKeyboard.A_SHIFT:
            // tap: next key only; second tap within 400 ms: caps lock; tap again: off
            setShift(shift == 1 && now - lastShiftTap < 400 ? 2 : shift == 0 ? 1 : 0)
            lastShiftTap = now
        case TempleKeyboard.A_CTRL: shell.toggleCtrl()
        case TempleKeyboard.A_ALT: shell.toggleAlt()
        case TempleKeyboard.A_SYM: layer = layer == TempleKeyboard.SYMBOLS ? TempleKeyboard.LETTERS : TempleKeyboard.SYMBOLS
        case TempleKeyboard.A_FN: layer = layer == TempleKeyboard.FUNCTIONS ? TempleKeyboard.LETTERS : TempleKeyboard.FUNCTIONS
        case TempleKeyboard.A_HIDE: shell.hideKeyboard()
        case TempleKeyboard.A_EXT: shell.showCharacterPicker()
        default:
            // SHIFT applies to special keys too: SHIFT-ESC (abort), SHIFT-F1..F12, SHIFT-arrows
            let (ch, sc) = keyCode(k)
            shell.key(ch, sc, true); shell.key(ch, sc | Keys.SCF_KEY_UP, false)
            if shift == 1 { setShift(0) }
        }
        shell.invalidate()
    }
}

public extension Surface {
    /**
     * TempleOS's own button look (Adam/Ctrls/CtrlsBttn.HC, DrawCtrlBttn): a BLACK rectangle,
     * the face color inset by 2 px, and the label centered in face XOR WHITE.
     */
    func templeButton(_ r: Rect, _ label: String, _ face: Int, _ scale: Int = 1) {
        fillRect(r.x, r.y, r.w, r.h, Palette.BLACK)
        fillRect(r.x + 2, r.y + 2, max(0, r.w - 4), max(0, r.h - 4), face)
        // a label too wide for its button at [scale] is drawn at the font's own size instead of being cut
        let k = scale > 1 && (measureUi(label, scale) > r.w - 4 || 8 * scale > r.h - 4) ? 1 : scale
        let w = min(measureUi(label, k), r.w - 4)
        uiText(r.x + (r.w - w) / 2, r.y + (r.h - 8 * k) / 2, label, face ^ Palette.WHITE, r.w - 4, scale: k)
    }
}

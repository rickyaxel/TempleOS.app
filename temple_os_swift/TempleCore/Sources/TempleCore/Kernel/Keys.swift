import Foundation

/**
 * Logical keyboard (port of kernel/Keys.kt): TempleOS uses PC set-1 scan codes
 * with SCF_* flags in the upper bits. Platform key events are translated to
 * (ch, scan code) here so both apps deliver identical input to HolyC programs.
 */
public enum Keys {
    public static let SCF_E0_PREFIX: Int64 = 1 << 7
    public static let SCF_KEY_UP: Int64 = 1 << 8
    public static let SCF_SHIFT: Int64 = 1 << 9
    public static let SCF_CTRL: Int64 = 1 << 10
    public static let SCF_ALT: Int64 = 1 << 11
    public static let SCF_CAPS: Int64 = 1 << 12
    public static let SCF_MS_L_DOWN: Int64 = 1 << 16
    public static let SCF_MS_R_DOWN: Int64 = 1 << 17
    public static let SCF_DELETE: Int64 = 1 << 18
    public static let SCF_INS: Int64 = 1 << 19

    public static let SC_ESC = 0x01, SC_BACKSPACE = 0x0E, SC_TAB = 0x0F, SC_ENTER = 0x1C
    public static let SC_SHIFT = 0x2A, SC_CTRL = 0x1D, SC_ALT = 0x38, SC_SPACE = 0x39
    public static let SC_CURSOR_UP = 0x48, SC_CURSOR_DOWN = 0x50, SC_CURSOR_LEFT = 0x4B, SC_CURSOR_RIGHT = 0x4D
    public static let SC_PAGE_UP = 0x49, SC_PAGE_DOWN = 0x51, SC_HOME = 0x47, SC_END = 0x4F
    public static let SC_INS = 0x52, SC_DELETE = 0x53
    public static let SC_F1 = 0x3B
    public static let SC_CAPS = 0x3A

    public static let CH_BACKSPACE = 8, CH_ESC = 0x1B, CH_SHIFT_ESC = 0x1C, CH_SHIFT_SPACE = 0x1F

    private static let ROW1 = latin1("1234567890-=")
    private static let ROW1S = latin1("!@#$%^&*()_+")
    private static let ROW2 = latin1("qwertyuiop[]")
    private static let ROW2S = latin1("QWERTYUIOP{}")
    private static let ROW3 = latin1("asdfghjkl;'`")
    private static let ROW3S = latin1("ASDFGHJKL:\"~")
    private static let ROW4 = latin1("\\zxcvbnm,./")
    private static let ROW4S = latin1("|ZXCVBNM<>?")
    private static let SHIFTED = latin1("!@#$%^&*()_+{}:\"~|<>?")

    /** Scan code (low byte) for a printable character. */
    public static func char2ScanCode(_ ch: Int) -> Int {
        let c = UInt8(truncatingIfNeeded: ch)
        if ch >= 0 && ch < 256 {
            if let i = ROW1.firstIndex(of: c) { return 0x02 + i }
            if let i = ROW1S.firstIndex(of: c) { return 0x02 + i }
            if let i = ROW2.firstIndex(of: c) { return 0x10 + i }
            if let i = ROW2S.firstIndex(of: c) { return 0x10 + i }
            if let i = ROW3.firstIndex(of: c) { return 0x1E + i }
            if let i = ROW3S.firstIndex(of: c) { return 0x1E + i }
            if let i = ROW4.firstIndex(of: c) { return 0x2B + i }
            if let i = ROW4S.firstIndex(of: c) { return 0x2B + i }
        }
        switch ch {
        case 32: return SC_SPACE
        case 10, 13: return SC_ENTER
        case 9: return SC_TAB
        case CH_BACKSPACE: return SC_BACKSPACE
        case CH_ESC, CH_SHIFT_ESC: return SC_ESC
        default: return 0
        }
    }

    /**
     * Kernel/SerialDev/Keyboard.HC ScanCode2Char: the CTRL table maps letters to control codes
     * (other keys keep their unshifted character); SHIFT xor CAPS selects the shifted table for every
     * key (TempleOS's CAPS LOCK also shifts digits), where SHIFT-SPACE is CH_SHIFT_SPACE.
     */
    public static func scanCode2Char(_ sc: Int64) -> Int {
        let code = Int(sc & 0x7F)
        if sc & SCF_E0_PREFIX != 0 { return 0 }
        if sc & SCF_CTRL != 0 {
            let c = scanCode2Char(Int64(code))
            return c >= 97 && c <= 122 ? c - 97 + 1 : c
        }
        let shift = (sc & SCF_SHIFT != 0) != (sc & SCF_CAPS != 0)
        func pick(_ row: [UInt8], _ rowS: [UInt8], _ base: Int) -> Int? {
            let i = code - base
            return i >= 0 && i < row.count ? Int(shift ? rowS[i] : row[i]) : nil
        }
        if let v = pick(ROW1, ROW1S, 0x02) { return v }
        if let v = pick(ROW2, ROW2S, 0x10) { return v }
        if let v = pick(ROW3, ROW3S, 0x1E) { return v }
        if let v = pick(ROW4, ROW4S, 0x2B) { return v }
        switch code {
        case SC_SPACE: return shift ? CH_SHIFT_SPACE : 32
        case SC_ENTER: return 10
        case SC_TAB: return 9
        case SC_BACKSPACE: return CH_BACKSPACE
        case SC_ESC: return shift ? CH_SHIFT_ESC : CH_ESC
        case 0x37: return 42; case 0x4A: return 45; case 0x4E: return 43 // keypad * - +
        default: return 0
        }
    }

    /** Keys sent with an E0 prefix on a PC keyboard (the grey navigation block); kbd.down_bitmap2 is indexed with that bit. */
    public static func isE0(_ code: Int) -> Bool {
        [SC_HOME, SC_CURSOR_UP, SC_PAGE_UP, SC_CURSOR_LEFT, SC_CURSOR_RIGHT, SC_END, SC_CURSOR_DOWN, SC_PAGE_DOWN, SC_INS, SC_DELETE].contains(code)
    }

    /** Builds the (ch, scan code) pair for a typed character with modifiers. */
    public static func forChar(_ ch: Int, shift: Bool = false, ctrl: Bool = false, alt: Bool = false) -> (Int, Int64) {
        var sc = Int64(char2ScanCode(ch))
        let isUpper = (ch >= 65 && ch <= 90) || (ch >= 0 && ch < 256 && SHIFTED.contains(UInt8(ch)))
        if shift || isUpper { sc |= SCF_SHIFT }
        if ctrl { sc |= SCF_CTRL }
        if alt { sc |= SCF_ALT }
        var c = ch
        let isLetter = (ch >= 65 && ch <= 90) || (ch >= 97 && ch <= 122)
        if ctrl && isLetter { c = (ch & ~0x20) - 65 + 1 }
        return (c, sc)
    }

    /** (ch, sc) for special (non-character) keys. */
    public static func special(_ sc: Int, shift: Bool = false, ctrl: Bool = false, alt: Bool = false) -> (Int, Int64) {
        // No SCF_E0_PREFIX: TempleOS's KbdBuildSC (Kernel/SerialDev/Keyboard.HC) remaps E0 keys
        // through scan_code_map into sc.u8[0], which overwrites that bit (programs test
        // sc.u8[0]==SC_CURSOR_UP; with the bit set they never saw arrow keys).
        var s = Int64(sc)
        if sc == SC_DELETE { s |= SCF_DELETE }
        if sc == SC_INS { s |= SCF_INS }
        if shift { s |= SCF_SHIFT }
        if ctrl { s |= SCF_CTRL }
        if alt { s |= SCF_ALT }
        let ch: Int
        switch sc {
        case SC_ESC: ch = shift ? CH_SHIFT_ESC : CH_ESC
        case SC_ENTER: ch = 10
        case SC_TAB: ch = 9
        case SC_BACKSPACE: ch = CH_BACKSPACE
        case SC_SPACE: ch = shift ? CH_SHIFT_SPACE : 32
        default: ch = 0
        }
        return (ch, s)
    }
}

/** The standard TempleOS 16-color palette (ARGB). Port of kernel/Palette.kt. */
public enum Palette {
    public static let STD: [Int32] = [
        Int32(bitPattern: 0xFF000000), Int32(bitPattern: 0xFF0000AA), Int32(bitPattern: 0xFF00AA00), Int32(bitPattern: 0xFF00AAAA),
        Int32(bitPattern: 0xFFAA0000), Int32(bitPattern: 0xFFAA00AA), Int32(bitPattern: 0xFFAA5500), Int32(bitPattern: 0xFFAAAAAA),
        Int32(bitPattern: 0xFF555555), Int32(bitPattern: 0xFF5555FF), Int32(bitPattern: 0xFF55FF55), Int32(bitPattern: 0xFF55FFFF),
        Int32(bitPattern: 0xFFFF5555), Int32(bitPattern: 0xFFFF55FF), Int32(bitPattern: 0xFFFFFF55), Int32(bitPattern: 0xFFFFFFFF),
    ]
    public static let BLACK = 0, BLUE = 1, GREEN = 2, CYAN = 3
    public static let RED = 4, PURPLE = 5, BROWN = 6, LTGRAY = 7
    public static let DKGRAY = 8, LTBLUE = 9, LTGREEN = 10, LTCYAN = 11
    public static let LTRED = 12, LTPURPLE = 13, YELLOW = 14, WHITE = 15
    public static let TRANSPARENT = 0xFF
}

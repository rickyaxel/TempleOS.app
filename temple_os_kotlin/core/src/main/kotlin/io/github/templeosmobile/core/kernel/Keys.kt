package io.github.templeosmobile.core.kernel

/**
 * Logical keyboard: TempleOS uses PC set-1 scan codes with SCF_* flags in the
 * upper bits. Platform key events are translated to (ch, scan code) here so
 * both apps deliver identical input to HolyC programs.
 */
object Keys {
    const val SCF_E0_PREFIX = 1L shl 7
    const val SCF_KEY_UP = 1L shl 8
    const val SCF_SHIFT = 1L shl 9
    const val SCF_CTRL = 1L shl 10
    const val SCF_ALT = 1L shl 11
    const val SCF_CAPS = 1L shl 12
    const val SCF_MS_L_DOWN = 1L shl 16
    const val SCF_MS_R_DOWN = 1L shl 17
    const val SCF_DELETE = 1L shl 18
    const val SCF_INS = 1L shl 19

    const val SC_ESC = 0x01; const val SC_BACKSPACE = 0x0E; const val SC_TAB = 0x0F; const val SC_ENTER = 0x1C
    const val SC_SHIFT = 0x2A; const val SC_CTRL = 0x1D; const val SC_ALT = 0x38; const val SC_SPACE = 0x39
    const val SC_CURSOR_UP = 0x48; const val SC_CURSOR_DOWN = 0x50; const val SC_CURSOR_LEFT = 0x4B; const val SC_CURSOR_RIGHT = 0x4D
    const val SC_PAGE_UP = 0x49; const val SC_PAGE_DOWN = 0x51; const val SC_HOME = 0x47; const val SC_END = 0x4F
    const val SC_INS = 0x52; const val SC_DELETE = 0x53
    const val SC_F1 = 0x3B
    const val SC_CAPS = 0x3A

    const val CH_BACKSPACE = 8; const val CH_ESC = 0x1B; const val CH_SHIFT_ESC = 0x1C; const val CH_SHIFT_SPACE = 0x1F

    private const val ROW1 = "1234567890-="
    private const val ROW1S = "!@#$%^&*()_+"
    private const val ROW2 = "qwertyuiop[]"
    private const val ROW2S = "QWERTYUIOP{}"
    private const val ROW3 = "asdfghjkl;'`"
    private const val ROW3S = "ASDFGHJKL:\"~"
    private const val ROW4 = "\\zxcvbnm,./"
    private const val ROW4S = "|ZXCVBNM<>?"

    /** Scan code (low byte) and shift flag for a printable character. */
    fun char2ScanCode(ch: Int): Int {
        val c = ch.toChar()
        ROW1.indexOf(c).let { if (it >= 0) return 0x02 + it }
        ROW1S.indexOf(c).let { if (it >= 0) return 0x02 + it }
        ROW2.indexOf(c).let { if (it >= 0) return 0x10 + it }
        ROW2S.indexOf(c).let { if (it >= 0) return 0x10 + it }
        ROW3.indexOf(c).let { if (it >= 0) return 0x1E + it }
        ROW3S.indexOf(c).let { if (it >= 0) return 0x1E + it }
        ROW4.indexOf(c).let { if (it >= 0) return 0x2B + it }
        ROW4S.indexOf(c).let { if (it >= 0) return 0x2B + it }
        return when (ch) {
            ' '.code -> SC_SPACE
            '\n'.code, '\r'.code -> SC_ENTER
            '\t'.code -> SC_TAB
            CH_BACKSPACE -> SC_BACKSPACE
            CH_ESC, CH_SHIFT_ESC -> SC_ESC
            else -> 0
        }
    }

    /**
     * Kernel/SerialDev/Keyboard.HC ScanCode2Char: the CTRL table maps letters to control codes
     * (other keys keep their unshifted character); SHIFT xor CAPS selects the shifted table for every
     * key (TempleOS's CAPS LOCK also shifts digits), where SHIFT-SPACE is CH_SHIFT_SPACE.
     */
    fun scanCode2Char(sc: Long): Int {
        val code = (sc and 0x7F).toInt()
        if (sc and SCF_E0_PREFIX != 0L) return 0
        if (sc and SCF_CTRL != 0L) {
            val c = scanCode2Char(code.toLong())
            return if (c in 'a'.code..'z'.code) c - 'a'.code + 1 else c
        }
        val shift = (sc and SCF_SHIFT != 0L) != (sc and SCF_CAPS != 0L)
        fun pick(row: String, rowS: String, base: Int): Int? {
            val i = code - base
            return if (i in row.indices) (if (shift) rowS[i] else row[i]).code else null
        }
        pick(ROW1, ROW1S, 0x02)?.let { return it }
        pick(ROW2, ROW2S, 0x10)?.let { return it }
        pick(ROW3, ROW3S, 0x1E)?.let { return it }
        pick(ROW4, ROW4S, 0x2B)?.let { return it }
        return when (code) {
            SC_SPACE -> if (shift) CH_SHIFT_SPACE else ' '.code
            SC_ENTER -> '\n'.code
            SC_TAB -> '\t'.code
            SC_BACKSPACE -> CH_BACKSPACE
            SC_ESC -> if (shift) CH_SHIFT_ESC else CH_ESC
            0x37 -> '*'.code; 0x4A -> '-'.code; 0x4E -> '+'.code // keypad
            else -> 0
        }
    }

    /** Keys sent with an E0 prefix on a PC keyboard (the grey navigation block); kbd.down_bitmap2 is indexed with that bit. */
    fun isE0(code: Int) = code in intArrayOf(SC_HOME, SC_CURSOR_UP, SC_PAGE_UP, SC_CURSOR_LEFT, SC_CURSOR_RIGHT, SC_END,
        SC_CURSOR_DOWN, SC_PAGE_DOWN, SC_INS, SC_DELETE)

    /** Builds the (ch, scan code) pair for a typed character with modifiers. */
    fun forChar(ch: Int, shift: Boolean = false, ctrl: Boolean = false, alt: Boolean = false): Pair<Int, Long> {
        var sc = char2ScanCode(ch).toLong()
        val isUpper = ch.toChar().isUpperCase() || "!@#$%^&*()_+{}:\"~|<>?".indexOf(ch.toChar()) >= 0
        if (shift || isUpper) sc = sc or SCF_SHIFT
        if (ctrl) sc = sc or SCF_CTRL
        if (alt) sc = sc or SCF_ALT
        var c = ch
        if (ctrl && ch.toChar().isLetter()) c = ch.toChar().uppercaseChar().code - 'A'.code + 1
        return c to sc
    }

    /** (ch, sc) for special (non-character) keys. */
    fun special(sc: Int, shift: Boolean = false, ctrl: Boolean = false, alt: Boolean = false): Pair<Int, Long> {
        // No SCF_E0_PREFIX: TempleOS's KbdBuildSC (Kernel/SerialDev/Keyboard.HC) remaps E0 keys
        // through scan_code_map into sc.u8[0], which overwrites that bit (programs test
        // sc.u8[0]==SC_CURSOR_UP; with the bit set they never saw arrow keys).
        var s = sc.toLong()
        if (sc == SC_DELETE) s = s or SCF_DELETE
        if (sc == SC_INS) s = s or SCF_INS
        if (shift) s = s or SCF_SHIFT
        if (ctrl) s = s or SCF_CTRL
        if (alt) s = s or SCF_ALT
        val ch = when (sc) {
            SC_ESC -> if (shift) CH_SHIFT_ESC else CH_ESC
            SC_ENTER -> '\n'.code
            SC_TAB -> '\t'.code
            SC_BACKSPACE -> CH_BACKSPACE
            SC_SPACE -> if (shift) CH_SHIFT_SPACE else ' '.code
            else -> 0
        }
        return ch to s
    }
}

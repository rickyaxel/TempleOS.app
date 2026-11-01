package io.github.templeosmobile.android

import android.view.KeyEvent
import io.github.templeosmobile.core.kernel.Keys

/** Physical key identity → TempleOS US set-1 events, without an IME or device-language text conversion. */
object HardwareKeyAdapter {
    fun map(keyCode: Int, e: KeyEvent): Pair<Int, Long>? {
        if (e.flags and KeyEvent.FLAG_SOFT_KEYBOARD != 0) return null
        val special = when (keyCode) {
            KeyEvent.KEYCODE_DPAD_UP -> Keys.SC_CURSOR_UP
            KeyEvent.KEYCODE_DPAD_DOWN -> Keys.SC_CURSOR_DOWN
            KeyEvent.KEYCODE_DPAD_LEFT -> Keys.SC_CURSOR_LEFT
            KeyEvent.KEYCODE_DPAD_RIGHT -> Keys.SC_CURSOR_RIGHT
            KeyEvent.KEYCODE_PAGE_UP -> Keys.SC_PAGE_UP
            KeyEvent.KEYCODE_PAGE_DOWN -> Keys.SC_PAGE_DOWN
            KeyEvent.KEYCODE_MOVE_HOME -> Keys.SC_HOME
            KeyEvent.KEYCODE_MOVE_END -> Keys.SC_END
            KeyEvent.KEYCODE_INSERT -> Keys.SC_INS
            KeyEvent.KEYCODE_FORWARD_DEL -> Keys.SC_DELETE
            KeyEvent.KEYCODE_ESCAPE -> Keys.SC_ESC
            in KeyEvent.KEYCODE_F1..KeyEvent.KEYCODE_F10 -> Keys.SC_F1 + keyCode - KeyEvent.KEYCODE_F1
            KeyEvent.KEYCODE_F11 -> 0x57
            KeyEvent.KEYCODE_F12 -> 0x58
            KeyEvent.KEYCODE_SHIFT_LEFT, KeyEvent.KEYCODE_SHIFT_RIGHT -> Keys.SC_SHIFT
            KeyEvent.KEYCODE_CTRL_LEFT, KeyEvent.KEYCODE_CTRL_RIGHT -> Keys.SC_CTRL
            KeyEvent.KEYCODE_ALT_LEFT, KeyEvent.KEYCODE_ALT_RIGHT -> Keys.SC_ALT
            KeyEvent.KEYCODE_CAPS_LOCK -> Keys.SC_CAPS
            KeyEvent.KEYCODE_NUMPAD_DIVIDE -> 0x35
            KeyEvent.KEYCODE_NUMPAD_MULTIPLY -> 0x37
            KeyEvent.KEYCODE_NUMPAD_SUBTRACT -> 0x4A
            KeyEvent.KEYCODE_NUMPAD_ADD -> 0x4E
            KeyEvent.KEYCODE_NUMPAD_DOT -> if (e.isNumLockOn) 0x34 else Keys.SC_DELETE
            in KeyEvent.KEYCODE_NUMPAD_0..KeyEvent.KEYCODE_NUMPAD_9 -> {
                val digit = keyCode - KeyEvent.KEYCODE_NUMPAD_0
                if (e.isNumLockOn) Keys.char2ScanCode('0'.code + digit)
                else intArrayOf(Keys.SC_INS, Keys.SC_END, Keys.SC_CURSOR_DOWN, Keys.SC_PAGE_DOWN,
                    Keys.SC_CURSOR_LEFT, 0x4C, Keys.SC_CURSOR_RIGHT, Keys.SC_HOME, Keys.SC_CURSOR_UP, Keys.SC_PAGE_UP)[digit]
            }
            KeyEvent.KEYCODE_DEL -> Keys.SC_BACKSPACE
            KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> Keys.SC_ENTER
            KeyEvent.KEYCODE_TAB -> Keys.SC_TAB
            KeyEvent.KEYCODE_SPACE -> Keys.SC_SPACE
            else -> null
        }
        val printable = when (keyCode) {
            in KeyEvent.KEYCODE_A..KeyEvent.KEYCODE_Z -> 'a'.code + keyCode - KeyEvent.KEYCODE_A
            in KeyEvent.KEYCODE_0..KeyEvent.KEYCODE_9 -> '0'.code + keyCode - KeyEvent.KEYCODE_0
            KeyEvent.KEYCODE_MINUS -> '-'.code; KeyEvent.KEYCODE_EQUALS -> '='.code
            KeyEvent.KEYCODE_LEFT_BRACKET -> '['.code; KeyEvent.KEYCODE_RIGHT_BRACKET -> ']'.code
            KeyEvent.KEYCODE_BACKSLASH -> '\\'.code; KeyEvent.KEYCODE_SEMICOLON -> ';'.code
            KeyEvent.KEYCODE_APOSTROPHE -> '\''.code; KeyEvent.KEYCODE_GRAVE -> '`'.code
            KeyEvent.KEYCODE_COMMA -> ','.code; KeyEvent.KEYCODE_PERIOD -> '.'.code; KeyEvent.KEYCODE_SLASH -> '/'.code
            else -> null
        }
        // Linux evdev ordinary key positions match PC set-1. Prefer them on real keyboards;
        // KeyEvent keycodes provide the stable fallback for adb/instrumentation and non-PC devices.
        val position = e.scanCode.takeIf { it in 0x02..0x35 && Keys.scanCode2Char(it.toLong()) >= 32 }
        val scan = special ?: position ?: printable?.let(Keys::char2ScanCode) ?: return null
        val flags = Keys.special(scan, e.isShiftPressed, e.isCtrlPressed, e.isAltPressed).second or
            (if (e.isCapsLockOn) Keys.SCF_CAPS else 0L)
        return Keys.scanCode2Char(flags) to flags
    }
}

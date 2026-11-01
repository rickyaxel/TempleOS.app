import Foundation

/** USB HID positions → TempleOS US set-1 scans. Never consult the device's text-input language. */
public enum PhysicalKeyMap {
    public static func hid(_ usage: Int, shift: Bool = false, ctrl: Bool = false, alt: Bool = false, caps: Bool = false) -> (Int, Int64)? {
        let scan: Int
        switch usage {
        case 4...29: scan = Keys.char2ScanCode(97 + usage - 4)
        case 30...38: scan = Keys.char2ScanCode(49 + usage - 30)
        case 39, 98: scan = Keys.char2ScanCode(48)
        // UIKit exposes the dedicated numeric keypad as HID digits (no Num Lock state).
        case 89...97: scan = Keys.char2ScanCode(49 + usage - 89)
        case 99: scan = Keys.char2ScanCode(46)
        default:
            let scans = [40: Keys.SC_ENTER, 41: Keys.SC_ESC, 42: Keys.SC_BACKSPACE, 43: Keys.SC_TAB, 44: Keys.SC_SPACE,
                         45: 0x0C, 46: 0x0D, 47: 0x1A, 48: 0x1B, 49: 0x2B, 50: 0x2B, 51: 0x27, 52: 0x28, 53: 0x29,
                         54: 0x33, 55: 0x34, 56: 0x35, 57: Keys.SC_CAPS,
                         71: 0x46, 73: Keys.SC_INS, 74: Keys.SC_HOME, 75: Keys.SC_PAGE_UP,
                         76: Keys.SC_DELETE, 77: Keys.SC_END, 78: Keys.SC_PAGE_DOWN,
                         79: Keys.SC_CURSOR_RIGHT, 80: Keys.SC_CURSOR_LEFT, 81: Keys.SC_CURSOR_DOWN, 82: Keys.SC_CURSOR_UP,
                         84: 0x35, 85: 0x37, 86: 0x4A, 87: 0x4E, 88: Keys.SC_ENTER,
                         89: 0x4F, 90: 0x50, 91: 0x51, 92: 0x4B, 93: 0x4C, 94: 0x4D, 95: 0x47, 96: 0x48, 97: 0x49,
                         98: 0x52, 99: 0x53, 224: Keys.SC_CTRL, 225: Keys.SC_SHIFT, 226: Keys.SC_ALT,
                         228: Keys.SC_CTRL, 229: Keys.SC_SHIFT, 230: Keys.SC_ALT]
            if (58...67).contains(usage) { scan = Keys.SC_F1 + usage - 58 }
            else if usage == 68 { scan = 0x57 }
            else if usage == 69 { scan = 0x58 }
            else if let s = scans[usage] { scan = s }
            // Print Screen/Pause require extended PC sequences; retain their previous unsupported
            // behavior rather than confusing them with keypad multiply or Num Lock.
            else { return nil }
        }
        let flags = Keys.special(scan, shift: shift, ctrl: ctrl, alt: alt).1 | (caps ? Keys.SCF_CAPS : 0)
        return (Keys.scanCode2Char(flags), flags)
    }
}

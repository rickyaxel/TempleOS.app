import TempleCore
import UIKit

/** A plain responder's physical events, with TempleOS US mappings independent of installed iOS keyboards. */
enum HardwareKeyAdapter {
    static func map(_ key: UIKey, heldModifiers: UIKeyModifierFlags = []) -> (Int, Int64)? {
        let modifiers = key.modifierFlags.union(heldModifiers)
        // Preserve UIKit commands (Cmd-. and Cmd-V) in the responder chain.
        if modifiers.contains(.command) { return nil }
        return PhysicalKeyMap.hid(key.keyCode.rawValue, shift: modifiers.contains(.shift),
                                  ctrl: modifiers.contains(.control), alt: modifiers.contains(.alternate),
                                  caps: modifiers.contains(.alphaShift))
    }
}

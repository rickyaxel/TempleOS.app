import Foundation

// Port of ui/Engines.kt.

/**
 * The two ways a bundled program can run on iOS:
 *
 * - **Pure Terry**: Terry A. Davis' HolyC compiled and interpreted on the device (every program,
 *   including the user's own HolyC);
 * - **Pure Swift**: the program's ahead-of-time translation to Swift (PureNative), for the bundled
 *   programs that have one, unchanged since translation.
 *
 * The choice is explicit: a program the native engine cannot run is never quietly run on the
 * interpreter under the native name; the user is told why and can run it in Pure Terry.
 */
public enum Engines {
    /** Names of the engines (proper names: the same in every language). */
    public static let TERRY_NAME = "Pure Terry"
    public static let NATIVE_NAME = "Pure Swift"

    /** True when this build contains translated programs. */
    public static var nativeAvailable: Bool { NativePrograms.catalog != nil }

    /** Why [path] cannot run natively (a localization key), or nil when its translation can run. */
    public static func unavailableReason(_ shell: Shell, _ path: String) -> String? {
        guard let cat = NativePrograms.catalog, let img = NativePrograms.find(path) else { return "engine.reason.untranslated" }
        if let r = img.requiresTerry { return "engine.reason.\(r)" }
        if NativePrograms.staleReason(img, shell.fs) != nil { return "engine.reason.changed" }
        if cat.programs.isEmpty { return "engine.reason.untranslated" }
        return nil
    }

    /** The binding that runs [path] natively, or nil (check [unavailableReason] first). */
    public static func binding(_ path: String) -> NativeBinding? {
        guard let cat = NativePrograms.catalog, let img = NativePrograms.find(path) else { return nil }
        return NativeBinding(cat.prelude, img)
    }
}

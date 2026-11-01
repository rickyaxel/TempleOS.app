import Foundation

/**
 * What the TempleOS screen shows next to the regions the operating system draws over it: the
 * iPhone home indicator, the Android navigation bar or gesture handle, and the side gutters of a
 * landscape screen (a display cutout or a side navigation bar). The shell resolves it on every
 * render from what it actually drew (`Shell.systemChrome`) and paints those regions in these
 * colors, so the system-owned region shows the TempleOS surface that owns the edge. The platform
 * adapters (iOS `TempleViewController`, Android `SystemBarsAdapter`) only translate it to system
 * calls: window background, home-gesture deferral, icon contrast.
 *
 * Kotlin `SystemChrome` (line-for-line port). Colors are palette indices.
 */
public struct SystemChrome: Equatable {
    public enum Owner: Equatable { case desktop, window, appOverride, popup, keyRow, keyboard }

    /** Where the platform reports its navigation bar (Android three-button bars move to a side in landscape). */
    public enum Edge { case bottom, left, right }

    /** Painted under the bottom system region (home indicator, navigation bar, gesture handle). */
    public let bottom: Int
    /** Painted in the left and right safe-area gutters beside the content. */
    public let side: Int
    /** What owns the bottom edge (for tests and diagnostics). */
    public let owner: Owner
    /** The device keyboard covers the bottom edge (its window draws the region under it). */
    public let deviceKeyboard: Bool
    /** The focused app asks for the bottom-edge system gestures to be deferred (its controls sit there). */
    public let defersEdgeGestures: Bool

    public init(bottom: Int, side: Int, owner: Owner, deviceKeyboard: Bool = false, defersEdgeGestures: Bool = false) {
        self.bottom = bottom; self.side = side; self.owner = owner
        self.deviceKeyboard = deviceKeyboard; self.defersEdgeGestures = defersEdgeGestures
    }

    /** The color under a navigation bar on [edge]. */
    public func colorAt(_ edge: Edge) -> Int { edge == .bottom ? bottom : side }

    /** True when dark system icons read better than light ones on the color at [edge]. */
    public func darkIconsAt(_ edge: Edge) -> Bool { SystemChrome.prefersDarkIcons(colorAt(edge)) }

    /** A surface that may own the bottom edge, with the color it shows along its bottom row. */
    public struct Layer {
        public let rect: Rect, color: Int, owner: Owner
        public init(_ rect: Rect, _ color: Int, _ owner: Owner) { self.rect = rect; self.color = color; self.owner = owner }
    }

    /**
     * WCAG contrast: dark icons when black contrasts more with [color] than white does (relative
     * luminance above 0.179). Every palette color keeps at least 4.5:1 against the chosen icons.
     */
    public static func prefersDarkIcons(_ color: Int) -> Bool { luminance(Palette.STD[color & 15]) > 0.1791 }

    /** WCAG 2 relative luminance of an ARGB color. */
    public static func luminance(_ argb: Int32) -> Double {
        let v = UInt32(bitPattern: argb)
        func lin(_ c: UInt32) -> Double { let x = Double(c) / 255; return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin((v >> 16) & 0xFF) + 0.7152 * lin((v >> 8) & 0xFF) + 0.0722 * lin(v & 0xFF)
    }

    /**
     * Resolves the edge colors. [content] are windows (bottom to top) judged against [contentBottom];
     * [bars] are bottom bars and popups (bottom to top) judged against [usableBottom]. A layer owns an
     * edge when it reaches it across the whole usable width ([left] to [right]); the side gutters follow
     * the content.
     */
    public static func resolve(desktop: Int, content: [Layer], contentBottom: Int, bars: [Layer], usableBottom: Int,
                               left: Int, right: Int, deviceKeyboard: Bool = false, defersEdgeGestures: Bool = false) -> SystemChrome {
        func owns(_ l: Layer, _ edge: Int) -> Bool { l.rect.bottom >= edge && l.rect.x <= left && l.rect.right >= right && l.rect.w > 0 && l.rect.h > 0 }
        let c = content.last { owns($0, contentBottom) }
        let sideColor = c?.color ?? desktop
        let b = bars.last { owns($0, usableBottom) }
        return SystemChrome(bottom: b?.color ?? sideColor, side: sideColor, owner: b?.owner ?? c?.owner ?? .desktop,
                            deviceKeyboard: deviceKeyboard, defersEdgeGestures: defersEdgeGestures)
    }
}

/**
 * Passes a value on only when it differs from the last one passed (platform adapters: one system
 * call per actual change, never per frame). [reset] forces the next value through.
 */
public final class ChangeGate<T: Equatable> {
    private let apply: (T) -> Void
    private var last: T?
    public init(_ apply: @escaping (T) -> Void) { self.apply = apply }
    /** Returns true if [value] was applied. */
    @discardableResult public func offer(_ value: T) -> Bool {
        if let l = last, l == value { return false }
        last = value
        apply(value)
        return true
    }
    public func reset() { last = nil }
}

import Foundation

// Shared declarations from ui/App.kt (KernelRunner is ported in App.swift).

/** Pointer actions delivered by the platform (logical pixel coordinates). */
public enum Ptr {
    public static let DOWN = 0, MOVE = 1, UP = 2, CANCEL = 3
}

public final class PointerEvent {
    public let action: Int, x: Int, y: Int, id: Int, timeMs: Int64
    public init(_ action: Int, _ x: Int, _ y: Int, id: Int = 0, timeMs: Int64 = 0) {
        self.action = action; self.x = x; self.y = y; self.id = id; self.timeMs = timeMs
    }
}

/** An entry in a menu (start menu, window menu, program menu). */
public final class MenuItem {
    private let labelText: L10n.Presentation<String>
    public var label: String { labelText.value }
    public let enabled: Bool
    public let checked: Bool
    public let action: () -> Void
    public init(_ label: @autoclosure @escaping () -> String, enabled: Bool = true, checked: Bool = false, _ action: @escaping () -> Void) {
        labelText = L10n.Presentation(label); self.enabled = enabled; self.checked = checked; self.action = action
    }
}

/**
 * An element exposed to TalkBack / VoiceOver. The desktop is one custom view, so the shell
 * records what it draws (buttons, rows, keys, text) and the platform publishes these as
 * virtual accessibility nodes; activating one taps its center. [rect] is in logical px.
 */
public final class A11yNode {
    public let rect: Rect, label: String, button: Bool, selected: Bool
    public init(_ rect: Rect, _ label: String, _ button: Bool, _ selected: Bool = false) {
        self.rect = rect; self.label = label; self.button = button; self.selected = selected
    }
}

/** A program frame the platform draws on top of the shell surface (640x480 indexed). */
public protocol FrameSource: AnyObject {
    var frameW: Int { get }
    var frameH: Int { get }
    /** Copies the latest frame into [dst] and returns its version. */
    func copyFrame(_ dst: UnsafeMutablePointer<UInt8>) -> Int64
    var frameVersion: Int64 { get }
    var palette: [Int32] { get }
    /** The part of the frame to show: the program's TempleOS window (frame pixels). */
    var window: Rect { get }
}

public extension FrameSource {
    var window: Rect { Rect(0, 0, frameW, frameH) }
}

/** [src] is the part of the frame shown in [rect] (frame pixels). */
public final class Overlay {
    public let rect: Rect
    public let source: FrameSource
    public let src: Rect
    public init(_ rect: Rect, _ source: FrameSource, _ src: Rect? = nil) {
        self.rect = rect; self.source = source; self.src = src ?? Rect(0, 0, source.frameW, source.frameH)
    }
}

/**
 * A TempleOS Mobile application hosted in a shell window. Apps draw into the
 * shell surface (client area) and receive pointer gestures and keys.
 * Kotlin `abstract class App`: subclasses override `title`, `kind` and `draw`.
 */
open class App {
    public unowned let shell: Shell
    /**
     * For code on kernel/background threads, which can outlive the shell (iOS may tear
     * the scene down while a program thread is still stopping): unlike [shell], reading
     * it after the shell is gone is safe.
     */
    public private(set) weak var liveShell: Shell?
    public var dirty = true
    /** Window that opened this child; IDs do not retain an app or its runtime. */
    public var navigationParentId: Int?
    @discardableResult open func navigateBack() -> Bool {
        guard navigationParentId != nil, let w = shell.windows.first(where: { $0.app === self }) else { return false }
        shell.close(w); return true
    }

    public init(_ shell: Shell) { self.shell = shell; liveShell = shell }

    open var title: String { fatalError("abstract") }
    /** Stable kind identifier used for session restore ("terminal", "editor"...). */
    open var kind: String { fatalError("abstract") }
    /** Whether the soft keyboard should be visible while this app is focused. */
    open var wantsKeyboard: Bool { false }

    open func draw(_ s: Surface, _ r: Rect) { fatalError("abstract") }

    /** Raw pointer stream; return true to consume (no gesture processing). */
    open func pointer(_ e: PointerEvent, _ r: Rect) -> Bool { false }
    open func tap(_ x: Int, _ y: Int, _ r: Rect) {}
    open func longPress(_ x: Int, _ y: Int, _ r: Rect) {}
    /** Vertical/horizontal drag (scroll) by a pixel delta. */
    open func scroll(_ dx: Int, _ dy: Int, _ r: Rect) {}
    /** A TempleOS key (ch, scan code with SCF_* flags). */
    open func key(_ ch: Int, _ sc: Int64, _ down: Bool) -> Bool { false }
    /**
     * True for a running TempleOS program: keys are a PC keyboard for it (held down until released,
     * SHIFT/CTRL/ALT are keys of their own), not text entry (Kernel/SerialDev/Keyboard.HC).
     */
    open var rawKeys: Bool { false }
    open func text(_ s: String) {
        guard InputCharacterPolicy.isByteText(s) else { shell.rejectInput(); return }
        for c in s.unicodeScalars {
            let code = c == "\n" ? 10 : Int(c.value)
            let (ch, sc) = Keys.forChar(code)
            _ = key(ch, sc, true); _ = key(ch, sc | Keys.SCF_KEY_UP, false)
        }
    }
    /** Window menu entries (shown by the window's menu button). */
    open func menu() -> [MenuItem] { [] }
    /** Periodic update; return true if the app needs redrawing. */
    open func tick(_ nowMs: Int64) -> Bool { false }
    open func overlays(_ r: Rect) -> [Overlay] { [] }
    /** Release controls owned by this target before focus/modal/lifecycle transitions. */
    open func releaseInput() {}
    open func close() {}
    /** Persistable state for session restore. */
    open func saveState() -> [String: String] { [:] }
    /** True while the app has unsaved changes (closing asks for confirmation). */
    open var unsaved: Bool { false }
    open func onBackground() {}
    open func onForeground() {}
    /** The window became visible or hidden (portrait shows only the focused window). */
    open func onVisibility(_ visible: Bool) {}

    /**
     * Palette color painted under the system navigation region while this app's window owns the
     * bottom edge (SystemChrome). nil (the default): what the shell draws along that edge, the
     * window background. Override only for an app that must differ from it.
     */
    open var systemEdgeColor: Int? { nil }

    /** True while focused: the platform defers its bottom-edge gestures (iOS home indicator). */
    open var defersEdgeGestures: Bool { false }

    public func invalidate() { dirty = true; shell.invalidate() }

    /** Screen-reader nodes filled by [draw] (the shell clears them before each draw). */
    var a11yItems: [A11yNode] = []
    public func a11yButton(_ r: Rect, _ label: String, selected: Bool = false) { a11yItems.append(A11yNode(r, label, true, selected)) }
    public func a11yText(_ r: Rect, _ label: String) { a11yItems.append(A11yNode(r, label, false)) }
    /** A whole page of text for screen readers (one node). */
    public func a11yPage(_ r: Rect, _ text: String) { a11yText(r, text) }

    /**
     * Publishes this app's screen-reader nodes for [r] after [draw] (see [A11yNode]). Apps that
     * record their buttons and text while drawing need nothing more; the default names the window.
     */
    open func accessibility(_ r: Rect) {
        if a11yItems.isEmpty { shell.a11yText(r, title) }
        for n in a11yItems { if n.button { shell.a11yButton(n.rect, n.label, selected: n.selected) } else { shell.a11yText(n.rect, n.label) } }
    }
}

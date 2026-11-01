import Foundation

// Port of ui/Shell.kt.

/** Services the platform provides to the shell. */
public protocol ShellEnv: AnyObject {
    /** System runtime files ("Prelude.HC", "PreludeDefines.HC", "GrLib.HC", "KernelClasses.HC", "font8x8.bin"). */
    func runtimeFile(_ name: String) -> [UInt8]?
    var fs: LayeredFs { get }
    /** Directory for session state (outside the user's C: drive). */
    var stateStore: StateStore { get }
    func nowMs() -> Int64
    /** CPU time this process has used (all threads), ns; -1 when the platform cannot tell (benchmarks). */
    func processCpuNs() -> Int64
    /**
     * The device's PC speaker: [freq] Hz from [atNs] (monoNanos) until the next call, 0 = off
     * (Kernel/PcSpeaker.swift renders it; docs/audio/TEMPLEOS_SOUND.md).
     */
    func tone(_ freq: Double, at atNs: Int64)
    func clipboardGet() -> String?
    func clipboardSet(_ s: String)
    /** User-selected About action; opens only Brand.privacyURL, never a program-supplied URL. */
    func openPrivacyPolicy()
    /** Invoked from any thread when the shell needs rendering. */
    func requestRender()
    /** The device's (or this app's) preferred UI languages, most preferred first (BCP-47 tags). */
    func preferredLanguages() -> [String]
    /** The device's region setting (ISO 3166 code), used only to pick a variant of a language. */
    func deviceRegion() -> String?
    /** Width in logical px of [s] drawn by the platform's text engine (see [Surface.TextRun]). */
    func measureText(_ s: String) -> Int
    var memoryLimitBytes: Int { get }
    /** The platform's minimum touch target in dp/pt (Material 48 dp, Apple HIG 44 pt): sizes menu rows. */
    var touchTargetDp: Double { get }
}

public extension ShellEnv {
    func nowMs() -> Int64 { epochMillisNow() }
    func processCpuNs() -> Int64 {
        var u = rusage()
        if getrusage(RUSAGE_SELF, &u) != 0 { return -1 }
        func ns(_ t: timeval) -> Int64 { Int64(t.tv_sec) * 1_000_000_000 + Int64(t.tv_usec) * 1_000 }
        return ns(u.ru_utime) + ns(u.ru_stime)
    }
    func tone(_ freq: Double, at atNs: Int64) {}
    /** The speaker set now. */
    func tone(_ freq: Double) { tone(freq, at: monoNanos()) }
    func clipboardGet() -> String? { nil }
    func clipboardSet(_ s: String) {}
    func openPrivacyPolicy() {}
    func requestRender() {}
    func preferredLanguages() -> [String] { ["en-US"] }
    func deviceRegion() -> String? { nil }
    func measureText(_ s: String) -> Int { s.scLen * 8 }
    var memoryLimitBytes: Int { 32 << 20 }
    var touchTargetDp: Double { 48.0 }
}

/** Small key-value persistence for the session (platform file or preferences). Errors are ignored by the shell. */
public protocol StateStore: AnyObject {
    func load() throws -> String?
    func save(_ text: String) throws
}

// MARK: - Latin-1 / UTF-16-like string helpers shared by the UI ports
// Kotlin indexes strings by char; these index by Unicode scalar (all TempleOS text is Latin-1).

extension String {
    var scLen: Int { unicodeScalars.count }
    var scArr: [Unicode.Scalar] { Array(unicodeScalars) }
    /** Kotlin substring(a, b) by scalar offsets. */
    func scSub(_ a: Int, _ b: Int) -> String {
        let u = unicodeScalars
        let i = u.index(u.startIndex, offsetBy: a)
        let j = u.index(i, offsetBy: b - a)
        return String(String.UnicodeScalarView(u[i..<j]))
    }
    /** Kotlin substring(a). */
    func scSub(_ a: Int) -> String {
        let u = unicodeScalars
        let i = u.index(u.startIndex, offsetBy: a)
        return String(String.UnicodeScalarView(u[i...]))
    }
    /** Kotlin split(c) (keeps empty parts). */
    func scSplit(_ sep: Unicode.Scalar) -> [String] {
        var res: [String] = []
        var cur = String.UnicodeScalarView()
        for c in unicodeScalars {
            if c == sep { res.append(String(cur)); cur = String.UnicodeScalarView() } else { cur.append(c) }
        }
        res.append(String(cur))
        return res
    }
    /** Kotlin indexOf(c, from); -1 when absent. */
    func scIndexOf(_ c: Unicode.Scalar, _ from: Int = 0) -> Int {
        var i = 0
        for x in unicodeScalars { if i >= from && x == c { return i }; i += 1 }
        return -1
    }
    /** Removes every occurrence of one scalar (e.g. "\r", which Swift merges into "\r\n" characters). */
    func scRemoving(_ c: Unicode.Scalar) -> String {
        String(String.UnicodeScalarView(unicodeScalars.filter { $0 != c }))
    }
}

func scString<S: Sequence>(_ s: S) -> String where S.Element == Unicode.Scalar {
    String(String.UnicodeScalarView(s))
}

/** Kotlin Int.coerceIn(lo, hi). */
@inline(__always) func coerceInUI(_ v: Int, _ lo: Int, _ hi: Int) -> Int { v < lo ? lo : (v > hi ? hi : v) }

/**
 * The TempleOS Mobile desktop: a window manager drawing TempleOS-style windows
 * into a logical framebuffer. Landscape shows overlapping windows like the
 * original desktop; portrait shows one window at a time with a window deck.
 *
 * All methods must be called on the UI thread. Kernels run on their own
 * threads and talk to the shell through queues.
 */
public final class Shell {
    public let env: ShellEnv
    /** The one speaker the program windows share ([UiKernelEnv]). */
    public let speaker: SpeakerMux
    public let font: [UInt8]
    public let surface: Surface
    public var fs: LayeredFs { env.fs }

    /** The effective UI language: the in-app choice, else the device's, else English. */
    public var uiLocale: UiLocale? { L10n.locale }

    /** Re-resolves the UI language (settings changed, device language changed); keeps all state. */
    public func applyLanguage() {
        guard let r = L10n.resolver else { return }
        let (id, _) = r.resolve(settings.language.isEmpty ? nil : settings.language, env.preferredLanguages(), env.deviceRegion())
        let before = L10n.version
        L10n.use(id)
        if L10n.version != before { windows.forEach { $0.app.dirty = true }; invalidate() }
    }

    public private(set) var width = 320
    public private(set) var height = 480
    /** Wider than tall (orientation only: layout decisions use [windowed] and the usable size). */
    public var landscape: Bool { width > height }
    /**
     * The desktop shows overlapping windows (TempleOS's own desktop) rather than one window at a time:
     * decided by the usable size ([DisplayLayout.windowed]), so an unfolded foldable held either way and a
     * phone in landscape are windowed, a phone in portrait shows the deck.
     */
    public var windowed: Bool { DisplayLayout.windowed(width, height, usableW: width - insetLeft - insetRight, usableH: height - insetTop - insetBottom) }
    /** Active fold divisions and occlusions (logical px; empty on ordinary screens). See [apply]. */
    public private(set) var divisions: [Rect] = []
    public private(set) var occlusions: [Rect] = []
    /** Corner-adapted insets for the top bar row ([DisplayGeometry.barLeft]); 0 = the safe area's. */
    private var barInsetLeft = 0
    private var barInsetRight = 0
    private var geometry: DisplayGeometry?
    /** Safe-area insets and keyboard height, in logical pixels. */
    public private(set) var insetTop = 0
    public private(set) var insetBottom = 0
    public private(set) var insetLeft = 0
    public private(set) var insetRight = 0
    public private(set) var keyboardHeight = 0
    /** dp (Android) or pt (iOS) per logical px: display scale / screen scale, from the platform view. */
    public private(set) var dpPerPx = 1.0

    public final class Window {
        public let app: App
        public var x = 0, y = 0, w = 0, h = 0
        public var maximized = false
        /** Last visibility reported to the app (nil = not reported yet). */
        public var shownState: Bool?
        public let id: Int
        public static var nextId = 1
        public init(_ app: App) { self.app = app; id = Window.nextId; Window.nextId += 1 }
    }

    public private(set) var windows: [Window] = []
    public private(set) var focused: Window? = nil
    private var needsRender = true
    private let uiQueue = LockedQueue<() -> Void>()

    // overlays (menus, dialogs)
    private var menu: PopupMenu? = nil
    private var dialog: Dialog? = nil
    private var toast: L10n.Presentation<String>? = nil
    private var toastUntil: Int64 = 0

    /** UI-thread frame pacing reported by the platform view (perf log). */
    public let uiFrames = UiFrameStats()

    public lazy var catalog: Catalog = Catalog.load(self)
    public lazy var historicalMenus: HistoricalMenus = HistoricalMenus.load(self)
    public var settings = Settings() { didSet { Touch.large = settings.largeTouch } }

    public init(_ env: ShellEnv) {
        self.env = env
        speaker = SpeakerMux(env)
        guard let f = env.runtimeFile("font8x8.bin") else { fatalError("font missing") }
        font = f
        surface = Surface(320, 480, f)
        // Kotlin captures env strongly; weak here so a platform env that owns the shell is no retain cycle
        surface.measureNative = { [weak env] s in env?.measureText(s) ?? s.scLen * 8 }
        // strong, as Kotlin's env::runtimeFile: L10n keeps the first env's files for the process lifetime
        L10n.initialize(env.runtimeFile)
        Touch.large = settings.largeTouch
        // Kotlin: init { applyLanguage() } right after invalidate() (all stored properties are set here)
        applyLanguage()
    }

    // ------------------------------------------------------------ lifecycle

    public func invalidate() { needsRender = true; env.requestRender() }

    /** User override from the key row's keyboard key: 1 force shown, -1 force hidden (until focus changes). */
    private var keyboardOverride = 0

    /** The in-app TempleOS keyboard (default input; the device keyboard is the fallback). */
    public private(set) lazy var keyboard = TempleKeyboard(self)

    /** True while the TempleOS keyboard is on screen. */
    public private(set) var templeKeyboardShown = false

    /**
     * Why the TempleOS keyboard's visibility changed (Swift-first diagnostics, docs/foldable/KEYBOARD_LIFECYCLE.md).
     * Every change is attributed: the user's own actions (keys, taps, back), the focused program's needs, a dialog,
     * or the keyboard mode. Nothing else changes it: geometry (folds, rotation, split view) and iOS focus never do.
     */
    public enum KeyboardReason: String {
        /** The focused window or a dialog needs (or no longer needs) text input. */
        case program
        /** A tap in a text area, or the key row's keyboard key, asked for it. */
        case userShow = "user-show"
        /** The keyboard's HIDE key or the key row's keyboard key. */
        case userHide = "user-hide"
        /** A physical keyboard was typed on: the on-screen keyboard steps aside. */
        case physicalKey = "physical-key"
        /** A back action (Cmd-., VoiceOver escape, Android back). */
        case back
        /** The TempleOS / device keyboard setting changed. */
        case mode
    }

    /** One change of the TempleOS keyboard's visibility. */
    public struct KeyboardTransition: Equatable {
        public let seq: Int, shown: Bool, reason: KeyboardReason, timeMs: Int64
    }

    /** The last changes (newest last, at most 32) and their count since launch. */
    public private(set) var keyboardTransitions: [KeyboardTransition] = []
    public private(set) var keyboardTransitionCount = 0
    /** Called on every change (the platform logs it). */
    public var onKeyboardTransition: ((KeyboardTransition) -> Void)?

    /** Re-shows the keyboard (e.g. a tap in a text area after the user dismissed it). */
    public func requestKeyboard() { keyboardOverride = 1; syncKeyboard(.userShow) }

    /** Hides the on-screen keyboard until a text area is tapped or focus changes. */
    public func hideKeyboard(_ reason: KeyboardReason = .userHide) { keyboardOverride = -1; syncKeyboard(reason) }

    /** Compatibility hook: hardware use does not change software keyboard intent. */
    public func hardwareKeyUsed() {} // Hardware use never withdraws the only software keyboard.

    // MARK: physical keyboards

    /** The one key that repeats, across the physical keyboard, the TempleOS keyboard and game buttons. */
    public let typematic = Typematic()

    private final class HeldKey {
        let ch: Int, sc: Int64, since: Int64, ticket: Int64
        var last: Int64 = 0
        init(_ ch: Int, _ sc: Int64, _ since: Int64, _ ticket: Int64) { self.ch = ch; self.sc = sc; self.since = since; self.ticket = ticket }
    }
    private var heldHw: [Int: HeldKey] = [:]
    private var heldHwOrder: [Int] = []

    /**
     * A physical key (Android KeyEvent, iOS UIPress), down or up. TempleOS repeats a held key at its
     * own typematic rate (HomeLocalize.HC KbdTypeMatic(0): 250 ms, then 30 per second) and never repeats
     * SHIFT/CTRL/ALT (Kernel/SerialDev/Keyboard.HC KbdBuildSC), so the platform's repeats are dropped
     * and [tick] repeats. Modifier keys are keys of their own for a running program (Titanium reads
     * Bt(kbd.down_bitmap,SC_CTRL)); other apps only see their flags on the other keys.
     */
    public func hardwareKey(_ ch: Int, _ sc: Int64, _ down: Bool, platformRepeat: Bool = false) {
        if platformRepeat || !inputActive { return }
        let code = Int(sc & 0xFF)
        if isModifierCode(code) {
            if down {
                guard heldHw[code] == nil else { return }
                heldHw[code] = HeldKey(ch, sc, env.nowMs(), -1); heldHwOrder.append(code)
            } else {
                guard heldHw.removeValue(forKey: code) != nil else { return }
                heldHwOrder.removeAll { $0 == code }
            }
            if dialog == nil, menu == nil, let app = focused?.app, app.rawKeys {
                let flag = code == Keys.SC_SHIFT ? Keys.SCF_SHIFT : code == Keys.SC_CTRL ? Keys.SCF_CTRL : Keys.SCF_ALT
                _ = app.key(ch, down ? sc : (sc & ~flag) | Keys.SCF_KEY_UP, down)
            }
            return
        }
        if down {
            if heldHw[code] != nil { return }
            heldHw[code] = HeldKey(ch, sc, env.nowMs(), typematic.pressed()); heldHwOrder.append(code)
            key(ch, sc, true)
        } else {
            guard let held = heldHw.removeValue(forKey: code) else { return }
            heldHwOrder.removeAll { $0 == code }
            key(held.ch, held.sc | Keys.SCF_KEY_UP, false)
        }
    }

    /** Lifts every held physical key (focus change, background) so none stays down in a program. */
    public func releaseHardwareKeys() {
        let held = heldHwOrder.compactMap { heldHw[$0] }
        heldHw.removeAll(); heldHwOrder.removeAll()
        for h in held { key(h.ch, (h.sc & ~(Keys.SCF_SHIFT | Keys.SCF_CTRL | Keys.SCF_ALT)) | Keys.SCF_KEY_UP, false) }
    }

    private func repeatHardwareKeys(_ now: Int64) {
        for code in heldHwOrder {
            guard let h = heldHw[code] else { continue }
            if isModifierCode(code) || !typematic.repeats(h.ticket) { continue }
            if now - h.since < Shell.TYPEMATIC_DELAY_MS { continue }
            if h.last == 0 { h.last = h.since + Shell.TYPEMATIC_DELAY_MS - Shell.TYPEMATIC_PERIOD_MS }
            var n = 0
            while now - h.last >= Shell.TYPEMATIC_PERIOD_MS && n < 2 { key(h.ch, h.sc, true); h.last += Shell.TYPEMATIC_PERIOD_MS; n += 1 }
            if now - h.last >= Shell.TYPEMATIC_PERIOD_MS { h.last = now } // no burst after a stall
        }
    }

    private func isModifierCode(_ code: Int) -> Bool { code == Keys.SC_SHIFT || code == Keys.SC_CTRL || code == Keys.SC_ALT }

    /**
     * The on-screen CTRL/ALT latches for a running program: TempleOS sees the key go down when it is
     * latched and up when the latch ends ("sticky keys"), so held-key checks see it.
     */
    private func latchEvent(_ code: Int, _ down: Bool) {
        guard dialog == nil, menu == nil, let app = focused?.app, app.rawKeys else { return }
        let flag = code == Keys.SC_CTRL ? Keys.SCF_CTRL : code == Keys.SC_ALT ? Keys.SCF_ALT : Keys.SCF_SHIFT
        _ = app.key(0, down ? Int64(code) | flag : Int64(code) | Keys.SCF_KEY_UP, down)
    }

    /** Compatibility for old callers/settings: software input is always TempleOS-owned. */
    public func setKeyboardMode(_ mode: Int) {
        settings.keyboardMode = Settings.KEYBOARD_TEMPLEOS
        syncKeyboard(.mode)
        saveSession()
    }

    private func keyboardWanted() -> Bool {
        if dialog?.wantsKeyboard == true { return true }
        switch keyboardOverride {
        case 1: return true
        case -1: return false
        default: return focused?.app.wantsKeyboard == true
        }
    }

    /**
     * Shows or hides the TempleOS or device keyboard to match what the dialog / focused app needs and the user
     * asked for. [reason] attributes a change it makes; without one it is the program's needs (focus, dialogs).
     */
    private func syncKeyboard(_ reason: KeyboardReason = .program) {
        let want = keyboardWanted()
        let tos = want
        if tos != templeKeyboardShown {
            templeKeyboardShown = tos
            keyboardTransitionCount += 1
            let t = KeyboardTransition(seq: keyboardTransitionCount, shown: tos, reason: reason, timeMs: env.nowMs())
            keyboardTransitions.append(t)
            if keyboardTransitions.count > 32 { keyboardTransitions.removeFirst() }
            onKeyboardTransition?(t)
            if !tos { keyboard.reset() }
            relayout(false); windows.forEach { $0.app.dirty = true }; invalidate()
        }
    }

    /** Height kept free at the bottom: home indicator / device keyboard, plus the TempleOS keyboard. */
    public var reservedBottom: Int { insetBottom + (templeKeyboardShown ? bottomBarHeight() : 0) }

    /** The bottom of the usable screen: above the home indicator / navigation bar and the device keyboard. */
    private var usableBottom: Int { height - insetBottom }

    /**
     * Tabletop: a fold runs across the screen below the desktop and the TempleOS keyboard fits under it.
     * The keyboard then takes the lower part (where the hands are) and the desktop keeps the upper part,
     * so nothing but the keyboard's background lies on the hinge.
     */
    private func tabletopFold() -> Rect? {
        if !templeKeyboardShown || divisions.isEmpty { return nil }
        let top = insetTop + topBarH
        guard let d = horizontalDivision(in: Rect(insetLeft, top, width - insetLeft - insetRight, usableBottom - top)) else { return nil }
        return usableBottom - d.bottom >= keyboard.rows().count * keyboardBaseRow() + 4 ? d : nil
    }

    /**
     * TempleOS keyboard row height without a fold: shorter on a short viewport, where height is scarce, and
     * never so tall that the keyboard would leave less than 40 px of desktop (a very small window).
     */
    private func keyboardBaseRow() -> Int {
        let base = metrics.compact ? 26 : Touch.kbdRow
        let room = usableBottom - insetTop - topBarH - 40 - 4
        return max(12, min(base, room / max(1, keyboard.rows().count)))
    }

    /** TempleOS keyboard row height: below a tabletop fold the rows grow (up to half again) into the lower part. */
    public func keyboardRowHeight(_ rows: Int) -> Int {
        let base = keyboardBaseRow()
        guard let d = tabletopFold() else { return base }
        return max(base, min(base * 3 / 2, (usableBottom - d.bottom - 4) / max(1, rows)))
    }

    /**
     * Columns [x0, x1) for a bottom-bar row of keys with relative [weights] in [r]: the part of the row no
     * occlusion covers, broken at a book fold so no key lies on the hinge (DisplayLayout.keyColumns).
     */
    public func keyColumns(_ weights: [Int], _ r: Rect) -> [(Int, Int)] {
        let (x0, x1) = DisplayLayout.rowSpan(r.y, r.bottom, r.x, r.right, occlusions)
        let span = Rect(x0, r.y, x1 - x0, r.h)
        return DisplayLayout.keyColumns(weights, span, gap: verticalDivision(in: span))
    }

    // accessibility nodes recorded while rendering (see [A11yNode])
    private var a11yBase: [A11yNode] = []
    private var a11yKeys: [A11yNode] = []
    private var a11yModal: [A11yNode] = []
    private var a11yTarget = 0 // 0 base, 1 keys, 2 modal

    private func a11yAdd(_ n: A11yNode) {
        switch a11yTarget { case 1: a11yKeys.append(n); case 2: a11yModal.append(n); default: a11yBase.append(n) }
    }

    /** Records a tappable element for TalkBack / VoiceOver; called while drawing. */
    public func a11yButton(_ r: Rect, _ label: String, selected: Bool = false) {
        if !label.trimmingCharacters(in: .whitespaces).isEmpty { a11yAdd(A11yNode(r, label, true, selected)) }
    }

    /** Records readable text for TalkBack / VoiceOver; called while drawing. */
    public func a11yText(_ r: Rect, _ label: String) {
        if !label.trimmingCharacters(in: .whitespaces).isEmpty { a11yAdd(A11yNode(r, label, false)) }
    }

    /** What a screen reader can reach now: a dialog or menu is modal; keyboard keys stay reachable. */
    public func accessibilityNodes() -> [A11yNode] { (a11yModal.isEmpty ? a11yBase : a11yModal) + a11yKeys }

    /** Increases whenever [accessibilityNodes] may have changed (each render). */
    public private(set) var a11yVersion: Int64 = 0

    /** Performs a screen reader's activation: a tap at the node's center. */
    public func accessibilityActivate(_ n: A11yNode) {
        let x = n.rect.x + n.rect.w / 2, y = n.rect.y + n.rect.h / 2
        let t = env.nowMs()
        pointer(PointerEvent(Ptr.DOWN, x, y, id: Shell.A11Y_POINTER, timeMs: t))
        pointer(PointerEvent(Ptr.UP, x, y, id: Shell.A11Y_POINTER, timeMs: t + 1))
        _ = tick()
    }

    /** Runs [f] on the UI thread at the next tick (safe from kernel threads). */
    public func post(_ f: @escaping () -> Void) { uiQueue.add(f); env.requestRender() }

    public func resize(_ w: Int, _ h: Int, _ top: Int = 0, _ bottom: Int = 0, _ left: Int = 0, _ right: Int = 0, _ keyboard: Int = 0, dpPerPx dp: Double? = nil) {
        resize(w, h, top, bottom, left, right, keyboard, dp, screenChanged: false)
    }

    private func resize(_ w: Int, _ h: Int, _ top: Int, _ bottom: Int, _ left: Int, _ right: Int, _ keyboard: Int, _ dp: Double?, screenChanged: Bool) {
        let wasWindowed = windowed
        width = max(w, 160); height = max(h, 160)
        insetTop = top; insetBottom = bottom; insetLeft = left; insetRight = right; keyboardHeight = 0
        if let dp = dp, dp.isFinite, dp > 0 { dpPerPx = dp }
        syncCompact()
        surface.resize(width, height)
        // a new desktop mode or fold re-places floating windows (as a rotation always did)
        relayout(wasWindowed != windowed || screenChanged)
        windows.forEach { $0.app.dirty = true }
        invalidate()
    }

    /**
     * Lays the desktop out for [g] (the platform view's measurement, every layout pass). Nothing happens
     * when it equals the last one, so the many layout passes of a fold or rotation animation cost nothing
     * and running programs never notice them. Programs keep running through every change: only the
     * surface and the window rectangles follow the screen.
     * Returns true when the layout changed.
     */
    @discardableResult
    public func apply(_ g: DisplayGeometry) -> Bool {
        if g == geometry { return false }
        geometry = g
        let g = DisplayLayout.sanitized(g)
        // a fold, a rotation or a new safe area re-places floating windows once the platform reports its final
        // geometry: the passes of a fold or rotation animation may carry the old insets for a moment, and
        // windows placed then would keep a stale position
        let screenChanged = g.divisions != divisions || g.width != width || g.height != height
            || (g.top, g.bottom, g.left, g.right) != (insetTop, insetBottom, insetLeft, insetRight)
        divisions = g.divisions; occlusions = g.occlusions
        barInsetLeft = g.barLeft; barInsetRight = g.barRight
        resize(g.width, g.height, g.top, g.bottom, g.left, g.right, g.keyboard, g.dpPerPx, screenChanged: screenChanged)
        return true
    }

    /** A fold that runs across [r] from left to right (tabletop), as the band it covers in [r], or nil. */
    public func horizontalDivision(in r: Rect) -> Rect? {
        for d in divisions {
            if let c = DisplayLayout.crossing(d, r), !DisplayLayout.isVertical(c, in: r), c.y - r.y >= 64, r.bottom - c.bottom >= 64 { return c }
        }
        return nil
    }

    /** A fold that runs across [r] from top to bottom (book), as the band it covers in [r], or nil. */
    public func verticalDivision(in r: Rect) -> Rect? {
        for d in divisions {
            if let c = DisplayLayout.crossing(d, r), DisplayLayout.isVertical(c, in: r), c.x > r.x, c.right < r.right { return c }
        }
        return nil
    }

    /**
     * Where popups may go: the usable screen, or on a folded screen one part of it, so a menu is never split
     * by the hinge. Beside a book fold: the side of ([x], [y]), the anchor. Above and below a tabletop fold:
     * the larger part (the lower one, where the hands are, on the Duo), since a menu's rows need height.
     */
    public func popupArea(near x: Int, _ y: Int) -> Rect {
        let top = insetTop + 2
        let bottom = height - insetBottom - 4
        let full = Rect(insetLeft + 4, top, max(1, width - insetLeft - insetRight - 8), max(1, bottom - top))
        if divisions.isEmpty { return full }
        let parts = DisplayLayout.regions(full, divisions)
        if parts.count < 2 { return full }
        if parts[0].x == parts[1].x { return parts.max { $0.h < $1.h } ?? full } // stacked: tabletop
        return DisplayLayout.region(at: x, y, parts)
    }

    /**
     * Where a dialog is centered: below the top bar, above the bottom bars; on a folded screen the larger
     * part (when it can hold a dialog at least 300 px wide).
     */
    public func dialogArea() -> Rect {
        let top = insetTop + barH
        let full = Rect(insetLeft, top, width - insetLeft - insetRight, height - top - reservedBottom - 16)
        let r = preferredRegion(full)
        return r.w >= 300 ? r : full
    }

    /** The side of the fold a dialog or toast is centered in: the larger part (the leading one on a tie). */
    public func preferredRegion(_ area: Rect) -> Rect {
        let parts = DisplayLayout.regions(area, divisions)
        if parts.count < 2 { return area }
        let ordered = L10n.rtl ? parts.reversed() : parts
        return ordered.max { $0.w * $0.h < $1.w * $1.h } ?? area
    }

    /** Re-lays out the windows with the current [Touch] sizes (Settings change). */
    public func relayout() { resize(width, height, insetTop, insetBottom, insetLeft, insetRight, keyboardHeight) }

    // ------------------------------------------------------------ menu layer sizes

    private var mmCache: MenuMetrics?
    private var mmKey: [Int64] = [0, 0, 0, 0, 0, 0]

    /**
     * Sizes of the menu layer for the current usable viewport ([MenuMetrics.compute]): recomputed when the
     * size, insets, keyboard, display scale, touch setting or typing layout change (rotation, split screen),
     * so a menu opened after a rotation never has the old sizes.
     */
    public var metrics: MenuMetrics {
        let uw = width - insetLeft - insetRight
        let uh = height - insetTop - insetBottom
        let key: [Int64] = [Int64(uw), Int64(uh), Int64(bitPattern: dpPerPx.bitPattern), Touch.large ? 1 : 0, typingCompact ? 1 : 0,
                            Int64(bitPattern: env.touchTargetDp.bitPattern)]
        if let c = mmCache, key == mmKey { return c }
        mmKey = key
        let c = MenuMetrics.compute(uw, uh, dpPerPx, env.touchTargetDp, Touch.large, typingCompact)
        mmCache = c
        return c
    }

    /** Height of the top bar (0 while typing in landscape, when it is hidden). */
    public var barH: Int { metrics.barH }
    private var chromeH: Int { metrics.chromeH }
    private var chromeBtnW: Int { metrics.chromeBtnW }
    /** Width of the window menu button (glyph and label) in a window's menu row. */
    private func menuBtnW(_ w: Window) -> Int {
        let m = metrics
        return min(max(8, w.w - 16 - 3 * m.chromeBtnW), 8 + 3 * m.charW + surface.measureUi(tr("window.menu"), m.textScale) + m.charW)
    }

    /** Desktop area (below the top bar, above the bottom bar / keyboard). */
    public func desktopRect() -> Rect {
        let top = insetTop + topBarH
        let bottom = height - insetBottom - bottomBarHeight()
        return Rect(insetLeft, top, width - insetLeft - insetRight, max(40, bottom - top))
    }

    /** The TempleOS keyboard when shown, else the key row for text apps. */
    private func bottomBarHeight() -> Int {
        if templeKeyboardShown { return tabletopFold().map { usableBottom - $0.y } ?? keyboard.height() }
        return focusedWantsKeyRow() ? Shell.KEY_ROW : 0
    }

    private func focusedWantsKeyRow() -> Bool { focused?.app.wantsKeyboard == true }

    /**
     * Where floating (landscape, not maximized) windows are placed and kept: the desktop
     * without the soft keyboard, so showing the keyboard does not shrink them for good (V-31).
     */
    private func floatRect() -> Rect {
        let top = insetTop + barH
        // neither keyboard counts (device or TempleOS): only the key row a text app always has
        let bottom = height - insetBottom - (focusedWantsKeyRow() ? Shell.KEY_ROW : 0)
        return aboveTabletopFold(Rect(insetLeft, top, width - insetLeft - insetRight, max(40, bottom - top)))
    }

    /**
     * [r] above a tabletop fold running across it: the upper part shows the windows, the lower part is for
     * input (the TempleOS keyboard, a program's controls), so floating and tiled windows stay above the hinge.
     */
    private func aboveTabletopFold(_ r: Rect) -> Rect {
        guard let d = horizontalDivision(in: r), d.y - r.y >= DisplayLayout.MIN_REGION else { return r }
        return Rect(r.x, r.y, r.w, d.y - r.y)
    }

    /**
     * V-31: in landscape the soft keyboard leaves very little height (about 90 logical px on
     * a phone). While it is up for a text app, that app fills the space with no window frame,
     * the top bar is hidden and STANDARD sizes are used. The key row's keyboard key hides the
     * keyboard and brings everything back; window geometry is not changed.
     * Decided by the height left (a short, wide viewport as MenuMetrics.compact measures it), not by the
     * orientation: an unfolded foldable held wide has room for the full layout while typing.
     */
    public var typingCompact: Bool { shortViewport && (templeKeyboardShown) && focusedWantsKeyRow() }

    /** Wider than tall and under [MenuMetrics.SHORT_DP] high inside the safe area (a phone in landscape). */
    private var shortViewport: Bool { landscape && Double(height - insetTop - insetBottom) * dpPerPx < MenuMetrics.SHORT_DP }

    private var topBarH: Int { typingCompact ? 0 : barH }

    private func borderless(_ w: Window) -> Bool { w === focused && typingCompact }

    /** Keeps [Touch.compact] in step with [typingCompact]; called at every entry point. */
    private func syncCompact() { Touch.compact = typingCompact }

    private func relayout(_ orientationChanged: Bool) {
        let d = desktopRect()
        for (i, win) in windows.enumerated() {
            if !windowed || win.maximized || win.w == 0 || orientationChanged {
                if windowed && !win.maximized { placeNew(win, i) } else { win.x = d.x; win.y = d.y; win.w = d.w; win.h = d.h }
            }
            clampWindow(win)
        }
    }

    private func placeNew(_ win: Window, _ index: Int) {
        let f = floatRect()
        // on a folded screen windows open on alternate sides of the fold, each inside its part
        let parts = foldParts(f)
        if parts.count > 1 {
            let d = parts[index % parts.count]
            let w = min(d.w, max(min(320, d.w), d.w * 5 / 6)) & ~7
            let h = min(d.h, max(min(200, d.h), d.h * 5 / 6)) & ~7
            let off = (index / parts.count % 4) * 16
            win.x = d.x + min(off, d.w - w); win.y = d.y + min(off, d.h - h); win.w = w; win.h = h
            return
        }
        let d = f
        let w = min(d.w, max(320, d.w * 2 / 3)) & ~7
        let h = min(d.h, max(200, d.h * 3 / 4)) & ~7
        let off = (index % 6) * 16
        win.x = d.x + min(off, d.w - w); win.y = d.y + min(off, d.h - h); win.w = w; win.h = h
    }

    /** [r] split by the folds, in reading order (the leading side first). */
    private func foldParts(_ r: Rect) -> [Rect] {
        let parts = DisplayLayout.regions(r, divisions)
        return L10n.rtl && parts.count > 1 && parts[0].y == parts[1].y ? parts.reversed() : parts
    }

    private func clampWindow(_ win: Window) {
        if !windowed || win.maximized { let d = desktopRect(); win.x = d.x; win.y = d.y; win.w = d.w; win.h = d.h; return }
        let d = floatRect()
        win.w = coerceInUI(win.w, min(160, d.w), d.w); win.h = coerceInUI(win.h, min(96, d.h), d.h)
        win.x = coerceInUI(win.x, d.x, d.right - win.w); win.y = coerceInUI(win.y, d.y, d.bottom - win.h)
    }

    @discardableResult
    public func open(_ app: App, maximized: Bool = false) -> Window {
        let win = Window(app)
        win.maximized = maximized
        windows.append(win)
        if windowed && !maximized { placeNew(win, windows.count - 1) } else { clampWindow(win) }
        clampWindow(win)
        focus(win)
        saveRequested = true
        return win
    }

    /** Set when the window list changed; the session is saved on the next tick. */
    private var saveRequested = false

    private func removeWindow(_ win: Window) -> Bool {
        guard let i = windows.firstIndex(where: { $0 === win }) else { return false }
        windows.remove(at: i)
        return true
    }

    public func focus(_ win: Window?) {
        if let win, !windows.contains(where: { $0 === win }) { return }
        if win !== focused {
            releaseInputOwnership()
            if let old = dialog { old.cancel(); if dialog === old { closeDialog() } }
        }
        if let win = win, removeWindow(win) { windows.append(win) }
        focused = win
        menu = nil
        keyboardOverride = 0
        // modifiers and keyboard layers never carry over to another window
        ctrlLatched = false; altLatched = false; keyboard.reset()
        syncKeyboard()
        relayout(false)
        invalidate()
    }

    public func close(_ win: Window, force: Bool = false) {
        if !force && win.app.unsaved {
            showDialog(Dialog.confirmDestructive(tr("dialog.close_unsaved.title", ("title", win.app.title)), tr("dialog.close_unsaved.message"), tr("button.close")) { [unowned self] in self.close(win, force: true) })
            invalidate(); return
        }
        if win === focused { releaseInputOwnership() }
        win.app.close()
        _ = removeWindow(win)
        if focused === win { focus(windows.first { $0.id == win.app.navigationParentId } ?? windows.last) }
        saveSession()
        invalidate()
    }

    public func findWindow(_ kind: String, _ pred: (App) -> Bool = { _ in true }) -> Window? {
        windows.first { $0.app.kind == kind && pred($0.app) }
    }

    public func showToast(_ msg: @autoclosure @escaping () -> String) { toast = L10n.Presentation(msg); toastUntil = env.nowMs() + 2500; invalidate() }

    public func showDialog(_ d: Dialog) {
        releaseInputOwnership()
        if let old = dialog { old.cancel() }
        dialog = d
        syncKeyboard()
        invalidate()
    }

    private func closeDialog() {
        releaseInputOwnership()
        dialog = nil
        syncKeyboard()
    }

    public var dialogOpen: Bool { dialog != nil }
    /** A menu or dialog is open (program frames are then drawn into the surface instead of as overlays). */
    public var popupOpen: Bool { dialog != nil || menu != nil }

    /**
     * True when [app]'s program picture must be drawn into the surface instead of as an
     * overlay: overlays are composited above the whole surface, so they would show through
     * a popup or (landscape) a window stacked above that covers part of the client area.
     */
    public func drawsFrameInSurface(_ app: App) -> Bool {
        if popupOpen { return true }
        if !windowed { return false }
        guard let i = windows.firstIndex(where: { $0.app === app }) else { return false }
        let c = clientRect(windows[i])
        for j in (i + 1)..<windows.count {
            let o = windows[j]
            if o.x < c.right && c.x < o.x + o.w && o.y < c.bottom && c.y < o.y + o.h { return true }
        }
        return false
    }

    /** Opens a menu at ([x], [y]); opened by another menu's item, it is that menu's submenu (back returns). */
    public func showMenu(_ items: [MenuItem], _ x: Int, _ y: Int, _ title: @autoclosure @escaping () -> String? = nil) {
        releaseInputOwnership()
        menu = PopupMenu(items, x, y, title(), menuSource)
        invalidate()
    }

    // ------------------------------------------------------------ frame loop

    /** Called by the platform each display frame. Returns true if the surface changed. */
    @discardableResult
    public func tick() -> Bool {
        let now = env.nowMs()
        syncCompact()
        if templeKeyboardShown && keyboard.tick(now) { invalidate() }
        if !heldHw.isEmpty { repeatHardwareKeys(now) }
        while let f = uiQueue.poll() { f() }
        for w in windows { if w.app.tick(now) { w.app.dirty = true } }
        for w in windows {
            let vis = windowed || w === focused
            if w.shownState != vis { w.shownState = vis; w.app.onVisibility(vis) }
        }
        if toast != nil && now > toastUntil { toast = nil; needsRender = true }
        if windows.contains(where: { $0.app.dirty }) { needsRender = true }
        syncKeyboard()
        if saveRequested { saveRequested = false; saveSession() }
        if !needsRender { return false }
        render()
        return true
    }

    /** Current program frames to draw over the surface (device-resolution scaling). */
    public func overlays() -> [Overlay] {
        if dialog != nil || menu != nil {
            // keep frames visible under the dialog except where covered
        }
        var res: [Overlay] = []
        let visible: [Window] = windowed ? windows : (focused.map { [$0] } ?? [])
        for w in visible {
            if drawsFrameInSurface(w.app) { continue } // drawn into the surface at its z-position
            let client = clientRect(w)
            for o in w.app.overlays(client) { res.append(o) }
        }
        // overlays are drawn on top of the surface, so hide them when a popup covers them
        if dialog != nil || menu != nil { return res.filter { o in !coveredByPopup(o.rect) } }
        return res
    }

    private func coveredByPopup(_ r: Rect) -> Bool { true }

    // ------------------------------------------------------------ rendering

    public func clientRect(_ w: Window) -> Rect {
        if borderless(w) { return desktopRect() }
        // client area inside the TempleOS border: 8px border on each side
        return Rect(w.x + 8, w.y + 8 + chromeH, max(0, w.w - 16), max(0, w.h - 16 - chromeH))
    }

    private func render() {
        syncCompact()
        a11yBase.removeAll(); a11yKeys.removeAll(); a11yModal.removeAll(); a11yTarget = 0
        a11yVersion += 1
        let s = surface
        s.setClip(nil)
        s.beginFrame()
        s.fillRect(0, 0, width, height, settings.desktopColor)
        let d = desktopRect()
        if windows.isEmpty { drawEmptyDesktop(s, d) }
        if windowed && !typingCompact {
            for w in windows { drawWindow(s, w) }
        } else {
            if let f = focused { drawWindow(s, f) }
        }
        if !typingCompact { s.layer(Rect(0, 0, width, insetTop + barH)); drawTopBar(s) }
        a11yTarget = 1
        if templeKeyboardShown {
            let r = keyboardRect()
            // tabletop: the keyboard's part starts at the fold (the band on the hinge is keyboard background)
            let top = min(r.y, usableBottom - bottomBarHeight())
            s.layer(Rect(0, top, width, height - top))
            s.fillRect(0, top, width, height - top, Shell.BAR_BG)
            keyboard.draw(s, r)
        } else if focusedWantsKeyRow() { s.layer(keyRowRect()); drawKeyRow(s) }
        a11yTarget = 2
        menu?.draw(s, self)
        dialog?.draw(s, self)
        a11yTarget = 0
        systemChrome = resolveSystemChrome()
        drawSystemGutters(s, systemChrome)
        if let t = toast { drawToast(s, t.value) }
        needsRender = false
        windows.forEach { $0.app.dirty = false }
        s.touch()
    }

    // MARK: system chrome

    /**
     * What the system navigation region, home indicator and side gutters show, resolved by the last
     * render from what it drew (SystemChrome). The platform adapters read it after each frame.
     */
    public private(set) var systemChrome = SystemChrome(bottom: Palette.DKGRAY, side: Palette.DKGRAY, owner: .desktop)

    /** The windows, bottom bars and popups that can own the bottom edge, as the last render drew them. */
    private func resolveSystemChrome() -> SystemChrome {
        let shown = windowed && !typingCompact ? windows : (focused.map { [$0] } ?? [])
        let content = shown.map { w -> SystemChrome.Layer in
            let app = w.app.systemEdgeColor
            let r = borderless(w) ? clientRect(w) : Rect(w.x, w.y, w.w, w.h)
            return SystemChrome.Layer(r, app ?? Shell.WINDOW_BG, app != nil ? .appOverride : .window)
        }
        var bars: [SystemChrome.Layer] = []
        if templeKeyboardShown { bars.append(SystemChrome.Layer(keyboardRect(), Shell.BAR_BG, .keyboard)) }
        else if focusedWantsKeyRow() { bars.append(SystemChrome.Layer(keyRowRect(), Shell.BAR_BG, .keyRow)) }
        if let m = menu { bars.append(SystemChrome.Layer(m.bounds, PopupMenu.BG, .popup)) }
        if let d = dialog { bars.append(SystemChrome.Layer(d.bounds, Dialog.BG, .popup)) }
        let d = desktopRect()
        return SystemChrome.resolve(
            desktop: settings.desktopColor, content: content, contentBottom: d.bottom, bars: bars, usableBottom: height - insetBottom,
            left: insetLeft, right: width - insetRight,
            deviceKeyboard: false,
            defersEdgeGestures: focused?.app.defersEdgeGestures == true)
    }

    /**
     * Paints the regions the system draws over (home indicator / navigation bar below, side gutters
     * in landscape) in the colors of the surface that owns the edge. Beside a bottom bar (TempleOS
     * keyboard, key row) the side gutters take its color. Each gutter is a layer: localized text
     * never shows through.
     */
    private func drawSystemGutters(_ s: Surface, _ c: SystemChrome) {
        let top = insetTop + topBarH
        let usableBottom = height - insetBottom
        let barTop = max(top, usableBottom - bottomBarHeight())
        func gutter(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: Int) {
            if w <= 0 || h <= 0 { return }
            s.layer(Rect(x, y, w, h)); s.fillRect(x, y, w, h, color)
        }
        gutter(0, top, insetLeft, barTop - top, c.side)
        gutter(width - insetRight, top, insetRight, barTop - top, c.side)
        gutter(0, barTop, insetLeft, usableBottom - barTop, c.bottom)
        gutter(width - insetRight, barTop, insetRight, usableBottom - barTop, c.bottom)
        gutter(0, usableBottom, width, height - usableBottom, c.bottom)
    }

    private func drawEmptyDesktop(_ s: Surface, _ d: Rect) {
        let lines = Brand.introLines
        var y = d.y + d.h / 3
        for (i, l) in lines.enumerated() {
            let parts = s.wrapUi(l, d.w - 16)
            let startY = y
            for part in parts {
                s.uiText(d.x + (d.w - s.measureUi(part)) / 2, y, part, i == 0 ? Palette.YELLOW : Palette.LTGRAY)
                y += 16
            }
            a11yText(Rect(d.x, startY, d.w, y - startY), l)
        }
    }

    private func drawTopBar(_ s: Surface) {
        let y = insetTop
        let m = metrics, ts = m.textScale, bh = m.barH
        let ty = y + (bh - m.glyphH) / 2
        s.fillRect(0, 0, width, y + bh, Palette.BLACK)
        // the bar's own span: inside the screen's rounded top corners when no status bar sits above it, and
        // clear of an occlusion (camera, status-bar block) reaching into the row
        let (bl, br) = topBarSpan()
        // MENU chip (TempleOS draws a blinking MENU button top-left)
        let menuLabel = windows.isEmpty ? "MENU" : tr("topbar.menu")
        let usable = br - bl
        let chipW = min(usable / 3, max(6 * m.charW, s.measureUi(menuLabel, ts) + 2 * m.padX))
        menuChipW = chipW
        s.fillRect(bl, y, chipW, bh, Palette.BLUE)
        s.uiText(bl + m.padX, ty, menuLabel, Palette.YELLOW, chipW - 2 * m.padX, scale: ts)
        a11yButton(Rect(bl, y, chipW + 4, bh), menuLabel)
        // window deck / task list: the focused window's tab always shows (shortened if it must), then the
        // others while they fit, then a "+N" chip listing the rest; no tab lies on a book fold
        let fold = verticalDivision(in: Rect(bl, y, usable, bh))
        var x = bl + chipW + m.charW / 2
        let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let clock = String(format: "%02ld:%02ld", comps.hour ?? 0, comps.minute ?? 0)
        tabRects.removeAll()
        overflowChip = nil
        let ordered: [Window] = (focused.map { [$0] } ?? []) + windows.filter { $0 !== focused }
        let overW = 3 * m.charW + m.padX / 2
        // on a narrow screen the clock gives way to the focused window's tab (at least 5 characters)
        let withClock = br - (clock.scLen * m.charW + m.padX)
        let showClock = ordered.isEmpty || withClock - x - (ordered.count > 1 ? overW + 4 : 0) >= 5 * m.charW + m.padX
        let limit = showClock ? withClock : br - 4
        for (i, w) in ordered.enumerated() {
            let t = w.app.title
            var tw = min(s.measureUi(t, ts), (windowed ? 14 : 10) * m.charW) + m.padX
            if let f = fold, x < f.right, x + tw > f.x, f.right + 3 * m.charW < limit { x = f.right }
            let needChip = i < ordered.count - 1
            let room = limit - x - (needChip ? overW + 4 : 0)
            if tw > room {
                if i == 0 && room >= 3 * m.charW { tw = room }
                else {
                    let chip = Rect(x, y + 2, min(overW, max(m.charW * 2, limit - x)), bh - 4)
                    s.fill(chip, Palette.BROWN)
                    s.text(chip.x + m.padX / 4, ty, "+\(ordered.count - i)".take(3), Palette.YELLOW, scale: ts)
                    overflowChip = chip
                    a11yButton(Rect(chip.x, y, chip.w, bh), tr("a11y.more_windows", ("count", ordered.count - i)))
                    break
                }
            }
            let active = w === focused
            s.fillRect(x, y + 2, tw, bh - 4, active ? Palette.WHITE : Palette.DKGRAY)
            s.uiText(x + m.padX / 2, ty, t, active ? Palette.BLUE : Palette.WHITE, tw - m.padX, scale: ts)
            tabRects.append((Rect(x, y, tw, bh), w))
            a11yButton(Rect(x, y, tw, bh), tr("a11y.window", ("title", w.app.title)), selected: active)
            x += tw + 4
        }
        if showClock {
            let cx = br - clock.scLen * m.charW - m.padX / 2
            s.text(cx, ty, clock, Palette.LTGREEN, scale: ts)
            a11yText(Rect(cx, y, clock.scLen * m.charW, bh), tr("a11y.time", ("time", clock)))
        }
    }

    private var tabRects: [(Rect, Window)] = []
    private var menuChipW = 48
    /** Left end of the MENU chip (the top bar's span), also where the start menu opens. */
    private var menuChipX: Int { topBarSpan().0 }

    /**
     * Left and right ends of the top bar's content. Below a status bar the safe area's; at the very top of
     * the screen (a status-bar column at the side, as on a foldable's displays) the corner-adapted insets the
     * platform reported, so the MENU chip and the clock stay out of the rounded corners; and never under an
     * occlusion reaching into the row.
     */
    private func topBarSpan() -> (Int, Int) {
        let l = max(insetLeft, barInsetLeft), r = width - max(insetRight, barInsetRight)
        return DisplayLayout.rowSpan(insetTop, insetTop + barH, l, max(l + 16, r), occlusions)
    }
    private var overflowChip: Rect? = nil

    /** Lists every open window (used when the top bar cannot show them all). */
    public func showWindowList() {
        showMenu(windows.map { w in MenuItem(w.app.title, checked: w === focused) { [unowned self] in self.focus(w) } },
                 overflowChip?.x ?? (width / 3), insetTop + barH, tr("menu.windows.title"))
    }

    private func drawWindow(_ s: Surface, _ w: Window) {
        // each window is a stacking layer: it hides the native text of the windows below
        s.layer(borderless(w) ? clientRect(w) : Rect(w.x, w.y, w.w, w.h))
        if borderless(w) {
            let client = clientRect(w)
            s.fillRect(client.x, client.y, client.w, client.h, Shell.WINDOW_BG)
            w.app.a11yItems.removeAll()
            s.withClip(client) { w.app.draw(s, client) }
            w.app.accessibility(client)
            return
        }
        let r = Rect(w.x, w.y, w.w, w.h)
        let active = w === focused
        let bg = Shell.WINDOW_BG
        s.fillRect(r.x, r.y, r.w, r.h, bg)
        s.border(Rect(r.x, r.y, r.w & ~7, r.h & ~7), active ? Palette.BLUE : Palette.LTBLUE, bg, active, " \(w.app.title) ")
        // chrome row: [≡] menu   ...   [-] max [X]  (MenuMetrics: text at the menu scale, touch-sized row)
        let m = metrics, ts = m.textScale
        let ch = m.chromeH, cb = m.chromeBtnW
        let cy = r.y + 8
        let gy = cy + (ch - m.glyphH) / 2
        s.fillRect(r.x + 8, cy, r.w - 16, ch, active ? Palette.BLUE : Palette.LTBLUE)
        let mw = menuBtnW(w)
        s.text(r.x + 8 + m.charW / 2, gy, "\u{F0}", Palette.WHITE, scale: ts) // menu glyph
        s.uiText(r.x + 8 + 2 * m.charW, gy, tr("window.menu"), Palette.YELLOW, max(0, mw - 8 - 2 * m.charW), scale: ts)
        let bx = r.right - 8 - 3 * cb
        if windowed { s.text(bx + (cb - m.charW) / 2, gy, w.maximized ? "\u{FE}" : "\u{1E}", Palette.WHITE, scale: ts) }
        s.text(bx + 2 * cb + (cb - m.charW) / 2, gy, "X", Palette.LTRED, scale: ts)
        if active {
            a11yButton(Rect(r.x + 8, cy, mw - 8, ch), tr("a11y.window_menu", ("title", w.app.title)))
            if windowed { a11yButton(Rect(bx, cy, cb, ch), tr(w.maximized ? "a11y.restore_window" : "a11y.maximize_window")) }
            a11yButton(Rect(bx + 2 * cb, cy, cb, ch), tr("a11y.close_window", ("title", w.app.title)))
        }
        let client = clientRect(w)
        w.app.a11yItems.removeAll()
        s.withClip(client) { w.app.draw(s, client) }
        if active { w.app.accessibility(client) }
    }

    /**
     * The key row under text apps while no on-screen TempleOS keyboard is shown. The last key
     * shows the keyboard again; with the device keyboard, TOS switches back to the TempleOS one.
     * At most 10 keys, so 4-letter labels fit a 360 px screen (HOME/END: the keyboard's FN layer).
     */
    private var keyRow: [String] {
        ["ESC", "TAB", "CTRL", "ALT", "\u{1B}", "\u{18}", "\u{19}", "\u{1A}", "\u{FB}"]
    }

    private func keyRowA11y(_ k: String) -> String {
        switch k {
        case "ESC": return tr("key.escape"); case "TAB": return tr("key.tab"); case "CTRL": return tr("key.control"); case "ALT": return tr("key.alt")
        case "\u{1B}": return tr("key.left"); case "\u{18}": return tr("key.up"); case "\u{19}": return tr("key.down")
        case "\u{1A}": return tr("key.right"); case "HOME": return tr("key.home"); case "END": return tr("key.end")
        case "TOS": return tr("key.use_templeos_keyboard"); case "\u{FB}": return tr("key.show_hide_keyboard")
        default: return k
        }
    }

    /** Where the TempleOS keyboard is drawn: above the home indicator / navigation bar. */
    public func keyboardRect() -> Rect {
        let h = keyboard.height()
        let bottom = height - insetBottom
        return Rect(insetLeft, bottom - h, width - insetLeft - insetRight, h)
    }

    public func toggleCtrl() { setLatches(!ctrlLatched, altLatched) }
    public func toggleAlt() { setLatches(ctrlLatched, !altLatched) }

    /** Sets the CTRL/ALT latches, telling a running program the key went down or up. */
    private func setLatches(_ ctrl: Bool, _ alt: Bool) {
        if ctrl != ctrlLatched { ctrlLatched = ctrl; latchEvent(Keys.SC_CTRL, ctrl) }
        if alt != altLatched { altLatched = alt; latchEvent(Keys.SC_ALT, alt) }
        invalidate()
    }

    /** The on-screen SHIFT latch (TempleKeyboard): a running program sees SHIFT down while it is on. */
    public func shiftLatch(_ on: Bool) { latchEvent(Keys.SC_SHIFT, on) }

    /** Pointer ids pressing TempleOS keyboard keys (several fingers can type at once). */
    private var keyboardPointers = Set<Int>()

    private func keyRowRect() -> Rect {
        let bottom = height - insetBottom
        return Rect(insetLeft, bottom - Shell.KEY_ROW, width - insetLeft - insetRight, Shell.KEY_ROW)
    }

    public private(set) var ctrlLatched = false
    public private(set) var altLatched = false

    private func drawKeyRow(_ s: Surface) {
        let r = keyRowRect()
        s.fillRect(r.x, r.y, r.w, r.h, Shell.BAR_BG)
        let keys = keyRow
        for (i, (x0, x1)) in keyRowColumns(r).enumerated() {
            let k = keys[i]
            let on = (k == "CTRL" && ctrlLatched) || (k == "ALT" && altLatched)
            let kr = Rect(x0, r.y, x1 - x0, r.h)
            s.templeButton(kr, k, on ? ButtonFace.SELECTED : ButtonFace.NORMAL)
            a11yButton(kr, keyRowA11y(k), selected: on)
        }
    }

    private func drawToast(_ s: Surface, _ msg: String) {
        let m = metrics, ts = m.textScale
        // localized: the TempleOS font when it has every character, else the platform's (Surface.uiText); it was
        // drawn byte by byte in the TempleOS font, which garbled every non-ASCII message
        // centered under the desktop, or on a folded screen under one of its parts
        let area = preferredRegion(desktopRect())
        let w = min(area.w - 16, s.measureUi(msg, ts) + 2 * m.padX)
        let lines = s.wrapUi(msg, max(8, w - 2 * m.padX), ts)
        let th = min(max(16, area.h - 16), lines.count * m.lineH + 12)
        let x = area.x + (area.w - w) / 2
        let y = max(area.y + 4, area.bottom - th - 12)
        s.layer(Rect(x, y, w, th))
        s.fillRect(x, y, w, th, Palette.BLACK)
        s.frame(Rect(x, y, w, th), Palette.YELLOW)
        a11yText(Rect(x, y, w, th), msg)
        s.withClip(Rect(x + 1, y + 1, w - 2, th - 2)) {
            for (i, line) in lines.enumerated() {
                _ = s.uiText(x + m.padX, y + 6 + i * m.lineH, line, Palette.YELLOW,
                             max(0, w - 2 * m.padX), alignEnd: L10n.rtl, scale: ts)
            }
        }
    }

    // ------------------------------------------------------------ input

    private var downX = 0, downY = 0
    private var downTime: Int64 = 0
    private var lastX = 0, lastY = 0
    private var gesture = 0 // 0 none, 1 pending tap, 2 dragging/scrolling, 3 window move, 4 window resize, 5 raw app, 6 long-pressed
    private var gestureWin: Window? = nil
    private var primaryId = 0
    private var extraPointers = Set<Int>()
    private weak var popupPointerOwner: AnyObject?
    private var popupPointerId: Int?

    // A release belongs to the popup in which that pointer went down. A key or
    // program can open a popup during DOWN; its eventual UP must not choose a row.
    private func ownsPopupPointer(_ e: PointerEvent, _ owner: AnyObject) -> Bool {
        if e.action == Ptr.DOWN {
            guard popupPointerId == nil || popupPointerOwner !== owner else { return false }
            popupPointerOwner = owner; popupPointerId = e.id
            return true
        }
        guard popupPointerOwner === owner, popupPointerId == e.id else { return false }
        if e.action == Ptr.UP || e.action == Ptr.CANCEL { popupPointerOwner = nil; popupPointerId = nil }
        return true
    }

    public func pointer(_ e: PointerEvent) {
        let now = e.timeMs != 0 ? e.timeMs : env.nowMs()
        syncCompact()
        // the TempleOS keyboard takes its touches first (also while a dialog asks for text)
        if templeKeyboardShown && (keyboardPointers.contains(e.id) || (e.action == Ptr.DOWN && menu == nil && keyboardRect().contains(e.x, e.y))) {
            if e.action == Ptr.DOWN { keyboardPointers.insert(e.id) }
            if e.action == Ptr.UP || e.action == Ptr.CANCEL { keyboardPointers.remove(e.id) }
            keyboard.pointer(e, env.nowMs())
            return
        }
        if dialog != nil || menu != nil { endGestureUnderPopup(e) }
        if let d = dialog {
            guard ownsPopupPointer(e, d) else { return }
            if d.pointer(e, self) && dialog === d { closeDialog() }
            invalidate(); return
        }
        if let m = menu { if ownsPopupPointer(e, m) { menuPointer(m, e) }; return }
        // Extra fingers while a gesture is active go straight to the focused app
        // (e.g. holding two on-screen game buttons at once).
        if extraPointers.contains(e.id) || (gesture != 0 && e.id != primaryId && e.action == Ptr.DOWN) {
            let w = focused
            if e.action == Ptr.DOWN { extraPointers.insert(e.id) }
            if e.action == Ptr.UP || e.action == Ptr.CANCEL { extraPointers.remove(e.id) }
            if let w = w { _ = w.app.pointer(e, clientRect(w)) }
            return
        }
        if e.id != primaryId && e.action != Ptr.DOWN { return }
        switch e.action {
        case Ptr.DOWN:
            primaryId = e.id
            downX = e.x; downY = e.y; lastX = e.x; lastY = e.y; downTime = now
            gesture = 1; gestureWin = nil
            if e.y < insetTop + topBarH { return }
            if focusedWantsKeyRow() && keyRowRect().contains(e.x, e.y) { return }
            let win = windowAt(e.x, e.y)
            gestureWin = win
            if let win = win, win !== focused { focus(win) }
            if let win = win {
                let client = clientRect(win)
                if windowed && !win.maximized && !borderless(win) && e.y < win.y + 8 + chromeH && e.x < win.right() - 8 - 3 * chromeBtnW && e.x > win.x + menuBtnW(win) { gesture = 3; return }
                if windowed && !win.maximized && !borderless(win) && e.x > win.right() - 12 && e.y > win.bottom() - 12 { gesture = 4; return }
                if client.contains(e.x, e.y) && win.app.pointer(e, client) { gesture = 5; return }
            }
        case Ptr.MOVE:
            let win = gestureWin
            switch gesture {
            case 5: if let it = win { _ = it.app.pointer(e, clientRect(it)) }
            case 3: if let it = win { it.x += e.x - lastX; it.y += e.y - lastY; clampWindow(it); invalidate() }
            case 4: if let it = win { it.w += e.x - lastX; it.h += e.y - lastY; clampWindow(it); it.app.dirty = true; invalidate() }
            case 1, 2:
                if gesture == 1 && (abs(e.x - downX) > 6 || abs(e.y - downY) > 6) { gesture = 2 }
                if gesture == 2, let win = win { win.app.scroll(e.x - lastX, e.y - lastY, clientRect(win)) }
            default: break
            }
            lastX = e.x; lastY = e.y
        case Ptr.UP, Ptr.CANCEL:
            let win = gestureWin
            if gesture == 5 { if let it = win { _ = it.app.pointer(e, clientRect(it)) } }
            else if gesture == 1 && e.action == Ptr.UP {
                if now - downTime > Shell.LONG_PRESS_MS, let win = win, clientRect(win).contains(e.x, e.y) {
                    win.app.longPress(e.x, e.y, clientRect(win))
                } else { click(e.x, e.y, win) }
            }
            if gesture == 3 || gesture == 4 { saveSession() }
            gesture = 0; gestureWin = nil
        default: break
        }
    }

    /**
     * A popup opened during a gesture consumes the rest of it: the gesture still
     * has to end here (touch ids differ per touch on iOS, so a gesture left open
     * would turn every later touch into an "extra finger"), and an app holding
     * the pointer gets CANCEL so held controls are released.
     */
    private func endGestureUnderPopup(_ e: PointerEvent) {
        if e.action != Ptr.UP && e.action != Ptr.CANCEL { return }
        let cancel = PointerEvent(Ptr.CANCEL, e.x, e.y, id: e.id, timeMs: e.timeMs)
        if extraPointers.remove(e.id) != nil, let f = focused { _ = f.app.pointer(cancel, clientRect(f)) }
        if e.id == primaryId && gesture != 0 {
            if gesture == 5, let w = gestureWin { _ = w.app.pointer(cancel, clientRect(w)) }
            gesture = 0; gestureWin = nil
        }
    }

    private func windowAt(_ x: Int, _ y: Int) -> Window? {
        if typingCompact {
            guard let f = focused, desktopRect().contains(x, y) else { return nil }
            return f
        }
        if !windowed {
            guard let f = focused, Rect(f.x, f.y, f.w, f.h).contains(x, y) else { return nil }
            return f
        }
        return windows.last { Rect($0.x, $0.y, $0.w, $0.h).contains(x, y) }
    }

    private func click(_ x: Int, _ y: Int, _ win: Window?) {
        if y < insetTop + topBarH {
            if x < menuChipX + menuChipW + 4 { showStartMenu(); return }
            if let t = tabRects.first(where: { $0.0.contains(x, y) }) { focus(t.1); return }
            if let c = overflowChip { if x >= c.x && x < c.right { showWindowList() } }
            return
        }
        if focusedWantsKeyRow() && keyRowRect().contains(x, y) { keyRowTap(x); return }
        guard let win = win else { return }
        let cy = win.y + 8
        if !borderless(win) && y >= cy && y < cy + chromeH + 8 && y >= win.y {
            let bx = win.right() - 8 - 3 * chromeBtnW
            if x < win.x + menuBtnW(win) { showWindowMenu(win, win.x + 8, cy + chromeH) }
            else if x >= bx + 2 * chromeBtnW { close(win) }
            else if x >= bx && windowed { win.maximized = !win.maximized; relayout(false); clampWindow(win); win.app.dirty = true; invalidate() }
            return
        }
        let client = clientRect(win)
        if client.contains(x, y) { win.app.tap(x, y, client) }
    }

    /** The key row's columns: equal keys, around occlusions and a book fold (as drawn). */
    private func keyRowColumns(_ r: Rect) -> [(Int, Int)] { keyColumns(Array(repeating: 1, count: keyRow.count), r) }

    private func keyRowTap(_ x: Int) {
        let r = keyRowRect()
        let keys = keyRow
        let cols = keyRowColumns(r)
        // the key under the finger, else the nearest one (a tap on the hinge or beside an occlusion)
        let i = cols.firstIndex { x >= $0.0 && x < $0.1 } ?? cols.indices.min { abs((cols[$0].0 + cols[$0].1) / 2 - x) < abs((cols[$1].0 + cols[$1].1) / 2 - x) } ?? 0
        switch keys[i] {
        case "CTRL": toggleCtrl(); return
        case "ALT": toggleAlt(); return
        case "TOS": setKeyboardMode(Settings.KEYBOARD_TEMPLEOS); return
        case "\u{FB}":
            let hide = templeKeyboardShown
            keyboardOverride = hide ? -1 : 1; syncKeyboard(hide ? .userHide : .userShow); return
        default: break
        }
        let pair: (Int, Int64)
        switch keys[i] {
        case "ESC": pair = Keys.special(Keys.SC_ESC)
        case "TAB": pair = Keys.special(Keys.SC_TAB)
        case "\u{1B}": pair = Keys.special(Keys.SC_CURSOR_LEFT)
        case "\u{1A}": pair = Keys.special(Keys.SC_CURSOR_RIGHT)
        case "\u{18}": pair = Keys.special(Keys.SC_CURSOR_UP)
        case "\u{19}": pair = Keys.special(Keys.SC_CURSOR_DOWN)
        case "HOME": pair = Keys.special(Keys.SC_HOME)
        case "END": pair = Keys.special(Keys.SC_END)
        default: return
        }
        let (ch, sc) = pair
        key(ch, sc, true); key(ch, sc | Keys.SCF_KEY_UP, false)
    }

    /** Key input from hardware keyboards, the key row or the soft keyboard. */
    public func key(_ ch0: Int, _ sc0: Int64, _ down: Bool) {
        guard inputActive, (0...255).contains(ch0) else { return }
        let (ch, sc) = resolvedKey(ch0, sc0)
        // a latch applies to one key: it is lifted after that key's own release
        if !down && (ctrlLatched || altLatched) { routeKey(ch, sc, down); setLatches(false, false); return }
        routeKey(ch, sc, down)
    }

    /** Snapshot modifiers at a touch key's press so repeats retain the same event. */
    public func resolvedKey(_ ch0: Int, _ sc0: Int64) -> (Int, Int64) {
        var ch = ch0, sc = sc0
        if ctrlLatched { sc |= Keys.SCF_CTRL; if (97...122).contains(ch) || (65...90).contains(ch) { ch &= 0x1F } }
        if altLatched { sc |= Keys.SCF_ALT }
        return (ch, sc)
    }

    private func routeKey(_ ch: Int, _ sc: Int64, _ down: Bool) {
        if let d = dialog { if down && d.key(ch, sc, self) && dialog === d { closeDialog() }; invalidate(); return }
        if down && sc & Keys.SCF_CTRL != 0 && sc & 127 == 0x32 { showStartMenu(); return }
        if let m = menu {
            // an open menu takes every key (none reaches the program under it); releases are dropped
            if !down { return }
            if ch == Keys.CH_ESC || ch == Keys.CH_SHIFT_ESC { menu = nil; invalidate(); return }
            let r = m.key(ch, sc)
            if r == PopupMenu.KEY_BACK { menu = m.parent ?? m }
            else if r >= 0 { runMenuItem(m, r) }
            invalidate(); return
        }
        _ = focused?.app.key(ch, sc, down)
    }

    private var menuDownY = 0
    private var menuDragged = false
    /** The menu whose item is running (a menu opened by that item is its submenu). */
    private var menuSource: PopupMenu?

    /**
     * Touch on an open menu: a tap runs an item, scrolls (arrow rows) or goes back (a submenu's title row);
     * a vertical drag scrolls by rows and runs nothing; a tap outside closes the menu and goes nowhere else
     * (dismissing a menu never reaches the program or window under it).
     */
    private func menuPointer(_ m: PopupMenu, _ e: PointerEvent) {
        switch e.action {
        case Ptr.DOWN: menuDownY = e.y; menuDragged = false
        case Ptr.MOVE:
            let dy = e.y - menuDownY
            if abs(dy) >= m.rowStep { if m.scrollBy(-dy / m.rowStep) { invalidate() }; menuDownY = e.y; menuDragged = true }
        case Ptr.UP:
            if menuDragged { menuDragged = false; return }
            let h = m.hit(e.x, e.y)
            switch h {
            case PopupMenu.HIT_OUTSIDE: menu = nil
            case PopupMenu.HIT_UP: m.scrollBy(-m.page)
            case PopupMenu.HIT_DOWN: m.scrollBy(m.page)
            case PopupMenu.HIT_BACK: menu = m.parent
            case PopupMenu.HIT_NONE: break
            default: runMenuItem(m, h)
            }
            invalidate()
        case Ptr.CANCEL: menuDragged = false
        default: break
        }
    }

    /** Closes [m] and runs its item [i]; a menu the item opens becomes [m]'s submenu. */
    private func runMenuItem(_ m: PopupMenu, _ i: Int) {
        guard let item = m.items.getOrNil(i), item.enabled else { return }
        menu = nil
        menuSource = m
        defer { menuSource = nil }
        item.action()
    }

    /** The open menu, for tests and accessibility (nil when none). */
    public var openMenu: PopupMenu? { menu }

    /** Byte text produced inside TempleOS. External Unicode enters through insertUnicodeText. */
    public func text(_ s: String) {
        guard inputActive, InputCharacterPolicy.isByteText(s) else { rejectInput(); return }
        if dialog != nil || menu != nil || ctrlLatched || altLatched {
            for c in s.unicodeScalars {
                let (ch, sc) = Keys.forChar(Int(c.value))
                key(ch, sc, true); key(ch, sc | Keys.SCF_KEY_UP, false)
            }
        } else { focused?.app.text(s) }
    }

    /** Lossless, whole-operation conversion. Never log the rejected text. */
    @discardableResult public func insertUnicodeText(_ s: String, lease: InputLease? = nil) -> Bool {
        guard inputActive, lease == nil || lease == inputLease else { return false }
        guard let bytes = InputCharacterPolicy.encode(s, singleLine: dialog?.wantsKeyboard == true) else {
            rejectInput(); return false
        }
        // Paste is data, even when invoked synchronously by a sticky Ctrl-V key-down.
        setLatches(false, false)
        text(bytes); return true
    }

    public func pasteClipboard() { if let s = env.clipboardGet() { _ = insertUnicodeText(s) } }
    public private(set) var rejectedInputCount = 0
    public func rejectInput() {
        rejectedInputCount += 1
        showToast(tr("input.unsupported"))
    }

    public struct InputLease: Equatable {
        public let generation: Int
        public let target: String
    }
    public private(set) var inputGeneration = 0
    private var inputActive = true
    public var inputTarget: String {
        if !inputActive { return "inactive" }
        if dialog != nil { return "dialog" }
        if menu != nil { return "menu" }
        return focused.map { "\($0.app.kind):\($0.id)" } ?? "none"
    }
    public var inputLease: InputLease { InputLease(generation: inputGeneration, target: inputTarget) }

    /** Release to the old owner BEFORE replacing it; late physical releases are ignored. */
    public func releaseInputOwnership() {
        releaseHardwareKeys(); keyboard.reset(); setLatches(false, false)
        focused?.app.releaseInput()
        gesture = 0; gestureWin = nil; extraPointers.removeAll()
        keyboardPointers.removeAll()
        popupPointerOwner = nil; popupPointerId = nil
        inputGeneration += 1
    }

    /** Original TempleOS extended byte repertoire; an application-owned picker, never an IME. */
    public func showCharacterPicker() {
        let lease = inputLease
        let owner = focused
        let parent = dialog
        let options = (128...255).map { (String(format: "%02X  ", $0) + Cp437.decode(String(Unicode.Scalar($0)!)), Int64($0)) }
        let picker = Dialog.choose("CP437", "", options, []) { [weak self, weak owner] value in
            self?.post { [weak self, weak owner] in
                guard let self, self.focused === owner, self.dialog == nil,
                      self.inputGeneration == lease.generation + 2 else { parent?.cancel(); return }
                self.dialog = parent; self.syncKeyboard()
                if (128...255).contains(value) { self.text(String(Unicode.Scalar(Int(value))!)) }
                self.invalidate()
            }
        }
        releaseInputOwnership()
        dialog = picker; syncKeyboard(); invalidate()
    }

    /** Android/iOS "back" gesture: close menus/dialogs, else unfocus. Returns false if nothing to do. */
    @discardableResult
    public func back() -> Bool {
        if let d = dialog { d.cancel(); if dialog === d { closeDialog() }; invalidate(); return true }
        if let m = menu { menu = m.parent; invalidate(); return true } // a submenu goes back, a menu closes
        if templeKeyboardShown { hideKeyboard(.back); return true }
        if focused?.app.navigateBack() == true { return true }
        return false
    }

    // ------------------------------------------------------------ menus

    public func showStartMenu() {
        var items: [MenuItem] = []
        items.append(MenuItem(tr("menu.start.terminal")) { [unowned self] in Launch.terminal(self) })
        items.append(MenuItem(tr("menu.start.editor")) { [unowned self] in Launch.editor(self, nil) })
        items.append(MenuItem(tr("menu.start.files")) { [unowned self] in Launch.files(self, "C:/Home") })
        items.append(MenuItem(tr("menu.start.games")) { [unowned self] in Launch.games(self) })
        for id in ["applications","programs","demos"] { if let g=catalog.group(id) {items.append(MenuItem(id == "demos" ? tr("menu.start.demos") : g.localizedTitle) { [unowned self] in Launch.programs(self,id) })} }
        items.append(MenuItem(tr("menu.start.examples")) { [unowned self] in self.showMenu(self.catalog.menuItems(self, "example"), self.menuChipX + 4, self.insetTop + self.barH, tr("menu.examples.title")) })
        items.append(MenuItem(tr("menu.start.documentation")) { [unowned self] in Launch.doc(self, "C:/Doc/HelpIndex.DD") })
        items.append(MenuItem(tr("menu.start.god_words")) { [unowned self] in Launch.god(self) })
        items.append(MenuItem(tr("menu.start.paint")) { [unowned self] in Launch.paint(self) })
        items.append(MenuItem(tr("menu.start.settings")) { [unowned self] in Launch.settings(self) })
        items.append(MenuItem(tr("menu.start.language")) { [unowned self] in Launch.language(self) })
        items.append(MenuItem(tr("menu.start.about")) { [unowned self] in Launch.about(self) })
        showMenu(items, menuChipX + 4, insetTop + barH, "TempleOS")
    }

    private func showWindowMenu(_ win: Window, _ x: Int, _ y: Int) {
        var items = win.app.menu()
        if windowed {
            items.append(MenuItem(tr(win.maximized ? "menu.window.restore" : "menu.window.maximize")) { [unowned self] in
                win.maximized = !win.maximized; self.relayout(false); self.clampWindow(win); win.app.dirty = true; self.invalidate()
            })
        }
        if windowed { items.append(MenuItem(tr("menu.window.tile")) { [unowned self] in self.tile() }) }
        items.append(MenuItem(tr("menu.window.close")) { [unowned self] in self.close(win) })
        showMenu(items, x, y, win.app.title)
    }

    public func tile() {
        let n = windows.count
        if n == 0 { return }
        // on a folded screen each side of the fold is tiled on its own: no window lies on the hinge
        let parts = foldParts(aboveTabletopFold(desktopRect()))
        for (pi, d) in parts.enumerated() {
            let mine = windows.enumerated().filter { $0.offset % parts.count == pi }.map { $0.element }
            let m = mine.count
            if m == 0 { continue }
            let cols = parts.count > 1 ? (m <= 2 && d.w > d.h ? m : 1) : (m <= 2 ? m : 2)
            let rows = (m + cols - 1) / cols
            for (i, w) in mine.enumerated() {
                w.maximized = false
                w.w = (d.w / cols) & ~7; w.h = (d.h / rows) & ~7
                w.x = d.x + (i % cols) * w.w; w.y = d.y + (i / cols) * w.h
                w.app.dirty = true
            }
        }
        invalidate()
    }

    // ------------------------------------------------------------ session

    public func saveSession() {
        var sb = ""
        sb += "v1\n"
        sb += "settings\t" + settings.encode() + "\n"
        for w in windows {
            var st = w.app.saveState()
            st["_windowId"]=String(w.id)
            if let parent=w.app.navigationParentId {st["_parentId"]=String(parent)}
            sb += "win\t\(w.app.kind)\t\(w.x)\t\(w.y)\t\(w.w)\t\(w.h)\t\(w.maximized ? 1 : 0)\t\(w === focused ? 1 : 0)"
            for (k, v) in st { sb += "\t" + esc(k) + "=" + esc(v) }
            sb += "\n"
        }
        try? env.stateStore.save(sb)
    }

    /**
     * Set by the platform when it creates the shell, cleared by `restoreSession`. While set, going to the
     * background does not save: the saved session has not been read yet (the platforms read it on the first
     * layout), and saving the still-empty desktop would replace the user's windows and unsaved editor drafts
     * before the first-run intro). Seen on an OPPO phone (Android port), where a system overlay
     * paused the app before its first frame.
     */
    public var awaitingRestore = false

    public func restoreSession() {
        awaitingRestore = false
        guard let text = (try? env.stateStore.load()) ?? nil else { return }
        let lines = text.scSplit("\n")
        if lines.first != "v1" { return }
        var focusWin: Window? = nil
        var restoredIds:[Int:Int]=[:],parents:[(App,Int)]=[]
        for l in lines.dropFirst() {
            let f = l.scSplit("\t")
            if f.isEmpty { continue }
            if f[0] == "settings" && f.count > 1 { settings = Settings.decode(f[1]); applyLanguage() }
            if f[0] != "win" || f.count < 8 { continue }
            var st: [String: String] = [:]
            for kv in f.dropFirst(8) {
                let i = kv.scIndexOf("=")
                if i > 0 { st[unesc(kv.scSub(0, i))] = unesc(kv.scSub(i + 1)) }
            }
            guard let app = Launch.restore(self, f[1], st) else { continue }
            let win = open(app, maximized: f[6] == "1")
            if let old=Int(st["_windowId"] ?? "") {restoredIds[old]=win.id}
            if let parent=Int(st["_parentId"] ?? "") {parents.append((app,parent))}
            win.x = Int(f[2]) ?? 0; win.y = Int(f[3]) ?? 0; win.w = Int(f[4]) ?? 0; win.h = Int(f[5]) ?? 0
            clampWindow(win)
            if f[7] == "1" { focusWin = win }
        }
        for (app,parent) in parents {app.navigationParentId=restoredIds[parent]}
        if let fw = focusWin { focus(fw) }
        relayout(false)
    }

    private func esc(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for c in s.unicodeScalars {
            switch c {
            case "\\": out.append("\\"); out.append("\\")
            case "\t": out.append("\\"); out.append("t")
            case "\n": out.append("\\"); out.append("n")
            case "=": out.append("\\"); out.append("e")
            default: out.append(c)
            }
        }
        return String(out)
    }

    private func unesc(_ s: String) -> String {
        let a = s.scArr
        var sb = String.UnicodeScalarView()
        var i = 0
        while i < a.count {
            if a[i] == "\\" && i + 1 < a.count {
                switch a[i + 1] {
                case "t": sb.append("\t")
                case "n": sb.append("\n")
                case "e": sb.append("=")
                default: sb.append(a[i + 1])
                }
                i += 2
            } else { sb.append(a[i]); i += 1 }
        }
        return String(sb)
    }

    /** App returning to the foreground: resume programs paused by [onBackground]. */
    public func suspendInput() { releaseInputOwnership(); inputActive = false }
    public func resumeInput() { inputActive = true; syncKeyboard() }

    public func onForeground() {
        resumeInput()
        windows.forEach { $0.app.onForeground() }
        invalidate()
    }

    /** App going to background: pause programs, persist everything. */
    public func onBackground() {
        releaseInputOwnership()
        inputActive = false
        windows.forEach { $0.app.onBackground() }
        if !awaitingRestore { saveSession() }
        env.tone(0.0)
    }

    public static var KEY_ROW: Int { Touch.keyRow }
    /** Window background (frame and client fill): also the color along a window's bottom edge. */
    public static let WINDOW_BG = Palette.WHITE
    /** Background of the bottom bars (TempleOS keyboard, key row). */
    public static let BAR_BG = Palette.BLACK
    public static let LONG_PRESS_MS: Int64 = 550
    /** TempleOS's keyboard repeat (HomeLocalize.HC KbdTypeMatic(0)): 250 ms delay, 30 keys per second. */
    public static let TYPEMATIC_DELAY_MS: Int64 = 250
    public static let TYPEMATIC_PERIOD_MS: Int64 = 33
    /** Pointer id of taps made for a screen reader ([accessibilityActivate]). */
    public static let A11Y_POINTER = 0x7A11
    /**
     * Perf log for benchmarks (launch flag): every running program prints one "TempleOSMobile perf"
     * line per second, as with Show frame rate on, without showing the readout.
     */
    public static var perfLog = false
    /** The last perf line (the iOS view publishes it for UI tests). */
    public var lastPerfLine = ""
}

fileprivate extension Shell.Window {
    func right() -> Int { x + w }
    func bottom() -> Int { y + h }
}

/** User settings persisted with the session. */
public final class Settings {
    public var desktopColor: Int
    public var sound: Bool
    public var controlsOpacity: Int   // 0..3
    public var uiScale: Int           // 0 auto, else device px per logical px
    public var crispScaling: Bool
    public var largeTouch: Bool       // V-32: 44-48 dp rows and buttons
    public var keyboardMode: Int { get { Self.KEYBOARD_TEMPLEOS } set {} }
    /** The in-app UI language (canonical locale id), or "" to follow the device. */
    public var language: String
    /** How bundled programs run: [ENGINE_TERRY] (the HolyC interpreter) or [ENGINE_NATIVE] (their Swift translation). */
    public var engine: Int

    /** Pure Terry: every program runs on the HolyC compiler and interpreter. */
    public static let ENGINE_TERRY = 0
    /** Pure Swift: bundled programs run as their ahead-of-time Swift translation (PureNative). */
    public static let ENGINE_NATIVE = 1

    /** The in-app TempleOS keyboard ([TempleKeyboard]). */
    public static let KEYBOARD_TEMPLEOS = 0
    /** The device's own keyboard (international input, dictation, accessibility). */
    public static let KEYBOARD_SYSTEM = 1 // Legacy serialized value only; cannot activate a device keyboard.

    public init(_ desktopColor: Int = Palette.DKGRAY, _ sound: Bool = true, _ controlsOpacity: Int = 2, _ uiScale: Int = 0, _ crispScaling: Bool = false, _ largeTouch: Bool = false, _ keyboardMode: Int = Settings.KEYBOARD_TEMPLEOS, _ language: String = "", _ engine: Int = Settings.ENGINE_TERRY) {
        self.desktopColor = desktopColor; self.sound = sound; self.controlsOpacity = controlsOpacity
        self.uiScale = uiScale; self.crispScaling = crispScaling; self.largeTouch = largeTouch
        self.language = language; self.engine = engine
    }

    public func encode() -> String {
        "d=\(desktopColor);s=\(sound ? 1 : 0);o=\(controlsOpacity);u=\(uiScale);c=\(crispScaling ? 1 : 0);t=\(largeTouch ? 1 : 0);k=\(keyboardMode);g=\(language);e=\(engine)"
    }

    /** Kotlin Char.isLetterOrDigit(): Unicode letters (L*) and decimal digits (Nd). */
    static func isLetterOrDigit(_ c: Unicode.Scalar) -> Bool {
        switch c.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber: return true
        default: return false
        }
    }

    public static func decode(_ s: String) -> Settings {
        var m: [String: String] = [:]
        for it in s.scSplit(";") {
            let i = it.scIndexOf("=")
            if i > 0 { m[it.scSub(0, i)] = it.scSub(i + 1) }
        }
        return Settings(
            m["d"].flatMap { Int($0) }.map { coerceInUI($0, 0, 15) } ?? Palette.DKGRAY, m["s"] != "0",
            m["o"].flatMap { Int($0) }.map { coerceInUI($0, 0, 3) } ?? 2, m["u"].flatMap { Int($0) }.map { coerceInUI($0, 0, 6) } ?? 0, m["c"] == "1", m["t"] == "1",
            KEYBOARD_TEMPLEOS,
            // an unknown or stale id falls back to the device language (LocaleResolver ignores it)
            scString((m["g"] ?? "").unicodeScalars.filter { Settings.isLetterOrDigit($0) || $0 == "-" }.prefix(35)),
            m["e"] == "1" ? ENGINE_NATIVE : ENGINE_TERRY
        )
    }
}

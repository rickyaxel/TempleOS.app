import Foundation

// Port of ui/ProgramHost.kt.

/** KernelEnv for kernels hosted in the shell. Callbacks arrive on kernel threads. */
public final class UiKernelEnv: KernelEnv {
    // Weak: kernel threads can outlive the shell while they stop (the environment is kept).
    private weak var shell: Shell?
    private let env: ShellEnv
    private let ownerFocused: () -> Bool

    public init(_ shell: Shell, _ ownerFocused: @escaping () -> Bool) {
        self.shell = shell; self.env = shell.env; self.ownerFocused = ownerFocused; self.mux = shell.speaker
    }

    public func runtimeFile(_ name: String) -> [UInt8]? { env.runtimeFile(name) }
    public var fs: VirtualFs? { env.fs }
    public var memoryLimit: Int { env.memoryLimitBytes }
    /** This program's speaker setting, audible or not (guarded by [mux]'s lock). */
    private var hz = 0.0
    /** Whether this program owns the speaker: sound is on, its window has the focus, it is not paused (main thread). */
    private var audible = false
    private let pausedLock = NSLock()
    private var isPaused = false
    private let mux: SpeakerMux

    /** Main thread, every tick: re-reads the setting, the focus and the pause, and claims or releases the speaker. */
    public func refresh() {
        pausedLock.lock(); let p = isPaused; pausedLock.unlock()
        let now = (shell?.settings.sound ?? false) && !p && ownerFocused()
        if now == audible { return }
        audible = now
        mux.sync { if now { mux.claim(self, hz) } else { mux.release(self) } }
    }

    public func sound(_ kernel: Kernel, _ freq: Double, _ atNs: Int64) {
        mux.sync { hz = freq; mux.set(self, freq, atNs) }
    }
    public func paused(_ kernel: Kernel, _ paused: Bool) {
        pausedLock.lock(); isPaused = paused; pausedLock.unlock()
        refresh()
    }
    public func openEditor(_ kernel: Kernel, _ path: String) {
        shell?.post { [weak shell] in if let shell = shell, self.ownerFocused() { Launch.editor(shell, path) } }
    }
    public func openDocument(_ kernel: Kernel, _ path: String) {
        shell?.post { [weak shell] in if let shell = shell, self.ownerFocused() { Launch.doc(shell, path) } }
    }
    public func popupRequested(_ kernel: Kernel, _ req: PopupRequest) {
        guard let shell = shell else { kernel.answerPopup(-1); return }
        let answer: (Int64) -> Void = { value in
            if kernel.popup === req { kernel.answerPopup(value) } else { req.result = value }
        }
        shell.post { [weak shell] in
            guard let shell, self.ownerFocused(), kernel.popup === req else { answer(-1); return }
            // texts come from the HolyC program (CP437 bytes): shown as the program wrote them
            let d = Dialog.choose(req.header.trimmed().isEmpty ? tr("dialog.choose") : Cp437.decode(req.header), Cp437.decode(req.footer),
                                  req.items.map { (Cp437.decode($0.label), $0.value) }, req.items.map { $0.bg }) { v in answer(v) }
            d.onCancel = { answer(-1) }
            shell.showDialog(d)
        }
    }
}

/**
 * The device has one speaker, like the PC. TempleOS lets any task set it; here the program whose window
 * has the focus owns it ([UiKernelEnv.refresh]). Kernel threads change their program's setting, the main
 * thread moves the ownership; one lock orders both, so a window losing the focus never silences the one
 * that took it, and a new owner's current setting (a held note) sounds at once.
 */
public final class SpeakerMux {
    private let env: ShellEnv
    private let lock = NSRecursiveLock()
    private weak var owner: AnyObject?
    public init(_ env: ShellEnv) { self.env = env }
    /** Runs [body] holding the speaker's lock (claim, release and set are called inside it). */
    public func sync<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    public func claim(_ who: AnyObject, _ hz: Double) { sync { if owner !== who { owner = who; env.tone(hz, at: monoNanos()) } } }
    public func release(_ who: AnyObject) { sync { if owner === who { owner = nil; env.tone(0.0, at: monoNanos()) } } }
    public func set(_ who: AnyObject, _ hz: Double, _ atNs: Int64) { sync { if owner === who { env.tone(hz, at: atNs) } } }
}

/** Frame source over a kernel's published 640x480 screen. */
public final class KernelFrame: FrameSource {
    private let k: Kernel
    public init(_ k: Kernel) { self.k = k }
    public let frameW = Kernel.W
    public let frameH = Kernel.H
    public var frameVersion: Int64 { k.publishedVersion }
    public var palette: [Int32] { k.palette }
    /** [dst] must hold Kernel.W * Kernel.H bytes. */
    public func copyFrame(_ dst: UnsafeMutablePointer<UInt8>) -> Int64 {
        k.publishLock.sync { () -> Int64 in
            memcpy(dst, k.published, Kernel.W * Kernel.H)
            return k.publishedVersion
        }
    }
    public var window: Rect { k.publishLock.sync { () -> Rect in let w = k.publishedWindow; return Rect(w[0], w[1], w[2], w[3]) } }
}

/**
 * Maps a touch at ([x], [y]) in [canvas] (which shows [window] of the 640x480 screen) to screen
 * pixels, as TempleOS's mouse reports them (ms.pos is screen-absolute).
 */
public func canvasToScreen(_ x: Int, _ y: Int, _ canvas: Rect, _ window: Rect) -> (Int, Int) {
    let sx = window.x + (x - canvas.x) * window.w / max(1, canvas.w)
    let sy = window.y + (y - canvas.y) * window.h / max(1, canvas.h)
    return (min(max(sx, window.x), window.right - 1), min(max(sy, window.y), window.bottom - 1))
}

/** Draws a kernel console (TempleOS document) into a rect with scrollback. */
public final class ConsoleView {
    public var scrollBack = 0
    private var cells: [Int] = []

    public init() {}

    public func draw(_ s: Surface, _ r: Rect, _ console: Console, _ showCursor: Bool) {
        let cols = max(1, r.w / 8), rows = max(1, r.h / 8)
        if cells.count < cols * rows { cells = [Int](repeating: 0, count: cols * rows) }
        let blank = (Console.DFT_BG << 4) | Console.DFT_FG
        let total = console.visualRows(cols)
        scrollBack = min(max(scrollBack, 0), max(0, total - rows))
        console.renderCells(&cells, cols, rows, blank, scrollBack)
        s.fill(r, Palette.WHITE)
        for row in 0..<rows {
            for c in 0..<cols {
                let cell = cells[row * cols + c]
                s.cell(r.x + c * 8, r.y + row * 8, cell)
            }
        }
        if showCursor && scrollBack == 0 && console.cursorVisible {
            // find the last non-blank row to place the cursor after the text
            var lastRow = 0
            rowLoop: for row in stride(from: rows - 1, through: 0, by: -1) {
                for c in 0..<cols where (cells[row * cols + c] & 0xFF) != 32 { lastRow = row; break rowLoop }
            }
            var col = 0
            for c in stride(from: cols - 1, through: 0, by: -1) where (cells[lastRow * cols + c] & 0xFF) != 32 { col = c + 1; break }
            if col >= cols { col = cols - 1 }
            if (epochMillisNow() / 500) % 2 == 0 { s.fillRect(r.x + col * 8, r.y + lastRow * 8 + 7, 8, 1, Palette.BLUE) }
        }
        if scrollBack > 0 {
            let t = " \u{18} \(scrollBack) "
            s.text(r.right - t.count * 8, r.y, t, Palette.WHITE, Palette.RED)
        }
    }

    public func scrollBy(_ rowsDelta: Int) { scrollBack = max(0, scrollBack + rowsDelta) }
}

/**
 * Touch controls for a running program: a d-pad (arrow keys, held while
 * pressed), action keys, and the program's own menu actions (TempleOS menus
 * carry key bindings, e.g. "Accelerator(,,SC_CURSOR_UP)").
 */
/**
 * A PC keyboard has one typematic key: the key pressed last repeats, and once it is released no key
 * repeats until another is pressed (PS/2 typematic; TempleOS only sees the repeated make codes). One
 * per shell, shared by the physical keyboard, the TempleOS keyboard and the game buttons.
 */
public final class Typematic {
    private var seq: Int64 = 0
    public init() {}
    /** A key went down: it becomes the typematic key. Returns its ticket. */
    public func pressed() -> Int64 { seq += 1; return seq }
    public func repeats(_ ticket: Int64) -> Bool { ticket == seq }
}

/** How a program's arrow keys are offered (Settings.directional): the four d-pad buttons, or the joystick in their place. */
public enum DirectionalControl: Int { case dpad = 0, joystick = 1 }

public final class GameControls {
    /**
     * A button. Key buttons ([ch], [sc]) are physical keys: down while held, typematic repeat, up on
     * release (menu shortcuts too: the button stands for the key the menu names). [wheel] buttons turn
     * the mouse wheel one notch per press and repeat; modifier keys never repeat (KbdBuildSC). [dir] is the
     * arrow ([Joystick.UP]...) of a d-pad button or of a joystick push; [touchMode] marks the touch-mode toggle.
     */
    private final class Btn {
        let label: String, rect: Rect, ch: Int, sc: Int64, a11y: String?, toggle: (() -> Void)?, wheel: Int, dir: Int, touchMode: Bool
        init(_ label: String, _ rect: Rect, _ ch: Int, _ sc: Int64, _ a11y: String? = nil, toggle: (() -> Void)? = nil, wheel: Int = 0,
             dir: Int = 0, touchMode: Bool = false) {
            self.label = label; self.rect = rect; self.ch = ch; self.sc = sc; self.a11y = a11y; self.toggle = toggle; self.wheel = wheel
            self.dir = dir; self.touchMode = touchMode
        }
    }
    private let send: (KInput) -> Void
    private var buttons: [Btn] = []
    private var held: [Int: Btn] = [:]  // hold id (a pointer id, or -arrow for the joystick) -> held button
    private var heldSince: [Int: Int64] = [:] // hold id -> first tick time (-1 until then)
    private var lastRepeat: [Int: Int64] = [:]
    private var ticket: [Int: Int64] = [:]
    /** The joystick, laid out in the d-pad's square in [DirectionalControl.joystick] mode. */
    let joystick = Joystick()
    /** The finger that drives the joystick (one at a time), and the arrows its push holds. */
    private var stickPointer: Int?
    private var stickHeld = 0
    /**
     * The arrow keys the joystick holds, the d-pad's keys. Their hold ids are -[dir]: pointer ids are never
     * negative, so a push and a finger on a button never share an entry.
     */
    private let stickKeys: [Btn] = [(Joystick.UP, Keys.SC_CURSOR_UP), (Joystick.DOWN, Keys.SC_CURSOR_DOWN),
                                    (Joystick.LEFT, Keys.SC_CURSOR_LEFT), (Joystick.RIGHT, Keys.SC_CURSOR_RIGHT)].map { dir, code in
        let (c, s) = Keys.special(code); return Btn("", Rect(0, 0, 0, 0), c, s, dir: dir)
    }
    /** The joystick toggle asks for the other directional control: the owner keeps it (Settings) and draws with it. */
    public var onDirectional: (DirectionalControl) -> Void = { _ in }
    /** How short a push holds the joystick's arrows ([Joystick.keys]): the owner's setting, read at each push. */
    public var stickSensitivity: () -> Int = { Joystick.SENSITIVITY_DEFAULT }
    /**
     * What the layout depends on. While it stays the same, a frame draws the last layout's buttons again instead of
     * building new ones: a held button is the one drawn (PRESSED), and a frame only compares and draws.
     */
    private struct LayoutKey: Equatable {
        let r: Rect, vertical: Bool, showDpad: Bool, directional: DirectionalControl, actionArea: Rect?
        let ctrl: Bool, shift: Bool, wheel: Bool, clickMode: Int, language: Int, buttonH: Int
    }
    private var layoutKey: LayoutKey?
    /** The menu snapshot the shortcut buttons were read from, and those shortcuts. */
    private var menuSeen: [MenuSnap] = []
    private var shortcuts: [MenuSnap] = []
    /** Layouts built (tests: frames with nothing new reuse the last one). */
    private(set) var layouts = 0
    /**
     * The controls' own labels in the UI language (touch modes with their spoken names, wheel) and the widths
     * the layout gives them: resolved when the language changes, not on every frame (the shell's surface
     * measures with one fixed font).
     */
    private struct ControlText {
        let modes: [(String, String)], modeW: Int
        let wheelUp: String, wheelDown: String, wheelUpW: Int, wheelDownW: Int
        let toJoystick: String, toDpad: String, directionalW: Int, toJoystickA11y: String, toDpadA11y: String, stickA11y: String
        init(_ s: Surface) {
            let modes = [(tr("controls.button.left_click"), tr("controls.a11y.left_click")),
                         (tr("controls.button.right_click"), tr("controls.a11y.right_click")), (tr("controls.button.hover"), tr("controls.a11y.hover"))]
            self.modes = modes; modeW = modes.map { s.measureUi($0.0) }.max() ?? 0
            wheelUp = tr("controls.button.wheel_up"); wheelDown = tr("controls.button.wheel_down")
            wheelUpW = s.measureUi(wheelUp); wheelDownW = s.measureUi(wheelDown)
            toJoystick = tr("controls.button.joystick"); toDpad = tr("controls.button.dpad")
            directionalW = max(s.measureUi(toJoystick), s.measureUi(toDpad))
            toJoystickA11y = tr("controls.a11y.joystick_mode"); toDpadA11y = tr("controls.a11y.dpad_mode"); stickA11y = tr("controls.a11y.joystick")
        }
    }
    private var controlText: L10n.Presentation<ControlText>?
    private let typematic: Typematic
    /** What a touch on the picture is: 0 left button, 1 right button, 2 pointer move only (hover). */
    public var clickMode = 0
    public var rightClick: Bool { clickMode == 1 }
    /** Turns the mouse wheel by one notch (BattleLines reads ms.pos.z). */
    public var onWheel: (Int) -> Void = { _ in }
    public static let REPEAT_DELAY_MS: Int64 = 250
    public static let REPEAT_PERIOD_MS: Int64 = 33
    /**
     * A held joystick push repeats its arrow 5 times a second, the pace of quick taps on a d-pad button: a
     * stick is held where a button is tapped, and a game that counts key messages (Varoom's accelerator)
     * gets 30 a second only from a button that is held on purpose.
     */
    public static let STICK_REPEAT_PERIOD_MS: Int64 = 200

    /**
     * Typematic repeat for held key buttons, like a PC keyboard: TempleOS boots with
     * KbdTypeMatic(0) (HomeLocalize.HC) = 250 ms delay, then 30 key-downs per second.
     * Games that move one step per key message (GetKey: CastleFrankenstein) need it. The joystick's arrows
     * repeat after the same delay, then [STICK_REPEAT_PERIOD_MS] apart. Returns true while the joystick's knob
     * is easing back to the centre (the controls need drawing).
     */
    @discardableResult
    public func tick(_ nowMs: Int64) -> Bool {
        for (id, b) in held {
            if b.toggle != nil || isModifier(b) { continue }
            if b.wheel == 0 && !typematic.repeats(ticket[id] ?? -1) { continue }
            guard let since = heldSince[id] else { continue }
            let period = id < 0 ? GameControls.STICK_REPEAT_PERIOD_MS : GameControls.REPEAT_PERIOD_MS // (the joystick's hold ids are negative)
            if since < 0 { heldSince[id] = nowMs; lastRepeat[id] = nowMs + GameControls.REPEAT_DELAY_MS - period; continue }
            if nowMs - since < GameControls.REPEAT_DELAY_MS { continue }
            var last = lastRepeat[id] ?? since
            var n = 0
            while nowMs - last >= period && n < 2 { press(b); last += period; n += 1 }
            if nowMs - last >= period { last = nowMs } // do not queue a burst after a stall
            lastRepeat[id] = last
        }
        return joystick.settle(nowMs)
    }

    public init(_ typematic: Typematic = Typematic(), _ send: @escaping (KInput) -> Void) { self.typematic = typematic; self.send = send }

    /** The labels of the buttons drawn last, in order (tests, diagnostics). */
    var labels: [String] { buttons.map { $0.label } }

    /** Screen-reader nodes for the joystick and the buttons drawn last (label, toggle state). */
    public func accessibility(_ add: (Rect, String, Bool) -> Void) {
        if joystick.shown, let t = controlText?.value { add(joystick.rect, t.stickA11y, false) }
        for b in buttons {
            let label: String
            if let a = b.a11y { label = a } else {
                switch b.label {
                case "\u{18}": label = tr("key.up"); case "\u{19}": label = tr("key.down"); case "\u{1B}": label = tr("key.left"); case "\u{1A}": label = tr("key.right")
                case "SPACE": label = tr("key.space"); case "ENTER": label = tr("key.enter"); case "ESC": label = tr("key.escape")
                default: label = Cp437.decode(b.label)
                }
            }
            add(b.rect, label, b.touchMode && clickMode != 0)
        }
    }

    /**
     * Lays out controls in [r] and draws them into [s]. With [actionArea] (landscape: the gutter right
     * of the picture) the action buttons go there instead of next to the d-pad. A program with the d-pad
     * ([showDpad]) shows it as four buttons or, in [DirectionalControl.joystick] mode, as the joystick in the
     * same square, and gets the button that switches between them; [directional] never adds either one.
     */
    public func draw(_ s: Surface, _ r: Rect, _ menu: [MenuSnap], vertical: Bool, showDpad: Bool, directional: DirectionalControl = .dpad,
                     actionArea: Rect? = nil, info: ProgramInfo? = nil) {
        let key = LayoutKey(r: r, vertical: vertical, showDpad: showDpad, directional: directional, actionArea: actionArea,
                            ctrl: info?.usesCtrl == true, shift: info?.usesShift == true, wheel: info?.usesWheel == true,
                            clickMode: clickMode, language: L10n.version, buttonH: Touch.button)
        if newShortcuts(menu) || key != layoutKey {
            layout(s, r, vertical: vertical, showDpad: showDpad, directional: directional, actionArea: actionArea, info: info)
            layoutKey = key; layouts += 1
        }
        for b in buttons {
            let pressed = held.values.contains { $0 === b }
            let on = b.touchMode && clickMode != 0
            s.templeButton(b.rect, b.label, pressed ? ButtonFace.PRESSED : on ? ButtonFace.SELECTED : ButtonFace.NORMAL)
        }
        if joystick.shown { joystick.draw(s, stickHeld) }
    }

    /**
     * Reads the program's menu shortcuts (the menu keys that get a button) when the kernel published a new snapshot:
     * it re-reads the menu every 15 frames, mostly with the same entries. True if the shortcuts changed.
     */
    private func newShortcuts(_ menu: [MenuSnap]) -> Bool {
        if menu.count == menuSeen.count && zip(menu, menuSeen).allSatisfy({ $0 === $1 }) { return false }
        menuSeen = menu
        // SPACE, ENTER and ESC have their own buttons, the arrows the d-pad
        let arrows = [Keys.SC_CURSOR_UP, Keys.SC_CURSOR_DOWN, Keys.SC_CURSOR_LEFT, Keys.SC_CURSOR_RIGHT]
        let now = Array(menu.filter { !$0.isDir && ($0.a1 != 0 || $0.a2 != 0) && $0.msgCode == -2 }
            .filter { m in !(m.a1 != 0 && [Int64(32), Int64(10), Int64(Keys.CH_ESC)].contains(m.a1)) }
            .filter { m in !arrows.contains(Int(m.a2 & 0x7F)) }
            .prefix(6))
        let same = now.count == shortcuts.count && zip(now, shortcuts).allSatisfy { $0.label == $1.label && $0.a1 == $1.a1 && $0.a2 == $1.a2 }
        shortcuts = now
        return !same
    }

    /** Builds the buttons (and places the joystick) for [draw]. */
    private func layout(_ s: Surface, _ r: Rect, vertical: Bool, showDpad: Bool, directional: DirectionalControl, actionArea: Rect?,
                        info: ProgramInfo?) {
        buttons.removeAll()
        if r.w < 40 || r.h < 40 { hideStick(); return }
        let size = min(44, min(r.w, r.h) / 3)
        let pad = Rect(r.x + 4, vertical ? r.y + 4 : r.y + (r.h - size * 3) / 2, size * 3, size * 3)
        let stick = showDpad && directional == .joystick
        if showDpad && !stick {
            add("\u{18}", Rect(pad.x + size, pad.y, size, size), Keys.SC_CURSOR_UP, dir: Joystick.UP)
            add("\u{1B}", Rect(pad.x, pad.y + size, size, size), Keys.SC_CURSOR_LEFT, dir: Joystick.LEFT)
            add("\u{1A}", Rect(pad.x + 2 * size, pad.y + size, size, size), Keys.SC_CURSOR_RIGHT, dir: Joystick.RIGHT)
            add("\u{19}", Rect(pad.x + size, pad.y + 2 * size, size, size), Keys.SC_CURSOR_DOWN, dir: Joystick.DOWN)
        }
        // a joystick whose square moved under the finger (rotation, a resized window) lets go
        if stick { if joystick.layout(pad) && stickPointer != nil { releaseStick() } } else { hideStick() }
        // action buttons: next to the pad, or in [actionArea]
        var actions: [(String, Int, Int64)] = []
        actions.append(("SPACE", 32, Keys.forChar(32).1))
        actions.append(("ENTER", 10, Keys.special(Keys.SC_ENTER).1))
        actions.append(("ESC", Keys.CH_ESC, Keys.special(Keys.SC_ESC).1))
        let menuKeys = shortcuts
        // keys and mouse parts the program needs that a phone lacks (catalog: source-derived)
        var extras: [Btn] = []
        if info?.usesCtrl == true { extras.append(Btn("CTRL", Rect(0, 0, 0, 0), 0, Int64(Keys.SC_CTRL), tr("key.control"))) }
        if info?.usesShift == true { extras.append(Btn("SHIFT", Rect(0, 0, 0, 0), 0, Int64(Keys.SC_SHIFT), tr("key.shift"))) }
        if controlText == nil { controlText = L10n.Presentation { ControlText(s) } }
        let t = controlText!.value
        if info?.usesWheel == true {
            extras.append(Btn(t.wheelUp, Rect(0, 0, 0, 0), 0, 0, tr("controls.a11y.wheel_up"), wheel: 1))
            extras.append(Btn(t.wheelDown, Rect(0, 0, 0, 0), 0, 0, tr("controls.a11y.wheel_down"), wheel: -1))
        }
        let area = actionArea ?? r
        let x0 = actionArea != nil ? area.x + 4 : showDpad ? pad.right + 8 : r.x + 4
        // a separate gutter holds one or two columns; next to the pad, up to three per row
        let bw = actionArea != nil ? min(area.w - 4 >= 2 * 56 ? (area.w - 4) / 2 : area.w - 4, 96)
            : min(max(56, (r.w - (showDpad ? pad.w + 12 : 4)) / 3), 96)
        var bx = x0
        var by: Int
        if actionArea != nil {
            let count = actions.count + menuKeys.count + extras.count + (showDpad ? 2 : 1)
            let rows = (count + max(1, (area.w - 4) / bw) - 1) / max(1, (area.w - 4) / bw)
            by = area.y + max(4, (area.h - rows * (Touch.button + 4)) / 2)
        } else { by = showDpad ? pad.y : r.y + 4 }
        // one grid cell per button; a translated label wider than its cell takes the cells it needs on its row
        func place(_ labelW: Int = 0) -> Rect {
            let w = bw * min(max((labelW + 8 + bw - 1) / bw, 1), max(1, (area.right - x0) / bw))
            if bx + w > area.right { bx = x0; by += Touch.button + 4 }
            let rr = Rect(bx, by, w - 4, Touch.button); bx += w; return rr
        }
        for (l, ch, sc) in actions { add(l, place(), -1, ch, sc) }
        for m in menuKeys {
            let (ch, sc) = menuKey(m.a1, m.a2)
            buttons.append(Btn(m.label.take(10), place(), ch, sc))
        }
        // CTRL and SHIFT are key caps and keep one cell; a translated wheel label may need more
        for b in extras { buttons.append(Btn(b.label, place(b.wheel == 1 ? t.wheelUpW : b.wheel == -1 ? t.wheelDownW : 0), b.ch, b.sc, b.a11y, wheel: b.wheel)) }
        // the touch mode's label and spoken name are the app's (translated); the toggle never reads them. Sized
        // for its widest label, so it keeps its place and size while it cycles.
        let (mode, modeA11y) = t.modes[clickMode]
        buttons.append(Btn(mode, place(t.modeW), 0, 0, modeA11y,
                           toggle: { [unowned self] in clickMode = (clickMode + 1) % 3 }, touchMode: true))
        // the d-pad/joystick switch is the app's too, named for the mode it switches to; last, so the buttons
        // before it keep their places, and sized for its wider label
        if showDpad {
            let next: DirectionalControl = stick ? .dpad : .joystick
            buttons.append(Btn(stick ? t.toDpad : t.toJoystick, place(t.directionalW), 0, 0, stick ? t.toDpadA11y : t.toJoystickA11y,
                               toggle: { [unowned self] in releaseArrows(); onDirectional(next) }))
        }
    }

    /**
     * The key a menu shortcut names (Adam/Menu.HC entries carry arg1 = ASCII, arg2 = scan code; many
     * give only the ASCII): a button is that key, so it gets the key's scan code for kbd.down_bitmap.
     */
    private func menuKey(_ a1: Int64, _ a2: Int64) -> (Int, Int64) {
        if a2 != 0 { return (Int(Int32(truncatingIfNeeded: a1)), a2) }
        if a1 == Int64(Keys.CH_SHIFT_ESC) { return Keys.special(Keys.SC_ESC, shift: true) }
        if a1 >= 1 && a1 <= 255 { return Keys.forChar(Int(a1)) }
        return (Int(Int32(truncatingIfNeeded: a1)), a2)
    }

    private func isModifier(_ b: Btn) -> Bool {
        let c = Int(b.sc & 0xFF)
        return c == Keys.SC_CTRL || c == Keys.SC_SHIFT || c == Keys.SC_ALT
    }

    private func press(_ b: Btn) { if b.wheel != 0 { onWheel(b.wheel) } else { send(.key(ch: b.ch, sc: b.sc, down: true)) } }

    private func add(_ label: String, _ rect: Rect, _ scCode: Int, _ ch: Int = 0, _ sc: Int64 = 0, dir: Int = 0) {
        if scCode >= 0 {
            let (c, s) = Keys.special(scCode)
            buttons.append(Btn(label, rect, c, s, dir: dir))
        } else { buttons.append(Btn(label, rect, ch, sc)) }
    }

    /** [b] goes down for hold id [id]: pressed now, repeated by [tick], up on [release]. */
    private func hold(_ id: Int, _ b: Btn) {
        held[id] = b; heldSince[id] = -1; lastRepeat[id] = nil
        if b.wheel == 0 && !isModifier(b) { ticket[id] = typematic.pressed() }
        press(b)
    }

    /** Lets go of what hold id [id] holds; false if it holds nothing. */
    @discardableResult
    private func release(_ id: Int) -> Bool {
        heldSince[id] = nil; lastRepeat[id] = nil; ticket[id] = nil
        guard let b = held.removeValue(forKey: id) else { return false }
        if b.wheel == 0 { send(.key(ch: b.ch, sc: b.sc | Keys.SCF_KEY_UP, down: false)) }
        return true
    }

    /** The joystick's finger is at ([x], [y]): the knob follows, and the push holds its arrows. */
    private func steer(_ x: Int, _ y: Int) {
        let (dx, dy) = joystick.push(x, y)
        holdArrows(Joystick.keys(dx, dy, joystick.travel, stickHeld, stickSensitivity()))
    }

    /**
     * Makes the joystick hold exactly the arrows in [bits], as d-pad buttons hold them: the arrows it no
     * longer pushes go up, new ones go down (and become the typematic key); one it keeps is not sent again.
     */
    private func holdArrows(_ bits: Int) {
        for b in stickKeys where stickHeld & b.dir != 0 && bits & b.dir == 0 { release(-b.dir) }
        for b in stickKeys where bits & b.dir != 0 && stickHeld & b.dir == 0 { hold(-b.dir, b) }
        stickHeld = bits
    }

    /** The joystick's finger lifted (or the joystick went away): its arrows go up at once, the knob eases home. */
    private func releaseStick() {
        holdArrows(0); stickPointer = nil; joystick.letGo()
    }

    private func hideStick() { if joystick.shown { releaseStick(); joystick.hide() } }

    /**
     * Switching between the d-pad and the joystick: the arrows either one holds go up, so nothing keeps
     * moving (a finger still on a d-pad button or on the joystick holds nothing more); other keys stay held.
     */
    private func releaseArrows() {
        for (id, b) in held where b.dir != 0 { release(id) }
        stickHeld = 0; stickPointer = nil; joystick.center()
    }

    /**
     * Returns true if the pointer hit a control. The joystick follows one finger from anywhere on it until
     * that finger lifts; another finger on it is taken and ignored. Fingers on buttons are independent of it.
     */
    public func pointer(_ e: PointerEvent) -> Bool {
        switch e.action {
        case Ptr.DOWN:
            if joystick.shown && joystick.rect.contains(e.x, e.y) {
                if stickPointer == nil { stickPointer = e.id; steer(e.x, e.y) }
                return true
            }
            guard let b = buttons.first(where: { $0.rect.contains(e.x, e.y) }) else { return false }
            if let toggle = b.toggle { toggle(); return true }
            hold(e.id, b)
            return true
        case Ptr.UP, Ptr.CANCEL:
            if e.id == stickPointer { releaseStick(); return true }
            return release(e.id)
        case Ptr.MOVE:
            if e.id == stickPointer { steer(e.x, e.y); return true }
            return held[e.id] != nil
        default: return false
        }
    }

    /**
     * The current layout has no control area (landscape gutters under 96 px, console view): forget the
     * last layout's buttons. They are hit-tested before the picture, so leftovers were invisible keys and
     * a tap beside the picture could send Abort (Shift-Esc) and end the program. Held keys stay held
     * until their finger lifts; the joystick lets go (there is no joystick without the control area).
     */
    public func clearLayout() { buttons.removeAll(); hideStick(); layoutKey = nil }

    /** Releases everything (focus loss, rotation) so no key stays stuck. */
    public func releaseAll() {
        for b in held.values where b.wheel == 0 { send(.key(ch: b.ch, sc: b.sc | Keys.SCF_KEY_UP, down: false)) }
        held.removeAll(); heldSince.removeAll(); lastRepeat.removeAll()
        stickHeld = 0; stickPointer = nil; joystick.letGo()
    }

    public var anyHeld: Bool { !held.isEmpty }
}

/**
 * The joystick that can take the d-pad's place ([GameControls], Settings.directional): a stick drawn in
 * TempleOS colors and pixels in the pad's square. It keeps the geometry, the picture and the knob; a push
 * ([keys]) becomes the arrow keys the d-pad buttons hold, through the same key path.
 */
public final class Joystick {
    /** Arrow bits (a d-pad button's or a push's [GameControls] dir). */
    static let UP = 1, DOWN = 2, LEFT = 4, RIGHT = 8
    /**
     * The sensitivity levels (Settings.joystickSensitivity): the higher, the shorter the push that holds keys.
     * The default needs twice the push of [SENSITIVITY_MAX].
     */
    public static let SENSITIVITY_MIN = 1, SENSITIVITY_MAX = 5, SENSITIVITY_DEFAULT = 3
    /**
     * A push holds keys from [engagePercent] of the knob's travel and lets go below [releasePercent], so a thumb
     * resting at the edge of the dead zone does not chatter. Each arrow takes [CARDINAL] degrees either side of
     * its axis, a diagonal (two arrows) the 30 degrees between, and a held direction stays until the push is
     * [STICKY] degrees past its edge.
     */
    static let CARDINAL = 30.0, STICKY = 6.0
    /** Percent of the knob's travel a push needs to hold keys at [sensitivity]: 90, 75, 60, 45, 30. */
    static func engagePercent(_ sensitivity: Int) -> Int { 105 - 15 * coerceInUI(sensitivity, SENSITIVITY_MIN, SENSITIVITY_MAX) }
    /** Percent of the knob's travel below which a held push lets go: 66, 55, 44, 33, 22. */
    static func releasePercent(_ sensitivity: Int) -> Int { engagePercent(sensitivity) * 11 / 15 }
    /** How long the released knob takes back to the centre (its keys go up at once). */
    static let RETURN_MS: Int64 = 80
    /** Counter-clockwise from right, 45 degrees apart. */
    private static let SECTORS = [RIGHT, UP | RIGHT, UP, UP | LEFT, LEFT, DOWN | LEFT, DOWN, DOWN | RIGHT]

    /**
     * The arrow keys a push of ([dx], [dy]) from the centre holds (y grows downwards) for a knob that travels
     * [travel] px, given the keys [held] now: none in the dead zone ([sensitivity] sets its size), else one
     * arrow, or two on a diagonal, as two fingers on the d-pad hold them.
     */
    static func keys(_ dx: Int, _ dy: Int, _ travel: Int, _ held: Int, _ sensitivity: Int = SENSITIVITY_DEFAULT) -> Int {
        // the dead zone's edge in whole numbers (percent of the travel): the same pixel on every platform
        let edge = (held == 0 ? engagePercent(sensitivity) : releasePercent(sensitivity)) * max(1, travel)
        if (dx * dx + dy * dy) * 10000 < edge * edge { return 0 }
        var a = atan2(Double(-dy), Double(dx)) * 180 / Double.pi
        if a < 0 { a += 360 }
        func apart(_ b: Double) -> Double { let d = abs(a - b).truncatingRemainder(dividingBy: 360); return d > 180 ? 360 - d : d }
        if let i = SECTORS.firstIndex(of: held), apart(Double(i) * 45) <= (i % 2 == 0 ? CARDINAL : 45 - CARDINAL) + STICKY { return held }
        let axis = Int((a / 90 + 0.5).rounded(.down)) % 4
        return apart(Double(axis) * 90) <= CARDINAL ? SECTORS[axis * 2] : SECTORS[Int(a / 90) % 4 * 2 + 1]
    }

    /** The square it fills: the pad's, one pixel less when even, so its crosshair and knob have a centre pixel. */
    private(set) var rect = Rect(0, 0, 0, 0)
    var shown: Bool { rect.w > 0 }
    var cx: Int { rect.x + rect.w / 2 }
    var cy: Int { rect.y + rect.h / 2 }
    /** How far the knob's centre moves from the centre. */
    private(set) var travel = 1
    /** The knob's offset from the centre. */
    private(set) var knobX = 0, knobY = 0
    private var returning: (x: Int, y: Int, at: Int64)?
    private var knob = 0
    /** The picture as rows of one color (built once per size, drawn as filled spans). */
    private struct Run { let x: Int, y: Int, w: Int, kind: Int }
    private var art: [Run] = []
    private var knobArt: [Run] = []

    /** Places it in the d-pad's square [pad]; returns true when it moved or changed size. */
    func layout(_ pad: Rect) -> Bool {
        let s = min(pad.w, pad.h), d = s % 2 == 1 ? s : s - 1
        let r = Rect(pad.x + (pad.w - d) / 2, pad.y + (pad.h - d) / 2, d, d)
        if r == rect { return false }
        if d != rect.w { build(d) }
        rect = r
        return true
    }

    func hide() { rect = Rect(0, 0, 0, 0); center() }

    func center() { knobX = 0; knobY = 0; returning = nil }

    /** A finger at ([x], [y]): the knob goes as far towards it as it travels. Returns the push from the centre. */
    func push(_ x: Int, _ y: Int) -> (Int, Int) {
        returning = nil
        let dx = x - cx, dy = y - cy, q = dx * dx + dy * dy
        if q <= travel * travel { knobX = dx; knobY = dy } else {
            let f = Double(travel) / Double(q).squareRoot()
            knobX = Joystick.round(Double(dx) * f); knobY = Joystick.round(Double(dy) * f)
        }
        return (dx, dy)
    }

    /** The finger let go: the knob eases back to the centre ([settle]). */
    func letGo() { if knobX != 0 || knobY != 0 { returning = (knobX, knobY, -1) } }

    /** Moves a returning knob on; true while it moves (and once more when it arrives). */
    func settle(_ nowMs: Int64) -> Bool {
        guard var r = returning else { return false }
        if r.at < 0 { r.at = nowMs; returning = r }
        let f = 1.0 - Double(nowMs - r.at) / Double(Joystick.RETURN_MS)
        if f <= 0 { center(); return true }
        knobX = Joystick.round(Double(r.x) * f); knobY = Joystick.round(Double(r.y) * f)
        return true
    }

    /** Halves round up, as on every platform (the knob lands on the same pixel). */
    private static func round(_ v: Double) -> Int { Int((v + 0.5).rounded(.down)) }

    // what a pixel of the picture is: the base, its guide marks, the rim (by quadrant: RIM | an arrow), the knob
    private static let BASE = 0, GUIDE = 1, MARK = 2, RIM = 16, KNOB = 32, KNOB_SHADE = 33, KNOB_EDGE = 34

    /** The rim lights up on the side of each arrow the push holds. */
    func draw(_ s: Surface, _ keys: Int) {
        for r in art { s.fillRect(rect.x + r.x, rect.y + r.y, r.w, 1, Joystick.color(r.kind, keys)) }
        let kx = cx + knobX - knob / 2, ky = cy + knobY - knob / 2
        for r in knobArt { s.fillRect(kx + r.x, ky + r.y, r.w, 1, Joystick.color(r.kind, keys)) }
    }

    private static func color(_ kind: Int, _ keys: Int) -> Int {
        switch kind {
        case BASE: return Palette.BLACK
        case GUIDE: return Palette.CYAN
        case MARK, KNOB: return Palette.LTCYAN
        case KNOB_SHADE: return Palette.CYAN
        case KNOB_EDGE: return Palette.WHITE
        default: return keys & (kind & 15) != 0 ? Palette.LTCYAN : Palette.CYAN
        }
    }

    /**
     * Draws the picture for diameter [d] (odd) in whole pixels, with integer arithmetic only (the same pixels on
     * every platform). Coordinates are doubled, from the centre pixel: X = 2x + 1 - d.
     */
    private func build(_ d: Int) {
        let rim = d >= 100 ? 3 : d >= 60 ? 2 : 1
        knob = max(7, (d * 2 / 5) | 1)
        travel = max(1, d / 2 - rim - knob / 2 - 1)
        let inner = d - 2 * rim, marks = inner - 6, guide = 2 * travel
        art = Joystick.runs(d) { X, Y in
            let q = X * X + Y * Y
            if q >= d * d { return -1 }
            if q >= inner * inner { return Joystick.RIM | (abs(X) > abs(Y) ? (X < 0 ? Joystick.LEFT : Joystick.RIGHT) : (Y < 0 ? Joystick.UP : Joystick.DOWN)) }
            if (X == 0 || Y == 0) && q < marks * marks {
                // the crosshair: a solid centre, then dashes out to the rim
                let along = (abs(X) + abs(Y)) / 2
                return along <= 3 ? Joystick.MARK : (along / 3) % 2 == 0 ? Joystick.GUIDE : Joystick.BASE
            }
            // the ring the knob's centre can reach, dashed
            if q >= (guide - 1) * (guide - 1) && q < (guide + 1) * (guide + 1) && (min(abs(X), abs(Y)) / 8) % 2 == 0 { return Joystick.GUIDE }
            return Joystick.BASE
        }
        let k = knob, shift = 2 * max(1, k / 12)
        knobArt = Joystick.runs(k) { X, Y in
            let q = X * X + Y * Y
            if q >= k * k { return -1 }
            if q >= (k - 2) * (k - 2) { return Joystick.KNOB_EDGE }
            // flat, with a shaded crescent down-right in whole pixels
            if (X + shift) * (X + shift) + (Y + shift) * (Y + shift) >= (k - 2) * (k - 2) { return Joystick.KNOB_SHADE }
            return Joystick.KNOB
        }
    }

    /** Run-length encodes a [d] x [d] picture whose pixel at doubled offset (X, Y) is [kind] (-1: none). */
    private static func runs(_ d: Int, _ kind: (Int, Int) -> Int) -> [Run] {
        var out: [Run] = []
        for y in 0..<d {
            var x = 0
            while x < d {
                let k = kind(2 * x + 1 - d, 2 * y + 1 - d)
                var e = x + 1
                while e < d && kind(2 * e + 1 - d, 2 * y + 1 - d) == k { e += 1 }
                if k >= 0 { out.append(Run(x: x, y: y, w: e - x, kind: k)) }
                x = e
            }
        }
        return out
    }
}

/** Largest 4:3 rectangle centred in [r] (programs keep their 640x480 aspect). */
public func fit43(_ r: Rect) -> Rect { fitAspect(r, 4, 3) }

/** Largest rectangle of aspect [aw]:[ah] centred in [r] (a program window keeps its shape). */
public func fitAspect(_ r: Rect, _ aw: Int, _ ah: Int) -> Rect {
    var w = r.w, h = w * ah / max(1, aw)
    if h > r.h { h = r.h; w = h * aw / max(1, ah) }
    return Rect(r.x + (r.w - w) / 2, r.y + (r.h - h) / 2, w, h)
}

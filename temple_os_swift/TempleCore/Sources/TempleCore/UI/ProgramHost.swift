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

public final class GameControls {
    /**
     * A button. Key buttons ([ch], [sc]) are physical keys: down while held, typematic repeat, up on
     * release (menu shortcuts too: the button stands for the key the menu names). [wheel] buttons turn
     * the mouse wheel one notch per press and repeat; modifier keys never repeat (KbdBuildSC).
     */
    private final class Btn {
        let label: String, rect: Rect, ch: Int, sc: Int64, a11y: String?, toggle: (() -> Void)?, wheel: Int
        init(_ label: String, _ rect: Rect, _ ch: Int, _ sc: Int64, _ a11y: String? = nil, toggle: (() -> Void)? = nil, wheel: Int = 0) {
            self.label = label; self.rect = rect; self.ch = ch; self.sc = sc; self.a11y = a11y; self.toggle = toggle; self.wheel = wheel
        }
    }
    private let send: (KInput) -> Void
    private var buttons: [Btn] = []
    private var held: [Int: Btn] = [:]  // pointer id -> held button
    private var heldSince: [Int: Int64] = [:] // pointer id -> first tick time (-1 until then)
    private var lastRepeat: [Int: Int64] = [:]
    private var ticket: [Int: Int64] = [:]
    private let typematic: Typematic
    /** What a touch on the picture is: 0 left button, 1 right button, 2 pointer move only (hover). */
    public var clickMode = 0
    public var rightClick: Bool { clickMode == 1 }
    /** Turns the mouse wheel by one notch (BattleLines reads ms.pos.z). */
    public var onWheel: (Int) -> Void = { _ in }
    public static let REPEAT_DELAY_MS: Int64 = 250
    public static let REPEAT_PERIOD_MS: Int64 = 33

    /**
     * Typematic repeat for held key buttons, like a PC keyboard: TempleOS boots with
     * KbdTypeMatic(0) (HomeLocalize.HC) = 250 ms delay, then 30 key-downs per second.
     * Games that move one step per key message (GetKey: CastleFrankenstein) need it.
     */
    public func tick(_ nowMs: Int64) {
        for (id, b) in held {
            if b.toggle != nil || isModifier(b) { continue }
            if b.wheel == 0 && !typematic.repeats(ticket[id] ?? -1) { continue }
            guard let since = heldSince[id] else { continue }
            if since < 0 { heldSince[id] = nowMs; lastRepeat[id] = nowMs + GameControls.REPEAT_DELAY_MS - GameControls.REPEAT_PERIOD_MS; continue }
            if nowMs - since < GameControls.REPEAT_DELAY_MS { continue }
            var last = lastRepeat[id] ?? since
            var n = 0
            while nowMs - last >= GameControls.REPEAT_PERIOD_MS && n < 2 { press(b); last += GameControls.REPEAT_PERIOD_MS; n += 1 }
            if nowMs - last >= GameControls.REPEAT_PERIOD_MS { last = nowMs } // do not queue a burst after a stall
            lastRepeat[id] = last
        }
    }

    public init(_ typematic: Typematic = Typematic(), _ send: @escaping (KInput) -> Void) { self.typematic = typematic; self.send = send }

    /** Screen-reader nodes for the buttons drawn last (label, toggle state). */
    public func accessibility(_ add: (Rect, String, Bool) -> Void) {
        for b in buttons {
            let label: String
            if let a = b.a11y { label = a } else {
                switch b.label {
                case "\u{18}": label = tr("key.up"); case "\u{19}": label = tr("key.down"); case "\u{1B}": label = tr("key.left"); case "\u{1A}": label = tr("key.right")
                case "SPACE": label = tr("key.space"); case "ENTER": label = tr("key.enter"); case "ESC": label = tr("key.escape")
                case "L-CLICK": label = tr("controls.a11y.left_click"); case "R-CLICK": label = tr("controls.a11y.right_click")
                case "MOVE": label = tr("controls.a11y.hover")
                default: label = Cp437.decode(b.label)
                }
            }
            add(b.rect, label, b.toggle != nil && clickMode != 0)
        }
    }

    /**
     * Lays out controls in [r] and draws them into [s]. With [actionArea] (landscape: the gutter right
     * of the picture) the action buttons go there instead of next to the d-pad.
     */
    public func draw(_ s: Surface, _ r: Rect, _ menu: [MenuSnap], vertical: Bool, showDpad: Bool, actionArea: Rect? = nil,
                     info: ProgramInfo? = nil) {
        buttons.removeAll()
        if r.w < 40 || r.h < 40 { return }
        let size = min(44, min(r.w, r.h) / 3)
        let pad = Rect(r.x + 4, vertical ? r.y + 4 : r.y + (r.h - size * 3) / 2, size * 3, size * 3)
        if showDpad {
            add("\u{18}", Rect(pad.x + size, pad.y, size, size), Keys.SC_CURSOR_UP)
            add("\u{1B}", Rect(pad.x, pad.y + size, size, size), Keys.SC_CURSOR_LEFT)
            add("\u{1A}", Rect(pad.x + 2 * size, pad.y + size, size, size), Keys.SC_CURSOR_RIGHT)
            add("\u{19}", Rect(pad.x + size, pad.y + 2 * size, size, size), Keys.SC_CURSOR_DOWN)
        }
        // action buttons: next to the pad, or in [actionArea]
        var actions: [(String, Int, Int64)] = []
        actions.append(("SPACE", 32, Keys.forChar(32).1))
        actions.append(("ENTER", 10, Keys.special(Keys.SC_ENTER).1))
        actions.append(("ESC", Keys.CH_ESC, Keys.special(Keys.SC_ESC).1))
        let arrows = [Keys.SC_CURSOR_UP, Keys.SC_CURSOR_DOWN, Keys.SC_CURSOR_LEFT, Keys.SC_CURSOR_RIGHT]
        let menuKeys = Array(menu.filter { !$0.isDir && ($0.a1 != 0 || $0.a2 != 0) && $0.msgCode == -2 }
            .filter { m in !actions.contains { Int64($0.1) == m.a1 && m.a1 != 0 } }
            .filter { m in !arrows.contains(Int(m.a2 & 0x7F)) }
            .prefix(6))
        // keys and mouse parts the program needs that a phone lacks (catalog: source-derived)
        var extras: [Btn] = []
        if info?.usesCtrl == true { extras.append(Btn("CTRL", Rect(0, 0, 0, 0), 0, Int64(Keys.SC_CTRL), tr("key.control"))) }
        if info?.usesShift == true { extras.append(Btn("SHIFT", Rect(0, 0, 0, 0), 0, Int64(Keys.SC_SHIFT), tr("key.shift"))) }
        if info?.usesWheel == true {
            extras.append(Btn("WHL+", Rect(0, 0, 0, 0), 0, 0, tr("controls.a11y.wheel_up"), wheel: 1))
            extras.append(Btn("WHL-", Rect(0, 0, 0, 0), 0, 0, tr("controls.a11y.wheel_down"), wheel: -1))
        }
        let area = actionArea ?? r
        let x0 = actionArea != nil ? area.x + 4 : showDpad ? pad.right + 8 : r.x + 4
        // a separate gutter holds one or two columns; next to the pad, up to three per row
        let bw = actionArea != nil ? min(area.w - 4 >= 2 * 56 ? (area.w - 4) / 2 : area.w - 4, 96)
            : min(max(56, (r.w - (showDpad ? pad.w + 12 : 4)) / 3), 96)
        var bx = x0
        var by: Int
        if actionArea != nil {
            let count = actions.count + menuKeys.count + extras.count + 1
            let rows = (count + max(1, (area.w - 4) / bw) - 1) / max(1, (area.w - 4) / bw)
            by = area.y + max(4, (area.h - rows * (Touch.button + 4)) / 2)
        } else { by = showDpad ? pad.y : r.y + 4 }
        func place() -> Rect {
            if bx + bw > area.right { bx = x0; by += Touch.button + 4 }
            let rr = Rect(bx, by, bw - 4, Touch.button); bx += bw; return rr
        }
        for (l, ch, sc) in actions { add(l, place(), -1, ch, sc) }
        for m in menuKeys {
            let (ch, sc) = menuKey(m.a1, m.a2)
            buttons.append(Btn(m.label.take(10), place(), ch, sc))
        }
        for b in extras { buttons.append(Btn(b.label, place(), b.ch, b.sc, b.a11y, wheel: b.wheel)) }
        buttons.append(Btn(clickMode == 1 ? "R-CLICK" : clickMode == 2 ? "MOVE" : "L-CLICK", place(), 0, 0,
                           toggle: { [unowned self] in clickMode = (clickMode + 1) % 3 }))
        for b in buttons {
            let pressed = held.values.contains { $0 === b }
            let on = b.toggle != nil && clickMode != 0
            s.templeButton(b.rect, b.label, pressed ? ButtonFace.PRESSED : on ? ButtonFace.SELECTED : ButtonFace.NORMAL)
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

    private func add(_ label: String, _ rect: Rect, _ scCode: Int, _ ch: Int = 0, _ sc: Int64 = 0) {
        if scCode >= 0 {
            let (c, s) = Keys.special(scCode)
            buttons.append(Btn(label, rect, c, s))
        } else { buttons.append(Btn(label, rect, ch, sc)) }
    }

    /** Returns true if the pointer hit a control. */
    public func pointer(_ e: PointerEvent) -> Bool {
        switch e.action {
        case Ptr.DOWN:
            guard let b = buttons.first(where: { $0.rect.contains(e.x, e.y) }) else { return false }
            if let toggle = b.toggle { toggle(); return true }
            held[e.id] = b; heldSince[e.id] = -1; lastRepeat[e.id] = nil
            if b.wheel == 0 && !isModifier(b) { ticket[e.id] = typematic.pressed() }
            press(b)
            return true
        case Ptr.UP, Ptr.CANCEL:
            heldSince[e.id] = nil; lastRepeat[e.id] = nil; ticket[e.id] = nil
            guard let b = held.removeValue(forKey: e.id) else { return false }
            if b.wheel == 0 { send(.key(ch: b.ch, sc: b.sc | Keys.SCF_KEY_UP, down: false)) }
            return true
        case Ptr.MOVE: return held[e.id] != nil
        default: return false
        }
    }

    /**
     * The current layout has no control area (landscape gutters under 96 px, console view): forget the
     * last layout's buttons. They are hit-tested before the picture, so leftovers were invisible keys and
     * a tap beside the picture could send Abort (Shift-Esc) and end the program. Held keys stay held
     * until their finger lifts.
     */
    public func clearLayout() { buttons.removeAll() }

    /** Releases everything (focus loss, rotation) so no key stays stuck. */
    public func releaseAll() {
        for b in held.values where b.wheel == 0 { send(.key(ch: b.ch, sc: b.sc | Keys.SCF_KEY_UP, down: false)) }
        held.removeAll(); heldSince.removeAll(); lastRepeat.removeAll()
    }

    public var anyHeld: Bool { !held.isEmpty }
}

/** Largest 4:3 rectangle centred in [r] (programs keep their 640x480 aspect). */
public func fit43(_ r: Rect) -> Rect { fitAspect(r, 4, 3) }

/** Largest rectangle of aspect [aw]:[ah] centred in [r] (a program window keeps its shape). */
public func fitAspect(_ r: Rect, _ aw: Int, _ ah: Int) -> Rect {
    var w = r.w, h = w * ah / max(1, aw)
    if h > r.h { h = r.h; w = h * aw / max(1, ah) }
    return Rect(r.x + (r.w - w) / 2, r.y + (r.h - h) / 2, w, h)
}

import OSLog
import TempleCore
import UIKit

/** Input events that change what is on screen (why the TempleOS keyboard stepped aside, back gestures). */
let inputLog = Logger(subsystem: "io.github.templeosmobile", category: "input")

/**
 * Draws the shell's indexed framebuffer scaled by an integer factor (nearest
 * neighbour) plus program frames as sublayers, and turns touches, the TempleOS keyboard and hardware keys into shell events. Main thread only.
 */
final class TempleView: UIView {
    let shell: Shell
    private var scale = 3
    private var displayLink: CADisplayLink?
    private var drawnVersion: Int64 = -1
    private var rgba: UnsafeMutablePointer<UInt32>?
    private var rgbaCount = 0
    private var frameLayers: [ObjectIdentifier: FrameLayer] = [:]
    private var touchIds: [ObjectIdentifier: Int] = [:]
    private var nextTouchId = 1
    private var idleFrames = 0
    let keyboardDiagnostics = NativeKeyboardDiagnostics()
    private var physicalEvents = 0
    private var physicalTrail: [String] = []
    private var lastPhysicalHID = -1
    private var lastPhysicalModifiers: Int = 0
    private var commandHeld = Set<Int>()
    private var physicalDown: [Int: (Int, Int64)] = [:]
    var onFirstLayout: (() -> Void)?
    /** Called once per frame step (the view controller follows focus for system-gesture settings). */
    var onStep: (() -> Void)?

    /**
     * Localized UI text the TempleOS font cannot show (Surface.TextRun): drawn by UIKit's text
     * engine (shaping, bidi, font fallback) at device resolution, above the framebuffer and below
     * program frames, clipped to its row and hidden under every window, menu or keyboard drawn
     * after it (Surface.Occluder).
     */
    private final class TextRunLayer: CALayer {
        var runs: [Surface.TextRun] = []
        var occluders: [Surface.Occluder] = []
        var k: CGFloat = 1

        override func draw(in ctx: CGContext) {
            UIGraphicsPushContext(ctx); defer { UIGraphicsPopContext() }
            func cg(_ r: Rect) -> CGRect { CGRect(x: CGFloat(r.x) * k, y: CGFloat(r.y) * k, width: CGFloat(r.w) * k, height: CGFloat(r.h) * k) }
            for r in runs {
                // visible part of the run: its clip minus every occluder above it
                var visible = [cg(r.clip)]
                for o in occluders where o.z > r.z {
                    let cut = cg(o.rect)
                    visible = visible.flatMap { TextRunLayer.subtract($0, cut) }
                    if visible.isEmpty { break }
                }
                if visible.isEmpty { continue }
                let color = TempleView.color(r.fg)
                // menu text is magnified like the TempleOS glyphs beside it (TextRun.scale); its line is centred on
                // the 8-row TempleOS text row, and ink that would leave the part of the row's box that stays
                // visible (Surface.runInkBox) is moved inside it, or the size reduced just enough
                // (docs/typography/TEMPLEOS_TYPOGRAPHY.md §4)
                let (bt, bb) = Surface.runInkBox(r, occluders)
                let boxTop = CGFloat(bt) * k, boxBottom = CGFloat(bb) * k
                let fit = TextRunFont.fit(r.text, size: 10 * k * CGFloat(r.scale), maxInk: boxBottom - boxTop, color: color)
                let x = r.rtl ? CGFloat(r.x + r.w) * k - fit.width : CGFloat(r.x) * k
                // the line (ascent above the baseline, descent below) centred on the row
                var base = CGFloat(r.y + 4 * r.scale) * k + (fit.ascent - fit.descent) / 2
                if base + fit.inkTop < boxTop { base = boxTop - fit.inkTop }
                if base + fit.inkBottom > boxBottom { base = boxBottom - fit.inkBottom }
                ctx.saveGState()
                ctx.clip(to: visible)
                ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1) // UIKit's context is flipped
                ctx.textPosition = CGPoint(x: x, y: base)
                CTLineDraw(fit.line, ctx)
                ctx.restoreGState()
            }
        }

        /** [a] minus [b] as up to four rectangles. */
        static func subtract(_ a: CGRect, _ b: CGRect) -> [CGRect] {
            let i = a.intersection(b)
            if i.isNull || i.isEmpty { return [a] }
            var out: [CGRect] = []
            if i.minY > a.minY { out.append(CGRect(x: a.minX, y: a.minY, width: a.width, height: i.minY - a.minY)) }
            if i.maxY < a.maxY { out.append(CGRect(x: a.minX, y: i.maxY, width: a.width, height: a.maxY - i.maxY)) }
            if i.minX > a.minX { out.append(CGRect(x: a.minX, y: i.minY, width: i.minX - a.minX, height: i.height)) }
            if i.maxX < a.maxX { out.append(CGRect(x: i.maxX, y: i.minY, width: a.maxX - i.maxX, height: i.height)) }
            return out
        }
    }

    private let textLayer = TextRunLayer()

    /**
     * The device pixels below the integer-scaled surface (the view's background covers those to its
     * right): filled in the bottom gutter color, so the home-indicator region has no seam.
     */
    private let remainderLayer = CALayer()

    /**
     * The view and window backgrounds follow the shell's SystemChrome: whatever the integer-scaled
     * surface or a rotation leaves uncovered continues the TempleOS gutters instead of showing black.
     * Applied only when it changes.
     */
    private lazy var chromeGate = ChangeGate<SystemChrome> { [weak self] c in
        guard let self else { return }
        self.backgroundColor = TempleView.color(c.side)
        self.window?.backgroundColor = TempleView.color(c.side)
        self.remainderLayer.backgroundColor = TempleView.color(c.bottom).cgColor
    }

    /** A TempleOS palette color as a UIColor (text runs, SystemChrome backgrounds): never a system color. */
    static func color(_ index: Int) -> UIColor {
        let c = UInt32(bitPattern: Palette.STD[index & 15])
        return UIColor(red: CGFloat((c >> 16) & 0xFF) / 255, green: CGFloat((c >> 8) & 0xFF) / 255, blue: CGFloat(c & 0xFF) / 255, alpha: 1)
    }

    private final class FrameLayer {
        let layer = CALayer()
        var version: Int64 = -1
        let idx: UnsafeMutablePointer<UInt8>
        let rgba: UnsafeMutablePointer<UInt32>
        let w: Int, h: Int
        init(w: Int, h: Int) {
            self.w = w; self.h = h
            idx = .allocate(capacity: w * h); idx.initialize(repeating: 0, count: w * h)
            rgba = .allocate(capacity: w * h); rgba.initialize(repeating: 0, count: w * h)
            layer.actions = ["contents": NSNull(), "frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
        }
        deinit { idx.deallocate(); rgba.deallocate() }
    }

    init(shell: Shell) {
        self.shell = shell
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        // VoiceOver sees the shell's buttons, keys and text as separate elements (see
        // accessibilityElements); UI tests read the logical-pixel layout from accessibilityValue.
        isAccessibilityElement = false
        accessibilityIdentifier = "templeView"
        accessibilityLabel = "TempleOS desktop"
        backgroundColor = .black
        layer.magnificationFilter = .nearest
        layer.actions = ["contents": NSNull()]
        textLayer.actions = ["contents": NSNull(), "frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
        textLayer.contentsScale = 1 // set to the view's display scale on every render
        layer.addSublayer(textLayer) // program frame layers are added later, above it
        remainderLayer.actions = ["backgroundColor": NSNull(), "frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer.addSublayer(remainderLayer)
        DisplayContextAdapter.observeHinge(self)
        keyboardDiagnostics.context = { [weak self] in
            guard let self else { return "view-released" }
            return "target=\(self.shell.inputTarget) generation=\(self.shell.inputGeneration) responder=\(self.isFirstResponder ? "TempleView" : "controller-chain")"
        }
        keyboardDiagnostics.changed = { [weak self] in self?.publishKeyboardState(); self?.kick() }
        // every change of the TempleOS keyboard's visibility, with its reason (docs/foldable/KEYBOARD_LIFECYCLE.md)
        shell.onKeyboardTransition = { [weak self] t in
            inputLog.info("TempleOS keyboard #\(t.seq, privacy: .public): \(t.shown ? "shown" : "hidden", privacy: .public), reason \(t.reason.rawValue, privacy: .public)")
            self?.publishKeyboardState()
        }
    }

    /** The accessibility value's layout part (relayout) and keyboard part (UI tests read both). */
    private var layoutValue = ""
    private var publishedInputLease: Shell.InputLease?

    /** Publishes the TempleOS keyboard's state for UI tests: shown, transition count, last reason. */
    private func publishKeyboardState() {
        let last = shell.keyboardTransitions.last
        let kb = ";kb=\(shell.templeKeyboardShown ? 1 : 0);kbSeq=\(shell.keyboardTransitionCount);kbWhy=\(last?.reason.rawValue ?? "-")"
        let perf = (accessibilityValue ?? "").components(separatedBy: ";perf=").dropFirst().first.map { ";perf=" + $0 } ?? ""
        accessibilityValue = layoutValue + kb + ";nativeKeyboardViolations=\(keyboardDiagnostics.violations);inputTarget=\(shell.inputTarget);inputGeneration=\(shell.inputGeneration);physicalEvents=\(physicalEvents);lastHID=\(lastPhysicalHID);lastModifiers=\(lastPhysicalModifiers);physicalTrail=\(physicalTrail.joined(separator: ","))" + perf
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { rgba?.deallocate() }

    // MARK: layout

    override func layoutSubviews() {
        super.layoutSubviews()
        relayout()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        relayout()
    }

    /**
     * Device pixels per point of the display this view is on. Not `contentScaleFactor`: that is this view's own
     * `layer.contentsScale`, which `render` sets to 1/k so the framebuffer image maps one logical pixel to k
     * points; reading it back returned 1 on a 3x iPhone, and the text-run layer, sized from it, drew localized
     * text at a third of the display's resolution for the compositor to stretch (blurry non-English labels).
     */
    var deviceScale: CGFloat {
        let s = traitCollection.displayScale
        // before the view joins a window its traits have no scale yet: its scene's screen, else 1
        return s > 0 ? s : (window?.windowScene?.screen.scale ?? 1)
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.displayScale != traitCollection.displayScale { relayout() }
    }

    /**
     * Measures the view (DisplayContextAdapter) and lays the shell out for it. Called on every layout pass,
     * safe-area or display-scale change; the shell ignores a geometry equal to the last one, so the many
     * passes of a fold or rotation animation cost nothing. The integer scale comes from the shared policy
     * (DisplayLayout.scale): one logical px per pt on phones and on an unfolded foldable, more on tablets.
     */
    func relayout() {
        let px = deviceScale
        let w = Int(bounds.width * px), h = Int(bounds.height * px)
        if w <= 0 || h <= 0 { return }
        scale = DisplayLayout.scale(pxW: w, pxH: h, displayScale: Double(px), chosen: shell.settings.uiScale)
        // Shell keeps content above max(insetBottom, keyboard), both measured in points from the
        // bottom edge (V-33: was pixels minus points, then scaled by px again)
        let g = DisplayContextAdapter.measure(self, scale: scale, displayScale: px, keyboardPt: 0)
        let changed = shell.apply(g)
        // UI tests read the layout here (points per logical px: the menu layer sizes its text and touch targets from it)
        layoutValue = "pointsPerLogical=\(g.dpPerPx);top=\(g.top);left=\(g.left);bottom=\(g.bottom);right=\(g.right);width=\(g.width);height=\(g.height)"
            + ";windowed=\(shell.windowed ? 1 : 0);barLeft=\(g.barLeft);barRight=\(g.barRight)"
            + ";div=\(DisplayContextAdapter.list(g.divisions));occ=\(DisplayContextAdapter.list(g.occlusions))"
        publishKeyboardState()
        if changed { drawnVersion = -1 }
        if let f = onFirstLayout { onFirstLayout = nil; f() }
        if changed { kick() }
    }

    // MARK: frame loop

    func resume() { acquireHardwareFocus(); kick() }

    func pause() {
        displayLink?.invalidate(); displayLink = nil
        idleTimer?.invalidate(); idleTimer = nil
    }

    private var idleTimer: Timer?

    /** Ensures the frame loop runs at display rate (any thread). */
    func kick() {
        if !Thread.isMainThread { DispatchQueue.main.async { self.kick() }; return }
        idleFrames = 0
        idleTimer?.invalidate(); idleTimer = nil
        if displayLink == nil {
            loopRestarted = true
            let dl = CADisplayLink(target: self, selector: #selector(onDisplayLink))
            dl.add(to: .main, forMode: .common)
            displayLink = dl
        }
    }

    /** The next display-link callback follows an idle pause, not a stall (UiFrameStats). */
    private var loopRestarted = true
    private var perfPublished = ""

    @objc private func onDisplayLink() {
        shell.uiFrames.frame(Int64(DispatchTime.now().uptimeNanoseconds), restarted: loopRestarted); loopRestarted = false
        let overlays = step()
        if Shell.perfLog && shell.lastPerfLine != perfPublished {
            // UI tests read the perf line from the view's accessibility value
            perfPublished = shell.lastPerfLine
            let base = (accessibilityValue ?? "").components(separatedBy: ";perf=")[0]
            accessibilityValue = base + ";perf=" + perfPublished
        }
        // Programs and consoles publish without notifying. After a second without
        // changes and with no program frames on screen, stop the display link and
        // poll at 10 Hz instead (as Android does); any input or change restarts it.
        if overlays.isEmpty && idleFrames > 60 {
            displayLink?.invalidate(); displayLink = nil
            idleTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self else { return }
                if self.step().isEmpty == false || self.idleFrames == 0 { self.kick() }
            }
        }
    }

    /** One frame: tick the shell, render if anything changed. Returns the current overlays. */
    @discardableResult private func step() -> [Overlay] {
        var changed = shell.tick()
        if publishedInputLease != shell.inputLease { publishedInputLease = shell.inputLease; publishKeyboardState() }
        onStep?()
        let overlays = shell.overlays()
        for o in overlays where o.source.frameVersion != frameLayers[ObjectIdentifier(o.source)]?.version { changed = true }
        if changed {
            render(overlays); idleFrames = 0
            // push changes only to a running VoiceOver; otherwise elements are built on demand
            if UIAccessibility.isVoiceOverRunning { a11y.sync() }
        } else { idleFrames += 1 }
        return overlays
    }

    private func render(_ overlays: [Overlay]) {
        let s = shell.surface
        let sw = s.width, sh = s.height
        if drawnVersion != s.version {
            if rgbaCount != sw * sh {
                rgba?.deallocate()
                rgbaCount = sw * sh
                rgba = .allocate(capacity: rgbaCount)
            }
            let out = rgba!
            let pal = Palette.STD.map { argbToRGBA($0) }
            let px = s.px
            for i in 0..<rgbaCount { out[i] = pal[Int(px[i] & 15)] }
            layer.contents = makeImage(out, sw, sh)
            drawnVersion = s.version
            let surfaceBottom = CGFloat(sh * scale) / deviceScale
            remainderLayer.frame = CGRect(x: 0, y: surfaceBottom, width: bounds.width, height: max(0, bounds.height - surfaceBottom))
            chromeGate.offer(shell.systemChrome)
            textLayer.runs = s.runs
            textLayer.occluders = s.occluders
            textLayer.k = CGFloat(scale) / deviceScale
            textLayer.frame = bounds
            textLayer.contentsScale = deviceScale // rasterized at the display's own resolution
            textLayer.setNeedsDisplay()
        }
        let px = deviceScale
        let k = CGFloat(scale) / px
        layer.contentsGravity = .topLeft
        layer.contentsScale = 1 / k
        var live = Set<ObjectIdentifier>()
        for o in overlays {
            let src = o.source
            let id = ObjectIdentifier(src)
            live.insert(id)
            let fl = frameLayers[id] ?? {
                let f = FrameLayer(w: src.frameW, h: src.frameH)
                layer.addSublayer(f.layer)
                frameLayers[id] = f
                return f
            }()
            if fl.version != src.frameVersion {
                fl.version = src.copyFrame(fl.idx)
                let pal = src.palette.map { argbToRGBA($0) }
                for i in 0..<(fl.w * fl.h) { fl.rgba[i] = pal[Int(fl.idx[i] & 15)] }
                fl.layer.contents = makeImage(fl.rgba, fl.w, fl.h)
            }
            let r = o.rect
            fl.layer.frame = CGRect(x: CGFloat(r.x) * k, y: CGFloat(r.y) * k, width: CGFloat(r.w) * k, height: CGFloat(r.h) * k)
            // the program's TempleOS window within the 640x480 frame (unit coordinates)
            let fw = CGFloat(src.frameW), fh = CGFloat(src.frameH)
            fl.layer.contentsRect = CGRect(x: CGFloat(o.src.x) / fw, y: CGFloat(o.src.y) / fh, width: CGFloat(o.src.w) / fw, height: CGFloat(o.src.h) / fh)
            let filter: CALayerContentsFilter = shell.settings.crispScaling ? .nearest : .linear
            fl.layer.magnificationFilter = filter
            fl.layer.minificationFilter = filter
        }
        for (id, fl) in frameLayers where !live.contains(id) { fl.layer.removeFromSuperlayer(); frameLayers[id] = nil }
    }

    private func argbToRGBA(_ c: Int32) -> UInt32 {
        let v = UInt32(bitPattern: c)
        let r = (v >> 16) & 0xFF, g = (v >> 8) & 0xFF, b = v & 0xFF
        return r | (g << 8) | (b << 16) | 0xFF00_0000 // little-endian RGBA in memory
    }

    private func makeImage(_ p: UnsafeMutablePointer<UInt32>, _ w: Int, _ h: Int) -> CGImage? {
        let data = Data(bytes: p, count: w * h * 4) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: touch

    private func send(_ t: UITouch, _ action: Int) {
        let id = ObjectIdentifier(t)
        let tid: Int
        if let v = touchIds[id] { tid = v } else { tid = nextTouchId; nextTouchId += 1; touchIds[id] = tid }
        let p = t.location(in: self)
        let k = deviceScale / CGFloat(scale)
        shell.pointer(PointerEvent(action, Int(p.x * k), Int(p.y * k), id: tid, timeMs: max(1, Int64(t.timestamp * 1000))))
        if action == Ptr.UP || action == Ptr.CANCEL { touchIds[id] = nil }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { touches.forEach { send($0, Ptr.DOWN) }; kick() }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { touches.forEach { send($0, Ptr.MOVE) }; kick() }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { touches.forEach { send($0, Ptr.UP) }; kick() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { touches.forEach { send($0, Ptr.CANCEL) }; kick() }

    // MARK: input adapters

    override var canBecomeFirstResponder: Bool { true }

    /** First-responder status is for physical press events only; this view has no text-entry conformance. */
    func acquireHardwareFocus() { if window != nil { _ = becomeFirstResponder() } }
    func releasePhysicalKeys() { physicalDown.removeAll(); commandHeld.removeAll(); shell.releaseInputOwnership() }

    override var keyCommands: [UIKeyCommand]? {
        let back = UIKeyCommand(input: ".", modifierFlags: .command, action: #selector(templeBackCommand))
        let paste = UIKeyCommand(input: "v", modifierFlags: .command, action: #selector(templePasteCommand))
        back.wantsPriorityOverSystemBehavior = true; paste.wantsPriorityOverSystemBehavior = true
        return [back, paste]
    }
    @objc private func templeBackCommand() { _ = shell.back(); kick() }
    @objc private func templePasteCommand() { shell.pasteClipboard(); kick() }

    func handlePresses(_ presses: Set<UIPress>, down: Bool) -> Bool {
        var handled = false
        for p in presses {
            guard let key = p.key else { continue }
            physicalEvents += 1
            if ProcessInfo.processInfo.arguments.contains("-input-diagnostics") {
                lastPhysicalHID = key.keyCode.rawValue; lastPhysicalModifiers = key.modifierFlags.rawValue
                physicalTrail.append("\(key.keyCode.rawValue):\(key.modifierFlags.rawValue):\(down ? 1 : 0)")
                if physicalTrail.count > 16 { physicalTrail.removeFirst() }
            }
            publishKeyboardState()
            let hid = key.keyCode.rawValue
            // Some press sources send modifier flags only on the modifier's own event.
            // Track HID state too, and consume GUI events so the responder chain does not deliver them twice.
            if hid == 227 || hid == 231 {
                if down { commandHeld.insert(hid) } else { commandHeld.remove(hid) }
                handled = true; continue
            }
            var heldModifiers: UIKeyModifierFlags = []
            if physicalDown.keys.contains(225) || physicalDown.keys.contains(229) { heldModifiers.insert(.shift) }
            if physicalDown.keys.contains(224) || physicalDown.keys.contains(228) { heldModifiers.insert(.control) }
            if physicalDown.keys.contains(226) || physicalDown.keys.contains(230) { heldModifiers.insert(.alternate) }
            if !commandHeld.isEmpty { heldModifiers.insert(.command) }
            if key.modifierFlags.union(heldModifiers).contains(.command), hid == 55 || hid == 25 {
                if down, physicalDown[hid] == nil {
                    physicalDown[hid] = (0, 0)
                    if hid == 55 { _ = shell.back() } else { shell.pasteClipboard() }
                } else if !down { physicalDown[hid] = nil }
                handled = true; continue
            }
            guard let (ch, sc) = HardwareKeyAdapter.map(key, heldModifiers: heldModifiers) else { continue }
            if down {
                if physicalDown[hid] == nil {
                    physicalDown[hid] = (ch, sc)
                    shell.hardwareKey(ch, sc, true)
                }
            } else if let held = physicalDown.removeValue(forKey: hid) {
                // Left/right modifiers share TempleOS's normalized scan code; lift only the last one.
                if !physicalDown.values.contains(where: { $0.1 & 255 == held.1 & 255 }) {
                    shell.hardwareKey(held.0, held.1, false)
                }
            }
            handled = true
        }
        if handled { kick() }
        return handled
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !handlePresses(presses, down: true) { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !handlePresses(presses, down: false) { super.pressesEnded(presses, with: event) }
    }

    /** A cancelled press (the app lost the keyboard) is a release: no key may stay down in a program. */
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !handlePresses(presses, down: false) { super.pressesCancelled(presses, with: event) }
    }

    // MARK: accessibility (AccessibilityAdapter)

    private lazy var a11y = AccessibilityAdapter(self)
    var pointsPerLogical: CGFloat { CGFloat(scale) / deviceScale }

    override var accessibilityElements: [Any]? {
        get { a11y.sync(); return a11y.elements }
        set {}
    }

    /** VoiceOver's two-finger scrub: close the topmost menu, dialog or keyboard. */
    override func accessibilityPerformEscape() -> Bool { inputLog.info("VoiceOver escape: back"); let r = shell.back(); kick(); return r }
}

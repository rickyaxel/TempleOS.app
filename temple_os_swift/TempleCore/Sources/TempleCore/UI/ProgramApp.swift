import Foundation

// Port of ui/ProgramApp.kt.

/**
 * Runs one HolyC program in its own kernel (isolated VM, arena and thread).
 * Graphics programs show their 640x480 screen scaled with its aspect ratio;
 * console programs show their document. [source] overrides the file contents
 * (used by the editor to run unsaved code).
 */
public final class ProgramApp: App {
    public let path: String
    public let info: ProgramInfo?
    private let source: [UInt8]?
    /** Pure Swift: the program's translation; nil runs it on the HolyC interpreter (Pure Terry). */
    public let native: NativeBinding?

    override public var kind: String { "program" }
    /** Game controls sit near the bottom edge (iOS: the home gesture is deferred while focused). */
    override public var defersEdgeGestures: Bool { true }
    override public var title: String {
        (info?.title ?? InputCharacterPolicy.display(path.substringAfterLast("/").substringBefore("."))) +
            (native != nil ? " \u{00B7} " + Engines.NATIVE_NAME : "") +
            (finished ? tr("program.title_suffix.ended") : runner.paused ? tr("program.title_suffix.paused") : "")
    }

    // Initialized in init (they capture self).
    private var env: UiKernelEnv!
    public private(set) var kernel: Kernel!
    private var runner: KernelRunner!
    private var frame: KernelFrame!
    private let consoleView = ConsoleView()
    private var controls: GameControls!
    private var finished = false // Kotlin @Volatile
    private var documentLinks:[(Rect,OriginalProgramLink)]=[]
    private var showConsole = false
    private var keyboardRequested = false
    private var lastConsoleVersion: Int64 = -1
    private var lastFrameVersion: Int64 = -1
    private var canvasRect = Rect(0, 0, 0, 0)
    /** The program's TempleOS window in the 640x480 screen, as shown in [canvasRect]. */
    private var shownWindow = Rect(0, 0, Kernel.W, Kernel.H)
    private var started = false
    private var wasBooting = false
    /** Per finger: 1 = drives the TempleOS mouse (one finger at a time), 2 = on the controls. */
    private var pointerModes: [Int: Int] = [:]
    /** Where the last touch put the TempleOS pointer and its buttons (wheel notches keep them). */
    private var lastPointer = (Kernel.W / 2, Kernel.H / 2) // TempleOS starts the pointer mid-screen
    private var lastButtons = (false, false)

    public init(_ shell: Shell, _ path: String, _ info: ProgramInfo?, _ source: [UInt8]? = nil, native: NativeBinding? = nil) {
        self.path = path; self.info = info; self.source = source; self.native = native
        super.init(shell)
        env = UiKernelEnv(shell) { [weak self] in
            guard let self = self else { return false }
            return self.liveShell?.focused?.app === self
        }
        kernel = Kernel(env, path.substringAfterLast("/"))
        kernel.native = native
        runner = KernelRunner(kernel) { [weak self] in
            self?.liveShell?.post { [weak self] in self?.invalidate() }
        }
        frame = KernelFrame(kernel)
        controls = GameControls(shell.typematic) { [weak self] e in
            guard let self = self else { return }
            self.kernel.post(e); self.runner.wake()
        }
        controls.onWheel = { [weak self] d in
            guard let self = self else { return }
            self.kernel.post(.mouse(x: self.lastPointer.0, y: self.lastPointer.1, lb: self.lastButtons.0, rb: self.lastButtons.1, wheel: d))
            self.runner.wake()
        }
        start()
    }

    private func start() {
        started = true
        let path = self.path, source = self.source
        runner.start { [weak self] k in
            let data = source ?? self?.shell.fs.readFile(path)
            guard let data = data else { k.console.write("$RED$" + L10n.tr8("program.file_not_found", ("path", path)) + "$FG$\n"); k.terminate("not found"); return }
            try k.runProgram(path, data)
        }
    }

    public var isFinished: Bool { kernel.finished || !runner.alive }

    override public var rawKeys: Bool { !isFinished }

    override public var wantsKeyboard: Bool {
        keyboardRequested || (info?.prefersFullKeyboard == true && !isFinished) || kernel.console.inputLine != nil ||
            (runner.booted && !kernel.graphicsUsed && !isFinished && kernel.waitingForKey)
    }

    override public func tick(_ nowMs: Int64) -> Bool {
        env.refresh()
        controls.tick(nowMs)
        var d = false
        if isFinished && !finished { finished = true; controls.releaseAll(); d = true }
        let cv = kernel.console.version
        if cv != lastConsoleVersion { lastConsoleVersion = cv; if !kernel.graphicsUsed || showConsole { d = true } }
        if kernel.graphicsUsed && frame.frameVersion != lastFrameVersion { lastFrameVersion = frame.frameVersion; d = true }
        // "Starting..." is static: redraw when the boot state changes, not every tick
        let booting = !runner.booted && runner.bootError == nil
        if booting != wasBooting { wasBooting = booting; d = true }
        if (showFps || (Shell.perfLog && shell.focused?.app === self)) && nowMs - fpsAt >= 1000 {
            let v = kernel.frameCount // kernel frames (publishedVersion only advances when pixels change)
            let span = max(1, nowMs - fpsAt)
            fps = Int((v - fpsVersion) * 1000 / span)
            if fpsAt != 0 { let l = perfLine(span); print(l); shell.lastPerfLine = l }
            else { _ = shell.uiFrames.take() }
            fpsVersion = v; fpsAt = nowMs; perfMark(); if showFps { d = true }
        }
        return d
    }

    // perf log counters at the last line (kernel values are read without a lock: diagnostics only)
    private var perfSpeaker: Int64 = 0
    private var perfTicks: Int64 = 0
    private var perfTaskNs: Int64 = 0
    private var perfComposeNs: Int64 = 0
    private var perfFrames: Int64 = 0
    private var perfCpuNs: Int64 = -1

    private func perfMark() {
        let st = kernel.frameStats
        perfSpeaker = kernel.speakerChanges; perfTicks = kernel.vm.ticksExecuted; perfTaskNs = st.taskNs; perfComposeNs = st.composeTotalNs; perfFrames = st.frames
        perfCpuNs = shell.env.processCpuNs()
    }

    /**
     * One line per second (Show frame rate, or [Shell.perfLog]): kernel frames per second, mean frame
     * composition, the kernel thread's busy share, speaker changes per second, and the UI thread's
     * frames, longest gap and stalls (UiFrameStats) over the same second, the HolyC work done per second (budget
     * ticks: the same count for the same work on Pure Terry and Pure Swift); last, the kernel frames since the
     * program started (Swift-only: a count that keeps rising through a fold or rotation shows the same program
     * kept running, docs/foldable/IPHONE_DUO_ADAPTATION.md).
     */
    private func perfLine(_ spanMs: Int64) -> String {
        let st = kernel.frameStats
        let frames = st.frames - perfFrames
        let composeMs = frames > 0 ? Double(st.composeTotalNs - perfComposeNs) / 1e6 / Double(frames) : 0
        let busy = 100.0 * Double((st.taskNs - perfTaskNs) + (st.composeTotalNs - perfComposeNs)) / (Double(spanMs) * 1e6)
        let (uiFrames, uiGap, uiJanks) = shell.uiFrames.take()
        let cpuNow = shell.env.processCpuNs()
        // the whole app's CPU (UI, audio, kernel and task threads) per second of wall time, in percent of one core
        let cpu = cpuNow >= 0 && perfCpuNs >= 0 ? 100.0 * Double(cpuNow - perfCpuNs) / (Double(spanMs) * 1e6) : -1.0
        return "TempleOSMobile perf program=\(info?.id ?? path) engine=\(native != nil ? "native" : "terry") fps=\(fps) compose_ms=\(String(format: "%.1f", composeMs)) busy_pct=\(String(format: "%.0f", busy)) cpu_pct=\(String(format: "%.0f", cpu)) speaker_per_s=\((kernel.speakerChanges - perfSpeaker) * 1000 / spanMs) ui_fps=\(Int64(uiFrames) * 1000 / spanMs) ui_max_gap_ms=\(String(format: "%.0f", uiGap)) ui_janks=\(uiJanks) ticks_per_s=\((kernel.vm.ticksExecuted - perfTicks) * 1000 / spanMs) kernel_frames=\(kernel.frameCount)"
    }

    // Frame-rate readout (window menu > Show frame rate): kernel frames per second.
    private var showFps = false
    private var fps = 0
    private var fpsAt: Int64 = 0
    private var fpsVersion: Int64 = 0

    private func layout(_ r: Rect, _ win: Rect) -> (Rect, Rect) {
        // returns (canvas, controls); the canvas keeps the shape of the program's window. The client's own
        // shape decides (not the screen's orientation): with room for the controls (96 px, as the gutters)
        // below the full-width picture they go there, else into the side gutters. A tabletop fold across the
        // client puts the picture above the hinge and the controls below it.
        let portrait = r.h - r.w * win.h / max(1, win.w) >= 96 || shell.horizontalDivision(in: r) != nil
        if portrait {
            if let fold = shell.horizontalDivision(in: r) {
                let canvas = fitAspect(Rect(r.x, r.y, r.w, fold.y - r.y), win.w, win.h)
                return (canvas, Rect(r.x, fold.bottom, r.w, r.bottom - fold.bottom))
            }
            let canvas = fitAspect(Rect(r.x, r.y, r.w, min(r.h, r.w * win.h / max(1, win.w))), win.w, win.h)
            return (canvas, Rect(r.x, canvas.bottom + 4, r.w, r.bottom - canvas.bottom - 4))
        }
        var canvas = fitAspect(r, win.w, win.h)
        // on a large screen (an unfolded foldable) the picture gives the controls their gutters as long as
        // it stays at least the program's own width (TempleOS's 640 px): touch controls instead of none
        if (r.w - canvas.w) / 2 < 96 && r.w - 2 * 96 >= win.w {
            canvas = fitAspect(Rect(r.x + 96, r.y, r.w - 2 * 96, r.h), win.w, win.h)
        }
        let side = (r.w - canvas.w) / 2
        return side >= 96 ? (canvas, Rect(r.x, r.y, side - 4, r.h)) : (canvas, Rect(0, 0, 0, 0))
    }

    private lazy var still = [UInt8](repeating: 0, count: Kernel.W * Kernel.H)

    override public func draw(_ s: Surface, _ r: Rect) {
        documentLinks.removeAll(keepingCapacity:true)
        if !runner.booted && runner.bootError == nil {
            s.fill(r, Palette.WHITE)
            s.uiText(r.x + 8, r.y + 8, tr("program.starting", ("title", title)), Palette.BLUE, r.w - 16)
            return
        }
        if !kernel.graphicsUsed || showConsole {
            consoleView.draw(s, r, kernel.console, !isFinished)
            a11yText(r, "\(title): " + kernel.console.tailText(6))
            canvasRect = Rect(0, 0, 0, 0)
            controls.clearLayout()
            return
        }
        s.fill(r, Palette.BLACK)
        let win = frame.window
        let (canvas, ctl) = layout(r, win)
        canvasRect = canvas
        shownWindow = win
        if shell.drawsFrameInSurface(self) || finished { // no overlay under popups or covering windows
            // overlays are hidden under popups, and once the program ended the end message below must not
            // be hidden by the picture: show the last frame in the surface instead
            let frame = self.frame!
            still.withUnsafeMutableBufferPointer { b in _ = frame.copyFrame(b.baseAddress!) }
            s.blitScaled(still, Kernel.W, Kernel.H, canvas, win)
        }
        if ctl.w > 0 && ctl.h > 0 {
            if ctl.y < canvas.bottom {
                // left gutter: d-pad; right gutter: action buttons (they do not fit beside the pad)
                let right = Rect(canvas.right + 4, r.y, r.right - canvas.right - 4, r.h)
                controls.draw(s, ctl, kernel.menuSnapshot, vertical: false, showDpad: wantsDpad(), actionArea: right, info: info)
            } else { controls.draw(s, ctl, kernel.menuSnapshot, vertical: true, showDpad: wantsDpad(), info: info) }
        } else { controls.clearLayout() } // no room for controls: only what is drawn may take touches
        for link in kernel.console.spriteLinks(max(1,win.w/8)) {
            guard let action=OriginalProgramLink.parse(link.format,Paths.parent(path)) else {continue}
            let hit=Rect(canvas.x+link.x*canvas.w/win.w,canvas.y+link.y*canvas.h/win.h,max(1,link.width*canvas.w/win.w),max(1,link.height*canvas.h/win.h)).intersect(canvas)
            if hit.w>0 && hit.h>0 {documentLinks.append((hit,action));a11yButton(hit,action.label)}
        }
        a11yText(canvas, tr("program.a11y.picture", ("title", title)))
        controls.accessibility { cr, label, on in self.a11yButton(cr, label, selected: on) }
        if showFps { s.text(canvas.right - 56, canvas.bottom + 2, String(format: "%3ld FPS", fps), Palette.YELLOW, Palette.BLACK) }
        if isFinished {
            // the exit reason is the kernel's own (HolyC/TempleOS) text; only the frame is translated
            let msg = kernel.exitMessage.map { tr("program.ended_with", ("reason", $0.take(40))) } ?? tr("program.ended")
            s.uiText(r.x + 4, r.bottom - 10, msg, Palette.YELLOW, r.w - 8, Palette.BLACK)
            a11yText(Rect(r.x, r.bottom - 10, r.w, 10), msg)
        }
    }

    private func wantsDpad() -> Bool { info?.usesArrows ?? true }

    override public func overlays(_ r: Rect) -> [Overlay] {
        kernel.graphicsUsed && !showConsole && canvasRect.w > 0 && !finished ? [Overlay(canvasRect, frame, shownWindow)] : []
    }

    override public func pointer(_ e: PointerEvent, _ r: Rect) -> Bool {
        if let link=documentLinks.first(where:{$0.0.contains(e.x,e.y)}) {if e.action == Ptr.UP {Launch.program(shell,link.1.path,shell.catalog.byPath(link.1.path))};return true}
        if !kernel.graphicsUsed || showConsole { return false }
        // each finger keeps its role until it lifts (two buttons held at once, or a button and the picture)
        if e.action == Ptr.DOWN {
            if controls.pointer(e) { pointerModes[e.id] = 2 }
            else if canvasRect.contains(e.x, e.y) && !pointerModes.values.contains(1) { pointerModes[e.id] = 1 }
            else { pointerModes[e.id] = 0 }
            if pointerModes[e.id] == 2 { invalidate(); return true }
        }
        let mode = pointerModes[e.id] ?? 0
        if e.action == Ptr.UP || e.action == Ptr.CANCEL { pointerModes[e.id] = nil }
        if mode == 2 { _ = controls.pointer(e); invalidate(); return true }
        if mode == 1 {
            let (cx, cy) = canvasToScreen(e.x, e.y, canvasRect, shownWindow)
            lastPointer = (cx, cy)
            let pressed = e.action == Ptr.DOWN || e.action == Ptr.MOVE
            lastButtons = (pressed && controls.clickMode == 0, pressed && controls.clickMode == 1)
            kernel.post(.mouse(x: cx, y: cy, lb: lastButtons.0, rb: lastButtons.1))
            runner.wake()
            return true
        }
        return false
    }

    override public func scroll(_ dx: Int, _ dy: Int, _ r: Rect) {
        if !kernel.graphicsUsed || showConsole { consoleView.scrollBy(dy / 8); invalidate() }
    }

    override public func key(_ ch: Int, _ sc: Int64, _ down: Bool) -> Bool {
        if isFinished { return false }
        kernel.post(.key(ch: ch, sc: sc, down: down))
        runner.wake()
        return true
    }

    override public func menu() -> [MenuItem] {
        var items = originalMenuItems("")
        if !isFinished { items.append(MenuItem(tr(self.runner.paused ? "program.menu.resume" : "program.menu.pause")) { [self] in runner.setPaused(!runner.paused); controls.releaseAll(); invalidate() }) }
        if !isFinished { items.append(MenuItem(tr("menu.stop_program")) { [self] in stop() }) }
        items.append(MenuItem(tr("program.menu.restart")) { [self] in restart() })
        if kernel.graphicsUsed { items.append(MenuItem(tr(self.showConsole ? "program.menu.show_screen" : "program.menu.show_console")) { [self] in showConsole = !showConsole; invalidate() }) }
        items.append(MenuItem(tr(self.shell.templeKeyboardShown ? "program.menu.hide_keyboard" : "program.menu.show_keyboard")) { [self] in
            keyboardRequested = !shell.templeKeyboardShown
            if keyboardRequested {shell.requestKeyboard()} else {shell.hideKeyboard()}
            shell.invalidate()
        })
        if runner.booted && isFinished && kernel.documents.canExport() {
            items.append(MenuItem(tr("menu.save_as")) { [self] in
                shell.showDialog(Dialog.input(tr("editor.dialog.save_as"),"C:/Home/"+path.substringAfterLast("/").substringBefore(".")+".DD") {target in
                    guard let target=target else {return}
                    do {try self.kernel.documents.export(target);self.shell.showToast(tr("toast.saved",("path",target)))} catch {self.shell.showToast(localizedError(error))}
                })
            })
        }
        items.append(MenuItem(tr("menu.edit_source")) { [self] in Launch.editor(shell, path) })
        if kernel.graphicsUsed { items.append(MenuItem(tr("program.menu.show_frame_rate"), checked: showFps) { [self] in showFps = !showFps; fpsAt = 0; invalidate() }) }
        if let info = info {
            items.append(MenuItem(tr("program.menu.about")) { [self] in
                let license = { info.license.hasPrefix("Public domain") ? tr("catalog.license.public_domain") : tr("catalog.license.project") }
                shell.showDialog(Dialog.confirm(info.title, tr("program.about.details", ("author", info.author), ("license", license()), ("source", info.source), ("file", info.path)) +
                    (!info.localizedDescription.isEmpty ? "\n\n\(info.localizedDescription)" : "") +
                    (!info.note.isEmpty ? "\n\n" + tr("program.about.compatibility", ("status", tr("catalog.status.\(info.status)")), ("note", info.localizedNote)) : ""), tr("button.ok")) {})
            })
        }
        return items
    }

    /** Re-read the live task menu at every submenu/selection: checked state and
     * MenuPush/MenuPop replacements belong to the running source, not this view. */
    private func originalMenuItems(_ parent: String) -> [MenuItem] {
        kernel.menuSnapshot.filter { $0.path.components(separatedBy:"/").dropLast().joined(separator:"/") == parent }.map { m in
            MenuItem(m.label,checked:m.checked) { [weak self] in
                guard let self,let current=self.kernel.menuSnapshot.first(where:{$0.path == m.path}) else {return}
                if current.isDir {
                    self.shell.showMenu(self.originalMenuItems(current.path),4,self.shell.insetTop+self.shell.barH,current.label)
                } else {
                    self.kernel.post(.raw(code:Int(Int32(truncatingIfNeeded:current.msgCode)),a1:current.a1,a2:current.a2));self.runner.wake()
                }
            }
        }
    }

    public func stop() {
        if isFinished { return }
        runner.stop(hard: false)
        // escalate if the program does not end within 1.5 s (spec: Stop raises Break first)
        let t = Thread { [weak self] in
            Thread.sleep(forTimeInterval: 1.5)
            guard let self = self else { return }
            if !self.kernel.finished { self.runner.stop(hard: true) }
            self.liveShell?.post { [weak self] in self?.invalidate() }
        }
        t.start()
        controls.releaseAll()
    }

    private func restart() {
        guard let win = shell.windows.first(where: { $0.app === self }) else { return }
        close()
        shell.close(win, force: true)
        Launch.program(shell, path, info)
    }

    // Automatic pausing (separate from the user's Pause): the program stops using
    // CPU while the app is in the background or its window is not visible.
    private var autoPaused = false
    private var inBackground = false
    private var hidden = false

    private func syncAutoPause() {
        let want = inBackground || hidden
        if want && !isFinished && !runner.paused { controls.releaseAll(); runner.setPaused(true); autoPaused = true }
        else if !want && autoPaused { autoPaused = false; runner.setPaused(false) }
    }

    override public func onBackground() { controls.releaseAll(); inBackground = true; syncAutoPause() }
    override public func onForeground() { inBackground = false; syncAutoPause() }
    override public func onVisibility(_ visible: Bool) { hidden = !visible; syncAutoPause() }

    /**
     * Closing the window is TempleOS's close box (Adam/WinMgr.HC): a terminal task gets SHIFT-ESC, so
     * the program ends its own way (FlapBat, Talons and others save their best scores then). The
     * window is gone at once; a program still running after [CLOSE_GRACE_S] (or paused) is stopped.
     */
    override public func releaseInput() {
        controls.releaseAll(); pointerModes.removeAll()
        if lastButtons.0 || lastButtons.1 {
            lastButtons = (false, false)
            kernel.post(.mouse(x: lastPointer.0, y: lastPointer.1, lb: false, rb: false)); runner.wake()
        }
    }

    override public func close() {
        controls.releaseAll()
        kernel.silence()
        if isFinished || runner.paused { runner.stop(hard: true); return }
        kernel.post(.key(ch: Keys.CH_SHIFT_ESC, sc: Int64(Keys.SC_ESC) | Keys.SCF_SHIFT, down: true))
        kernel.post(.key(ch: Keys.CH_SHIFT_ESC, sc: Int64(Keys.SC_ESC) | Keys.SCF_SHIFT | Keys.SCF_KEY_UP, down: false))
        runner.wake()
        guard let kernel = self.kernel, let runner = self.runner else { return }
        let t = Thread {
            let end = Date().addingTimeInterval(ProgramApp.CLOSE_GRACE_S)
            while !kernel.finished && Date() < end { Thread.sleep(forTimeInterval: 0.02) }
            runner.stop(hard: true)
        }
        t.start()
    }

    static let CLOSE_GRACE_S = 1.0

    override public func saveState() -> [String: String] { ["path": path, "id": info?.id ?? "", "engine": native != nil ? "native" : "terry"] }
}

/** Bytes of a file's text part (before the DolDoc binary section). */
public func textPart(_ data: [UInt8]) -> String {
    let end = data.firstIndex(of: 0) ?? data.count
    return latin1(data, 0, end)
}

import Foundation

// Port of ui/TerminalApp.kt.

/**
 * The TempleOS command line. As in TempleOS, the shell language is HolyC:
 * every line is compiled and executed in a persistent kernel, so definitions
 * persist between commands ("I64 x=5;" then "x*2;"). There is no access to
 * the host operating system: commands only reach the sandboxed runtime.
 */
public final class TerminalApp: App {
    override public var kind: String { "terminal" }
    override public var title: String { tr("app.terminal.title") }
    override public var wantsKeyboard: Bool { true }

    // Initialized in init (they capture self).
    private var env: UiKernelEnv!
    public private(set) var kernel: Kernel!
    private var runner: KernelRunner!
    private var frame: KernelFrame!
    private let view = ConsoleView()
    /** The edited command line (Kotlin StringBuilder of Latin-1 chars). */
    private var line: [Unicode.Scalar] = []
    private var cursor = 0
    private var history: [String] = []
    private var histPos = -1
    private var lastVersion: Int64 = -1
    private var lastFrame: Int64 = -1
    private var showGraphics = true
    private var canvasRect = Rect(0, 0, 0, 0)
    private var shownWindow = Rect(0, 0, Kernel.W, Kernel.H)
    private lazy var still = [UInt8](repeating: 0, count: Kernel.W * Kernel.H)
    private var ready = false // Kotlin @Volatile

    private var lineStr: String { String(String.UnicodeScalarView(line)) }

    public init(_ shell: Shell, _ startDir: String = "C:/Home") {
        super.init(shell)
        env = UiKernelEnv(shell) { [weak self] in
            guard let self = self else { return false }
            return self.liveShell?.focused?.app === self
        }
        kernel = Kernel(env, "Terminal", shellMode: true)
        runner = KernelRunner(kernel)
        frame = KernelFrame(kernel)
        runner.start { [weak self] k in
            k.onShellIdle = { [weak self] in self?.prompt() }
            // the banner is console text (8-bit TempleOS cells): translated when the TempleOS font can show it
            k.console.write("$PURPLE$\(Brand.appName) Terminal$FG$ - " + L10n.tr8("terminal.banner", ("dir", "$GREEN$Dir;$FG$"), ("help", "$GREEN$Help;$FG$")) + "\n")
            if startDir != "C:/Home" { k.post(.exec("Cd(\"\(startDir)\");")) }
            else { self?.prompt() }
            self?.ready = true
        }
    }

    private func prompt() {
        var dir = "C:/Home"
        if let t = kernel.mainTask { dir = (try? kernel.curDir(t)) ?? "C:/Home" }
        kernel.console.write("\n$GREEN$\(dir)$FG$>")
        liveShell?.post { [weak self] in self?.invalidate() }
    }

    public var busy: Bool { kernel.busy }

    // The app in the background: the terminal's kernel (the running command and every task it spawned,
    // such as Noise/Sweep sound tasks) stops using the CPU and the speaker until the app returns, as a
    // program window does (ProgramApp). Without this a `while (TRUE) Snd(..)` typed here kept playing.
    override public func onBackground() { runner.setPaused(true) }
    override public func onForeground() { runner.setPaused(false) }

    override public func tick(_ nowMs: Int64) -> Bool {
        env.refresh()
        var d = false
        if kernel.console.version != lastVersion { lastVersion = kernel.console.version; d = true }
        if kernel.graphicsUsed && frame.frameVersion != lastFrame { lastFrame = frame.frameVersion; d = true }
        if !busy { kernel.console.setInput(lineStr, cursor) } // (Kotlin's else-branch is a no-op)
        return d
    }

    private func graphicsVisible() -> Bool { kernel.graphicsUsed && showGraphics }

    override public func draw(_ s: Surface, _ r: Rect) {
        if !ready { s.fill(r, Palette.WHITE); s.uiText(r.x + 8, r.y + 8, tr("terminal.starting"), Palette.BLUE, r.w - 16); return }
        if graphicsVisible() {
            let canvasArea = r.w > r.h ? Rect(r.x, r.y, r.w * 3 / 5, r.h) : Rect(r.x, r.y, r.w, min(r.h / 2, r.w * 3 / 4))
            shownWindow = frame.window
            canvasRect = fitAspect(canvasArea, shownWindow.w, shownWindow.h)
            s.fill(canvasArea, Palette.BLACK)
            if shell.drawsFrameInSurface(self) {
                let frame = self.frame!
                still.withUnsafeMutableBufferPointer { b in _ = frame.copyFrame(b.baseAddress!) }
                s.blitScaled(still, Kernel.W, Kernel.H, canvasRect, shownWindow)
            }
            let text = r.w > r.h ? Rect(canvasArea.right + 2, r.y, r.right - canvasArea.right - 2, r.h)
                : Rect(r.x, canvasArea.bottom + 2, r.w, r.bottom - canvasArea.bottom - 2)
            view.draw(s, text, kernel.console, true)
            a11yText(canvasRect, tr("terminal.a11y.graphics"))
            a11yText(text, tr("terminal.a11y.output", ("text", Cp437.decode(kernel.console.tailText(6)))))
        } else {
            canvasRect = Rect(0, 0, 0, 0)
            view.draw(s, r, kernel.console, true)
            a11yText(r, tr("terminal.a11y.output", ("text", Cp437.decode(kernel.console.tailText(6)))))
        }
    }

    override public func overlays(_ r: Rect) -> [Overlay] {
        graphicsVisible() && canvasRect.w > 0 ? [Overlay(canvasRect, frame, shownWindow)] : []
    }

    override public func pointer(_ e: PointerEvent, _ r: Rect) -> Bool {
        if !graphicsVisible() || !canvasRect.contains(e.x, e.y) && e.action == Ptr.DOWN { return false }
        if !busy { return false }
        let (cx, cy) = canvasToScreen(e.x, e.y, canvasRect, shownWindow)
        kernel.post(.mouse(x: cx, y: cy, lb: e.action == Ptr.DOWN || e.action == Ptr.MOVE, rb: false))
        runner.wake()
        return true
    }

    override public func scroll(_ dx: Int, _ dy: Int, _ r: Rect) { view.scrollBy(dy / 8); invalidate() }

    override public func key(_ ch: Int, _ sc: Int64, _ down: Bool) -> Bool {
        if busy {
            // a program is running: keys go to it (Ctrl+C breaks, like Ctrl-Alt-C)
            if down && (ch == 3 || (ch == 99 && sc & Keys.SCF_CTRL != 0)) { kernel.post(.breakKey); runner.wake(); return true }
            kernel.post(.key(ch: ch, sc: sc, down: down)); runner.wake(); return true
        }
        if !down { return true }
        view.scrollBack = 0
        let code = Int(sc & 0x7F)
        if ch == 10 { submit() }
        else if ch == Keys.CH_BACKSPACE { if cursor > 0 { line.remove(at: cursor - 1); cursor -= 1 } }
        else if code == Keys.SC_DELETE && sc & Keys.SCF_DELETE != 0 { if cursor < line.count { line.remove(at: cursor) } }
        else if code == Keys.SC_CURSOR_LEFT && ch == 0 { cursor = max(0, cursor - 1) }
        else if code == Keys.SC_CURSOR_RIGHT && ch == 0 { cursor = min(line.count, cursor + 1) }
        else if code == Keys.SC_HOME && ch == 0 { cursor = 0 }
        else if code == Keys.SC_END && ch == 0 { cursor = line.count }
        else if code == Keys.SC_CURSOR_UP && ch == 0 { recall(-1) }
        else if code == Keys.SC_CURSOR_DOWN && ch == 0 { recall(1) }
        else if ch == Keys.CH_ESC { line.removeAll(); cursor = 0 }
        else if ch == 9 { complete() }
        else if ch >= 32 && ch <= 255 { line.insert(Unicode.Scalar(UInt8(ch)), at: cursor); cursor += 1 }
        kernel.console.setInput(lineStr, cursor)
        invalidate()
        return true
    }

    private func recall(_ dir: Int) {
        if history.isEmpty { return }
        histPos = histPos < 0 ? history.count : histPos
        histPos = min(max(histPos + dir, 0), history.count)
        line.removeAll()
        if histPos < history.count { line.append(contentsOf: history[histPos].unicodeScalars) }
        cursor = line.count
    }

    /** Tab: complete a file name in the current directory. */
    private func complete() {
        // search only before the cursor: a separator after it must not start the word
        let start = (line[..<cursor].lastIndex { $0 == "\"" || $0 == " " || $0 == "(" || $0 == "," } ?? -1) + 1
        let partial = String(String.UnicodeScalarView(line[start..<cursor]))
        let dir = kernel.mainTask.map { (try? kernel.curDir($0)) ?? "C:/Home" } ?? "C:/Home"
        let base: String
        if let slash = partial.lastIndex(of: "/") {
            guard let b = Paths.normalize(dir, String(partial[..<slash])) else { return }
            base = b
        } else { base = dir }
        let prefix = partial.substringAfterLast("/")
        guard let matches = shell.fs.list(base)?.filter({ $0.name.startsWith(prefix, ignoreCase: true) }) else { return }
        if matches.count == 1 {
            let add = Array(matches[0].name.unicodeScalars.dropFirst(prefix.unicodeScalars.count)) + (matches[0].isDir ? ["/"] : [])
            line.insert(contentsOf: add, at: cursor); cursor += add.count
        } else if matches.count > 1 {
            kernel.console.write("\n" + matches.map { $0.name }.joined(separator: "  ") + "\n")
            prompt()
        }
    }

    private func submit() {
        let cmd = lineStr
        guard InputCharacterPolicy.isByteText(cmd) else { shell.rejectInput(); return }
        line.removeAll(); cursor = 0
        kernel.console.setInput(nil, 0)
        kernel.console.write(cmd + "\n")
        if cmd.trimmed().isEmpty { prompt(); return }
        if history.last != cmd { history.append(cmd) }
        if history.count > 200 { history.remove(at: 0) }
        histPos = -1
        // TempleOS convenience: a bare statement without ';' still runs
        let src = (trimEndWs(cmd).hasSuffix(";") || trimEndWs(cmd).hasSuffix("}") || trimStartWs(cmd).hasPrefix("#")) ? cmd : "\(cmd);"
        showGraphics = true
        kernel.post(.exec(src))
        runner.wake()
    }

    override public func text(_ s: String) {
        guard InputCharacterPolicy.isByteText(s) else { shell.rejectInput(); return }
        if busy { super.text(s); return }
        for c in s.unicodeScalars {
            if c == "\n" { _ = key(10, Keys.special(Keys.SC_ENTER).1, true); continue }
            line.insert(Unicode.Scalar(UInt8(c.value)), at: cursor); cursor += 1
        }
        kernel.console.setInput(lineStr, cursor)
        invalidate()
    }

    override public func menu() -> [MenuItem] {
        [
            MenuItem(tr("terminal.menu.break"), enabled: busy) { [self] in kernel.post(.breakKey); runner.wake() },
            MenuItem(tr(self.showGraphics ? "terminal.menu.hide_graphics" : "terminal.menu.show_graphics"), enabled: kernel.graphicsUsed) { [self] in showGraphics = !showGraphics; invalidate() },
            MenuItem(tr("terminal.menu.clear")) { [self] in kernel.console.clear(); if !busy { prompt() } },
            MenuItem(tr("menu.paste")) { [self] in shell.pasteClipboard() },
            MenuItem(tr("terminal.menu.copy_output")) { [self] in shell.env.clipboardSet(Cp437.decode(kernel.console.plainText().takeLast(20000))); shell.showToast(tr("toast.copied")) },
            MenuItem(tr("terminal.menu.commands_help")) { [self] in Launch.doc(shell, "C:/Doc/CmdLineOverview.DD") },
        ]
    }

    override public func close() { runner.stop(hard: true); kernel.silence() }

    override public func saveState() -> [String: String] {
        var dir: String? = nil
        if let t = kernel.mainTask { dir = try? kernel.curDir(t) }
        return [
            "dir": dir ?? "C:/Home",
            "hist": history.suffix(50).joined(separator: "\u{1}"),
        ]
    }

    public func restoreHistory(_ h: String) {
        if !h.isEmpty { history.append(contentsOf: h.split(separator: "\u{1}", omittingEmptySubsequences: false).map(String.init)) }
    }
}

/** Kotlin String.trimEnd() / trimStart() (whitespace). */
private func trimEndWs(_ s: String) -> String {
    var v = Substring(s).unicodeScalars
    while let l = v.last, CharacterSet.whitespacesAndNewlines.contains(l) { v.removeLast() }
    return String(v)
}

private func trimStartWs(_ s: String) -> String {
    var v = Substring(s).unicodeScalars
    while let f = v.first, CharacterSet.whitespacesAndNewlines.contains(f) { v.removeFirst() }
    return String(v)
}

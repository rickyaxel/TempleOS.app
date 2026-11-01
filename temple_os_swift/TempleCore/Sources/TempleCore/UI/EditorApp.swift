import Foundation

// Port of ui/EditorApp.kt. Strings are indexed by Unicode scalar (Kotlin indexes by char;
// all TempleOS text is Latin-1). The line list lives in a shared Ref so the Highlighter
// sees edits, like the Kotlin ArrayList shared by reference.

// Kotlin Char classification (Unicode general categories).
fileprivate func ktIsLetter(_ c: Unicode.Scalar) -> Bool {
    switch c.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
    default: return false
    }
}
fileprivate func ktIsDigit(_ c: Unicode.Scalar) -> Bool { c.properties.generalCategory == .decimalNumber }
fileprivate func ktIsLetterOrDigit(_ c: Unicode.Scalar) -> Bool { ktIsLetter(c) || ktIsDigit(c) }
fileprivate func ktIsUpperCase(_ c: Unicode.Scalar) -> Bool { c.properties.isUppercase }
fileprivate func ktIsWhitespace(_ c: Unicode.Scalar) -> Bool { c.properties.isWhitespace }

/** Kotlin startsWith(p, i) on a scalar array. */
fileprivate func startsAt(_ a: [Unicode.Scalar], _ i: Int, _ p: String) -> Bool {
    let ps = p.scArr
    if i < 0 || i + ps.count > a.count { return false }
    for k in 0..<ps.count where a[i + k] != ps[k] { return false }
    return true
}

/**
 * HolyC source editor. Edits the text part of a file; a DolDoc binary section
 * (embedded sprites) is preserved unchanged on save. Source is saved only in
 * the app's virtual drive; there is no import from outside the app.
 */
public final class EditorApp: App {
    public override var kind: String { "editor" }
    public private(set) var path: String?
    public override var title: String { InputCharacterPolicy.display(path?.substringAfterLast("/") ?? "Untitled.HC") + (modified ? "*" : "") }
    public override var wantsKeyboard: Bool { true }

    private let linesRef: Ref<[String]>
    public var lines: [String] {
        get { linesRef.value }
        _modify { yield &linesRef.value }
        set { linesRef.value = newValue }
    }
    private var binTail: [UInt8] = []
    public private(set) var row = 0
    public private(set) var col = 0
    private var anchorRow = -1, anchorCol = 0 // selection anchor (-1 = none)
    private var top = 0
    private var left = 0
    public private(set) var modified = false
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var errorLine = -1
    private var errorMsg: String? = nil
    private var program: ProgramApp? = nil
    private var lastEditTime: Int64 = 0
    private var visibleRows = 20
    private var textCols = 40
    private var gutter = 32

    private struct Snapshot { let text: String; let row: Int; let col: Int }
    private let hl: Highlighter

    public init(_ shell: Shell, _ initialPath: String?, _ draft: String? = nil) {
        let ref = Ref<[String]>([])
        linesRef = ref
        hl = Highlighter(ref)
        path = initialPath
        super.init(shell)
        let data = initialPath.flatMap { shell.fs.readFile($0) }
        if let data = data {
            if let end = data.firstIndex(of: 0) { binTail = Array(data[end...]) } else { binTail = [] }
            setText(textPart(data).scRemoving("\r"))
        } else { setText(initialPath == nil ? EditorApp.TEMPLATE : "") }
        if let draft = draft, draft != text() { setText(draft); modified = true }
    }

    public func text() -> String { lines.joined(separator: "\n") }

    private func setText(_ t: String) {
        lines = t.scSplit("\n")
        if lines.isEmpty { lines.append("") }
        row = coerceInUI(row, 0, lines.count - 1); col = coerceInUI(col, 0, lines[row].scLen)
        hl.invalidateFrom(0)
    }

    // ------------------------------------------------------------ editing primitives

    private func snapshot(_ force: Bool = false) {
        let now = shell.env.nowMs()
        if !force && now - lastEditTime < 800 && !undoStack.isEmpty { lastEditTime = now; return }
        lastEditTime = now
        undoStack.append(Snapshot(text: text(), row: row, col: col))
        if undoStack.count > 200 { undoStack.remove(at: 0) }
        redoStack.removeAll()
    }

    private func changed(_ fromRow: Int) {
        modified = true
        errorLine = -1
        hl.invalidateFrom(fromRow)
        invalidate()
    }

    public func insert(_ s: String) {
        guard InputCharacterPolicy.isByteText(s) else { shell.rejectInput(); return }
        snapshot(s.unicodeScalars.contains("\n"))
        deleteSelectionNoSnap()
        let cur = lines[row]
        let before = cur.scSub(0, col), after = cur.scSub(col)
        let parts = (before + s + after).scSplit("\n")
        lines[row] = parts[0]
        if parts.count > 1 { for i in 1..<parts.count { lines.insert(parts[i], at: row + i) } }
        let lastLen = parts[parts.count - 1].scLen - after.scLen
        let startRow = row
        row += parts.count - 1
        col = parts.count == 1 ? before.scLen + s.scLen : lastLen
        changed(startRow)
        ensureVisible()
    }

    private func newline() {
        // keep the current line's indentation, like the TempleOS editor
        let indent = scString(lines[row].unicodeScalars.prefix { $0 == " " || $0 == "\t" })
        var head = lines[row].scSub(0, col).scArr
        while let l = head.last, ktIsWhitespace(l) { head.removeLast() }
        let extra = head.last == "{" ? "  " : ""
        insert("\n" + indent + extra)
    }

    private func backspace() {
        if hasSelection() { snapshot(true); deleteSelectionNoSnap(); changed(row); return }
        snapshot()
        if col > 0 { lines[row] = lines[row].scSub(0, col - 1) + lines[row].scSub(col); col -= 1 }
        else if row > 0 { col = lines[row - 1].scLen; lines[row - 1] += lines[row]; lines.remove(at: row); row -= 1 }
        changed(row); ensureVisible()
    }

    private func deleteForward() {
        if hasSelection() { snapshot(true); deleteSelectionNoSnap(); changed(row); return }
        snapshot()
        if col < lines[row].scLen { lines[row] = lines[row].scSub(0, col) + lines[row].scSub(col + 1) }
        else if row < lines.count - 1 { lines[row] += lines[row + 1]; lines.remove(at: row + 1) }
        changed(row)
    }

    public func hasSelection() -> Bool { anchorRow >= 0 && (anchorRow != row || anchorCol != col) }

    private func selRange() -> [Int] {
        let a = anchorRow * 100000 + anchorCol, b = row * 100000 + col
        return a <= b ? [anchorRow, anchorCol, row, col] : [row, col, anchorRow, anchorCol]
    }

    public func selectedText() -> String {
        if !hasSelection() { return "" }
        let s = selRange()
        let r0 = s[0], c0 = s[1], r1 = s[2], c1 = s[3]
        if r0 == r1 { return lines[r0].scSub(c0, c1) }
        var sb = lines[r0].scSub(c0)
        if r0 + 1 < r1 { for r in (r0 + 1)..<r1 { sb += "\n" + lines[r] } }
        sb += "\n" + lines[r1].scSub(0, c1)
        return sb
    }

    private func deleteSelectionNoSnap() {
        if !hasSelection() { anchorRow = -1; return }
        let s = selRange()
        let keep = lines[s[0]].scSub(0, s[1]) + lines[s[2]].scSub(s[3])
        var i = s[2]
        while i >= s[0] + 1 { lines.remove(at: i); i -= 1 }
        lines[s[0]] = keep
        row = s[0]; col = s[1]
        anchorRow = -1
    }

    public func undo() {
        guard let s = undoStack.removeLastOrNil() else { return }
        redoStack.append(Snapshot(text: text(), row: row, col: col))
        setText(s.text); row = coerceInUI(s.row, 0, lines.count - 1); col = coerceInUI(s.col, 0, lines[row].scLen)
        modified = true; anchorRow = -1; invalidate(); ensureVisible()
    }

    public func redo() {
        guard let s = redoStack.removeLastOrNil() else { return }
        undoStack.append(Snapshot(text: text(), row: row, col: col))
        setText(s.text); row = coerceInUI(s.row, 0, lines.count - 1); col = coerceInUI(s.col, 0, lines[row].scLen)
        modified = true; anchorRow = -1; invalidate(); ensureVisible()
    }

    private func move(_ dr: Int, _ dc: Int, _ select: Bool) {
        if select && anchorRow < 0 { anchorRow = row; anchorCol = col }
        if !select { anchorRow = -1 }
        if dr != 0 { row = coerceInUI(row + dr, 0, lines.count - 1); col = min(col, lines[row].scLen) }
        if dc < 0 { if col > 0 { col -= 1 } else if row > 0 { row -= 1; col = lines[row].scLen } }
        if dc > 0 { if col < lines[row].scLen { col += 1 } else if row < lines.count - 1 { row += 1; col = 0 } }
        ensureVisible(); invalidate()
    }

    private func ensureVisible() {
        if row < top { top = row }
        if row >= top + visibleRows { top = row - visibleRows + 1 }
        let vc = visualCol(row, col)
        if vc < left { left = max(0, vc - 4) }
        if vc >= left + textCols { left = vc - textCols + 4 }
    }

    private func visualCol(_ r: Int, _ c: Int) -> Int {
        var v = 0
        let l = lines[r].scArr
        for i in 0..<min(c, l.count) { v = l[i] == "\t" ? (v / 8 + 1) * 8 : v + 1 }
        return v
    }

    private func colFromVisual(_ r: Int, _ vc: Int) -> Int {
        var v = 0
        let l = lines[r].scArr
        for i in 0..<l.count {
            let nv = l[i] == "\t" ? (v / 8 + 1) * 8 : v + 1
            if nv > vc { return i }
            v = nv
        }
        return l.count
    }

    // ------------------------------------------------------------ file operations

    @discardableResult
    public func save(_ as_: String? = nil) -> Bool {
        guard let target = as_ ?? path else { saveAs(); return false }
        guard InputCharacterPolicy.isByteBuffer(text()) else { shell.rejectInput(); return false }
        let t = latin1(text())
        let data = !binTail.isEmpty ? t + binTail : t
        do {
            try shell.fs.writeFile(target, data)
            path = target; modified = false
            shell.showToast(tr("toast.saved", ("path", InputCharacterPolicy.display(target))))
            shell.saveSession()
            invalidate(); return true
        } catch {
            shell.showDialog(Dialog.confirm(tr("editor.save_failed.title"), localizedError(error), tr("button.ok")) {}); return false
        }
    }

    public func saveAs(_ afterSave:(()->Void)? = nil) {
        let initial = path ?? "C:/Home/Untitled.HC"
        shell.showDialog(Dialog.input(tr("editor.dialog.save_as"), initial) { [self] p in
            guard let p = p else { return }
            let norm = Paths.normalize("C:/Home", p)
            guard let n = norm, n != "C:/" else { shell.showToast(tr("toast.invalid_path")); return }
            let withExt = Paths.name(n).contains(".") ? n : "\(n).HC"
            if shell.fs.exists(withExt) && withExt != path {
                shell.showDialog(Dialog.confirmDestructive(tr("dialog.replace.title", ("name", InputCharacterPolicy.display(Paths.name(withExt)))), tr("dialog.replace.message"), tr("button.replace")) { [self] in if save(withExt) {afterSave?()} })
            } else { if save(withExt) {afterSave?()} }
        })
    }

    public func run() {
        guard InputCharacterPolicy.isByteBuffer(text()) else { shell.rejectInput(); return }
        if let p = program, let w = shell.windows.first(where: { $0.app === p }) { shell.close(w, force: true) }
        let src = latin1(text()) + binTail
        let runPath = path ?? "C:/Home/Untitled.HC"
        // the user's own HolyC is compiled on the device: it always runs in Pure Terry
        let p = ProgramApp(shell, runPath, nil, src)
        program = p
        p.navigationParentId=shell.windows.first(where:{$0.app === self})?.id
        shell.open(p, maximized: !shell.windowed)
        if shell.settings.engine == Settings.ENGINE_NATIVE { shell.showToast(tr("engine.custom_terry", ("engine", Engines.TERRY_NAME))) }
        // collect compile errors for highlighting once the program reports them
        let re = try! NSRegularExpression(pattern: "Compile error: (.*?):(\\d+): (.*)")
        let t = Thread { [self] in
            let start = epochMillisNow()
            while epochMillisNow() - start < 8000 {
                Thread.sleep(forTimeInterval: 0.15)
                let txt = p.kernel.console.plainText()
                let ns = txt as NSString
                if let m = re.firstMatch(in: txt, range: NSRange(location: 0, length: ns.length)) {
                    let file = ns.substring(with: m.range(at: 1))
                    let lineNo = ns.substring(with: m.range(at: 2))
                    let msg = ns.substring(with: m.range(at: 3))
                    if file.equalsIgnoreCase(runPath) {
                        self.liveShell?.post { [self] in
                            errorLine = (Int(lineNo) ?? 0) - 1; errorMsg = msg
                            if errorLine >= 0 && errorLine < lines.count { row = errorLine; col = 0; ensureVisible() }
                            invalidate()
                        }
                    }
                    break
                }
                if p.isFinished || ns.length > 2 { break }
            }
        }
        t.start()
    }

    // ------------------------------------------------------------ input

    public override func key(_ ch: Int, _ sc: Int64, _ down: Bool) -> Bool {
        if !down { return true }
        let code = Int(sc & 0x7F)
        let ctrl = sc & Keys.SCF_CTRL != 0
        let shift = sc & Keys.SCF_SHIFT != 0
        if ctrl {
            switch ch | 0x60 {
            case 0x73: save(); return true // 's'
            case 0x7A: undo(); return true // 'z'
            case 0x79: redo(); return true // 'y'
            case 0x63: shell.env.clipboardSet(InputCharacterPolicy.display(selectedText())); return true // 'c'
            case 0x78: shell.env.clipboardSet(InputCharacterPolicy.display(selectedText())); snapshot(true); deleteSelectionNoSnap(); changed(row); return true // 'x'
            case 0x76: shell.pasteClipboard(); return true // 'v'
            case 0x61: anchorRow = 0; anchorCol = 0; row = lines.count - 1; col = lines[row].scLen; invalidate(); return true // 'a'
            default: break
            }
        }
        if ch == 0 || code == Keys.SC_DELETE {
            switch code {
            case Keys.SC_CURSOR_LEFT: move(0, -1, shift)
            case Keys.SC_CURSOR_RIGHT: move(0, 1, shift)
            case Keys.SC_CURSOR_UP: move(-1, 0, shift)
            case Keys.SC_CURSOR_DOWN: move(1, 0, shift)
            case Keys.SC_HOME: if !shift { anchorRow = -1 }; col = 0; invalidate()
            case Keys.SC_END: if !shift { anchorRow = -1 }; col = lines[row].scLen; invalidate()
            case Keys.SC_PAGE_UP: move(-visibleRows, 0, shift)
            case Keys.SC_PAGE_DOWN: move(visibleRows, 0, shift)
            case Keys.SC_DELETE: deleteForward()
            case Keys.SC_F1 + 4: run() // F5
            default: break
            }
            return true
        }
        switch ch {
        case 10: newline()
        case Keys.CH_BACKSPACE: backspace()
        case 9: insert("  ")
        case Keys.CH_ESC: anchorRow = -1; invalidate()
        default: if ch >= 32 && ch <= 255 { insert(scString([Unicode.Scalar(UInt8(ch))])) }
        }
        return true
    }

    public override func text(_ s: String) {
        let t = s.scRemoving("\r")
        if t == "\n" { newline(); return }
        insert(t)
    }

    public override func tap(_ x: Int, _ y: Int, _ r: Rect) {
        guard let pos = posAt(x, y, r) else { return }
        let (rr, cc) = pos
        anchorRow = -1; row = rr; col = cc
        shell.requestKeyboard()
        invalidate()
    }

    public override func longPress(_ x: Int, _ y: Int, _ r: Rect) {
        guard let pos = posAt(x, y, r) else { return }
        let (rr, cc) = pos
        row = rr
        // select the word under the finger
        let l = lines[rr].scArr
        var a = min(cc, l.count), b = a
        while a > 0 && (ktIsLetterOrDigit(l[a - 1]) || l[a - 1] == "_") { a -= 1 }
        while b < l.count && (ktIsLetterOrDigit(l[b]) || l[b] == "_") { b += 1 }
        anchorRow = rr; anchorCol = a; col = b
        invalidate()
        shell.showMenu([
            MenuItem(tr("menu.copy")) { [self] in shell.env.clipboardSet(InputCharacterPolicy.display(selectedText())) },
            MenuItem(tr("menu.cut")) { [self] in shell.env.clipboardSet(InputCharacterPolicy.display(selectedText())); snapshot(true); deleteSelectionNoSnap(); changed(row) },
            MenuItem(tr("menu.paste")) { [self] in shell.pasteClipboard() },
            MenuItem(tr("menu.select_line")) { [self] in anchorRow = rr; anchorCol = 0; col = lines[rr].scLen; invalidate() },
            MenuItem(tr("menu.select_all")) { [self] in anchorRow = 0; anchorCol = 0; row = lines.count - 1; col = lines[row].scLen; invalidate() },
        ], x, y, tr("menu.edit.title"))
    }

    private func posAt(_ x: Int, _ y: Int, _ r: Rect) -> (Int, Int)? {
        let tr = r.y + headerHeight
        if y < tr { return nil }
        let rr = coerceInUI(top + (y - tr) / 8, 0, lines.count - 1)
        let vc = max(0, (x - r.x - gutter) / 8 + left)
        return (rr, colFromVisual(rr, vc))
    }

    private var scrollAccX = 0
    private var scrollAccY = 0

    public override func scroll(_ dx: Int, _ dy: Int, _ r: Rect) {
        scrollAccY -= dy; scrollAccX -= dx
        let rowsMoved = scrollAccY / 8; scrollAccY %= 8
        let colsMoved = scrollAccX / 8; scrollAccX %= 8
        top = coerceInUI(top + rowsMoved, 0, max(0, lines.count - visibleRows / 2))
        left = max(0, left + colsMoved)
        invalidate()
    }

    // ------------------------------------------------------------ drawing

    public override func draw(_ s: Surface, _ r: Rect) {
        s.fill(r, Palette.WHITE)
        // header: file name + action buttons
        headerButtons.removeAll()
        let acts: [(String, () -> Void)] = [(tr("editor.button.run"), { [self] in run() }), (tr("editor.button.save"), { [self] in save() }),
            (tr("editor.button.undo"), { [self] in undo() }), (tr("editor.button.redo"), { [self] in redo() })]
        let status = "\(row + 1):\(col + 1)" + (modified ? " *" : "")
        let layout = s.toolbarLayout(acts.map { $0.0 }, r, EditorApp.HEADER, status.scLen * 8 + 4)
        headerHeight = layout.height
        let HEADER = headerHeight
        s.fillRect(r.x, r.y, r.w, HEADER, Palette.LTGRAY)
        for (i, item) in acts.enumerated() {
            let (label, act) = item, br = layout.buttons[i]
            s.templeButton(br, label, headerButtons.isEmpty ? ButtonFace.ACTION : ButtonFace.NORMAL)
            headerButtons.append((br, act))
            a11yButton(br, label)
        }
        s.text(r.right - status.scLen * 8 - 4, layout.trailing.y + (layout.trailing.h - 8) / 2, status, Palette.BLACK)
        let body = Rect(r.x, r.y + HEADER, r.w, r.h - HEADER - ((errorMsg != nil && errorLine >= 0) ? 10 : 0))
        a11yText(body, tr(modified ? "editor.a11y.position_modified" : "editor.a11y.position", ("line", row + 1), ("lines", lines.count), ("column", col + 1)) + ": " + InputCharacterPolicy.display(lines[row]))
        visibleRows = max(1, body.h / 8)
        let digits = max(3, String(lines.count).count)
        gutter = digits * 8 + 4
        textCols = max(4, (r.w - gutter) / 8)
        top = coerceInUI(top, 0, max(0, lines.count - 1))
        let sel: [Int]? = hasSelection() ? selRange() : nil
        for i in 0..<visibleRows {
            let ln = top + i
            if ln >= lines.count { break }
            let y = body.y + i * 8
            s.text(r.x, y, String(ln + 1).padStart(digits), Palette.DKGRAY)
            if ln == errorLine { s.fillRect(r.x + gutter, y, r.w - gutter, 8, Palette.LTRED) }
            else if ln == row { s.fillRect(r.x + gutter, y, r.w - gutter, 8, Palette.WHITE) }
            let colors = hl.colors(ln)
            let l = lines[ln].scArr
            var v = 0
            for (ci, c) in l.enumerated() {
                let w = c == "\t" ? 8 - (v % 8) : 1
                let vx = v - left
                if vx >= 0 && vx < textCols {
                    let selected = sel != nil && inSel(sel!, ln, ci)
                    s.glyph(r.x + gutter + vx * 8, y, c == "\t" ? 32 : (c.value <= 255 ? Int(c.value) : 63),
                            selected ? Palette.WHITE : colors[ci], selected ? Palette.BLUE : -1)
                }
                v += w
            }
            if l.contains(where: { $0.value > 255 }) {
                s.uiText(r.x + gutter, y, scString(l.dropFirst(left).prefix(textCols)), Palette.BLUE, textCols * 8)
            }
            // V-25: like nano's '$', mark text hidden past either edge
            if left > 0 && v > 0 { s.glyph(r.x + gutter, y, 0x11, Palette.WHITE, Palette.DKGRAY) }
            if v - left > textCols { s.glyph(r.x + gutter + (textCols - 1) * 8, y, 0x10, Palette.WHITE, Palette.DKGRAY) }
            if ln == row {
                let cx = r.x + gutter + (visualCol(row, col) - left) * 8
                if cx >= r.x + gutter && cx < r.right && (shell.env.nowMs() / 530) % 2 == 0 { s.fillRect(cx, y, 2, 8, Palette.RED) }
            }
        }
        if let em = errorMsg, errorLine >= 0 {
            // the compiler's message stays as HolyC reports it; only the frame is translated
            let t = tr("editor.error_line", ("line", errorLine + 1), ("message", em))
            a11yText(Rect(r.x, r.bottom - 10, r.w, 10), t)
            s.fillRect(r.x, r.bottom - 10, r.w, 10, Palette.RED)
            s.uiText(r.x + 2, r.bottom - 9, t, Palette.WHITE, r.w - 4)
        }
    }

    private func inSel(_ s: [Int], _ ln: Int, _ c: Int) -> Bool {
        let p = ln * 100000 + c
        return p >= s[0] * 100000 + s[1] && p < s[2] * 100000 + s[3]
    }

    private var headerButtons: [(Rect, () -> Void)] = []
    private var headerHeight = Touch.editorHeader

    public override func pointer(_ e: PointerEvent, _ r: Rect) -> Bool {
        if e.action == Ptr.DOWN && e.y < r.y + headerHeight {
            headerButtons.first { $0.0.contains(e.x, e.y) }?.1()
            return true
        }
        return false
    }

    public override func tick(_ nowMs: Int64) -> Bool {
        let b = (nowMs / 530) % 2
        if b != lastBlink { lastBlink = b; return true }
        return false
    }
    private var lastBlink: Int64 = -1

    public override func menu() -> [MenuItem] {
        let close = { [self] in if let w=shell.windows.first(where:{$0.app === self}) {shell.close(w,force:true)} }
        let sourceActions:[String:()->Void] = [
            "File/Save":{[self] in _ = save()},"File/SaveAs":{[self] in saveAs()},
            "File/Abort":close,"File/Exit":{[self] in if path == nil {saveAs(close)} else if save() {close()}},
            "Edit/Undo":{[self] in undo()},"Edit/Cut":{[self] in shell.env.clipboardSet(InputCharacterPolicy.display(selectedText()));snapshot(true);deleteSelectionNoSnap();changed(row)},
            "Edit/Copy":{[self] in shell.env.clipboardSet(InputCharacterPolicy.display(selectedText()))},"Edit/Paste":{[self] in shell.pasteClipboard()},
            "Edit/GoBegin":{[self] in row=0;col=0;ensureVisible();invalidate()},
            "Edit/GoEnd":{[self] in row=lines.count-1;col=lines[row].scLen;ensureVisible();invalidate()},
            "Edit/GoLeft":{[self] in col=0;ensureVisible();invalidate()},"Edit/GoRight":{[self] in col=lines[row].scLen;ensureVisible();invalidate()},
            "Program/Include":{[self] in run()},"View/FileMgr":{[self] in Launch.files(shell,path.map {Paths.parent($0)} ?? "C:/Home")},
            "Help/Menu":{[self] in shell.showStartMenu()},"Help/Help":{[self] in Launch.doc(shell,"C:/Doc/HelpIndex.DD")},"Help/About":{[self] in Launch.about(shell)}
        ]
        return OriginalContextMenu.items(shell,"C:/Doc/EdPullDown.DD",sourceActions) + [
            MenuItem(tr("editor.menu.run")) { [self] in run() },
            MenuItem(tr("menu.stop_program"), enabled: program?.isFinished == false) { [self] in program?.stop() },
            MenuItem(tr("editor.menu.save")) { [self] in save() },
            MenuItem(tr("menu.save_as")) { [self] in saveAs() },
            MenuItem(tr("editor.menu.new_file")) { [self] in Launch.editor(shell, nil) },
            MenuItem(tr("editor.menu.open_file")) { [self] in Launch.files(shell, path.map { Paths.parent($0) } ?? "C:/Home") },
            MenuItem(tr("menu.undo")) { [self] in undo() },
            MenuItem(tr("menu.redo")) { [self] in redo() },
            MenuItem(tr("menu.copy")) { [self] in shell.env.clipboardSet(InputCharacterPolicy.display(selectedText())) },
            MenuItem(tr("menu.paste")) { [self] in shell.pasteClipboard() },
            MenuItem(tr("menu.select_all")) { [self] in anchorRow = 0; anchorCol = 0; row = lines.count - 1; col = lines[row].scLen; invalidate() },
            MenuItem(tr("editor.menu.go_to_top")) { [self] in row = 0; col = 0; top = 0; invalidate() },
        ]
    }

    public override var unsaved: Bool { modified }

    public override func saveState() -> [String: String] {
        var m: [String: String] = [:]
        if let p = path { m["path"] = p }
        if modified && text().utf16.count < 200_000 { m["draft"] = text() }
        m["row"] = String(row); m["col"] = String(col)
        return m
    }

    public func restoreCursor(_ r: Int, _ c: Int) { row = coerceInUI(r, 0, lines.count - 1); col = coerceInUI(c, 0, lines[row].scLen); ensureVisible() }

    public static var HEADER: Int { Touch.editorHeader }
    public static let TEMPLATE = "//New HolyC program. Press RUN to execute it.\n\nU0 Main()\n{\n  \"Hello from HolyC!\\n\";\n}\n\nMain;\n"
}

/** Incremental HolyC syntax highlighter (per-line color arrays, block-comment state carried over lines). */
public final class Highlighter {
    private let lines: Ref<[String]>
    private var cache: [[Int]?] = []
    private var startsInComment: [Bool] = []

    public init(_ lines: Ref<[String]>) { self.lines = lines }

    public func invalidateFrom(_ r: Int) {
        while cache.count > r { cache.removeLast(); startsInComment.removeLast() }
    }

    public func colors(_ r: Int) -> [Int] {
        while cache.count <= r {
            let i = cache.count
            let inC = i == 0 ? false : endsInComment(i - 1)
            startsInComment.append(inC)
            cache.append(nil)
        }
        let line = lines.value[r]
        if let it = cache[r], it.count == line.scLen { return it }
        let c = compute(line, startsInComment[r]).0
        cache[r] = c
        return c
    }

    private func endsInComment(_ i: Int) -> Bool { compute(lines.value[i], startsInComment[i]).1 }

    private func compute(_ ls: String, _ inComment0: Bool) -> ([Int], Bool) {
        let l = ls.scArr
        let n = l.count
        var c = [Int](repeating: Palette.BLUE, count: n)
        var inComment = inComment0
        var i = 0
        while i < n {
            if inComment {
                c[i] = Palette.GREEN
                if startsAt(l, i, "*/") { c[i + 1] = Palette.GREEN; i += 2; inComment = false; continue }
                i += 1; continue
            }
            let ch = l[i]
            if startsAt(l, i, "//") { for j in i..<n { c[j] = Palette.GREEN }; return (c, false) }
            else if startsAt(l, i, "/*") { inComment = true; c[i] = Palette.GREEN; c[i + 1] = Palette.GREEN; i += 2 }
            else if ch == "\"" || ch == "'" {
                let q = ch; var j = i + 1
                while j < n && l[j] != q { if l[j] == "\\" { j += 1 }; j += 1 }
                for k in i...min(j, n - 1) { c[k] = Palette.RED }
                i = j + 1
            }
            else if ch == "$" {
                var j = -1
                var k0 = i + 1
                while k0 < n { if l[k0] == "$" { j = k0; break }; k0 += 1 }
                if j > i { for k in i...j { c[k] = Palette.PURPLE }; i = j + 1 } else { i += 1 }
            }
            else if ch == "#" { var j = i + 1; while j < n && ktIsLetter(l[j]) { j += 1 }; for k in i..<j { c[k] = Palette.CYAN }; i = j }
            else if ktIsDigit(ch) { var j = i; while j < n && (ktIsLetterOrDigit(l[j]) || l[j] == ".") { j += 1 }; for k in i..<j { c[k] = Palette.BROWN }; i = j }
            else if ktIsLetter(ch) || ch == "_" || ch.value >= 128 {
                var j = i; while j < n && (ktIsLetterOrDigit(l[j]) || l[j] == "_" || l[j].value >= 128) { j += 1 }
                let w = scString(l[i..<j])
                let col: Int
                if Highlighter.KEYWORDS.contains(w) { col = Palette.BLACK }
                else if Highlighter.TYPES.contains(w) { col = Palette.PURPLE }
                else if j - i > 1 && l[i..<j].allSatisfy({ ktIsUpperCase($0) || ktIsDigit($0) || $0 == "_" }) { col = Palette.CYAN }
                else { col = Palette.BLUE }
                for k in i..<j { c[k] = col }
                i = j
            }
            else { i += 1 }
        }
        return (c, inComment)
    }

    public static let KEYWORDS: Set<String> = ["if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return",
        "goto", "try", "catch", "throw", "class", "union", "public", "extern", "static", "sizeof", "offset", "start", "end",
        "lock", "no_warn", "reg", "noreg", "asm", "lastclass"]
    public static let TYPES: Set<String> = ["U0", "I0", "I8", "U8", "I16", "U16", "I32", "U32", "I64", "U64", "F64", "Bool", "CDC", "CTask",
        "CD3", "CD3I32", "CD2I32", "CD3I64", "CD2I64", "CDate"]
}

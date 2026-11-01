import Foundation

// Port of ui/FilesApp.kt.

/** File manager for the virtual C: drive (bundled originals + the user's files). */
public final class FilesApp: App {
    override public var kind: String { "files" }
    public private(set) var dir: String
    override public var title: String { tr("app.files.title") + " " + InputCharacterPolicy.display(dir) }
    private var entries: [FsEntry] = []
    private var scroll = 0
    private var scrollAcc = 0
    private var buttons: [(Rect, () -> Void)] = []
    private var selectedPath: String?
    private var headerHeight = Touch.header

    public static var HEADER: Int { Touch.header }

    public init(_ shell: Shell, _ startDir: String) {
        dir = Paths.normalize("C:/", startDir) ?? "C:/Home"
        super.init(shell)
        refresh()
    }

    public func refresh() {
        entries = (shell.fs.list(dir) ?? []).sorted { a, b in
            if a.isDir != b.isDir { return a.isDir } // compareBy({ !it.isDir }, { it.name.lowercase() })
            return a.name.lowercased() < b.name.lowercased()
        }
        scroll = min(max(scroll, 0), max(0, entries.count - 1))
        invalidate()
    }

    public func cd(_ p: String) {
        guard let n = Paths.normalize(dir, p) else { return }
        if !shell.fs.isDir(n) { shell.showToast(tr("files.not_a_directory", ("path", InputCharacterPolicy.display(n)))); return }
        dir = n; scroll = 0; selectedPath=nil;refresh()
    }

    override public func draw(_ s: Surface, _ r: Rect) {
        s.fill(r, Palette.WHITE)
        buttons.removeAll()
        let defs: [(String, () -> Void)] = [
            ("up", { [unowned self] in cd("..") }), ("new", { [unowned self] in newFile() }),
            ("new_folder", { [unowned self] in newDir() }), ("home", { [unowned self] in cd("C:/Home") }),
        ]
        let labels = defs.map { tr("files.button.\($0.0)") }
        let layout = s.toolbarLayout(labels, r, FilesApp.HEADER, 36)
        headerHeight = layout.height
        let HEADER = headerHeight
        s.fillRect(r.x, r.y, r.w, HEADER, Palette.LTGRAY)
        for (i, item) in defs.enumerated() {
            let (key, a) = item, l = labels[i], br = layout.buttons[i]
            s.templeButton(br, l, ButtonFace.NORMAL)
            buttons.append((br, a))
            a11yButton(br, tr("files.a11y.\(key)"))
        }
        let pathRect = layout.trailing
        let pathShown = dir.takeLast(max(1, (pathRect.w - 4) / 8))
        s.text(pathRect.x + 4, pathRect.y + (pathRect.h - 8) / 2, pathShown, Palette.BLACK)
        a11yText(pathRect, tr("files.a11y.folder", ("path", InputCharacterPolicy.display(dir))))
        let listTop = r.y + HEADER
        let rows = max(1, (r.h - HEADER) / ROW_H)
        scroll = min(max(scroll, 0), max(0, entries.count - rows))
        if entries.isEmpty { let t = tr("files.empty"); s.uiText(r.x + 8, listTop + 8, t, Palette.DKGRAY, r.w - 16); a11yText(Rect(r.x, listTop, r.w, ROW_H), t) }
        for i in 0..<rows {
            guard let e = entries.getOrNil(scroll + i) else { break }
            let y = listTop + i * ROW_H
            if i % 2 == 1 { s.fillRect(r.x, y, r.w, ROW_H, Palette.WHITE) } // Kotlin: 0x07.let { Palette.WHITE }
            let icon: String
            if e.isDir { icon = "\u{FE}" } else {
                switch e.name.substringAfterLast(".", "").uppercased() {
                case "HC", "HH": icon = "\u{11}"
                case "DD", "TXT": icon = "\u{F0}"
                default: icon = "\u{FA}"
                }
            }
            let color = e.isDir ? Palette.CYAN : e.readOnly ? Palette.BLUE : Palette.PURPLE
            s.text(r.x + 4, y + 6, icon, color)
            s.text(r.x + 16, y + 6, (e.name + (e.isDir ? "/" : "")).take((r.w - 90) / 8), color)
            if !e.isDir {
                let size = e.size >= 1024 ? "\(e.size / 1024)K" : "\(e.size)"
                s.text(r.right - size.count * 8 - 4, y + 6, size, Palette.DKGRAY)
            }
            s.hline(r.x, r.right - 1, y + ROW_H - 1, Palette.LTGRAY)
            a11yButton(Rect(r.x, y, r.w, ROW_H), e.isDir ? tr("files.a11y.folder_item", ("name", InputCharacterPolicy.display(e.name))) : tr("files.a11y.file_item", ("name", InputCharacterPolicy.display(e.name)), ("size", e.size)))
        }
        if entries.count > rows {
            let h = (r.h - HEADER) * rows / entries.count
            let y = listTop + (r.h - HEADER - h) * scroll / max(1, entries.count - rows)
            s.fillRect(r.right - 3, y, 3, max(8, h), Palette.BLUE)
        }
    }

    override public func pointer(_ e: PointerEvent, _ r: Rect) -> Bool {
        if e.action == Ptr.DOWN && e.y < r.y + headerHeight { buttons.first { $0.0.contains(e.x, e.y) }?.1(); return true }
        return false
    }

    private func entryAt(_ y: Int, _ r: Rect) -> FsEntry? {
        if y < r.y + headerHeight { return nil }
        return entries.getOrNil(scroll + (y - r.y - headerHeight) / ROW_H)
    }

    override public func tap(_ x: Int, _ y: Int, _ r: Rect) {
        guard let e = entryAt(y, r) else { return }
        selectedPath=e.path
        if e.isDir { cd(e.path); return }
        open(e)
    }

    public func open(_ e: FsEntry) {
        let shell = self.shell
        if e.name.uppercased().hasSuffix(".GR") || e.name.uppercased().hasSuffix(".GR.Z") {
            Launch.paint(shell, e.path); return
        }
        switch e.name.substringAfterLast(".", "").uppercased() {
        case "HC":
            shell.showMenu([
                MenuItem(tr("files.menu.run")) { Launch.program(shell, e.path, shell.catalog.byPath(e.path)) },
                MenuItem(tr("files.menu.edit")) { Launch.editor(shell, e.path) },
            ], 40, shell.height / 3, e.name)
        case "DD", "TXT": Launch.doc(shell, e.path)
        case "HH": Launch.editor(shell, e.path)
        default: Launch.doc(shell, e.path)
        }
    }

    override public func longPress(_ x: Int, _ y: Int, _ r: Rect) {
        guard let e = entryAt(y, r) else { return }
        selectedPath=e.path
        var items = [
            MenuItem(tr("files.menu.open")) { [self] in if e.isDir { cd(e.path) } else { open(e) } },
            MenuItem(tr("files.menu.rename")) { [self] in rename(e) },
            MenuItem(tr("files.menu.copy_to")) { [self] in copyOrMove(e, move: false) },
            MenuItem(tr("files.menu.move_to")) { [self] in copyOrMove(e, move: true) },
            MenuItem(tr("files.menu.delete")) { [self] in
                shell.showDialog(Dialog.confirmDestructive(tr("dialog.delete.title", ("name", InputCharacterPolicy.display(e.name))), tr(e.readOnly ? "dialog.delete.message_bundled" : "dialog.delete.message"), tr("button.delete")) { [self] in
                    do { try shell.fs.delete(e.path, recursive: true); refresh() } catch { shell.showToast(localizedError(error)) }
                })
            },
        ]
        if !e.isDir && !e.readOnly && isModifiedOriginal(e) {
            items.append(MenuItem(tr("files.menu.restore_original")) { [self] in
                do { try shell.fs.restoreOriginal(e.path) } catch { shell.showToast(localizedError(error)) }
                refresh()
            })
        }
        if !e.isDir && e.name.endsWith(".HC", ignoreCase: true) { items.insert(MenuItem(tr("files.menu.edit")) { [self] in Launch.editor(shell, e.path) }, at: 1) }
        shell.showMenu(items, x, y, InputCharacterPolicy.display(e.name))
    }

    /** A user copy shadowing a bundled original (restoring removes the copy). */
    private func isModifiedOriginal(_ e: FsEntry) -> Bool { shell.fs.hasBundledOriginal(e.path) }

    private func rename(_ e: FsEntry) {
        shell.showDialog(Dialog.input(tr("files.dialog.rename", ("name", InputCharacterPolicy.display(e.name))), e.name) { [self] n in
            guard let n = n, !n.trimmed().isEmpty, n != e.name else { return }
            if n.contains("/") { shell.showToast(tr("files.name_no_slash")); return }
            do { try shell.fs.move(e.path, Paths.parent(e.path).trimEnd("/") + "/" + n); refresh() } catch { shell.showToast(localizedError(error)) }
        })
    }

    private func copyOrMove(_ e: FsEntry, move: Bool) {
        shell.showDialog(Dialog.input(tr(move ? "files.dialog.move_to" : "files.dialog.copy_to"), dir) { [self] d in
            guard let d = d else { return }
            guard let target = Paths.normalize(dir, d) else { return }
            let dst = shell.fs.isDir(target) ? target.trimEnd("/") + "/" + e.name : target
            do {
                if move { try shell.fs.move(e.path, dst) }
                else if e.isDir { shell.showToast(tr("files.copy_folder_unsupported")) }
                else {
                    guard let data = shell.fs.readFile(e.path) else { throw FsError("Could not read \(e.path)", "fs.error.could_not_read", ["path": e.path]) }
                    try shell.fs.writeFile(dst, data)
                }
                refresh()
            } catch { shell.showToast(localizedError(error)) }
        })
    }

    private func newFile() {
        shell.showDialog(Dialog.input(tr("files.dialog.new_file"), "New.HC") { [self] n in
            guard let n = n, !n.trimmed().isEmpty else { return }
            let name = n.contains(".") ? n : "\(n).HC"
            guard let p = Paths.normalize(dir, name) else { shell.showToast(tr("toast.invalid_name")); return }
            if shell.fs.exists(p) { shell.showToast(tr("toast.already_exists")); return }
            do { try shell.fs.writeFile(p, []); refresh(); Launch.editor(shell, p) } catch { shell.showToast(localizedError(error)) }
        })
    }

    private func newDir() {
        shell.showDialog(Dialog.input(tr("files.dialog.new_folder"), "Folder") { [self] n in // l10n-ok: default name on the TempleOS drive (ASCII file names)
            guard let n = n, !n.trimmed().isEmpty else { return }
            guard let p = Paths.normalize(dir, n) else { shell.showToast(tr("toast.invalid_name")); return }
            do { try shell.fs.mkdir(p); refresh() } catch { shell.showToast(localizedError(error)) }
        })
    }

    override public func scroll(_ dx: Int, _ dy: Int, _ r: Rect) {
        scrollAcc -= dy
        scroll += scrollAcc / ROW_H; scrollAcc %= ROW_H
        scroll = min(max(scroll, 0), max(0, entries.count - 1))
        invalidate()
    }

    override public func key(_ ch: Int, _ sc: Int64, _ down: Bool) -> Bool {
        if !down { return true }
        switch Int(sc & 0x7F) {
        case Keys.SC_CURSOR_DOWN: scroll += 1; invalidate()
        case Keys.SC_CURSOR_UP: scroll = max(0, scroll - 1); invalidate()
        case Keys.SC_BACKSPACE: cd("..")
        default: break
        }
        return true
    }

    override public func menu() -> [MenuItem] {
        let close = { [self] in if let w=shell.windows.first(where:{$0.app === self}) {shell.close(w)} }
        var actions:[String:()->Void] = ["File/DirMk":{[self] in newDir()},"File/Abort":close,"File/Exit":close]
        if let e=entries.first(where:{$0.path == selectedPath}) {
            actions["File/Rename"] = {[self] in rename(e)}
            if !e.isDir {
                actions["Edit/Ed"] = {[self] in Launch.editor(shell,e.path)}
                actions["Edit/Plain"] = {[self] in Launch.editor(shell,e.path)}
                if e.name.endsWith(".HC",ignoreCase:true) {actions["Program/Include"] = {[self] in Launch.program(shell,e.path,shell.catalog.byPath(e.path))}}
            }
        }
        return OriginalContextMenu.items(shell,"C:/Doc/FileMgrPullDown.DD",actions) + [
            MenuItem(tr("files.menu.refresh")) { [self] in refresh() },
            MenuItem(tr("files.menu.new_file")) { [self] in newFile() },
            MenuItem(tr("files.menu.new_folder")) { [self] in newDir() },
            MenuItem(tr("files.menu.open_terminal")) { [self] in Launch.terminal(shell, dir) },
            MenuItem(tr("files.menu.storage", ("used", self.shell.fs.usedBytes() / 1024), ("total", self.shell.fs.quota >> 20)), enabled: false) {},
        ]
    }

    override public func saveState() -> [String: String] { ["dir": dir] }
}

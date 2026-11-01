package io.github.templeosmobile.core.ui

import io.github.templeosmobile.core.kernel.*

/** File manager for the virtual C: drive (bundled originals + the user's files). */
class FilesApp(shell: Shell, startDir: String) : App(shell) {
    override val kind = "files"
    var dir = Paths.normalize("C:/", startDir) ?: "C:/Home"; private set
    override val title get() = tr("app.files.title") + " " + InputCharacterPolicy.display(dir)
    private var entries: List<FsEntry> = emptyList()
    private var scroll = 0
    private var scrollAcc = 0
    private val buttons = ArrayList<Pair<Rect, () -> Unit>>()
    private var selectedPath:String?=null
    private var headerHeight = Touch.header

    init { refresh() }

    fun refresh() {
        entries = (shell.fs.list(dir) ?: emptyList()).sortedWith(compareBy({ !it.isDir }, { it.name.lowercase() }))
        scroll = scroll.coerceIn(0, maxOf(0, entries.size - 1))
        invalidate()
    }

    fun cd(p: String) {
        val n = Paths.normalize(dir, p) ?: return
        if (!shell.fs.isDir(n)) { shell.showToast( { tr("files.not_a_directory", "path" to InputCharacterPolicy.display(n)) }); return }
        dir = n; scroll = 0; selectedPath=null;refresh()
    }

    override fun draw(s: Surface, r: Rect) {
        s.fill(r, Palette.WHITE)
        buttons.clear()
        val actions = listOf<Pair<String, () -> Unit>>("up" to { cd("..") }, "new" to { newFile() }, "new_folder" to { newDir() }, "home" to { cd("C:/Home") })
        val labels = actions.map { tr("files.button.${it.first}") }
        val layout = s.toolbarLayout(labels, r, HEADER, 36)
        headerHeight = layout.height
        val header = headerHeight
        s.fillRect(r.x, r.y, r.w, header, Palette.LTGRAY)
        for ((i, action) in actions.withIndex()) {
            val (key, a) = action
            val l = labels[i]; val br = layout.buttons[i]
            s.templeButton(br, l, ButtonFace.NORMAL)
            buttons.add(br to a)
            a11yButton(br, tr("files.a11y.$key"))
        }
        val pathRect = layout.trailing
        val pathShown = dir.takeLast(maxOf(1, (pathRect.w - 4) / 8))
        s.text(pathRect.x + 4, pathRect.y + (pathRect.h - 8) / 2, pathShown, Palette.BLACK)
        a11yText(pathRect, tr("files.a11y.folder", "path" to InputCharacterPolicy.display(dir)))
        val listTop = r.y + header
        val rows = maxOf(1, (r.h - header) / ROW_H)
        scroll = scroll.coerceIn(0, maxOf(0, entries.size - rows))
        if (entries.isEmpty()) { val t = tr("files.empty"); s.uiText(r.x + 8, listTop + 8, t, Palette.DKGRAY, r.w - 16); a11yText(Rect(r.x, listTop, r.w, ROW_H), t) }
        for (i in 0 until rows) {
            val e = entries.getOrNull(scroll + i) ?: break
            val y = listTop + i * ROW_H
            if (i % 2 == 1) s.fillRect(r.x, y, r.w, ROW_H, 0x07.let { Palette.WHITE })
            val icon = if (e.isDir) "\u00FE" else when (e.name.substringAfterLast('.', "").uppercase()) { "HC", "HH" -> "\u0011"; "DD", "TXT" -> "\u00F0"; else -> "\u00FA" }
            val color = if (e.isDir) Palette.CYAN else if (e.readOnly) Palette.BLUE else Palette.PURPLE
            s.text(r.x + 4, y + 6, icon, color)
            s.text(r.x + 16, y + 6, (e.name + if (e.isDir) "/" else "").take((r.w - 90) / 8), color)
            if (!e.isDir) {
                val size = if (e.size >= 1024) "${e.size / 1024}K" else "${e.size}"
                s.text(r.right - size.length * 8 - 4, y + 6, size, Palette.DKGRAY)
            }
            s.hline(r.x, r.right - 1, y + ROW_H - 1, Palette.LTGRAY)
            a11yButton(Rect(r.x, y, r.w, ROW_H), if (e.isDir) tr("files.a11y.folder_item", "name" to InputCharacterPolicy.display(e.name)) else tr("files.a11y.file_item", "name" to InputCharacterPolicy.display(e.name), "size" to e.size))
        }
        if (entries.size > rows) {
            val h = (r.h - header) * rows / entries.size
            val y = listTop + (r.h - header - h) * scroll / maxOf(1, entries.size - rows)
            s.fillRect(r.right - 3, y, 3, maxOf(8, h), Palette.BLUE)
        }
    }

    override fun pointer(e: PointerEvent, r: Rect): Boolean {
        if (e.action == Ptr.DOWN && e.y < r.y + headerHeight) { buttons.firstOrNull { it.first.contains(e.x, e.y) }?.second?.invoke(); return true }
        return false
    }

    private fun entryAt(y: Int, r: Rect): FsEntry? {
        if (y < r.y + headerHeight) return null
        return entries.getOrNull(scroll + (y - r.y - headerHeight) / ROW_H)
    }

    override fun tap(x: Int, y: Int, r: Rect) {
        val e = entryAt(y, r) ?: return
        selectedPath=e.path
        if (e.isDir) { cd(e.path); return }
        open(e)
    }

    fun open(e: FsEntry) {
        if (e.name.endsWith(".GR", true) || e.name.endsWith(".GR.Z", true)) {
            Launch.paint(shell, e.path); return
        }
        when (e.name.substringAfterLast('.', "").uppercase()) {
            "HC" -> shell.showMenu(listOf(
                MenuItem( { tr("files.menu.run") }) { Launch.program(shell, e.path, shell.catalog.byPath(e.path)) },
                MenuItem( { tr("files.menu.edit") }) { Launch.editor(shell, e.path) },
            ), 40, shell.height / 3, { e.name })
            "DD", "TXT" -> Launch.doc(shell, e.path)
            "HH" -> Launch.editor(shell, e.path)
            else -> Launch.doc(shell, e.path)
        }
    }

    override fun longPress(x: Int, y: Int, r: Rect) {
        val e = entryAt(y, r) ?: return
        selectedPath=e.path
        val items = arrayListOf(
            MenuItem( { tr("files.menu.open") }) { if (e.isDir) cd(e.path) else open(e) },
            MenuItem( { tr("files.menu.rename") }) { rename(e) },
            MenuItem( { tr("files.menu.copy_to") }) { copyOrMove(e, move = false) },
            MenuItem( { tr("files.menu.move_to") }) { copyOrMove(e, move = true) },
            MenuItem( { tr("files.menu.delete") }) {
                shell.showDialog(Dialog.confirmDestructive( { tr("dialog.delete.title", "name" to InputCharacterPolicy.display(e.name)) }, { tr(if (e.readOnly) "dialog.delete.message_bundled" else "dialog.delete.message") }, { tr("button.delete") }) {
                    try { shell.fs.delete(e.path, recursive = true); refresh() } catch (x: FsError) { shell.showToast( { x.localized() }) }
                })
            },
        )
        if (!e.isDir && !e.readOnly && isModifiedOriginal(e)) items.add(MenuItem( { tr("files.menu.restore_original") }) {
            try { shell.fs.restoreOriginal(e.path); refresh() } catch (x: FsError) { shell.showToast( { x.localized() }) } // as on iOS
        })
        if (!e.isDir && e.name.endsWith(".HC", true)) items.add(1, MenuItem( { tr("files.menu.edit") }) { Launch.editor(shell, e.path) })
        shell.showMenu(items, x, y, { InputCharacterPolicy.display(e.name) })
    }

    /** A user copy shadowing a bundled original (restoring removes the copy). */
    private fun isModifiedOriginal(e: FsEntry) = shell.fs.hasBundledOriginal(e.path)

    private fun rename(e: FsEntry) {
        shell.showDialog(Dialog.input( { tr("files.dialog.rename", "name" to InputCharacterPolicy.display(e.name)) }, e.name) { n ->
            if (n.isNullOrBlank() || n == e.name) return@input
            if (n.contains('/')) { shell.showToast( { tr("files.name_no_slash") }); return@input }
            try { shell.fs.move(e.path, Paths.parent(e.path).trimEnd('/') + "/" + n); refresh() } catch (x: FsError) { shell.showToast( { x.localized() }) }
        })
    }

    private fun copyOrMove(e: FsEntry, move: Boolean) {
        shell.showDialog(Dialog.input( { tr(if (move) "files.dialog.move_to" else "files.dialog.copy_to") }, dir) { d ->
            if (d == null) return@input
            val target = Paths.normalize(dir, d) ?: return@input
            val dst = if (shell.fs.isDir(target)) target.trimEnd('/') + "/" + e.name else target
            try {
                if (move) shell.fs.move(e.path, dst)
                else if (e.isDir) shell.showToast( { tr("files.copy_folder_unsupported") })
                else shell.fs.writeFile(dst, shell.fs.readFile(e.path) ?: throw FsError("Could not read ${e.path}", "fs.error.could_not_read", mapOf("path" to e.path)))
                refresh()
            } catch (x: FsError) { shell.showToast( { x.localized() }) }
        })
    }

    private fun newFile() {
        shell.showDialog(Dialog.input( { tr("files.dialog.new_file") }, "New.HC") { n ->
            if (n.isNullOrBlank()) return@input
            val name = if (n.contains('.')) n else "$n.HC"
            val p = Paths.normalize(dir, name) ?: run { shell.showToast( { tr("toast.invalid_name") }); return@input }
            if (shell.fs.exists(p)) { shell.showToast( { tr("toast.already_exists") }); return@input }
            try { shell.fs.writeFile(p, ByteArray(0)); refresh(); Launch.editor(shell, p) } catch (x: FsError) { shell.showToast( { x.localized() }) }
        })
    }

    private fun newDir() {
        shell.showDialog(Dialog.input( { tr("files.dialog.new_folder") }, "Folder") { n -> // l10n-ok: default name on the TempleOS drive (ASCII file names)
            if (n.isNullOrBlank()) return@input
            val p = Paths.normalize(dir, n) ?: run { shell.showToast( { tr("toast.invalid_name") }); return@input }
            try { shell.fs.mkdir(p); refresh() } catch (x: FsError) { shell.showToast( { x.localized() }) }
        })
    }

    override fun scroll(dx: Int, dy: Int, r: Rect) {
        scrollAcc -= dy
        scroll += scrollAcc / ROW_H; scrollAcc %= ROW_H
        scroll = scroll.coerceIn(0, maxOf(0, entries.size - 1))
        invalidate()
    }

    override fun key(ch: Int, sc: Long, down: Boolean): Boolean {
        if (!down) return true
        when ((sc and 0x7F).toInt()) {
            Keys.SC_CURSOR_DOWN -> { scroll++; invalidate() }
            Keys.SC_CURSOR_UP -> { scroll = maxOf(0, scroll - 1); invalidate() }
            Keys.SC_BACKSPACE -> cd("..")
        }
        return true
    }

    override fun menu():List<MenuItem> {
        val close:()->Unit={shell.windows.firstOrNull {it.app===this}?.let {shell.close(it)};Unit}
        val actions=hashMapOf<String,()->Unit>("File/DirMk" to {newDir()},"File/Abort" to close,"File/Exit" to close)
        entries.firstOrNull {it.path==selectedPath}?.let {e->
            actions["File/Rename"]={rename(e)}
            if(!e.isDir) {
                actions["Edit/Ed"]={Launch.editor(shell,e.path)}
                actions["Edit/Plain"]={Launch.editor(shell,e.path)}
                if(e.name.endsWith(".HC",true))actions["Program/Include"]={Launch.program(shell,e.path,shell.catalog.byPath(e.path))}
            }
        }
        return OriginalContextMenu.items(shell,"C:/Doc/FileMgrPullDown.DD",actions) + listOf(
        MenuItem( { tr("files.menu.refresh") }) { refresh() },
        MenuItem( { tr("files.menu.new_file") }) { newFile() },
        MenuItem( { tr("files.menu.new_folder") }) { newDir() },
        MenuItem( { tr("files.menu.open_terminal") }) { Launch.terminal(shell, dir) },
        MenuItem( { tr("files.menu.storage", "used" to shell.fs.usedBytes() / 1024, "total" to (shell.fs.quota shr 20)) }, enabled = false) {},
    )
    }

    override fun saveState() = mapOf("dir" to dir)

    companion object { val HEADER get() = Touch.header }
}

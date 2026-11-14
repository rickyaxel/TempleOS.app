package io.github.templeosmobile.core.ui

import io.github.templeosmobile.core.kernel.FsError

/**
 * Start menu > Import...: the first-time explanation (until the user continues once; Settings `i=1`), the
 * platform's document picker ([ShellEnv.pickImportFiles]), [FileImport] on a background thread, a question for
 * each name that is already taken (Replace / Keep Both / Cancel), then a summary with Open Folder, and Run when
 * one program was imported. Imported code runs only when the user chooses Run here or in Files.
 *
 * UI thread, except [receive]. While a picker or an import is in progress ([busy]) Import does nothing, so
 * repeated taps never open a second picker. Its dialogs wait while another dialog (a program's) is open.
 */
class ImportFlow internal constructor(private val shell: Shell) {
    /** A picker is open or files are being imported. */
    var busy = false
        private set
    /** Picked batches still being prepared on background threads. */
    private var working = 0
    /** A Replace / Keep Both / Cancel question is open. */
    private var asking = false
    private val queue = ArrayDeque<FileImport.Prepared>()
    /** Summary lines (re-read when the language changes while the summary is open). */
    private val lines = ArrayList<() -> String>()
    private val imported = ArrayList<Pair<String, Boolean>>()
    private var failures = 0

    /** The start menu's Import... row. */
    fun start() {
        if (busy) return
        if (!shell.settings.importIntroSeen) { showIntro(); return }
        openPicker()
    }

    private fun showIntro() {
        shell.showDialog(Dialog.choose( { tr("import.intro.title") }, { tr("import.intro.message", "path" to FileImport.DESTINATION) },
            { listOf(tr("button.choose_files") to 1L, tr("button.cancel") to 0L) }, listOf(-1, -1)) { v ->
            // Cancel, Esc and back leave it unacknowledged: the explanation comes again next time
            if (v != 1L) return@choose
            shell.settings.importIntroSeen = true
            shell.saveSession()
            shell.post { openPicker() }
        })
    }

    private fun openPicker() {
        if (busy) return
        busy = true
        if (!shell.env.pickImportFiles()) { busy = false; shell.showToast { tr("import.unavailable") } }
    }

    /**
     * The picker's result, from any thread: the private copies of the chosen documents, or none when the picker
     * was cancelled. Also accepted when no picker is pending (Android delivers a result to a recreated activity).
     */
    fun receive(files: List<PickedFile>) {
        shell.post { received(files) }
    }

    private fun received(files: List<PickedFile>) {
        if (files.isEmpty()) {
            if (working == 0 && !asking && queue.isEmpty()) busy = false
            return
        }
        busy = true
        working++
        shell.showToast { tr("import.progress") }
        val fs = shell.fs; val sh = shell
        val picked = files.take(FileImport.MAX_PICKED); val extra = files.drop(FileImport.MAX_PICKED)
        Thread({
            val prepared = try {
                picked.map { FileImport.prepare(fs, it) } +
                    extra.map { FileImport.refuse(it, ImportError("import.error.too_many_files", "count" to FileImport.MAX_PICKED)) }
            } catch (e: Throwable) { // never leave the flow busy: every file is reported
                files.map { FileImport.refuse(it, ImportError("import.error.interrupted")) }
            }
            sh.post {
                working--
                queue.addAll(prepared)
                if (!asking) next()
            }
        }, "TempleOS-Import").apply { isDaemon = true }.start()
    }

    /** Publishes the prepared files in order, asking when a name is taken; the summary comes after the last. */
    private fun next() {
        while (queue.isNotEmpty()) {
            val p = queue.removeFirst()
            val e = p.error
            if (e != null) { fail(p, e); continue }
            val target = FileImport.DESTINATION + "/" + p.name
            if (!shell.fs.exists(target)) { publish(p, p.name, false); continue }
            ask(p, target)
            return
        }
        if (working == 0) finish()
    }

    private fun ask(p: FileImport.Prepared, target: String) {
        asking = true
        val canReplace = !shell.fs.hasBundledOriginal(target)
        var answered = false
        val d = Dialog.choose( { tr("dialog.replace.title", "name" to InputCharacterPolicy.display(p.name)) },
            { tr("import.conflict.message", "path" to InputCharacterPolicy.display(target)) },
            { (if (canReplace) listOf(tr("button.replace") to 1L) else emptyList()) + listOf(tr("button.keep_both") to 2L, tr("button.cancel") to 0L) },
            if (canReplace) listOf(Dialog.DESTRUCTIVE_ROW, -1, -1) else listOf(-1, -1)) { v ->
            if (answered) return@choose
            answered = true
            // dismissed: by the user (back, Esc), or replaced by another dialog (a program's), then asked again
            shell.post {
                if (v == -1L && shell.dialogOpen) { whenFree { ask(p, target) }; return@post }
                decide(p, v)
            }
        }
        whenFree { shell.showDialog(d) }
    }

    private fun decide(p: FileImport.Prepared, choice: Long) {
        asking = false
        when (choice) {
            1L -> publish(p, p.name, true)
            2L -> {
                val n = FileImport.freeName(shell.fs, p.name)
                if (n != null) publish(p, n, false)
                else fail(p, FsError("Already exists", "fs.error.already_exists", mapOf("path" to FileImport.DESTINATION + "/" + p.name)))
            }
            else -> {
                val source = p.source
                lines.add { tr("import.result.skipped", "name" to source) }
                discardLater(p)
            }
        }
        next()
    }

    private fun publish(p: FileImport.Prepared, name: String, replace: Boolean) {
        try {
            val path = FileImport.publish(shell.fs, p, name, replace)
            imported.add(path to p.isDir)
            val source = p.source; val shown = InputCharacterPolicy.display(path); val count = p.files
            if (p.isDir) lines.add { tr("import.result.folder", "name" to source, "path" to shown, "count" to count) }
            else lines.add { tr("import.result.file", "name" to source, "path" to shown) }
            discardLater(p)
        } catch (e: Exception) {
            fail(p, e)
        }
    }

    private fun fail(p: FileImport.Prepared, e: Throwable) {
        failures++
        val source = p.source
        lines.add { tr("import.result.failed", "name" to source, "reason" to FileImport.reason(e)) }
        discardLater(p)
    }

    /** The staging folder (with a replaced entry in it) is deleted off the UI thread. */
    private fun discardLater(p: FileImport.Prepared) {
        val fs = shell.fs
        Thread({ FileImport.discard(fs, p) }, "TempleOS-Import-Cleanup").apply { isDaemon = true }.start()
    }

    private fun finish() {
        busy = false
        // open Files windows show the new entries (each re-lists only its own folder)
        for (w in shell.windows) (w.app as? FilesApp)?.refresh()
        val ok = imported.size; val failed = failures; val summary = lines.toList(); val paths = imported.toList()
        lines.clear(); imported.clear(); failures = 0
        if (ok == 0 && failed == 0) { shell.showToast { tr("import.nothing") }; return }
        val folder = if (paths.size == 1 && paths[0].second) paths[0].first else FileImport.DESTINATION
        val program = paths.singleOrNull()?.takeIf { !it.second && it.first.uppercase().endsWith(".HC") }?.first
        val sh = shell
        val d = Dialog.choose( { if (ok == 0) tr("import.failed.title") else if (failed > 0) tr("import.partial.title") else tr("import.done.title") },
            { summary.joinToString("\n") { it() } },
            { (if (ok > 0) listOf(tr("button.open_folder") to 1L) else emptyList()) + (if (program != null) listOf(tr("button.run") to 2L) else emptyList()) +
                listOf(tr("button.close") to 0L) },
            listOf(-1, -1, -1)) { v ->
            if (v == 1L) sh.post { Launch.files(sh, folder) }
            else if (v == 2L && program != null) sh.post { Launch.program(sh, program, sh.catalog.byPath(program)) }
        }
        whenFree { shell.showDialog(d) }
    }

    /** Runs [f] once no other dialog is open (checked again every 300 ms, without keeping the display busy). */
    private fun whenFree(f: () -> Unit) {
        if (!shell.dialogOpen) { f(); return }
        val sh = shell
        Thread({ Thread.sleep(300); sh.post { whenFree(f) } }, "TempleOS-Import-Wait").apply { isDaemon = true }.start()
    }
}

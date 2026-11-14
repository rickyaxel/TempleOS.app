import Foundation

// Port of ui/ImportFlow.kt.

/**
 * Start menu > Import...: the first-time explanation (until the user continues once; Settings `i=1`), the
 * platform's document picker ([ShellEnv.pickImportFiles]), [FileImport] on a background thread, a question for
 * each name that is already taken (Replace / Keep Both / Cancel), then a summary with Open Folder, and Run when
 * one program was imported. Imported code runs only when the user chooses Run here or in Files.
 *
 * UI thread, except [receive]. While a picker or an import is in progress ([busy]) Import does nothing, so
 * repeated taps never open a second picker. Its dialogs wait while another dialog (a program's) is open.
 */
public final class ImportFlow {
    private unowned let shell: Shell
    /** A picker is open or files are being imported. */
    public private(set) var busy = false
    /** Picked batches still being prepared on background threads. */
    private var working = 0
    /** A Replace / Keep Both / Cancel question is open. */
    private var asking = false
    private var queue: [FileImport.Prepared] = []
    /** Summary lines (re-read when the language changes while the summary is open). */
    private var lines: [() -> String] = []
    private var imported: [(path: String, isDir: Bool)] = []
    private var failures = 0

    init(_ shell: Shell) { self.shell = shell }

    /** The start menu's Import... row. */
    public func start() {
        if busy { return }
        if !shell.settings.importIntroSeen { showIntro(); return }
        openPicker()
    }

    private func showIntro() {
        shell.showDialog(Dialog.choose(tr("import.intro.title"), tr("import.intro.message", ("path", FileImport.DESTINATION)),
                                       [(tr("button.choose_files"), Int64(1)), (tr("button.cancel"), Int64(0))], [-1, -1]) { [unowned self] v in
            // Cancel, Esc and back leave it unacknowledged: the explanation comes again next time
            if v != 1 { return }
            shell.settings.importIntroSeen = true
            shell.saveSession()
            shell.post { [unowned self] in openPicker() }
        })
    }

    private func openPicker() {
        if busy { return }
        busy = true
        if !shell.env.pickImportFiles() { busy = false; shell.showToast(tr("import.unavailable")) }
    }

    /**
     * The picker's result, from any thread: the private copies of the chosen documents, or none when the picker
     * was cancelled. Also accepted when no picker is pending (Android delivers a result to a recreated activity).
     */
    public func receive(_ files: [PickedFile]) {
        shell.post { [weak self] in self?.received(files) }
    }

    private func received(_ files: [PickedFile]) {
        if files.isEmpty {
            if working == 0 && !asking && queue.isEmpty { busy = false }
            return
        }
        busy = true
        working += 1
        shell.showToast(tr("import.progress"))
        let fs = shell.fs, sh = shell
        let picked = Array(files.prefix(FileImport.MAX_PICKED)), extra = Array(files.dropFirst(FileImport.MAX_PICKED))
        let t = Thread { [weak self] in
            var prepared = picked.map { FileImport.prepare(fs, $0) }
            prepared += extra.map { FileImport.refuse($0, ImportError("import.error.too_many_files", ("count", FileImport.MAX_PICKED))) }
            sh.post { [weak self] in
                guard let self = self else { prepared.forEach { FileImport.discard(fs, $0) }; return }
                working -= 1
                queue += prepared
                if !asking { next() }
            }
        }
        t.name = "TempleOS-Import"
        t.start()
    }

    /** Publishes the prepared files in order, asking when a name is taken; the summary comes after the last. */
    private func next() {
        while !queue.isEmpty {
            let p = queue.removeFirst()
            if let e = p.error { fail(p, e); continue }
            let target = FileImport.DESTINATION + "/" + p.name
            if !shell.fs.exists(target) { publish(p, p.name, replace: false); continue }
            ask(p, target)
            return
        }
        if working == 0 { finish() }
    }

    private func ask(_ p: FileImport.Prepared, _ target: String) {
        asking = true
        let canReplace = !shell.fs.hasBundledOriginal(target)
        var answered = false
        let d = Dialog.choose(tr("dialog.replace.title", ("name", InputCharacterPolicy.display(p.name))),
                              tr("import.conflict.message", ("path", InputCharacterPolicy.display(target))),
                              (canReplace ? [(tr("button.replace"), Int64(1))] : []) + [(tr("button.keep_both"), Int64(2)), (tr("button.cancel"), Int64(0))],
                              canReplace ? [Dialog.DESTRUCTIVE_ROW, -1, -1] : [-1, -1]) { [unowned self] v in
            if answered { return }
            answered = true
            // dismissed: by the user (back, Esc), or replaced by another dialog (a program's), then asked again
            shell.post { [unowned self] in
                if v == -1 && shell.dialogOpen { whenFree { [unowned self] in ask(p, target) }; return }
                decide(p, v)
            }
        }
        whenFree { [unowned self] in shell.showDialog(d) }
    }

    private func decide(_ p: FileImport.Prepared, _ choice: Int64) {
        asking = false
        switch choice {
        case 1: publish(p, p.name, replace: true)
        case 2:
            if let n = FileImport.freeName(shell.fs, p.name) { publish(p, n, replace: false) }
            else { fail(p, FsError("Already exists", "fs.error.already_exists", ["path": FileImport.DESTINATION + "/" + p.name])) }
        default:
            let source = p.source
            lines.append { tr("import.result.skipped", ("name", source)) }
            discardLater(p)
        }
        next()
    }

    private func publish(_ p: FileImport.Prepared, _ name: String, replace: Bool) {
        do {
            let path = try FileImport.publish(shell.fs, p, as: name, replace: replace)
            imported.append((path, p.isDir))
            let source = p.source, shown = InputCharacterPolicy.display(path), count = p.files
            if p.isDir { lines.append { tr("import.result.folder", ("name", source), ("path", shown), ("count", count)) } }
            else { lines.append { tr("import.result.file", ("name", source), ("path", shown)) } }
            discardLater(p)
        } catch {
            fail(p, error)
        }
    }

    private func fail(_ p: FileImport.Prepared, _ e: Error) {
        failures += 1
        let source = p.source
        lines.append { tr("import.result.failed", ("name", source), ("reason", FileImport.reason(e))) }
        discardLater(p)
    }

    /** The staging folder (with a replaced entry in it) is deleted off the UI thread. */
    private func discardLater(_ p: FileImport.Prepared) {
        let fs = shell.fs
        let t = Thread { FileImport.discard(fs, p) }
        t.name = "TempleOS-Import-Cleanup"
        t.start()
    }

    private func finish() {
        busy = false
        // open Files windows show the new entries (each re-lists only its own folder)
        for w in shell.windows { (w.app as? FilesApp)?.refresh() }
        let ok = imported.count, failed = failures, summary = lines, paths = imported
        lines = []; imported = []; failures = 0
        if ok == 0 && failed == 0 { shell.showToast(tr("import.nothing")); return }
        let folder = paths.count == 1 && paths[0].isDir ? paths[0].path : FileImport.DESTINATION
        let program: String? = paths.count == 1 && !paths[0].isDir && paths[0].path.uppercased().hasSuffix(".HC") ? paths[0].path : nil
        let sh = shell
        let d = Dialog.choose(ok == 0 ? tr("import.failed.title") : failed > 0 ? tr("import.partial.title") : tr("import.done.title"),
                              summary.map { $0() }.joined(separator: "\n"),
                              (ok > 0 ? [(tr("button.open_folder"), Int64(1))] : []) + (program != nil ? [(tr("button.run"), Int64(2))] : [])
                                + [(tr("button.close"), Int64(0))],
                              [-1, -1, -1]) { v in
            if v == 1 { sh.post { Launch.files(sh, folder) } }
            else if v == 2, let path = program { sh.post { Launch.program(sh, path, sh.catalog.byPath(path)) } }
        }
        whenFree { [unowned self] in shell.showDialog(d) }
    }

    /** Runs [f] once no other dialog is open (checked again every 300 ms, without keeping the display busy). */
    private func whenFree(_ f: @escaping () -> Void) {
        if !shell.dialogOpen { f(); return }
        let sh = shell
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in sh.post { self?.whenFree(f) } }
    }
}

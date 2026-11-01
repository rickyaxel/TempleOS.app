package io.github.templeosmobile.core.kernel

import io.github.templeosmobile.core.holyc.*

/** Shell-level file commands (Dir, Cd, Del, Copy...) on the virtual filesystem. */
class FsCommands(private val k: Kernel, private val t: Task) {
    private val fs get() = k.env.fs
    private fun out(s: String) = k.console.write(s)
    private fun norm(p: String) = Paths.normalize(k.curDir(t), p)

    private fun err(msg: String): Nothing = throw VmFault(chCode("File"), msg)

    fun dir(mask0: String, full: Boolean): Long {
        val vfs = fs ?: return 0
        var mask = mask0
        var dir = k.curDir(t)
        val asPath = norm(mask0)
        if (asPath != null && vfs.isDir(asPath)) { dir = asPath; mask = "*" }
        else if (mask0.contains('/')) {
            val p = norm(mask0.substringBeforeLast('/').ifEmpty { "/" }) ?: return 0
            dir = p; mask = mask0.substringAfterLast('/')
        }
        val entries = vfs.list(dir) ?: run { out("\$RED\$Directory not found: $dir\$FG\$\n"); return 0 }
        out("\$MA-X+PU,\"Directory\"\$ of \$GREEN\$$dir\$FG\$\n")
        out("DATE_ TIME_ SIZE\n")
        var n = 0L
        for (e in entries.sortedWith(compareBy({ !it.isDir }, { it.name.lowercase() }))) {
            if (!e.isDir && !Paths.matches(mask, e.name)) continue
            val date = dirDate(e)
            val size = if (e.isDir) "    " else "%04X".format(java.util.Locale.ROOT, minOf(e.size, 0xFFFF))
            val color = if (e.isDir) "\$CYAN\$" else if (e.readOnly) "\$BLUE\$" else "\$PURPLE\$"
            out("$date $size $color${e.name}${if (e.isDir) "/" else ""}\$FG\$\n")
            n++
        }
        return n
    }

    fun cd(target: String, makeDirs: Boolean): Boolean {
        val vfs = fs ?: return false
        val p = norm(target) ?: run { out("\$RED\$Invalid path\$FG\$\n"); return false }
        if (!vfs.isDir(p)) {
            if (makeDirs) try { vfs.mkdir(p) } catch (e: FsError) { out("\$RED\$${e.message}\$FG\$\n"); return false }
            else { out("\$RED\$Directory not found: $p\$FG\$\n"); return false }
        }
        k.mem.st8(t.fsAddr + k.o.task("cur_dir"), k.prog.stringAddr(latin1(p)).toLong())
        return true
    }

    fun mkdir(target: String): Boolean {
        val p = norm(target) ?: return false
        return try { fs?.mkdir(p); true } catch (e: FsError) { out("\$RED\$${e.message}\$FG\$\n"); false }
    }

    private fun expand(mask: String): List<String> {
        val vfs = fs ?: return emptyList()
        val p = norm(mask) ?: return emptyList()
        if (!mask.contains('*') && !mask.contains('?')) return if (vfs.exists(p)) listOf(p) else emptyList()
        val dir = Paths.parent(p)
        val m = Paths.name(p)
        return vfs.list(dir)?.filter { Paths.matches(m, it.name) }?.map { it.path } ?: emptyList()
    }

    fun del(mask: String, delDir: Boolean, print: Boolean): Long {
        var n = 0L
        for (p in expand(mask)) {
            try {
                if (fs!!.isDir(p) && !delDir) continue
                fs!!.delete(p)
                if (print) out("Del $p\n")
                n++
            } catch (e: FsError) { out("\$RED\$${e.message}\$FG\$\n") }
        }
        return n
    }

    fun delTree(mask: String): Long {
        var n = 0L
        for (p in expand(mask)) {
            try { fs!!.delete(p, recursive = true); n++ } catch (e: FsError) { out("\$RED\$${e.message}\$FG\$\n") }
        }
        return n
    }

    fun copy(src: String, dst: String): Boolean {
        val vfs = fs ?: return false
        val srcs = expand(src)
        if (srcs.isEmpty()) { out("\$RED\$File not found: $src\$FG\$\n"); return false }
        val d = norm(dst) ?: return false
        for (s in srcs) {
            val data = vfs.readFile(s) ?: continue
            val target = if (vfs.isDir(d)) "$d/${Paths.name(s)}" else d
            try { vfs.writeFile(target, data); out("Copy $s ${target}\n") } catch (e: FsError) { out("\$RED\$${e.message}\$FG\$\n"); return false }
        }
        return true
    }

    fun move(src: String, dst: String): Boolean {
        val vfs = fs ?: return false
        val s = norm(src) ?: return false
        var d = norm(dst) ?: return false
        if (vfs.isDir(d)) d = "$d/${Paths.name(s)}"
        return try { vfs.move(s, d); true } catch (e: FsError) { out("\$RED\$${e.message}\$FG\$\n"); false }
    }

    fun type(file: String) {
        val p = norm(file) ?: return
        val data = fs?.readFile(p) ?: run { out("\$RED\$File not found: $file\$FG\$\n"); return }
        val end = data.indexOf(0.toByte()).let { if (it < 0) data.size else it }
        k.console.write(data, 0, end)
        out("\n")
    }

    /** Compiles and runs a file inside the current task (nested; must not block). */
    fun exeFile(file: String): Long {
        val p = norm(file) ?: return 0
        val data = fs?.readFile(p) ?: run { out("\$RED\$File not found: $file\$FG\$\n"); return 0 }
        val init = try {
            k.prog.compile(SourceFile.parse(p, data), Paths.parent(p), k.vfsProvider(), k.defines)
        } catch (e: CompileError) { out("\$RED\$${e.message}\$FG\$\n"); return 0 }
        return k.vm.callFunction(t, k.prog.funcPtr(init))
    }

    companion object {
        /**
         * "MM/DD HH:MM" as TempleOS's Dir prints it. Bundled entries carry the ISO's wall-clock
         * time (shown as is, in UTC terms); user files carry a real instant (shown in local time).
         */
        fun dirDate(e: FsEntry): String {
            if (e.modified <= 0) return "--/-- --:--"
            val tz = if (e.readOnly) java.util.TimeZone.getTimeZone("UTC") else java.util.TimeZone.getDefault()
            val cal = java.util.Calendar.getInstance(tz).apply { timeInMillis = e.modified }
            return "%02d/%02d %02d:%02d".format(java.util.Locale.ROOT, cal.get(java.util.Calendar.MONTH) + 1, cal.get(java.util.Calendar.DAY_OF_MONTH),
                cal.get(java.util.Calendar.HOUR_OF_DAY), cal.get(java.util.Calendar.MINUTE))
        }
    }
}

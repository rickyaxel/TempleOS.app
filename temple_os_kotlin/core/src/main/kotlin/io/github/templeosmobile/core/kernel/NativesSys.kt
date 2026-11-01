package io.github.templeosmobile.core.kernel

import io.github.templeosmobile.core.Brand
import io.github.templeosmobile.core.holyc.*

/**
 * System-level host functions: runtime compilation (ExePrint/ExeFile), the
 * registry (game settings and high scores), and document/task utilities.
 */
class NativesSys(private val k: Kernel) {
    private val mem get() = k.mem

    private fun reg(t: NativeTable, name: String, fn: NativeFn) {
        t.add(object : Native(name) {
            override fun call(t: Task, base: Int, argc: Int): Long =
                try { fn.call(t, base, argc) } catch (e: CompileError) { throw VmFault(COMPILER, e.message ?: "compile error") }
        })
    }

    fun register(nt: NativeTable) {
        // Compiler/CMain.HC: ExePrint catches a compile error and returns 0; ExePrint2 throws it
        // ('Compiler'), which GetI64 and GetF64 catch to ask again
        reg(nt, "ExePrint") { t, a, n ->
            val src = k.fmt.format(mem.readStrBytes(t.st[a]), t.st, a + 1, n - 1)
            if (k.isNative) k.dynExpr.exePrint(t, src, rethrow = false)
            else runNested(t, "C:/Home/ExePrint.HC", src, k.curDir(t))
        }
        reg(nt, "ExePrint2") { t, a, n ->
            val src = k.fmt.format(mem.readStrBytes(t.st[a]), t.st, a + 1, n - 1)
            if (k.isNative) k.dynExpr.exePrint(t, src, rethrow = true)
            else runNested(t, "C:/Home/ExePrint.HC", src, k.curDir(t), rethrow = true)
        }
        reg(nt, "ExeFile") { t, a, _ ->
            if(k.isNative) {
                val path=Paths.normalize(k.curDir(t),mem.readStr(t.st[a])) ?: return@reg 0
                val source=k.native!!.fileSession(k,path);var result=0L
                while(true) {val fn=source.next() ?: break;result=k.vm.callFunction(t,k.prog.funcPtr(fn))};return@reg result
            }
            val p = Paths.normalize(k.curDir(t), mem.readStr(t.st[a])) ?: return@reg 0
            val data = k.env.fs?.readFile(p) ?: run { k.console.write("\$RED\$File not found: $p\$FG\$\n"); return@reg 0 }
            runNested(t, p, data, Paths.parent(p))
        }
        reg(nt, "RegDft") { t, a, _ ->
            val path = mem.readStr(t.st[a])
            val reg = registry()
            if (reg.containsKey(path)) 1 else {
                reg[path] = mem.readStr(t.st[a + 1])
                saveRegistry(reg)
                0
            }
        }
        reg(nt, "RegExe") { t, a, _ ->
            val path = mem.readStr(t.st[a])
            val code = registry()[path] ?: return@reg 0
            val nb = k.native
            if (nb != null) nb.regExe(k, t, path, code)
            else runNested(t, "C:/Home/Registry.HC", latin1(code), "C:/Home")
        }
        reg(nt, "RegWrite") { t, a, n ->
            val path = mem.readStr(t.st[a])
            val code = latin1(k.fmt.format(mem.readStrBytes(t.st[a + 1]), t.st, a + 2, n - 2))
            val reg = registry()
            reg[path] = code
            saveRegistry(reg)
            1
        }
        reg(nt, "RegCnt") { t, a, _ -> if (registry().containsKey(mem.readStr(t.st[a]))) 1 else 0 }
        reg(nt, "MenuNew") { t, a, _ ->
            val task = if (t.st[a + 2] != 0L) t.st[a + 2] else t.fsAddr.toLong()
            menuNew(mem.readStr(t.st[a]), t.st[a + 1], task)
        }
        reg(nt, "PopUpChoose") { t, a, _ ->
            // PopUpChoose(U8 *header,U8 *footer,U8 *labels,I64 *values,I64 *bgs,I64 cnt)
            val pending = k.popup
            if (t.resumed && pending?.result != null) {
                t.resumed = false
                k.popup = null
                pending.result!!
            } else if (t.nestLevel > 0) -1 else {
                val cnt = t.st[a + 5].toInt().coerceIn(0, 4096)
                val items = ArrayList<PopupRequest.Item>()
                var lp = if (t.st[a + 2] != 0L) mem.check(t.st[a + 2], 1) else 0
                val vp = if (cnt > 0) mem.check(t.st[a + 3], cnt * 8) else 0
                val bp = if (t.st[a + 4] != 0L && cnt > 0) mem.check(t.st[a + 4], cnt * 8) else 0
                for (i in 0 until cnt) {
                    val label = mem.readStr(lp.toLong())
                    lp += label.length + 1
                    items.add(PopupRequest.Item(label, mem.ld8(vp + i * 8), if (bp != 0) mem.ld8(bp + i * 8).toInt() else -1))
                }
                val req = PopupRequest(stripDolDoc(mem.readStr(t.st[a])), stripDolDoc(mem.readStr(t.st[a + 1])), items)
                k.popup = req
                k.env.popupRequested(k, req)
                if (req.result != null) { k.popup = null; req.result!! }
                else { t.resumed = false; k.block(t, Kernel.WAIT_POPUP); 0 }
            }
        }
        reg(nt, "MPInt") { _, _, _ -> 0 }
        // Kernel/KHashB.HC: named values in a task's hash table (task, default Fs), found through the parent
        // tasks' tables; each Noise/Sweep task keeps its own CSoundEffectFrame there (Adam/ASnd.HC)
        reg(nt, "FramePtr") { t, a, _ -> frameFind(fsArg(t, t.st[a + 1]), mem.readStr(t.st[a]))?.let { it.second.last() } ?: 0 }
        reg(nt, "FramePtrAdd") { t, a, _ -> framePtrs.getOrPut(fsArg(t, t.st[a + 2])) { HashMap() }.getOrPut(mem.readStr(t.st[a])) { ArrayList() }.add(t.st[a + 1]); 0 }
        reg(nt, "FramePtrSet") { t, a, _ ->
            val f = frameFind(fsArg(t, t.st[a + 2]), mem.readStr(t.st[a]))
            if (f == null) 0 else { val l = f.second; val old = l.last(); l[l.size - 1] = t.st[a + 1]; old }
        }
        reg(nt, "FramePtrDel") { t, a, _ ->
            val n = mem.readStr(t.st[a])
            val f = frameFind(fsArg(t, t.st[a + 1]), n)
            if (f == null) 0 else {
                val l = f.second; val old = l.removeAt(l.size - 1)
                if (l.isEmpty()) framePtrs[f.first]?.let { m -> m.remove(n); if (m.isEmpty()) framePtrs.remove(f.first) }
                old
            }
        }
        reg(nt, "SleepUntil") { t, a, _ ->
            val wake = TempleClock.jiffyStartNs(t.st[a])
            if (t.nestLevel > 0 || k.taskNow(t) >= wake) 0 // already due on the task's own clock (Kernel.taskNow)
            else if (t.resumed) { t.resumed = false; 0 }
            else { t.wakeAt = wake; k.block(t, Kernel.SLEEP); 0 }
        }
        reg(nt, "TaskRep") { _, _, _ ->
            k.console.write("\$PURPLE\$CPU00\$FG\$\n")
            for (tk in k.tasks) k.console.write("  \$BLUE\$${tk.name}\$FG\$ #${tk.id} ${stateName(tk.state)}\n")
            0
        }
    }

    /** FramePtr tables by task (Fs address): name -> values, the newest last (HashGenericAdd shadows older ones). */
    private val framePtrs = HashMap<Long, HashMap<String, ArrayList<Long>>>()

    private fun fsArg(t: Task, task: Long): Long = if (task != 0L) task else t.fsAddr.toLong()

    /** The table holding [name], searched from [fs] up through its parent tasks (HashFind follows hash_table->next). */
    private fun frameFind(fs: Long, name: String): Pair<Long, ArrayList<Long>>? {
        var f = fs
        var depth = 0
        while (f != 0L && depth++ < 64) {
            framePtrs[f]?.get(name)?.let { return f to it }
            val task = k.taskByFs(f) ?: return null
            f = mem.ld8(task.fsAddr + k.o.task("parent_task"))
        }
        return null
    }

    /** A task is gone: so is its hash table (TempleOS frees it with the task). */
    fun taskGone(fs: Long) { framePtrs.remove(fs) }
    fun allTasksGone() { framePtrs.clear() }

    private fun stripDolDoc(s: String): String {
        val c = Console(); c.write(s); return c.plainText()
    }

    // ---------------------------------------------------------------- menus

    /** Builds a CMenu from TempleOS menu syntax: Name(msg_code,arg1,arg2); and Dir { ... }. */
    private fun menuNew(st: String, flags: Long, task: Long): Long {
        val defs=HashMap(k.defines)
        if(k.isNative) {
            if(menuHeaderDefines==null) k.env.runtimeFile("PreludeDefines.HC")?.let {data->
                val header=HashMap<String,List<Token>>()
                Lexer(null,header).tokenize(SourceFile.parse("C:/Runtime/PreludeDefines.HC",data),"C:/")
                menuHeaderDefines=header
            }
            menuHeaderDefines.orEmpty().forEach {(name,body)->defs.putIfAbsent(name,body)}
        }
        val toks = Lexer(null, defs).tokenize(SourceFile.ofString("menu", st), "C:/")
        var i = 0
        val o = k.o
        val entrySize = o.cls("CMenuEntry").size.toLong()
        fun tk() = toks[i]
        fun isP(s: String) = tk().kind == T.PUNCT && tk().text == s
        fun expr(): Long = MenuExpr(toks, i, k.prog.uiConstants).let { val v = it.eval(); i = it.i; v }
        fun entry(): Long {
            if (tk().kind != T.IDENT) return 0
            val e = mem.calloc(entrySize)
            val name = latin1(tk().text.take(31))
            mem.writeBytes(e + o.member("CMenuEntry", "name"), name)
            i++
            if (isP("(")) {
                i++
                mem.st8(e + o.member("CMenuEntry", "msg_code"), -2) // MSG_KEY_DOWN_UP
                if (!isP(",") && !isP(")")) mem.st8(e + o.member("CMenuEntry", "msg_code"), expr())
                if (isP(",")) i++
                if (!isP(",") && !isP(")")) mem.st8(e + o.member("CMenuEntry", "arg1"), expr())
                if (isP(",")) i++
                if (!isP(",") && !isP(")")) mem.st8(e + o.member("CMenuEntry", "arg2"), expr())
                if (isP(")")) i++
                if (isP(";")) i++
            } else if (isP("{")) {
                i++
                mem.st1(e + o.member("CMenuEntry", "dir"), 1)
                var prev = e + o.member("CMenuEntry", "sub")
                while (!isP("}") && tk().kind != T.EOF) {
                    val c = entry()
                    if (c == 0L) break
                    mem.st8(prev, c.toLong())
                    prev = c.toInt() + o.member("CMenuEntry", "next")
                }
                if (isP("}")) i++
            } else throw VmFault(chCode("Menu"), "menu syntax: expecting '{' or '('")
            return e.toLong()
        }
        val m = mem.calloc(o.cls("CMenu").size.toLong())
        mem.st8(m + o.member("CMenu", "task"), task)
        mem.st8(m + o.member("CMenu", "flags"), flags)
        mem.st1(m + o.member("CMenu", "attr"), (1L shl 4) + 14)
        var prev = m + o.member("CMenu", "sub")
        while (tk().kind != T.EOF) {
            val e = entry()
            if (e == 0L) break
            mem.st8(prev, e)
            prev = e.toInt() + o.member("CMenuEntry", "next")
        }
        k.menuChanged = true
        return m.toLong()
    }

    private var menuHeaderDefines:Map<String,List<Token>>?=null
    private class MenuExpr(val t: List<Token>, var i: Int, val constants:Map<String,Long>) {
        fun eval(): Long = or()
        private fun p(s: String) = t[i].kind == T.PUNCT && t[i].text == s
        private fun or(): Long { var v = xor(); while (p("|")) { i++; v = v or xor() }; return v }
        private fun xor(): Long { var v = and(); while (p("^")) { i++; v = v xor and() }; return v }
        private fun and(): Long { var v = add(); while (p("&")) { i++; v = v and add() }; return v }
        private fun add(): Long { var v = mul(); while (p("+") || p("-")) { val o = t[i++].text; val r = mul(); v = if (o == "+") v + r else v - r }; return v }
        private fun mul(): Long { var v = sh(); while (p("*") || p("/")) { val o = t[i++].text; val r = sh(); v = if (o == "*") v * r else if (r != 0L) v / r else 0 }; return v }
        private fun sh(): Long { var v = un(); while (p("<<") || p(">>")) { val o = t[i++].text; val r = un(); v = if (o == "<<") v shl r.toInt() else v shr r.toInt() }; return v }
        private fun un(): Long {
            val tk = t[i++]
            return when {
                tk.kind == T.PUNCT && tk.text == "-" -> -un()
                tk.kind == T.PUNCT && tk.text == "~" -> un().inv()
                tk.kind == T.PUNCT && tk.text == "!" -> if (un() == 0L) 1 else 0
                tk.kind == T.PUNCT && tk.text == "(" -> { val v = or(); if (p(")")) i++; v }
                tk.kind == T.INT || tk.kind == T.CHAR -> tk.ival
                tk.text == "TRUE" -> 1
                tk.text == "FALSE" -> 0
                tk.text in constants -> constants.getValue(tk.text)
                else -> throw VmFault(chCode("Menu"),"undefined menu constant '${tk.text}'")
            }
        }
    }

    private fun stateName(s: Int) = when (s) {
        Kernel.READY -> "Ready"; Kernel.SLEEP -> "Sleeping"; Kernel.WAIT_MSG -> "AwaitingMsg"
        Kernel.WAIT_FRAME -> "Refresh"; Kernel.SUSPENDED -> "Suspended"; else -> "Dead"
    }

    /**
     * Compiles and runs [src] synchronously on task [t] (TempleOS ExePrint/ExeFile).
     * Runs chunk by chunk so later code can use symbols defined by earlier code.
     * Code executed this way cannot block (it runs nested inside a native call).
     */
    /**
     * A natively translated program has no HolyC compiler at run time. ExePrint/ExePrint2 text (Cartesian's
     * formula, GetI64/GetF64's typed numbers) is evaluated by the native expression engine (k.dynExpr);
     * a file to compile (ExeFile) is reported, as a compile error would be.
     */
    private fun nativeNoCompile(s: String): Long {
        val msg = "this program runs as native code, which does not compile HolyC at run time; use Pure Terry mode to compile ${s.take(60)}"
        k.console.write("\$RED\$$msg\$FG\$\n")
        return 0
    }

    fun runNested(t: Task, name: String, src: ByteArray, dir: String, rethrow: Boolean = false): Long {
        val session = try {
            // like TempleOS's ExePutS, the value of the last expression is the result (an F64 as its
            // bits: GetF64 does ExePrint("ToF64(%s);",st)(F64))
            k.prog.session(SourceFile.parse(name, src), dir, k.vfsProvider(), k.defines, answers = true)
        } catch (e: CompileError) {
            k.console.write("\$RED\$${e.message}\$FG\$\n"); if (rethrow) throw e; k.compileErrorCaught(t); return 0
        }
        var res = 0L
        while (true) {
            val f = try { session.next() } catch (e: CompileError) {
                k.console.write("\$RED\$${e.message}\$FG\$\n"); if (rethrow) throw e; k.compileErrorCaught(t); return res
            } ?: break
            res = k.vm.callFunction(t, k.prog.funcPtr(f))
        }
        return res
    }

    // ---------------------------------------------------------------- registry

    private val regPath = "C:/Home/Registry.HC"

    private var regCache: LinkedHashMap<String, String>? = null

    /** Registry file format: "//#REG path" header lines followed by HolyC code. */
    fun registry(): LinkedHashMap<String, String> {
        regCache?.let { return it }
        val map = LinkedHashMap<String, String>()
        regCache = map
        val data = k.env.fs?.readFile(regPath) ?: return map
        var cur: String? = null
        val sb = StringBuilder()
        for (line in latin1(data).split('\n')) {
            if (line.startsWith("//#REG ")) {
                if (cur != null) map[cur] = sb.toString()
                cur = line.substring(7).trim(); sb.setLength(0)
            } else if (cur != null) sb.append(line).append('\n')
        }
        if (cur != null) map[cur] = sb.toString().removeSuffix("\n")
        return map
    }

    private fun saveRegistry(map: LinkedHashMap<String, String>) {
        regCache = map
        val sb = StringBuilder("//${Brand.APP_NAME} registry: settings saved by programs (RegWrite).\n")
        for ((p, code) in map) sb.append("//#REG ").append(p).append('\n').append(code.trimEnd('\n')).append('\n')
        try { k.env.fs?.writeFile(regPath, latin1(sb.toString())) } catch (_: FsError) {}
    }
}

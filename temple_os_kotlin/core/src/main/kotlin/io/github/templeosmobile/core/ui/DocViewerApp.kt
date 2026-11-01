package io.github.templeosmobile.core.ui

import io.github.templeosmobile.core.kernel.*

/**
 * DolDoc document viewer. Supports the subset used by the bundled
 * documentation: $FG/$BG colors and color names, $TX (+CX centering), $LK links
 * (FI/FF/FL/FA file targets), $MA/$BT macros (run their HolyC in a terminal),
 * $TR trees (shown expanded), $ID indentation, $UL/$IV/$BK, $CL, $WW, $$.
 * Embedded sprites ($SP) are shown as placeholders.
 *
 * Above the document the viewer shows where it comes from ([DocProvenance]): modern app text,
 * drawn by the app and never written into the file. It scrolls away with the document.
 */
class DocViewerApp(shell: Shell, startPath: String) : App(shell) {
    override val kind = "doc"
    var path = startPath; private set
    override val title get() = tr("app.doc.title") + " " + InputCharacterPolicy.display(path.substringAfterLast('/'))
    private val historyStack = ArrayList<String>()
    private var raw: String = ""
    private var laidOutCols = -1
    private val vlines = ArrayList<IntArray>()
    private class Link(val line: Int, val c0: Int, val c1: Int, val target: String, val macro: Boolean, val label:String)
    private val links = ArrayList<Link>()
    /** In 8 px rows, counting the notice's rows before the document's first line. */
    private var top = 0
    private var scrollAcc = 0
    var provenance: DocProvenance? = null; private set
    private var notice: List<Pair<String, Int>> = emptyList()
    private var noticeKey = ""
    private var noticeRows = 0
    private val collapsed=HashMap<String,MutableSet<Int>>()

    init { load(startPath) }

    fun load(p: String) {
        path = p
        val data = shell.fs.readFile(p)
        raw = if (data == null) "\$RED\$" + L10n.tr8("doc.not_found") + "\$FG\$ $p" else textPart(data)
        provenance = if (data == null) null else DocProvenance.of(shell.fs, p)
        laidOutCols = -1; top = 0; noticeKey = ""
        invalidate()
    }

    // ------------------------------------------------------------ layout

    private fun layout(cols: Int) {
        vlines.clear(); links.clear()
        var fg = Palette.BLUE; var bg = Palette.WHITE
        var flags = 0
        var indent = 0
        var cur = ArrayList<Int>()
        var wrap = true
        var hiddenIndent:Int?=null
        fun flush() { vlines.add(cur.toIntArray()); cur = ArrayList(); repeat(indent) { cur.add(' '.code or (bg shl 12) or (fg shl 8)) } }
        fun put(c: Int) {
            if (cur.size >= cols) {
                if (wrap) {
                    // move the current word to the next line
                    var i = cur.size - 1
                    while (i > indent && (cur[i] and 0xFF) != ' '.code) i--
                    if (i > indent && cur.size - i < cols / 2) {
                        val tail = ArrayList(cur.subList(i + 1, cur.size))
                        while (cur.size > i) cur.removeAt(cur.size - 1)
                        flush(); cur.addAll(tail)
                    } else flush()
                } else return
            }
            cur.add((c and 0xFF) or (fg shl 8) or (bg shl 12) or flags)
        }
        fun text(t: String) {
            for (ch in t) when (ch) {
                '\n' -> flush()
                '\t' -> { val n = 8 - (cur.size % 8); repeat(n) { put(' '.code) } }
                '\r' -> {}
                else -> put(ch.code)
            }
        }
        var i = 0
        val s = raw
        while (i < s.length) {
            val tagStart=i
            val c = s[i]
            if (c != '$') {
                if(hiddenIndent!=null) {i++;continue}
                when (c) {
                    '\n' -> flush()
                    '\t' -> { val n = 8 - (cur.size % 8); repeat(n) { put(' '.code) } }
                    '\r' -> {}
                    else -> put(c.code)
                }
                i++; continue
            }
            var end = -1;var k=i+1;var quoted=false
            while(k<s.length) {
                if(s[k]=='\\' && quoted) {k+=2;continue}
                if(s[k]=='"')quoted=!quoted
                if(s[k]=='$' && !quoted) {end=k;break};k++
            }
            if (end < 0) { put('$'.code); i++; continue }
            if (end == i + 1) { put('$'.code); i += 2; continue }
            val cmd = s.substring(i + 1, end)
            i = end + 1
            val code = cmd.take(2)
            if(hiddenIndent!=null && code!="ID")continue
            val args = parseArgs(cmd)
            val tag = args.firstOrNull { it.startsWith("\"") }?.let { unquote(it) }
            fun attr(k: String): String? = args.firstOrNull { it.startsWith("$k=") }?.substringAfter('=')?.let { if (it.startsWith("\"")) unquote(it) else it }
            Console.COLOR_NAMES[cmd]?.let { fg = it; continue }
            when (code) {
                "FG" -> fg = args.drop(1).firstOrNull()?.let { color(it) } ?: Palette.BLUE
                "BG" -> bg = args.drop(1).firstOrNull()?.let { color(it) } ?: Palette.WHITE
                "FD", "BD" -> {}
                "CL" -> { vlines.clear(); links.clear(); cur = ArrayList() }
                "WW" -> wrap = !cmd.endsWith(",0")
                "ID" -> {
                    val n = args.drop(1).firstOrNull()?.trim()?.toIntOrNull() ?: 0
                    indent = (indent + n).coerceIn(0, cols / 2)
                    if(hiddenIndent?.let {indent<=it}==true)hiddenIndent=null
                    if (cur.all { (it and 0xFF) == ' '.code }) { cur = ArrayList(); repeat(indent) { cur.add(' '.code or (bg shl 12) or (fg shl 8)) } }
                }
                "UL" -> flags = if (cmd.endsWith(",0")) flags and 0x80000000.toInt().inv() else flags or 0x80000000.toInt()
                "IV" -> flags = if (cmd.endsWith(",0")) flags and 0x20000000.inv() else flags or 0x20000000
                "BK" -> flags = if (cmd.endsWith(",0")) flags and 0x10000000.inv() else flags or 0x10000000
                "TX" -> {
                    val t = tag ?: ""
                    if (cmd.contains("+CX")) { val pad = maxOf(0, (cols - t.length) / 2 - cur.size); repeat(pad) { put(' '.code) } }
                    text(t)
                }
                "TR" -> {
                    val save=fg;val line=vlines.size;val c0=cur.size;val label=tag ?: ""
                    val shut=collapsed[path]?.contains(tagStart)==true
                    fg=Palette.PURPLE;text((if(shut) "\u0010" else "\u001f")+label);fg=save
                    links.add(Link(line,c0,cur.size,"TREE:"+tagStart,false,label))
                    if(shut)hiddenIndent=indent
                }
                "LK", "MA", "BT", "MU" -> {
                    val label = tag ?: ""
                    val positional=args.filter {it.startsWith("\"")}.drop(1).firstOrNull()?.let {unquote(it)}
                    val target = attr("A") ?: attr("LM") ?: attr("LE") ?: (if(code=="LK")positional else null) ?: label
                    val isMacro = code != "LK"
                    val line = vlines.size; val c0 = cur.size
                    val save = fg; val saveFlags = flags
                    fg = if (isMacro) Palette.LTBLUE else Palette.RED
                    flags = flags or 0x80000000.toInt()
                    text(if (code == "BT") "[$label]" else label)
                    flags = saveFlags; fg = save
                    for(row in line..vlines.size) {
                        val first=if(row==line)c0 else 0;val last=if(row==vlines.size)cur.size else vlines[row].size
                        if(last>first)links.add(Link(row,first,last,target,isMacro,label))
                    }
                }
                "SP", "IB", "IS" -> if (code == "SP") { val save = fg; fg = Palette.DKGRAY; text("[" + L10n.tr8("doc.picture") + "]"); fg = save }
                "HL", "CM", "SY", "PT", "LM", "RM", "HC", "ER", "CH" -> {}
                else -> if (tag != null) text(tag)
            }
        }
        if (cur.isNotEmpty()) flush()
        laidOutCols = cols
    }

    private fun color(a: String): Int? = Console.COLOR_NAMES[a.trim()] ?: a.trim().toIntOrNull()?.coerceIn(0, 15)

    private fun parseArgs(cmd: String): List<String> {
        val res = ArrayList<String>(); val sb = StringBuilder(); var q = false; var i = 0
        while (i < cmd.length) {
            val c = cmd[i]
            if (c == '\\' && q && i + 1 < cmd.length) { sb.append(c).append(cmd[i + 1]); i += 2; continue }
            if (c == '"') q = !q
            if (c == ',' && !q) { res.add(sb.toString().trim()); sb.setLength(0) } else sb.append(c)
            i++
        }
        res.add(sb.toString().trim())
        return res
    }

    private fun unquote(t: String): String {
        val s = t.trim().removePrefix("\"").let { it.substring(0, it.lastIndexOf('"').let { j -> if (j < 0) it.length else j }) }
        return s.replace("\\n", "\n").replace("\\\"", "\"").replace("\\\\", "\\").replace("\\d", "$")
    }

    // ------------------------------------------------------------ view

    /** The notice's lines (text, color) wrapped to [w]: a title, then its explanation. */
    private fun layoutNotice(s: Surface, w: Int) {
        val pv = provenance
        val key = "${L10n.version}/$w/$pv"
        if (key == noticeKey) return
        noticeKey = key
        notice = if (pv == null) emptyList() else
            s.wrapUi(tr(pv.titleKey), w).map { it to Palette.PURPLE } + s.wrapUi(tr(pv.bodyKey), w).map { it to Palette.DKGRAY }
        // 10 px per text line plus a 4 px margin above and a rule with 3 px below, in whole 8 px rows
        noticeRows = if (notice.isEmpty()) 0 else (notice.size * 10 + 4 + 4 + 7) / 8
    }

    override fun draw(s: Surface, r: Rect) {
        val cols = maxOf(16, r.w / 8)
        if (cols != laidOutCols) layout(cols)
        layoutNotice(s, r.w - 12)
        s.fill(r, Palette.WHITE)
        val rows = r.h / 8
        val total = noticeRows + vlines.size
        top = top.coerceIn(0, maxOf(0, total - rows))
        if (top < noticeRows) {
            // the notice: separate from the document (its own accessibility element), scrolled with it
            val y0 = r.y - top * 8
            var y = y0 + 4
            for ((t, c) in notice) {
                if (y >= r.y && y + 8 <= r.bottom) s.uiText(r.x + 6, y, t, c, r.w - 12, alignEnd = L10n.rtl)
                y += 10
            }
            val rule = y0 + noticeRows * 8 - 4
            if (rule >= r.y && rule < r.bottom) s.fillRect(r.x + 6, rule, r.w - 12, 1, Palette.LTGRAY)
            val vis = Rect(r.x, maxOf(r.y, y0), r.w, minOf(r.bottom, y0 + noticeRows * 8) - maxOf(r.y, y0))
            a11yText(vis, notice.joinToString(" ") { it.first })
        }
        val visible = StringBuilder()
        val docTop = maxOf(0, top - noticeRows)
        val skip = maxOf(0, noticeRows - top)
        val docRect = Rect(r.x, r.y + skip * 8, r.w, r.h - skip * 8)
        for (i in 0 until rows - skip) {
            val l = vlines.getOrNull(docTop + i) ?: break
            for ((c, cell) in l.withIndex()) if (c < cols) s.cell(r.x + c * 8, docRect.y + i * 8, cell)
            for (cell in l) visible.append((cell and 0xFF).toChar())
            visible.append('\n')
        }
        if (docRect.h > 0) a11yText(docRect, visible.toString().lines().map { it.trimEnd() }.filter { it.isNotEmpty() }.joinToString("\n"))
        for(link in links) {
            val y=r.y+(link.line+noticeRows-top)*8
            if(y>=r.y && y+8<=r.bottom)a11yButton(Rect(r.x+link.c0*8,y,minOf(r.w-link.c0*8,(link.c1-link.c0)*8),8),link.label)
        }
        if (total > rows) {
            val h = r.h * rows / total
            s.fillRect(r.right - 3, r.y + (r.h - h) * top / maxOf(1, total - rows), 3, maxOf(8, h), Palette.BLUE)
        }
    }

    override fun scroll(dx: Int, dy: Int, r: Rect) {
        scrollAcc -= dy; top += scrollAcc / 8; scrollAcc %= 8
        top = maxOf(0, top); invalidate()
    }

    override fun tap(x: Int, y: Int, r: Rect) {
        val line = top + (y - r.y) / 8 - noticeRows
        val col = (x - r.x) / 8
        val l = links.firstOrNull { it.line == line && col >= it.c0 - 1 && col <= it.c1 + 1 } ?: return
        follow(l.target, l.macro)
    }

    private fun follow(target: String, macro: Boolean) {
        if(target.startsWith("TREE:")) {
            target.drop(5).toIntOrNull()?.let {index->val set=collapsed.getOrPut(path) {HashSet()};if(!set.add(index))set.remove(index);laidOutCols=-1;invalidate()};return
        }
        if (macro) {
            val expression=target.replace("\\n","\n")
            if(!OriginalNavigation.macro(shell,path,expression))Launch.terminal(shell,Paths.parent(path),expression)
            return
        }
        val t = target.trim()
        val kind = t.substringBefore(':', "")
        val rest = t.substringAfter(':', t)
        when (kind) {
            "FI", "FA", "FF", "FL", "PI", "PF", "PL" -> {
                val file = rest.substringBefore(',')
                val full=OriginalNavigation.resolve(shell,Paths.parent(path),file)
                if(full==null) {shell.showToast( { tr("doc.link_not_found","file" to file) });return}
                if(shell.fs.isDir(full))Launch.files(shell,full)
                else if(listOf(".HC",".HH",".IN",".CPP").any {full.endsWith(it,true)})Launch.editor(shell,full)
                else { historyStack.add(path); load(full) }
            }
            "HI"->{val g=shell.catalog.groups.firstOrNull {it.source=="#help_index "+rest};if(g!=null)Launch.programs(shell,g.id) else shell.showToast( { tr("doc.link_symbol_unsupported","target" to rest) })}
            "MN"->{val source=shell.historicalMenus.symbols[rest]?.firstOrNull {shell.fs.exists(it)};if(source!=null)Launch.editor(shell,source) else shell.showToast( { tr("doc.link_symbol_unsupported","target" to rest) })}
            "BF", "DN" -> shell.showToast( { tr("doc.link_symbol_unsupported", "target" to rest) })
            else -> {
                val p = OriginalNavigation.resolve(shell,Paths.parent(path),t)
                if(p!=null) {
                    if(shell.fs.isDir(p))Launch.files(shell,p)
                    else if(listOf(".HC",".HH",".IN",".CPP").any {p.endsWith(it,true)})Launch.editor(shell,p)
                    else {historyStack.add(path);load(p)}
                }
                else shell.showToast( { tr("doc.link_unsupported", "target" to t.take(30)) })
            }
        }
    }

    override fun key(ch: Int, sc: Long, down: Boolean): Boolean {
        if (!down) return true
        when ((sc and 0x7F).toInt()) {
            Keys.SC_CURSOR_DOWN -> top++
            Keys.SC_CURSOR_UP -> top = maxOf(0, top - 1)
            Keys.SC_PAGE_DOWN, Keys.SC_SPACE -> top += 20
            Keys.SC_PAGE_UP -> top = maxOf(0, top - 20)
            Keys.SC_BACKSPACE, Keys.SC_ESC -> back()
        }
        invalidate(); return true
    }

    override fun navigateBack():Boolean {historyStack.removeLastOrNull()?.let {load(it);return true};return super.navigateBack()}
    private fun back() {navigateBack()}

    override fun menu() = listOf(
        MenuItem( { tr("doc.menu.back") }, enabled = historyStack.isNotEmpty() || navigationParentId!=null) { back() },
        MenuItem( { tr("doc.menu.help_index") }) { historyStack.add(path); load("C:/Doc/HelpIndex.DD") },
        MenuItem( { tr("menu.edit_source") }) { Launch.editor(shell, path) },
    )

    /** The laid-out document text (CP437 bytes as chars), without the notice; tests compare it with the file. */
    internal fun documentText(cols: Int = 80): String {
        if (cols != laidOutCols) layout(cols)
        return vlines.joinToString("\n") { l -> String(CharArray(l.size) { (l[it] and 0xFF).toChar() }) }
    }

    override fun saveState() = mapOf("path" to path, "top" to top.toString())
    fun restoreTop(t: Int) { top = t }
}

/**
 * Where a document shown by the viewer comes from, from the provenance the bundled drive records
 * for each file (bundled-fs.index, tools/resource-packaging/build_bundled_fs.py) and whether the
 * user changed it. docs/fidelity-audit/TEMPLEOS_DOCUMENTATION_ATTRIBUTION_AUDIT.md explains the
 * categories and how the bundled files were checked against the TempleOS V5.03 ISO.
 */
enum class DocProvenance(private val id: String) {
    /** Category A: Terry A. Davis' file, byte for byte as on the ISO. */
    ORIGINAL("original"),
    /** Category C: Terry's file with offensive content censored or redacted (docs/content-moderation). */
    ADAPTED("adapted"),
    /** Distributed with TempleOS, but the text is someone else's (Doc/Credits.DD: the Bible, the PCI list). */
    INCLUDED("included"),
    /** Written for TempleOS Mobile. */
    MOBILE("mobile"),
    /** Category E: the user's copy over a bundled file. */
    CHANGED("changed"),
    /** Category E: a file that is not part of the bundled drive. */
    USER("user");

    val titleKey get() = "doc.notice.$id.title"
    val bodyKey get() = "doc.notice.$id.body"

    companion object {
        const val TERRY = "TempleOS V5.03 (public domain, Terry A. Davis)"

        fun of(fs: LayeredFs, path: String): DocProvenance {
            val origin = fs.bundledOrigin(path) ?: return USER
            if (!fs.isOriginal(path)) return CHANGED
            return when {
                origin == TERRY -> ORIGINAL
                origin.startsWith("$TERRY; modified:") -> ADAPTED
                origin == "TempleOS Mobile" -> MOBILE
                else -> INCLUDED
            }
        }
    }
}

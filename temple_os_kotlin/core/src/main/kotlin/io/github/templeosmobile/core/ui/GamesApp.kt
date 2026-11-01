package io.github.templeosmobile.core.ui

import io.github.templeosmobile.core.kernel.Palette
import io.github.templeosmobile.core.kernel.Keys

/** Historical metadata is generated from PersonalMenu.DD, never a second hand-maintained game list. */
class OriginalGamesMenu(val entries: List<Entry>) {
    class Entry(val programId: String, val title: String, val label: String, val category: String,
                val row: Int, val asset: String, val width: Int, val height: Int, val minX: Int, val minY: Int,
                val sourcePath: String, val documentLine: Int, val documentColumn: Int, val headingLine: Int, val headingColumn: Int, val animationAsset:String="",val animationWidth:Int=0,val animationHeight:Int=0,val animationMinX:Int=0,val animationMinY:Int=0)
    companion object {
        fun parse(text: String): OriginalGamesMenu {
            val root = Json.parse(text) as Map<*, *>
            val entries = (root["entries"] as List<*>).map { item ->
                val m = item as Map<*, *>
                fun s(k: String) = m[k] as? String ?: ""
                fun n(k: String) = (m[k] as Number).toInt()
                Entry(s("programId"), s("title"), s("originalLabel"), s("category"), n("row"),
                    s("asset"), n("width"), n("height"), n("minX"), n("minY"), s("sourcePath"), n("documentLine"), n("documentColumn"), n("headingLine"), n("headingColumn"), s("animationAsset"),(m["animationWidth"] as? Number)?.toInt() ?: 0,(m["animationHeight"] as? Number)?.toInt() ?: 0,(m["animationMinX"] as? Number)?.toInt() ?: 0,(m["animationMinY"] as? Number)?.toInt() ?: 0)
            }
            require(entries.map { it.programId }.distinct().size == entries.size)
            return OriginalGamesMenu(entries)
        }
    }
}

/** White DolDoc page, purple headings, original sprite/label anchors and integer pixel magnification. */
class GamesApp(shell: Shell) : App(shell) {
    override fun navigateBack(): Boolean {
        if(navigationParentId!=null)return super.navigateBack()
        shell.windows.firstOrNull {it.app===this}?.let {shell.close(it)}
        shell.showStartMenu();return true
    }
    override val kind = "games"
    override val title get() = tr("menu.games.title")
    private val original = shell.env.runtimeFile("games-menu/menu.json")?.let { OriginalGamesMenu.parse(String(it, Charsets.UTF_8)) }
        ?: OriginalGamesMenu(emptyList())
    private val icons = HashMap<String, ByteArray>()
    private val animations=HashMap<String,IndexedAnimation>()
    private var animationMs=0L
    private var visible=true
    override fun onVisibility(visible:Boolean) {this.visible=visible}
    override fun tick(nowMs:Long):Boolean {if(visible && !catalogView && nowMs/100!=animationMs/100) {animationMs=nowMs;invalidate();return true};return false}
    private var catalogView = false
    private var offset = 0
    private var contentHeight = 0
    private var viewport = Rect(0, 0, 0, 0)
    private var tabs = emptyList<Rect>()
    private var cells = ArrayList<Pair<Rect, OriginalGamesMenu.Entry>>()
    private var programs = ArrayList<Pair<Rect, ProgramInfo>>()
    private var up = Rect(0,0,0,0); private var down = Rect(0,0,0,0)
    private var selected = -1

    override fun draw(s: Surface, r: Rect) {
        val m = shell.metrics
        val naturalWidth = original.entries.maxOfOrNull { (it.documentColumn + it.label.length) * 8 } ?: 280
        val ts = if (catalogView) minOf(m.textScale, maxOf(1, (r.w - 8) / 192)) else minOf(m.textScale, maxOf(1, (r.w - 16) / naturalWidth))
        val names = listOf(tr("games.original"), tr("games.catalog"))
        val tabLines = names.map { s.wrapUi(it, maxOf(8, r.w / 2 - 8), ts) }
        val header = maxOf(m.rowH, 24, ((tabLines.maxOfOrNull { it.size } ?: 1) * 12 + 8) * ts)
        tabs = listOf(Rect(r.x, r.y, r.w / 2, header), Rect(r.x + r.w / 2, r.y, r.w - r.w / 2, header))
        s.fill(r, Palette.WHITE)
        for ((i,t) in tabs.withIndex()) {
            val active = (i == 1) == catalogView
            s.fill(t, if (active) Palette.YELLOW else Palette.WHITE)
            val name = names[i]; val lines = tabLines[i]
            for ((line, text) in lines.withIndex())
                s.uiText(t.x + 4, t.y + (t.h - lines.size * 12 * ts) / 2 + 2 * ts + line * 12 * ts,
                    text, Palette.BLUE, t.w - 8, alignEnd = L10n.rtl, scale = ts)
            a11yButton(t, name, active)
        }
        viewport = Rect(r.x, r.y + header, r.w, maxOf(0, r.h - header - m.rowH))
        up = Rect(r.x, viewport.bottom, r.w / 2, m.rowH)
        down = Rect(r.x + r.w / 2, viewport.bottom, r.w - r.w / 2, m.rowH)
        cells.clear(); programs.clear()
        var y = viewport.y + 8 - offset
        s.withClip(viewport) {
            if (!catalogView) {
                val groups = original.entries.groupBy { it.category }.entries.toList()
                for ((groupIndex, group) in groups.withIndex()) {
                    val category = group.key; val es = group.value
                    s.uiText(r.x + minOf(es.first().headingColumn * 8 * ts + 8, r.w / 3), y, category, Palette.PURPLE, r.w - 16, scale = ts)
                    if(y>=viewport.y && y+8*ts<=viewport.bottom)a11yText(Rect(r.x+8,y,r.w-16,8*ts),category)
                    var previousLine = es.first().headingLine
                    for (row in es.groupBy { it.row }.values) {
                        val exact = row.maxOf { (it.documentColumn + it.label.length) * 8 * ts } <= r.w - 16
                        val columns = if (exact) row.size else maxOf(1, (r.w - 16) / (104 * ts))
                        var firstChunk = true
                        for (chunk in row.chunked(columns)) {
                            val baseline = y + (if (firstChunk) (row.first().documentLine - previousLine) * 8 else maxOf(64,chunk.maxOf { -it.minY }) + 24) * ts
                            val cellW = (r.w - 16) / chunk.size
                            for ((i,e) in chunk.withIndex()) {
                                val animated=e.animationAsset.isNotEmpty()
                                val iw=if(animated) e.animationWidth else e.width;val ih=if(animated) e.animationHeight else e.height
                                val mx=if(animated) e.animationMinX else e.minX;val my=if(animated) e.animationMinY else e.minY
                                val labelW = e.label.length * 8 * ts
                                val tx = if (exact) r.x + 8 + e.documentColumn * 8 * ts else r.x + 8 + i * cellW + (cellW - labelW) / 2
                                val imageX = tx + labelW + mx * ts
                                val x = minOf(tx,imageX)
                                val right = maxOf(tx + labelW + 8 * ts,imageX + iw * ts)
                                val cell = Rect(x,baseline + minOf(my,0) * ts,right - x,(maxOf(8,my+ih)-minOf(my,0)) * ts)
                                cells.add(cell to e)
                                val p = shell.catalog.byId(e.programId)
                                val disabled = p == null || p.unsupported
                                if (cell.bottom > viewport.y && cell.y < viewport.bottom) {
                                    val pixels=if(animated) runCatching {animations.getOrPut(e.animationAsset) {IndexedAnimation(shell.env.runtimeFile(e.animationAsset) ?: byteArrayOf())}.pixels(animationMs)}.getOrNull()
                                        else icons.getOrPut(e.asset) {shell.env.runtimeFile(e.asset)?.takeIf {it.size==8+iw*ih}?.copyOfRange(8,8+iw*ih) ?: byteArrayOf()}.takeIf {it.size==iw*ih}
                                    if(pixels!=null && pixels.size==iw*ih) {
                                        val iy=baseline+my*ts
                                        for(yy in 0 until ih) for(xx in 0 until iw) {val c=pixels[yy*iw+xx].toInt() and 255;if(c<16) s.fillRect(imageX+xx*ts,iy+yy*ts,ts,ts,c)}
                                    }
                                    s.uiText(tx, baseline, e.label, if (disabled) Palette.DKGRAY else Palette.LTBLUE, labelW, scale = ts)
                                    if(cells.getOrNull(selected)?.second?.programId==e.programId)s.hline(tx,tx+labelW-1,baseline+8*ts,Palette.PURPLE)
                                    if (disabled || p?.status == "partial") s.text(tx + labelW, baseline, if (disabled) "?" else "*", Palette.RED, scale = ts)
                                    val hit = cell.intersect(viewport)
                                    if (hit.h > 8 * ts) a11yButton(hit, if (disabled) tr("a11y.unavailable", "label" to e.title) else p!!.title)
                                }
                            }
                            y = baseline; firstChunk = false
                        }
                        previousLine = row.first().documentLine
                    }
                    y += (groups.getOrNull(groupIndex + 1)?.value?.first()?.headingLine?.minus(previousLine) ?: 4) * 8 * ts
                }
            } else {
                val shown = original.entries.map { it.programId }.toSet()
                val extra = shell.catalog.programs.filter { it.author == "Terry A. Davis" && it.id !in shown && !it.unsupported }.sortedBy { if (it.path.startsWith("C:/Demo/Snd/")) 0 else 1 }
                for ((category, ps) in extra.groupBy { when {
                    it.path.startsWith("C:/Demo/Snd/") -> tr("games.sound")
                    it.path.startsWith("C:/Demo/Games/") -> "/Demo/Games"
                    it.path.startsWith("C:/Demo/Graphics/") -> "/Demo/Graphics"
                    else -> io.github.templeosmobile.core.kernel.Paths.parent(it.path).removePrefix("C:")
                } }) {
                    val headingLines = s.wrapUi(category, maxOf(8, r.w - 16), ts)
                    val heading = Rect(r.x + 8, y, r.w - 16, maxOf(24 * ts, (headingLines.size * 12 + 4) * ts))
                    for ((i,line) in headingLines.withIndex()) s.uiText(heading.x, y+i*12*ts, line, Palette.PURPLE, heading.w, alignEnd=L10n.rtl, scale=ts)
                    val hit = heading.intersect(viewport)
                    if (hit.h >= 10) a11yText(hit, category)
                    y += heading.h
                    for (p in ps) {
                        val lines = s.wrapUi(p.title, r.w - 24, ts)
                        val h = maxOf(m.rowH, (lines.size * 10 + 8) * ts)
                        val cell = Rect(r.x + 4, y, r.w - 8, h); programs.add(cell to p)
                        if (cell.bottom > viewport.y && y < viewport.bottom) {
                            for ((i,l) in lines.withIndex()) s.uiText(r.x + 12, y + 4 + i * 10 * ts, l, Palette.BLUE, r.w - 24, scale = ts)
                            val hit = cell.intersect(viewport)
                            if (hit.h >= 16) a11yButton(hit, p.title)
                        }
                        y += h
                    }
                    y += 8 * ts
                }
                val indexLines = s.wrapUi(tr("games.demo_index"), maxOf(8, r.w - 24), ts)
                val doc = Rect(r.x + 4,y,r.w - 8,maxOf(m.rowH,(indexLines.size * 12 + 8) * ts))
                for ((i,line) in indexLines.withIndex()) s.uiText(doc.x+8, y+4+i*12*ts, line, Palette.BLUE, doc.w-16, alignEnd=L10n.rtl, scale=ts)
                if (doc.intersect(viewport).h >= 16) a11yButton(doc.intersect(viewport), tr("games.demo_index"))
                indexRect = doc; y += doc.h
            }
        }
        contentHeight = y + offset - viewport.y
        val maxOffset = maxOf(0, contentHeight - viewport.h)
        if (offset > maxOffset) { offset = maxOffset; invalidate() }
        s.hline(r.x, r.right - 1, viewport.bottom, Palette.PURPLE)
        s.text(up.x + up.w / 2, up.y + (up.h - 8) / 2, "\u0018", Palette.BLUE)
        s.text(down.x + down.w / 2, down.y + (down.h - 8) / 2, "\u0019", Palette.BLUE)
        a11yButton(up, tr("a11y.scroll_menu_up")); a11yButton(down, tr("a11y.scroll_menu_down"))
    }
    private var indexRect = Rect(0,0,0,0)
    override fun tap(x: Int, y: Int, r: Rect) {
        val tab = tabs.indexOfFirst { it.contains(x,y) }
        if (tab >= 0) { catalogView = tab == 1; offset = 0; selected = -1; invalidate(); return }
        if (up.contains(x,y)) { move(-maxOf(48, viewport.h * 2 / 3)); return }
        if (down.contains(x,y)) { move(maxOf(48, viewport.h * 2 / 3)); return }
        if (!viewport.contains(x,y)) return
        if (catalogView) {
            programs.indexOfFirst {it.first.contains(x,y)}.takeIf {it>=0}?.let {selected=it;val p=programs[it].second;Launch.program(shell,p.path,p);return}
            if (indexRect.contains(x,y)) Launch.doc(shell,"C:/Doc/DemoIndex.DD")
        } else cells.firstOrNull { it.first.contains(x,y) }?.second?.let { e ->
            selected=cells.indexOfFirst {it.second.programId==e.programId}
            val p = shell.catalog.byId(e.programId)
            if (p == null || p.unsupported) {
                shell.showToast( { p?.localizedNote ?: tr("games.source_only") }); Launch.editor(shell,e.sourcePath)
            } else Launch.program(shell,p.path,p)
        }
    }
    private fun move(d: Int) { offset = (offset + d).coerceIn(0, maxOf(0,contentHeight - viewport.h)); invalidate() }
    override fun scroll(dx: Int, dy: Int, r: Rect) { move(-dy) }
    override fun key(ch: Int, sc: Long, down: Boolean): Boolean {
        if (!down) return true
        when ((sc and 127).toInt()) {
            Keys.SC_CURSOR_DOWN,Keys.SC_CURSOR_RIGHT->select(1)
            Keys.SC_CURSOR_UP,Keys.SC_CURSOR_LEFT->select(-1)
            Keys.SC_PAGE_DOWN -> move(maxOf(48,viewport.h / 2))
            Keys.SC_PAGE_UP -> move(-maxOf(48,viewport.h / 2))
            Keys.SC_HOME -> move(-contentHeight)
            Keys.SC_END -> move(contentHeight)
            Keys.SC_SPACE,Keys.SC_ENTER->{
                val targets=if(catalogView)programs.map {it.first} else cells.map {it.first}
                if(targets.isNotEmpty()) {val i=if(selected in targets.indices)selected else targets.indexOfFirst {it.y>=viewport.y && it.bottom<=viewport.bottom}.coerceAtLeast(0);val cell=targets[i];tap(cell.x+cell.w/2,cell.y+cell.h/2,viewport)}
            }
            Keys.SC_ESC->navigateBack()
            else -> return false
        }
        return true
    }
    private fun select(delta:Int) {
        val targets=if(catalogView)programs.map {it.first} else cells.map {it.first}
        if(targets.isEmpty())return
        selected=(if(selected<0) {if(delta>0)0 else targets.lastIndex} else selected+delta).coerceIn(0,targets.lastIndex)
        val cell=targets[selected];if(cell.y<viewport.y)move(cell.y-viewport.y) else if(cell.bottom>viewport.bottom)move(cell.bottom-viewport.bottom);invalidate()
    }
    override fun saveState() = mapOf("catalog" to catalogView.toString(), "offset" to offset.toString(),"selection" to selected.toString())
    fun restore(catalog: Boolean, scroll: Int, selection:Int = -1) { catalogView=catalog; offset=maxOf(0,scroll);selected=selection }
}

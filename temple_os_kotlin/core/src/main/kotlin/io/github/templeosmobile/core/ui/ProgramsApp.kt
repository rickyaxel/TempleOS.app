package io.github.templeosmobile.core.ui

import io.github.templeosmobile.core.kernel.Keys
import io.github.templeosmobile.core.kernel.Palette
import io.github.templeosmobile.core.kernel.Paths

/** Historical expressions are evidence only. Only these typed destinations dispatch. */
class HistoricalMenus(val menus: List<Menu>, val symbols:Map<String,List<String>> = emptyMap()) {
    class Entry(val label: String, val group: String, val kind: String, val target: String,
                val programId: String, val expression: String, val context: String, val availability: String) {
        val localizedContext get() = when (context) {
            "editor" -> tr("menu.start.editor")
            "file-manager" -> tr("app.files.title")
            else -> tr("catalog.context.owner")
        }
        val localizedAvailability get() = when (availability) {
            "supported" -> tr("catalog.availability.supported")
            "source-only" -> tr("games.source_only")
            "runtime-context", "document-context", "context-only" -> tr("catalog.context.owner")
            else -> tr("catalog.availability.unsupported")
        }
    }
    class Menu(val id: String, val title: String, val source: String, val type: String,
               val dynamic: Boolean, val owners: List<String>, val entries: List<Entry>) {
        val localizedType get() = tr("catalog.group.menus.$type")
    }
    fun byId(id: String) = menus.firstOrNull { it.id == id }
    companion object {
        fun parse(text: String): HistoricalMenus {
            val root = Json.parse(text) as Map<*, *>
            val menus = (root["menus"] as List<*>).map { item ->
                val m = item as Map<*, *>
                fun s(k: String) = m[k] as? String ?: ""
                val entries = (m["entries"] as List<*>).map { value ->
                    val e = value as Map<*, *>
                    fun t(k: String) = e[k] as? String ?: ""
                    Entry(t("label"),t("group"),t("actionKind"),t("target"),t("programId"),t("originalAction"),t("requiredContext"),t("availability"))
                }
                Menu(s("id"),s("title"),s("source"),s("menuType"),m["dynamic"] == true,
                    (m["ownerProgramIds"] as? List<*>)?.map { it as String } ?: emptyList(),entries)
            }
            require(menus.map { it.id }.distinct().size == menus.size) { "duplicate historical menu ID" }
            val symbols=(root["symbols"] as? Map<*, *>)?.entries?.associate {(k,v)->(k as String) to (v as List<*>).map {it as String}} ?: emptyMap()
            return HistoricalMenus(menus,symbols)
        }
        fun load(shell: Shell): HistoricalMenus = shell.env.runtimeFile("original-menus.json")?.let {
            parse(String(it, Charsets.UTF_8))
        } ?: HistoricalMenus(emptyList())
    }
}

/** Resolve original references within C:, never via host paths or macro evaluation. */
object OriginalNavigation {
    fun resolve(shell:Shell,base:String,target:String):String? {
        val path=Paths.normalize(base,target.removeSuffix(".Z")) ?: return null
        val candidates=mutableListOf(path,path+".DD",path+".HC",path+".HH",path+".IN")
        if(path.startsWith("C:/Home/"))candidates.addAll(candidates.map {"C:/"+Paths.name(it)})
        return candidates.firstOrNull {shell.fs.exists(it)}
    }
    fun dispatch(shell:Shell,e:HistoricalMenus.Entry):Boolean {
        if(e.availability!="supported")return false
        when(e.kind) {
            "launchProgram"->{val p=shell.catalog.byId(e.programId)?.takeIf {!it.unsupported} ?: return false;Launch.program(shell,p.path,p)}
            "openSource"->{if(!shell.fs.exists(e.target))return false;Launch.editor(shell,e.target)}
            "openDocument"->{if(!shell.fs.exists(e.target))return false;Launch.doc(shell,e.target)}
            "openDirectory"->{if(!shell.fs.isDir(e.target))return false;Launch.files(shell,e.target)}
            else->return false
        };return true
    }
    fun macro(shell:Shell,source:String,expression:String):Boolean {
        for(m in shell.historicalMenus.menus.filter {it.source.equals(source,true) && it.type=="document"}) {
            val i=m.entries.indexOfFirst {it.expression.trim()==expression.trim()}
            if(i>=0) {
                if(!dispatch(shell,m.entries[i])) {Launch.programs(shell);(shell.focused?.app as? ProgramsApp)?.showHistoricalEntry(m.id,i)}
                return true
            }
        };return false
    }
}

/** Original grouping, with commands enabled only by explicit contextual adapters. */
object OriginalContextMenu {
    fun items(shell:Shell,source:String,actions:Map<String,()->Unit>):List<MenuItem> {
        val menu=shell.historicalMenus.menus.firstOrNull {it.source==source && it.type=="pulldown"} ?: return emptyList()
        return menu.entries.map {it.group}.distinct().map {group->MenuItem( { group }) {
            val children=menu.entries.filter {it.group==group}.map {entry->
                val action=actions[group+"/"+entry.label]
                MenuItem( { entry.label },enabled=action!=null) {action?.invoke()}
            }
            shell.showMenu(children,4,shell.insetTop+shell.barH, { group })
        }}
    }
}

/** Native bitmap-document view, hosted by the existing window/deck and input system. */
class ProgramsApp(shell: Shell) : App(shell) {
    override val kind = "programs"
    private val history = ArrayList<String>()
    private val offsets = HashMap<String, Int>()
    private var route = "g:programs"
    private val menus get() = shell.historicalMenus
    override val title: String get() = when {
        route.startsWith("g:") -> shell.catalog.group(route.drop(2))?.localizedTitle
        route.startsWith("p:") -> shell.catalog.byId(route.drop(2))?.title
        route.startsWith("m:") -> menus.byId(route.drop(2))?.title
        else -> null
    } ?: shell.catalog.group("programs")?.localizedTitle ?: tr("catalog.group.programs")
    private class Row(val label: String, val action: String, val value: String = "")
    private val hits = ArrayList<Pair<Rect, Row>>()
    private val keyboardRows=ArrayList<Pair<Rect,Row>>()
    private val selection=HashMap<String,Int>()
    private var renderedRoute=""
    private var viewport = Rect(0,0,0,0)
    private var contentHeight = 0
    private var backRect = Rect(0,0,0,0)
    private var up = Rect(0,0,0,0)
    private var down = Rect(0,0,0,0)

    fun showGroup(id: String) {
        if (shell.catalog.group(id) == null) return
        history.clear()
        var parent = shell.catalog.group(id)?.parent
        while (!parent.isNullOrEmpty()) {
            history.add(0,"g:$parent"); parent = shell.catalog.group(parent)?.parent
        }
        route = "g:$id"; invalidate()
    }
    private fun navigate(next: String) {
        if (route == next) return
        val index=history.indexOf(next)
        if(index>=0) {while(history.size>index)history.removeAt(history.lastIndex)}
        else {history.add(route);if(history.size>32)history.removeAt(0)}
        route = next; invalidate()
    }
    fun showProgram(id:String) {if(shell.catalog.byId(id)!=null)navigate("p:"+id)}
    fun showHistoricalEntry(id:String,index:Int) {
        val m=menus.byId(id) ?: return
        if(index in m.entries.indices)activate(Row("","entry",id+"\n"+index))
    }
    override fun navigateBack(): Boolean {
        if (history.isNotEmpty()) { route = history.removeAt(history.lastIndex); invalidate() }
        else if(navigationParentId!=null)return super.navigateBack()
        else { shell.windows.firstOrNull { it.app === this }?.let { shell.close(it) }; shell.showStartMenu() }
        return true
    }
    private fun rows(): List<Row> {
        val out = ArrayList<Row>()
        when {
            route.startsWith("g:") -> {
                val g = shell.catalog.group(route.drop(2)) ?: return out
                out.add(Row(g.source,"text"))
                shell.catalog.children(g.id).forEach { out.add(Row(it.localizedTitle,"navigate","g:"+it.id)) }
                for (id in g.programIds) shell.catalog.byId(id)?.let {
                    out.add(Row(if (it.unsupported) tr("a11y.unavailable","label" to it.title) else it.title,"navigate","p:"+id))
                }
                for (id in g.menuIds) menus.byId(id)?.let { out.add(Row(it.title + "  [" + it.source.removePrefix("C:/") + "]","navigate","m:"+id)) }
                for (ref in g.references) {
                    if (ref.path.isNotEmpty()) out.add(Row(if(ref.available)ref.label else tr("a11y.unavailable","label" to ref.label),if(!ref.available) "text" else if(ref.directory) "directory" else if(ref.path.endsWith(".DD")) "document" else "source",ref.path))
                }
                if (g.document.isNotEmpty()) out.add(Row(g.document,"document",g.document))
                if (g.directory.isNotEmpty()) out.add(Row(g.directory,"directory",g.directory))
            }
            route.startsWith("p:") -> {
                val p = shell.catalog.byId(route.drop(2)) ?: return out
                out.add(Row(p.path,"text")); out.add(Row(p.source,"text"))
                if (p.localizedDescription.isNotEmpty()) out.add(Row(p.localizedDescription,"text"))
                if (p.unsupported) out.add(Row(tr("games.source_only"),"text"))
                if (p.localizedNote.isNotEmpty()) out.add(Row(p.localizedNote,"text"))
                if (!p.unsupported) out.add(Row(tr("button.run_in","engine" to if(shell.settings.engine == Settings.ENGINE_NATIVE) Engines.NATIVE_NAME else Engines.TERRY_NAME),"run",p.id))
                out.add(Row(tr("menu.edit_source"),"source",p.path))
                for (m in menus.menus.filter { p.id in it.owners }) out.add(Row(m.title,"navigate","m:"+m.id))
            }
            route.startsWith("m:") -> {
                val m = menus.byId(route.drop(2)) ?: return out
                out.add(Row(m.source,"text")); out.add(Row(m.localizedType,"text"))
                if (m.source == "C:/PersonalMenu.DD") out.add(Row(shell.catalog.group("games")?.localizedTitle ?: tr("menu.games.title"),"games"))
                // Contextual menus are inspected here; their commands dispatch only
                // inside the owning application, through its live event menu.
                if (m.type != "document") out.add(Row(tr("games.source_only"),"text"))
                for (id in m.owners) shell.catalog.byId(id)?.let { out.add(Row(it.title,"navigate","p:"+id)) }
                var group = ""
                for ((i,e) in m.entries.withIndex()) {
                    if (e.group != group && e.group.isNotEmpty()) { group=e.group; out.add(Row(group,"text")) }
                    val label = e.label.ifEmpty { e.target.ifEmpty { e.expression.take(100) } }.replace('\u001f',' ')
                    out.add(Row(label,"entry",m.id+"\n"+i))
                }
                if(shell.fs.exists(m.source))out.add(Row(tr("menu.edit_source"),"source",m.source)) else out.add(Row(tr("doc.link_not_found","file" to m.source),"text"))
            }
            route.startsWith("a:") -> {
                val parts = route.drop(2).split('\n'); val m = menus.byId(parts[0]) ?: return out
                val e = m.entries.getOrNull(parts.getOrNull(1)?.toIntOrNull() ?: -1) ?: return out
                out.add(Row(e.label,"text")); out.add(Row(e.localizedContext,"text")); out.add(Row(e.localizedAvailability,"text"))
                out.add(Row(e.expression,"text"))
                if(shell.fs.exists(m.source)) {out.add(Row(tr("games.source_only"),"text"));out.add(Row(tr("menu.edit_source"),"source",m.source))}
                else out.add(Row(tr("doc.link_not_found","file" to m.source),"text"))
            }
        }
        return out
    }
    private fun activate(row: Row) {
        when(row.action) {
            "navigate" -> navigate(row.value)
            "games" -> Launch.games(shell)
            "run" -> shell.catalog.byId(row.value)?.takeIf { !it.unsupported }?.let { Launch.program(shell,it.path,it) }
            "source" -> if (shell.fs.exists(row.value)) Launch.editor(shell,row.value) else shell.showToast( { tr("games.source_only") })
            "document" -> if (shell.fs.exists(row.value)) Launch.doc(shell,row.value) else shell.showToast( { tr("games.source_only") })
            "directory" -> if (shell.fs.isDir(row.value)) Launch.files(shell,row.value) else shell.showToast( { tr("games.source_only") })
            "entry" -> {
                val parts=row.value.split('\n');val m=menus.byId(parts[0]) ?: return
                val e=m.entries[parts[1].toInt()]
                if (m.type == "document" && e.availability == "supported") {
                    when(e.kind) {
                        "launchProgram" -> shell.catalog.byId(e.programId)?.let { if(it.unsupported) navigate("p:"+it.id) else Launch.program(shell,it.path,it) }
                        "openSource" -> activate(Row("","source",e.target))
                        "openDocument" -> activate(Row("","document",e.target))
                        "openDirectory" -> activate(Row("","directory",e.target))
                        else -> navigate("a:"+row.value)
                    }
                } else navigate("a:"+row.value)
            }
        }
    }
    override fun draw(s: Surface, r: Rect) {
        val m=shell.metrics;val ts=minOf(m.textScale,maxOf(1,(r.w-16)/240))
        val header=maxOf(m.rowH,24);s.fill(r,Palette.WHITE)
        backRect=Rect(r.x,r.y,minOf(r.w/3,80),header)
        s.uiText(backRect.x+4,m.textTop(r.y,header),tr("doc.menu.back"),Palette.BLUE,backRect.w-8,scale=ts)
        a11yButton(backRect,tr("doc.menu.back"))
        s.uiText(backRect.right+4,m.textTop(r.y,header),title,Palette.PURPLE,r.w-backRect.w-8,scale=ts)
        a11yText(Rect(backRect.right,r.y,r.w-backRect.w,header),title)
        viewport=Rect(r.x,r.y+header,r.w,maxOf(0,r.h-header-m.rowH))
        up=Rect(r.x,viewport.bottom,r.w/2,m.rowH);down=Rect(up.right,viewport.bottom,r.w-up.w,m.rowH)
        hits.clear();keyboardRows.clear();var y=viewport.y+8-(offsets[route] ?: 0)
        s.withClip(viewport) {
            for (row in rows()) {
                val lines=s.wrapUi(row.label,maxOf(8,r.w-24),ts)
                val h=maxOf(if(row.action=="text") 16*ts else m.rowH,(lines.size*10+8)*ts)
                val cell=Rect(r.x+4,y,r.w-8,h)
                val chosen=row.action!="text" && keyboardRows.size==(selection[route] ?: -1)
                if(chosen)s.fill(cell,Palette.YELLOW)
                if(row.action!="text")keyboardRows.add(cell to row)
                for ((i,line) in lines.withIndex()) s.uiText(r.x+12,y+4+i*10*ts,line,if(row.action=="text") Palette.PURPLE else Palette.BLUE,r.w-24,alignEnd=L10n.rtl,scale=ts)
                val hit=cell.intersect(viewport)
                if(hit.h>=minOf(16,h)) {
                    if(row.action=="text") a11yText(hit,row.label) else { a11yButton(hit,row.label,chosen);hits.add(hit to row) }
                }
                y+=h
            }
        }
        contentHeight=y+(offsets[route] ?: 0)-viewport.y
        renderedRoute=route
        val limit=maxOf(0,contentHeight-viewport.h)
        if ((offsets[route] ?: 0)>limit) {offsets[route]=limit;invalidate()}
        s.hline(r.x,r.right-1,viewport.bottom,Palette.PURPLE)
        s.text(up.x+up.w/2,up.y+(up.h-8)/2,"\u0018",Palette.BLUE)
        s.text(down.x+down.w/2,down.y+(down.h-8)/2,"\u0019",Palette.BLUE)
        a11yButton(up,tr("a11y.scroll_menu_up"));a11yButton(down,tr("a11y.scroll_menu_down"))
    }
    override fun tap(x:Int,y:Int,r:Rect) {
        when {backRect.contains(x,y)->navigateBack();up.contains(x,y)->move(-maxOf(48,viewport.h*2/3));down.contains(x,y)->move(maxOf(48,viewport.h*2/3))
            else->hits.firstOrNull {it.first.contains(x,y)}?.let {activate(it.second)}}
    }
    private fun move(delta:Int) {offsets[route]=((offsets[route] ?: 0)+delta).coerceIn(0,maxOf(0,contentHeight-viewport.h));invalidate()}
    private fun choose(delta:Int) {
        if(keyboardRows.isEmpty())return
        val old=selection[route] ?: -1
        val index=(if(old<0) {if(delta>0)0 else keyboardRows.lastIndex} else old+delta).coerceIn(0,keyboardRows.lastIndex)
        selection[route]=index;val rect=keyboardRows[index].first
        if(rect.y<viewport.y)move(rect.y-viewport.y) else if(rect.bottom>viewport.bottom)move(rect.bottom-viewport.bottom)
        invalidate()
    }
    override fun scroll(dx:Int,dy:Int,r:Rect) = move(-dy)
    override fun key(ch:Int,sc:Long,down:Boolean):Boolean {
        if(!down)return true
        if(renderedRoute!=route)return true
        when(sc.toInt() and 127) {
            Keys.SC_CURSOR_DOWN,Keys.SC_CURSOR_RIGHT->choose(1)
            Keys.SC_CURSOR_UP,Keys.SC_CURSOR_LEFT->choose(-1)
            Keys.SC_PAGE_DOWN->move(maxOf(48,viewport.h/2))
            Keys.SC_PAGE_UP->move(-maxOf(48,viewport.h/2))
            Keys.SC_SPACE,Keys.SC_ENTER->{val i=selection[route] ?: -1;if(i in keyboardRows.indices)activate(keyboardRows[i].second) else hits.firstOrNull()?.let {activate(it.second)}}
            Keys.SC_HOME->move(-contentHeight);Keys.SC_END->move(contentHeight)
            else->if(ch==Keys.CH_ESC)navigateBack() else return false
        };return true
    }
    override fun saveState():Map<String,String> = mapOf("route" to route,"history" to history.joinToString("\t")) + offsets.mapKeys {"offset."+it.key}.mapValues {it.value.toString()} + selection.mapKeys {"selection."+it.key}.mapValues {it.value.toString()}
    fun restore(st:Map<String,String>) {
        val candidate=st["route"] ?: "g:programs"
        fun valid(r:String)=when {r.startsWith("g:")->shell.catalog.group(r.drop(2))!=null;r.startsWith("p:")->shell.catalog.byId(r.drop(2))!=null;r.startsWith("m:")->menus.byId(r.drop(2))!=null;else->false}
        route=if(valid(candidate))candidate else "g:programs"
        history.clear();history.addAll((st["history"] ?: "").split('\t').filter {valid(it)}.take(32))
        offsets.clear();st.filterKeys {it.startsWith("offset.")}.forEach {(k,v)->offsets[k.drop(7)]=maxOf(0,v.toIntOrNull() ?: 0)}
        selection.clear();st.filterKeys {it.startsWith("selection.")}.forEach {(k,v)->selection[k.drop(10)]=maxOf(-1,v.toIntOrNull() ?: -1)}
    }
}

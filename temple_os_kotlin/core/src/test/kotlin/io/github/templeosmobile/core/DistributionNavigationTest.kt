package io.github.templeosmobile.core

import io.github.templeosmobile.core.ui.*
import io.github.templeosmobile.core.kernel.*
import org.junit.Assert.*
import org.junit.Test

class DistributionNavigationTest {
    @Test fun cDateFractionSurvivesHolyCShiftPrecedence() {
        val k=runHolyC(java.io.File(SHARED,"test-vectors/holyc/237_DateClock.HC").readBytes())
        assertTrue(k.finished);assertNull(k.exitMessage);assertTrue(k.console.plainText().contains("date-clock-ok"))
    }
    @Test fun focusedChildMenuAndParentRestoration() {
        val k=Kernel(TestEnv(),"focused menus");k.virtualTime=true;k.boot()
        try {
            val source="""
            U0 Child(U8 *) { WinFocus; MenuPush("Child { Done(,CH_ESC); }"); GetChar; MenuPop; GetChar; }
            MenuPush("Parent { Done(,CH_ESC); }"); Spawn(&Child,NULL,"Child"); Sleep(1000); MenuPop;
            """.trimIndent()
            k.runProgram("C:/Home/FocusMenu.HC",source.toByteArray(Charsets.ISO_8859_1))
            fun advance(ms:Long) {
                val deadline=System.nanoTime()+5_000_000_000L
                while(!k.finished && k.now()<ms*1_000_000 && System.nanoTime()<deadline) {
                    k.virtualStopAt=ms*1_000_000;k.step(50_000_000)
                }
                assertNull(k.exitMessage)
            }
            advance(100);assertEquals(listOf("Child"),k.menuSnapshot.filter {it.isDir}.map {it.label})
            k.post(KInput.Key(97,Keys.forChar(97).second,true));advance(200)
            assertEquals(listOf("Parent"),k.menuSnapshot.filter {it.isDir}.map {it.label})
            k.post(KInput.Key(98,Keys.forChar(98).second,true));advance(1200)
            assertTrue(k.finished);assertTrue(k.menuSnapshot.isEmpty())
        } finally {k.terminate("test cleanup")}
    }
    private fun withShell(body:(Shell,HeadlessEnv)->Unit) {
        val dir=kotlin.io.path.createTempDirectory("distribution-ui").toFile()
        val env=HeadlessEnv(dir);val sh=Shell(env);sh.resize(402,874,62,34);sh.tick()
        try {body(sh,env)} finally {sh.windows.toList().forEach {it.app.close()};dir.deleteRecursively();L10n.use("en-US")}
    }
    private fun tap(sh:Shell,label:String) {
        sh.tick();val node=sh.accessibilityNodes().firstOrNull {it.button && it.label==label}
        assertNotNull(label,node);val r=node!!.rect
        sh.pointer(PointerEvent(Ptr.DOWN,r.x+r.w/2,r.y+r.h/2));sh.pointer(PointerEvent(Ptr.UP,r.x+r.w/2,r.y+r.h/2));sh.tick()
    }
    private fun wait(sh:Shell,condition:()->Boolean):Boolean {
        val end=System.nanoTime()+10_000_000_000L
        while(System.nanoTime()<end) {sh.tick();if(condition())return true;Thread.sleep(10)}
        return condition()
    }
    @Test fun exactIntroAcrossLocalesAndDisplays() = withShell {sh,env->
        val expected=listOf("TempleOS.app","Tap MENU to begin.","TempleOS by Terry A. Davis","Mobile adaptation by Ricky Axel")
        assertEquals(expected,Brand.INTRO_LINES)
        for(locale in listOf("en-US","es-ES","ja-JP","ar-SA")) {
            L10n.use(locale)
            for((w,h) in listOf(300 to 568,402 to 874,874 to 402,1024 to 1366,1366 to 1024,160 to 240)) {
                sh.resize(w,h,0,0);sh.invalidate();sh.tick()
                val nodes=sh.accessibilityNodes().filter {!it.button && it.label in expected}
                assertEquals(expected,nodes.map {it.label});assertTrue(sh.accessibilityNodes().any {it.button && it.label=="MENU"})
                nodes.forEach {assertTrue("$w x $h ${it.label}",it.rect.y>=0 && it.rect.bottom<=h)}
                nodes.zipWithNext().forEach {(a,b)->assertTrue(a.rect.bottom<=b.rect.y)}
                assertFalse(env.systemKeyboard)
            }
        }
    }
    @Test fun touchMenuGamesAndBack() = withShell {sh,env->
        tap(sh,"MENU");assertTrue(sh.openMenu!!.items.any {it.label==tr("menu.start.games")})
        tap(sh,tr("menu.start.games"));assertEquals("games",sh.focused?.app?.kind)
        assertTrue(sh.accessibilityNodes().any {it.button && it.label=="Titanium"})
        assertTrue(sh.back());sh.tick();assertNotNull(sh.openMenu);assertFalse(env.systemKeyboard)
    }
    @Test fun everyGroupHasRenderedDestinationAndNoDanglingMenus() = withShell {sh,_->
        Launch.programs(sh)
        for(g in sh.catalog.groups.filter {it.id!="games"}) {
            val app=sh.focused!!.app as ProgramsApp;app.restore(mapOf("route" to "g:"+g.id));sh.invalidate();sh.tick()
            assertEquals(g.title,app.title);assertTrue(g.id,sh.accessibilityNodes().any {it.label==g.source})
            g.menuIds.forEach {assertNotNull(it,sh.historicalMenus.byId(it))};g.programIds.forEach {assertNotNull(it,sh.catalog.byId(it))}
            assertEquals(1,sh.windows.size)
        }
    }
    @Test fun everyHistoricalMenuReferenceRendersWithoutGlobalCommandExecution() = withShell {sh,_->
        Launch.programs(sh);val app=sh.focused!!.app as ProgramsApp
        for(menu in sh.historicalMenus.menus) {
            app.restore(mapOf("route" to "m:"+menu.id));sh.invalidate();sh.tick()
            assertTrue(menu.id,sh.accessibilityNodes().any {it.label==menu.source})
            assertFalse(menu.id,sh.accessibilityNodes().any {it.button && it.label.startsWith("RUN IN")})
            assertEquals(1,sh.windows.size)
        }
    }
    @Test fun sourceOnlyProgramsNeverOfferRun() = withShell {sh,_->
        Launch.programs(sh);val app=sh.focused!!.app as ProgramsApp
        for(p in sh.catalog.programs.filter {it.unsupported}) {
            app.restore(mapOf("route" to "p:"+p.id));sh.invalidate();sh.tick()
            assertTrue(p.id,sh.accessibilityNodes().any {it.label==tr("games.source_only")})
            assertFalse(p.id,sh.accessibilityNodes().any {it.button && it.label.startsWith("RUN IN")})
        }
    }
    @Test fun sourceLinksOpenEditorAndReturnToOrigin() = withShell {sh,env->
        Launch.programs(sh);val parent=sh.focused!!.id;Launch.doc(sh,"C:/Doc/DemoIndex.DD");sh.tick();val doc=sh.focused!!.id
        tap(sh,"::/Demo/Graphics/NetOfDots.HC");assertEquals("editor",sh.focused?.app?.kind)
        assertEquals("C:/Demo/Graphics/NetOfDots.HC",(sh.focused!!.app as EditorApp).path)
        sh.close(sh.focused!!,true);assertEquals(doc,sh.focused!!.id);assertTrue(sh.back());assertEquals(parent,sh.focused!!.id)
        assertEquals("C:/Demo/Games/TreeCheckers.HC",OriginalNavigation.resolve(sh,"C:/Home","::/Demo/Games/TreeCheckers.HC.Z"))
        assertNotNull(OriginalNavigation.resolve(sh,"C:/Home","c:/demo/games/maze.hc"));assertFalse(env.systemKeyboard)
    }
    @Test fun dolDocTreesCollapseAndExpand() = withShell {sh,_->
        Launch.doc(sh,"C:/Doc/DemoIndex.DD");sh.tick();val doc=sh.focused!!.app as DocViewerApp
        assertTrue(doc.documentText(50).contains("NetOfDots"));tap(sh,"Games: Beginner")
        assertFalse(doc.documentText(50).contains("NetOfDots"));assertTrue(doc.documentText(50).contains("Games: Intermediate"))
        tap(sh,"Games: Beginner");assertTrue(doc.documentText(50).contains("NetOfDots"))
    }
    @Test fun historicalMacrosUseTypedRoutes() = withShell {sh,_->
        Launch.programs(sh);val m=sh.historicalMenus.menus.first {it.source=="C:/PersonalMenu.DD"}
        assertTrue(OriginalNavigation.dispatch(sh,m.entries.first {it.target=="C:/Demo/Snd"}));assertEquals("C:/Demo/Snd",(sh.focused!!.app as FilesApp).dir)
        sh.close(sh.focused!!,true)
        assertFalse(OriginalNavigation.dispatch(sh,m.entries.first {it.expression.contains("BootRAM")}));assertEquals("programs",sh.focused?.app?.kind)
        val game=m.entries.first {it.programId=="game.flapbat"};assertTrue(OriginalNavigation.dispatch(sh,game));assertEquals(sh.catalog.byId(game.programId)!!.path,(sh.focused!!.app as ProgramApp).path)
    }
    @Test fun contextualGroupsAndUnsupportedDiskCommands() = withShell {sh,_->
        Launch.editor(sh,"C:/Home/Examples/Hello.HC");val editor=sh.focused!!.app as EditorApp
        assertEquals(listOf("File","Edit","Insert","Program","View","Help"),editor.menu().take(6).map {it.label})
        editor.menu().first {it.label=="Program"}.action();sh.tick()
        assertTrue(sh.openMenu!!.items.any {it.label=="Include" && it.enabled});assertTrue(sh.openMenu!!.items.any {it.label.contains("AdamInclude") && !it.enabled})
        sh.back();Launch.files(sh,"C:/Demo/Games");sh.focused!!.app.menu().first {it.label=="File"}.action();sh.tick()
        assertTrue(sh.openMenu!!.items.any {it.label.contains("FmtDrv") && !it.enabled});assertTrue(sh.openMenu!!.items.any {it.label=="DirMk" && it.enabled})
    }
    @Test fun liveSubmenusDispatchWithoutRestart() = withShell {sh,_->
        val p=ProgramApp(sh,"C:/Demo/PullDownMenu.HC",null);sh.open(p)
        assertTrue(wait(sh) {p.kernel.menuSnapshot.isNotEmpty()})
        sh.showMenu(p.menu(),4,sh.insetTop+sh.barH,p.title);sh.tick();tap(sh,"Misc");assertNotNull(sh.openMenu?.parent);tap(sh,"Opt1")
        assertTrue(wait(sh) {p.kernel.menuSnapshot.any {it.path=="Misc/Opt1" && it.checked}});assertTrue(p.kernel.console.plainText().contains("Option # 1"));assertFalse(p.isFinished)
        sh.showMenu(p.menu(),4,sh.insetTop+sh.barH,p.title);sh.tick();tap(sh,"File");tap(sh,"Exit")
        assertTrue(wait(sh) {p.isFinished});assertTrue(p.kernel.menuSnapshot.isEmpty())
    }
    @Test fun scrollRestoreAndCyclesStayBounded() = withShell {sh,_->
        Launch.programs(sh,"tools");val app=sh.focused!!.app as ProgramsApp;sh.tick();app.scroll(0,-160,Rect(0,0,402,700));sh.tick()
        val saved=app.saveState();assertEquals(saved,Launch.restore(sh,"programs",saved)!!.saveState())
        repeat(40) {app.showGroup("demos");app.showProgram("game.maze");app.showGroup("applications")}
        assertTrue((app.saveState()["history"] ?: "").split('\t').size<=32);assertEquals(1,sh.windows.count {it.app.kind=="programs"})
    }
    @Test fun ctrlMUsesCentralMenu() = withShell {sh,_->
        val (_,sc)=Keys.forChar(109);sh.key(13,sc or Keys.SCF_CTRL,true);sh.tick()
        assertNotNull(sh.openMenu);assertTrue(sh.openMenu!!.items.any {it.label==tr("menu.start.games")})
    }
    @Test fun menuProgramsAlwaysReturnsToHubWithoutDuplicatingWindow() = withShell {sh,_->
        Launch.programs(sh,"applications");val id=sh.focused!!.id
        Launch.programs(sh);sh.tick();assertEquals(id,sh.focused!!.id)
        assertEquals("g:programs",sh.focused!!.app.saveState()["route"])
        assertTrue(sh.accessibilityNodes().any {it.button && it.label=="Original menus"})
    }
}

package io.github.templeosmobile.core

import io.github.templeosmobile.core.kernel.*
import io.github.templeosmobile.core.holyc.*
import org.junit.Test
import org.junit.Assert.*
import java.io.File

/** Execute untouched sources; native comparisons are in purekotlin's integration suite. */
class SourceOnlyProgramsTest {
    private fun boot(path:String):Pair<Kernel,TestEnv> {
        val dir=kotlin.io.path.createTempDirectory("source-only").toFile()
        val fs=LayeredFs(DirBundle(File(SHARED,"bundled-fs"),File(SHARED,"bundled-fs.index")),dir)
        val env=TestEnv(fs);val k=Kernel(env,"source-only");k.virtualTime=true;k.boot();k.runProgram(path,fs.readFile(path)!!);return k to env
    }
    private fun advance(k:Kernel,ms:Long) {k.virtualStopAt=ms*1_000_000;val deadline=System.nanoTime()+60_000_000_000;while(!k.finished && k.now()<k.virtualStopAt && System.nanoTime()<deadline) k.step(50_000_000);assertTrue("stalled at ${k.now()}: ${k.console.plainText()}",k.finished || k.now()>=k.virtualStopAt);assertNull(k.console.plainText(),k.exitMessage)}
    private fun key(k:Kernel,ch:Int,down:Boolean=true) {val sc=Keys.forChar(ch).second;k.post(KInput.Key(ch,sc,down))}
    @Test fun originalDictionaryAndQuiz() {
        val (k,env)=boot("C:/Apps/Vocabulary/Run.HC")
        try {
            advance(k,3000);assertFalse(k.finished)
            assertTrue(k.console.plainText(),k.console.plainText().contains("Answer:"))
            val def=k.dictionary.get("WATERFOWL")!!
            assertTrue(latin1(def),latin1(def).contains("water",true))
            key(k,'1'.code);advance(k,4000)
            assertTrue(k.console.plainText(),k.console.plainText().contains("(1)"))
            key(k,Keys.CH_ESC);advance(k,7000);key(k,Keys.CH_ESC);advance(k,7500)
            assertTrue(k.finished);assertEquals(0.0,env.sounds.last(),0.0)
        } finally {k.terminate("test")}
    }
    @Test fun originalMorseDecodesDotDashAndStopsSound() {
        val (k,env)=boot("C:/Demo/Snd/MorseCode.HC")
        try {
            advance(k,100);key(k,'x'.code);advance(k,200);key(k,'x'.code,false);advance(k,250)
            key(k,'x'.code);advance(k,450);key(k,'x'.code,false);advance(k,800)
            assertTrue(k.console.plainText(),k.console.plainText().contains(".-A "))
            assertTrue(env.sounds.any {it>0});assertEquals(0.0,env.sounds.last(),0.0)
            key(k,Keys.CH_ESC);advance(k,1000);assertTrue(k.finished)
        } finally {k.terminate("test")}
    }
    @Test fun originalStadiumLoadsBackgroundThrowsBallAndRestarts() {
        val (k,env)=boot("C:/Demo/Games/Stadium/Stadium.HC")
        try {
            advance(k,1000);assertTrue(k.graphicsUsed);assertTrue(k.published.toSet().size>6)
            val before=k.published.copyOf();k.post(KInput.Mouse(300,60,true,false));advance(k,1050)
            assertFalse(before.contentEquals(k.published));k.post(KInput.Mouse(300,60,false,false))
            key(k,'\n'.code);advance(k,1500);key(k,Keys.CH_ESC);key(k,Keys.CH_ESC,false);advance(k,2000)
            assertTrue(k.finished)
        } finally {k.terminate("test")}
    }
    @Test fun originalModelsGenerateManAfterEditingForm() {
        val (k,env)=boot("C:/Apps/GrModels/Run.HC")
        try {
            advance(k,1000);assertTrue("finished=${k.finished} fields=${k.prog.classes["ManDefineStruct"]?.members?.values?.map {it.name+":"+(it.format?.size)}} doc=${k.mem.ld8(k.mainTask!!.fsAddr+k.o.task("put_doc"))} ${k.console.plainText()}",k.console.plainText().contains("Head Radius"))
            key(k,Keys.CH_ESC);advance(k,2000);key(k,'n'.code);advance(k,2500)
            assertTrue(k.console.plainText(),k.console.plainText().contains("Do another"))
            assertTrue(k.graphicsUsed)
        } finally {k.terminate("test")}
    }
    @Test fun documentEntriesCallbacksAndFormMetadata() {
        val k=runHolyC(latin1("""
            class TestForm {F64 x format "${'$'}${'$'}DA,A=\"Value:%g\"${'$'}${'$'}";};
            CDoc *doc=DocNew;CDocEntry *e=DocPrint(doc,"${'$'}${'$'}MU,\"One\",LE=17${'$'}${'$'}\n");
            if(e->left_exp!=17 || e->type_u8!=DOCT_MENU_VAL) throw('BadDoc');
            if(StrCmp(e->tag,"One")) throw('BadTag');
            U8 *fields=MobileDocFields("TestForm");if(!*fields) throw('NoFormat');Free(fields);
            U8 *Meta(U8 *ptr,U8 *name=lastclass) {Print("class:%s",name);return MobileDocFields(name);}
            TestForm form;Free(Meta(&form));DocDel(doc);"done";
        """.trimIndent()))
        assertTrue(k.console.plainText(),k.finished);assertNull(k.exitMessage);assertTrue(k.console.plainText().contains("done"));assertTrue(k.console.plainText(),k.console.plainText().contains("class:TestForm"))
    }
    @Test fun originalBudgetEntrySaveAndReload() {
        val (k,env)=boot("C:/Apps/Budget/Run.HC")
        fun type(s:String) {for(c in s) key(k,c.code)}
        try {
            advance(k,1000);key(k,'n'.code);advance(k,1100)
            assertTrue(k.console.plainText(),k.console.plainText().contains("Credit"))
            type("10/24/2026\n12.5\nCASH\nBANK\nsimulator entry")
            key(k,Keys.CH_ESC);advance(k,1500)
            assertTrue(k.console.plainText(),k.console.plainText().contains("simulator entry"))
            key(k,Keys.CH_ESC);advance(k,2000);assertTrue(k.finished)
            assertTrue(env.fs!!.exists("C:/Home/Budget/Bgt.DATA.Z"))
            val again=Kernel(TestEnv(env.fs),"budget-reopen");again.virtualTime=true;again.boot()
            again.runProgram("C:/Apps/Budget/Run.HC",env.fs!!.readFile("C:/Apps/Budget/Run.HC")!!)
            try {advance(again,1000);assertTrue(again.console.plainText(),again.console.plainText().contains("simulator entry"))}
            finally {again.terminate("test")}
        } finally {k.terminate("test")}
    }
    @Test fun originalPsalmodyRecordsPlaysAndSavesNotes() {
        val (k,env)=boot("C:/Apps/Psalmody/Run.HC")
        fun tap(ch:Int) {key(k,ch);key(k,ch,false)}
        try {
            advance(k,1000);assertFalse(k.finished);assertTrue(k.graphicsUsed)
            tap('z'.code);advance(k,1100)
            key(k,'a'.code);advance(k,1400);key(k,'a'.code,false);advance(k,1500)
            key(k,'s'.code);advance(k,1800);key(k,'s'.code,false);advance(k,1900)
            assertTrue(env.sounds.any {it>0});assertEquals(0.0,env.sounds.last(),0.0)
            val head=k.o.global("psm");assertNotEquals(head.toLong(),k.mem.ld8(head))
            k.post(KInput.Raw(2,0,0x4CB0000044B));advance(k,2000)
            tap('x'.code);advance(k,3500)
            assertTrue(env.sounds.count {it>0}>=4)
            tap(Keys.CH_ESC);advance(k,3700)
            assertTrue(k.console.plainText(),k.console.plainText().contains("FileName"))
            tap(Keys.CH_ESC);advance(k,4000);assertTrue(k.finished)
            val song=env.fs!!.readFile("C:/Home/Psalmody/Tmp.HC.Z")!!
            assertTrue(latin1(song),latin1(song).contains("Play(\""))
            assertEquals(0.0,env.sounds.last(),0.0)
        } finally {k.terminate("test")}
    }
    @Test fun commandServerExecutesRealFunctionAndExits() {
        val k=runHolyC(latin1("""
            U0 PrintJob(I64 number) {"job:%d\n",number;}
            CTask *server=Spawn(&SrvCmdLine,NULL,"Server");
            TaskExe(server,Fs,"PrintJob(17);PrintJob(23);",1<<JOBf_EXIT_ON_COMPLETE);
            TaskWait(server);"done\n";
        """.trimIndent()))
        assertNull(k.console.plainText(),k.exitMessage);assertTrue(k.finished)
        assertTrue(k.console.plainText(),k.console.plainText().contains("job:17\njob:23"))
    }
    @Test fun originalToTheFrontLoadsAIAndTerrain() {
        val (k,env)=boot("C:/Apps/ToTheFront/Run.HC")
        try {
            advance(k,500);key(k,10);advance(k,5000);assertFalse(k.console.plainText(),k.finished);assertTrue("time=${k.now()} ${k.console.plainText()}",k.graphicsUsed)
            val array=k.prog.globals["player_move"] as GlobalSym
            assertNotEquals(0L,k.mem.ld8(array.addr));assertNotEquals(0L,k.mem.ld8(array.addr+8))
            assertTrue(k.published.toSet().size>6)
            key(k,' '.code);advance(k,7000);key(k,Keys.CH_ESC);key(k,Keys.CH_ESC,false);advance(k,7500)
            assertTrue(k.console.plainText(),k.finished)
        } finally {k.terminate("test")}
    }
    @Test fun originalJukeBoxSelectsPlaysRatesAndExits() {
        val (k,env)=boot("C:/Apps/Psalmody/Load.HC")
        try {
            advance(k,1000);assertFalse(k.finished)
            assertTrue(k.console.plainText(),k.console.plainText().contains("to rate a song"))
            key(k,'7'.code);advance(k,1100)
            key(k,' '.code);advance(k,2500)
            assertTrue(k.console.plainText(),env.sounds.any {it>0})
            key(k,Keys.CH_ESC);advance(k,3000)
            assertTrue(k.console.plainText(),k.finished);assertEquals(0.0,env.sounds.last(),0.0)
        } finally {k.terminate("test")}
    }
    @Test fun originalFontEditorTogglesAndSavesGlyph() {
        val (k,env)=boot("C:/Demo/Graphics/FontEd.HC")
        try {
            advance(k,1000);val font=k.gfx.fontAddr;val old=k.mem.ld1(font)
            k.post(KInput.Mouse(145,41,true,false));advance(k,1100);k.post(KInput.Mouse(145,41,false,false));advance(k,1200)
            assertEquals(old or 1,k.mem.ld1(font))
            key(k,Keys.CH_ESC);key(k,Keys.CH_ESC,false);advance(k,1500);assertTrue(k.finished)
            assertTrue(env.fs!!.readFile("C:/Home/Tmp.DD.Z")!!.isNotEmpty())
        } finally {k.terminate("test")}
    }
    @Test fun originalGridSnapsAndRestores() {
        val (k,env)=boot("C:/Demo/Graphics/Grid.HC")
        try {
            advance(k,100);k.post(KInput.Mouse(113,117,false,false));advance(k,200)
            assertEquals(110L,k.mem.ld8(k.o.msAddr+k.o.msPos));assertEquals(115L,k.mem.ld8(k.o.msAddr+k.o.msPos+8))
            k.post(KInput.Mouse(113,117,true,false));advance(k,300);assertTrue(k.finished)
            assertEquals(0L,k.mem.ld1(k.o.global("ms_grid")))
        } finally {k.terminate("test")}
    }
    @Test fun originalBalloonUsesPlanarPixelsAndTiming() {
        val (k,env)=boot("C:/Demo/Graphics/Balloon.HC")
        try {
            advance(k,100);assertFalse(k.finished);assertTrue(k.graphicsUsed)
            assertTrue(k.published.any {(it.toInt() and 15)==14});val first=k.published.copyOf()
            advance(k,900);assertFalse(first.contentEquals(k.published))
            advance(k,2200);assertTrue(k.finished)
        } finally {k.terminate("test")}
    }
    @Test fun originalScreenCaptureSavesAndReadsPixels() {
        val (k,env)=boot("C:/Demo/Graphics/ScrnCapture.HC")
        try {
            advance(k,100);key(k,'x'.code);advance(k,250)
            val im=GRImage.decodeFile(env.fs!!.readFile("C:/Home/DemoScrnShot.GR.Z")!!,true)
            assertEquals(640,im.width);assertEquals(480,im.height);assertTrue(im.body.toSet().size>1)
            key(k,'x'.code);advance(k,500);assertTrue(k.graphicsUsed);key(k,'x'.code);advance(k,750);assertTrue(k.finished)
        } finally {k.terminate("test")}
    }
    @Test fun originalWallpaperControlRetainsCallbacksAndExits() {
        val (k,env)=boot("C:/Demo/Graphics/WallPaperCtrl.HC")
        try {
            advance(k,1000);assertFalse(k.finished);assertTrue(k.graphicsUsed)
            val before=k.published.copyOf();k.post(KInput.Mouse(300,240,true,false));advance(k,1100)
            k.post(KInput.Mouse(300,240,false,false));advance(k,1200);assertFalse(before.contentEquals(k.published))
            key(k,Keys.CH_ESC);advance(k,1500);assertTrue(k.finished)
        } finally {k.terminate("test")}
    }
    @Test fun originalSpriteSourceSummary() {
        val (k,env)=boot("C:/Demo/Graphics/SpriteText.HC")
        try {advance(k,1000);assertTrue(k.finished);assertTrue(k.console.plainText(),k.console.plainText().contains("ENTIRE SPRITE CODE"));assertTrue(k.console.plainText().contains("Line{"))}
        finally {k.terminate("test")}
    }

}

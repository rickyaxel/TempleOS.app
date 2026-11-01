package io.github.templeosmobile.purekotlin

import io.github.templeosmobile.core.kernel.*
import io.github.templeosmobile.core.holyc.*
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.Parameterized
import org.junit.Assert.*
import java.io.File

/** Original source workflows on each independent engine, including real files, rendering and audio. */
@RunWith(Parameterized::class)
class SourceOnlyProgramParityTest(private val engine:Engine) {
    companion object {@JvmStatic @Parameterized.Parameters(name="{0}") fun engines()=Engine.entries.map {arrayOf(it)}}
    private fun boot(path:String)=bootProgram(path,engine)
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
            assertTrue(k.finished);assertEquals(0.0,env.sound.last().second,0.0)
        } finally {if(engine==Engine.NATIVE) assertEquals(0L,k.vm.instructionsExecuted);k.terminate("test")}
    }
    @Test fun originalMorseDecodesDotDashAndStopsSound() {
        val (k,env)=boot("C:/Demo/Snd/MorseCode.HC")
        try {
            advance(k,100);key(k,'x'.code);advance(k,200);key(k,'x'.code,false);advance(k,250)
            key(k,'x'.code);advance(k,450);key(k,'x'.code,false);advance(k,800)
            assertTrue(k.console.plainText(),k.console.plainText().contains(".-A "))
            assertTrue(env.sound.any {it.second>0});assertEquals(0.0,env.sound.last().second,0.0)
            key(k,Keys.CH_ESC);advance(k,1000);assertTrue(k.finished)
        } finally {if(engine==Engine.NATIVE) assertEquals(0L,k.vm.instructionsExecuted);k.terminate("test")}
    }
    @Test fun originalStadiumLoadsBackgroundThrowsBallAndRestarts() {
        val (k,env)=boot("C:/Demo/Games/Stadium/Stadium.HC")
        try {
            advance(k,1000);assertTrue(k.graphicsUsed);assertTrue(k.published.toSet().size>6)
            val before=k.published.copyOf();k.post(KInput.Mouse(300,60,true,false));advance(k,1050)
            assertFalse(before.contentEquals(k.published));k.post(KInput.Mouse(300,60,false,false))
            key(k,'\n'.code);advance(k,1500);key(k,Keys.CH_ESC);key(k,Keys.CH_ESC,false);advance(k,2000)
            assertTrue(k.finished)
        } finally {if(engine==Engine.NATIVE) assertEquals(0L,k.vm.instructionsExecuted);k.terminate("test")}
    }
    @Test fun originalModelsGenerateManAfterEditingForm() {
        val (k,env)=boot("C:/Apps/GrModels/Run.HC")
        try {
            advance(k,1000);assertTrue("finished=${k.finished} fields=${k.prog.classes["ManDefineStruct"]?.members?.values?.map {it.name+":"+(it.format?.size)}} doc=${k.mem.ld8(k.mainTask!!.fsAddr+k.o.task("put_doc"))} ${k.console.plainText()}",k.console.plainText().contains("Head Radius"))
            key(k,Keys.CH_ESC);advance(k,2000);key(k,'n'.code);advance(k,2500)
            assertTrue(k.console.plainText(),k.console.plainText().contains("Do another"))
            assertTrue(k.graphicsUsed);assertFalse("PersonalMenu's trailing View keeps the generated model open",k.finished)
            val first=k.published.copyOf();val allocated=k.mem.allocated;advance(k,3000)
            val changed=first.indices.count {first[it]!=k.published[it]}
            assertTrue("the original mesh continues rotating in View",changed>200)
            val afterAnimation=k.mem.allocated
            assertTrue("live sprite redraw does not retain per-frame arena allocations",afterAnimation<=allocated+4096)
            key(k,Keys.CH_ESC);key(k,Keys.CH_ESC,false);advance(k,3300);assertTrue(k.finished)
            k.documents.export("C:/Home/GeneratedModel.DD")
            val saved=env.fs!!.readFile("C:/Home/GeneratedModel.DD")!!
            assertEquals(1,io.github.templeosmobile.core.holyc.SourceFile.parse("model",saved).bins.size)
            assertTrue(latin1(saved).contains("BI=1"))
            val out=File("build/distribution-support");out.mkdirs()
            File(out,"Models-View-$engine.txt").writeText("path=C:/Apps/GrModels/Run.HC\nengine=$engine\ninstructions=${k.vm.instructionsExecuted}\nchangedPixels=$changed\narenaBefore=$allocated\narenaAfterAnimation=$afterAnimation\narenaAfterExit=${k.mem.allocated}\nviewExited=${k.finished}\nexportedBinaryRecords=1\n")
        } finally {if(engine==Engine.NATIVE) assertEquals(0L,k.vm.instructionsExecuted);k.terminate("test")}
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
            val again=bootProgram("C:/Apps/Budget/Run.HC",engine,env.fs!!).first
            try {advance(again,1000);assertTrue(again.console.plainText(),again.console.plainText().contains("simulator entry"))}
            finally {again.terminate("test")}
        } finally {if(engine==Engine.NATIVE) assertEquals(0L,k.vm.instructionsExecuted);k.terminate("test")}
    }
    @Test fun originalPsalmodyRecordsPlaysAndSavesNotes() {
        val (k,env)=boot("C:/Apps/Psalmody/Run.HC")
        fun tap(ch:Int) {key(k,ch);key(k,ch,false)}
        try {
            advance(k,1000);assertFalse(k.finished);assertTrue(k.graphicsUsed)
            tap('z'.code);advance(k,1100)
            key(k,'a'.code);advance(k,1400);key(k,'a'.code,false);advance(k,1500)
            key(k,'s'.code);advance(k,1800);key(k,'s'.code,false);advance(k,1900)
            assertTrue(env.sound.any {it.second>0});assertEquals(0.0,env.sound.last().second,0.0)
            val head=k.o.global("psm");assertNotEquals(head.toLong(),k.mem.ld8(head))
            k.post(KInput.Raw(2,0,0x4CB0000044B));advance(k,2000)
            tap('x'.code);advance(k,3500)
            assertTrue(env.sound.count {it.second>0}>=4)
            tap(Keys.CH_ESC);advance(k,3700)
            assertTrue(k.console.plainText(),k.console.plainText().contains("FileName"))
            tap(Keys.CH_ESC);advance(k,6000);assertTrue(k.finished)
            val song=env.fs!!.readFile("C:/Home/Psalmody/Tmp.HC.Z")!!
            assertTrue(latin1(song),latin1(song).contains("Play(\""))
            assertEquals(0.0,env.sound.last().second,0.0)
            env.fs!!.writeFile("C:/Apps/Psalmody/Examples/aaa_recorded.HC",song)
            val (replay,replayEnv)=bootProgram("C:/Apps/Psalmody/Load.HC",engine,env.fs!!)
            try {
                advance(replay,1000);assertTrue(replay.console.plainText().contains("aaa_reco"))
                key(replay,' '.code);advance(replay,2500)
                assertTrue(replay.console.plainText(),replayEnv.sound.any {it.second>0})
                key(replay,Keys.CH_ESC);advance(replay,3000);assertTrue(replay.finished)
                if(engine==Engine.NATIVE) assertEquals(0L,replay.vm.instructionsExecuted)
                assertEquals(0.0,replayEnv.sound.last().second,0.0)
            } finally {replay.terminate("test")}

        } finally {if(engine==Engine.NATIVE) assertEquals(0L,k.vm.instructionsExecuted);k.terminate("test")}
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
        } finally {if(engine==Engine.NATIVE) assertEquals(0L,k.vm.instructionsExecuted);k.terminate("test")}
    }
    @Test fun originalJukeBoxSelectsPlaysRatesAndExits() {
        val (k,env)=boot("C:/Apps/Psalmody/Load.HC")
        try {
            advance(k,1000);assertFalse(k.finished)
            assertTrue(k.console.plainText(),k.console.plainText().contains("to rate a song"))
            key(k,'7'.code);advance(k,1100)
            key(k,' '.code);advance(k,2500)
            assertTrue(k.console.plainText(),env.sound.any {it.second>0})
            key(k,Keys.CH_ESC);advance(k,3000)
            assertTrue(k.console.plainText(),k.finished);assertEquals(0.0,env.sound.last().second,0.0)
        } finally {if(engine==Engine.NATIVE) assertEquals(0L,k.vm.instructionsExecuted);k.terminate("test")}
    }
    @Test fun originalFontEditorTogglesAndSavesGlyph() {
        val (k,env)=boot("C:/Demo/Graphics/FontEd.HC")
        try {
            advance(k,1000);val font=k.gfx.fontAddr;val old=k.mem.ld1(font)
            k.post(KInput.Mouse(145,41,true,false));advance(k,1100);k.post(KInput.Mouse(145,41,false,false));advance(k,1200)
            assertEquals(old or 1,k.mem.ld1(font))
            key(k,Keys.CH_ESC);key(k,Keys.CH_ESC,false);advance(k,1500);assertTrue(k.finished)
            assertTrue(env.fs!!.readFile("C:/Home/Tmp.DD.Z")!!.isNotEmpty())
        } finally {if(engine==Engine.NATIVE) assertEquals(0L,k.vm.instructionsExecuted);k.terminate("test")}
    }
    @Test fun originalGridSnapsAndRestores() {
        val (k,env)=boot("C:/Demo/Graphics/Grid.HC")
        try {
            advance(k,100);k.post(KInput.Mouse(113,117,false,false));advance(k,200)
            assertEquals(110L,k.mem.ld8(k.o.msAddr+k.o.msPos));assertEquals(115L,k.mem.ld8(k.o.msAddr+k.o.msPos+8))
            assertEquals("original 5-pixel cursor first row",k.published[115*640+110],k.published[115*640+114]);assertNotEquals("cursor width",k.published[115*640+114],k.published[115*640+115])
            k.post(KInput.Mouse(113,117,true,false));advance(k,300);assertTrue(k.finished)
            assertEquals(0L,k.mem.ld1(k.o.global("ms_grid")))
        } finally {if(engine==Engine.NATIVE) assertEquals(0L,k.vm.instructionsExecuted);k.terminate("test")}
    }
    @Test fun originalBalloonUsesPlanarPixelsAndTiming() {
        val (k,env)=boot("C:/Demo/Graphics/Balloon.HC")
        try {
            advance(k,100);assertFalse(k.finished);assertTrue(k.graphicsUsed)
            assertTrue(k.published.any {(it.toInt() and 15)==14});val first=k.published.copyOf()
            advance(k,900);assertFalse(first.contentEquals(k.published))
            advance(k,2200);assertTrue(k.finished)
        } finally {if(engine==Engine.NATIVE) assertEquals(0L,k.vm.instructionsExecuted);k.terminate("test")}
    }
    @Test fun originalScreenCaptureSavesAndReadsPixels() {
        val (k,env)=boot("C:/Demo/Graphics/ScrnCapture.HC")
        try {
            advance(k,100);key(k,'x'.code);advance(k,250)
            val im=GRImage.decodeFile(env.fs!!.readFile("C:/Home/DemoScrnShot.GR.Z")!!,true)
            assertEquals(640,im.width);assertEquals(480,im.height);assertTrue(im.body.toSet().size>1)
            key(k,'x'.code);advance(k,500);assertTrue(k.graphicsUsed);key(k,'x'.code);advance(k,750);assertTrue(k.finished)
        } finally {if(engine==Engine.NATIVE) assertEquals(0L,k.vm.instructionsExecuted);k.terminate("test")}
    }
    @Test fun originalWallpaperControlRetainsCallbacksAndExits() {
        val (k,env)=boot("C:/Demo/Graphics/WallPaperCtrl.HC")
        try {
            advance(k,1000);assertFalse(k.finished);assertTrue(k.graphicsUsed)
            val before=k.published.copyOf();k.post(KInput.Mouse(300,240,true,false));advance(k,1100)
            k.post(KInput.Mouse(300,240,false,false));advance(k,1200);assertFalse(before.contentEquals(k.published))
            key(k,Keys.CH_ESC);advance(k,1500);assertTrue(k.finished)
        } finally {if(engine==Engine.NATIVE) assertEquals(0L,k.vm.instructionsExecuted);k.terminate("test")}
    }
    @Test fun originalSpriteSourceSummary() {
        val (k,env)=boot("C:/Demo/Graphics/SpriteText.HC")
        try {advance(k,1000);assertTrue(k.finished);assertTrue(k.console.plainText(),k.console.plainText().contains("ENTIRE SPRITE CODE"));assertTrue(k.console.plainText().contains("Line{"))}
        finally {if(engine==Engine.NATIVE) assertEquals(0L,k.vm.instructionsExecuted);k.terminate("test")}
    }

    @Test fun originalPoleZeroDraggingAndPhaseView() {
        val (k,env)=boot("C:/Demo/Graphics/PoleZeros.HC")
        fun step(ms:Long=600) {advance(k,k.now()/1_000_000+ms)}
        try {
            step(2500);assertFalse(k.finished);assertTrue(k.graphicsUsed)
            val before=k.published.copyOf();k.post(KInput.Mouse(330,240,true,false));step()
            k.post(KInput.Mouse(350,260,true,false));step();k.post(KInput.Mouse(350,260,false,false));step()
            val zeros=(k.prog.globals["zeros"] as GlobalSym).addr
            assertEquals("mouse translated to original zero",30.0,Double.fromBits(k.mem.ld8(zeros)),0.0)
            assertFalse(before.contentEquals(k.published))
            k.post(KInput.Mouse(350,260,false,true));step();k.post(KInput.Mouse(350,260,false,false));step()
            key(k,Keys.CH_ESC);key(k,Keys.CH_ESC,false);step();assertTrue(k.finished)
            if(engine==Engine.NATIVE) assertEquals(0L,k.vm.instructionsExecuted)
        } finally {k.terminate("test")}
    }
    @Test fun originalTimeClockPunchInOutAndReload() {
        val fs=bundledFs();val env=ParityEnv(fs);env.popupAnswers.addAll(listOf(0,1,2,-1))
        val k=bootProgram("C:/Apps/TimeClock/Load.HC",engine,fs,env).first
        try {
            advance(k,500);assertTrue(k.console.plainText(),k.console.plainText().contains("Enter Description"))
            for(c in "arrived") key(k,c.code);key(k,Keys.CH_ESC);advance(k,1000)
            for(c in "left") key(k,c.code);key(k,Keys.CH_ESC);advance(k,1500)
            assertTrue(k.finished);assertTrue(k.console.plainText().contains("arrived"));assertTrue(k.console.plainText().contains("left"))
            val data=fs.readFile("C:/Home/TimeClock/TimeFile.DATA.Z")!!;assertEquals(1,data[0].toInt());assertTrue(data.contains(2))
            if(engine==Engine.NATIVE) assertEquals(0L,k.vm.instructionsExecuted)
        } finally {k.terminate("test")}
    }

}

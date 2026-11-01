package io.github.templeosmobile.core

import io.github.templeosmobile.core.holyc.latin1
import io.github.templeosmobile.core.kernel.*
import io.github.templeosmobile.core.ui.Json
import org.junit.Assert.*
import org.junit.Test
import java.io.File

/**
 * The sound of the three programs TempleOS Mobile cannot run as a whole (Psalmody and ToTheFront need the DolDoc
 * document API, Vocabulary the 26 MB AutoComplete dictionary), checked by running their original HolyC headless:
 * Psalmody's song files unmodified, Vocabulary's VocabQuiz.HC and ToTheFront's fire and move code unmodified behind
 * a test-only stand-in for the missing API. Nothing here is shipped. Port: BlockedProgramsSoundTests.swift.
 * Spec: docs/audio/TEMPLEOS_AUDIO_FIDELITY.md §11.
 */
class BlockedProgramsSoundTest {
    @Suppress("UNCHECKED_CAST")
    private val fx = Json.parse(File(SHARED, "test-vectors/audio/play-fixtures.json").readText()) as Map<String, Any?>
    @Suppress("UNCHECKED_CAST")
    private val onaHz: Map<Int, Double> = (fx["pit_counts"] as List<List<Number>>).associate { it[0].toInt() to it[2].toDouble() } + (0 to 0.0)

    private fun bundledFs() = LayeredFs(DirBundle(File(SHARED, "bundled-fs"), File(SHARED, "bundled-fs.index")),
        kotlin.io.path.createTempDirectory("tosm-blocked").toFile())

    /** Boots, runs [src] as [name], and steps virtual time until [untilNs] (or the end); [during] may post input. */
    private fun run(env: TestEnv, src: ByteArray, name: String, untilNs: Long, during: (Kernel) -> Unit = {}): Kernel {
        val k = Kernel(env, "blocked")
        k.virtualTime = true
        k.boot()
        k.runProgram(name, src)
        val wall = System.nanoTime() + 120_000_000_000L
        k.virtualStopAt = untilNs
        while (!k.finished && k.now() < untilNs && System.nanoTime() < wall) { during(k); if (k.step(50_000_000) < 0) break }
        return k
    }

    private fun changes(env: TestEnv, fromJiffy: Long): List<Pair<Long, Double>> {
        val out = ArrayList<Pair<Long, Double>>()
        var cur = 0.0
        for (i in env.sounds.indices) {
            val j = TempleClock.jiffyAt(env.soundNowNs[i])
            if (j < fromJiffy) { cur = env.sounds[i]; continue }
            if (env.sounds[i] != cur) { out.add(j to env.sounds[i]); cur = env.sounds[i] }
        }
        return out
    }

    // ------------------------------------------------------------------ Psalmody

    @Test fun psalmodySongFilesPlayTheirScoresAsTheReference() {
        // Apps/Psalmody/Examples/*.HC, the songs JukeBox plays, run unmodified from cnts.jiffies 200000: one pass of
        // each song's loop must match the reference model's events jiffy for jiffy (tools/audio/templeos_snd.py)
        @Suppress("UNCHECKED_CAST") val cases = (fx["cases"] as List<Map<String, Any?>>).filter { (it["id"] as String).startsWith("psalmody:") }
        assertEquals(3, cases.size)
        for (c in cases) {
            val file = (c["id"] as String).removePrefix("psalmody:")
            val j0 = (c["j0"] as Number).toLong()
            val end = (c["end"] as Number).toLong()
            val bytes = File(SHARED, "bundled-fs/Apps/Psalmody/Examples/$file").readBytes()
            val env = TestEnv(bundledFs())
            val k = run(env, latin1("SleepUntil($j0);\n") + bytes, "C:/Apps/Psalmody/Examples/$file", TempleClock.jiffyStartNs(j0 + end + 30))
            assertFalse("$file: ${k.console.plainText().takeLast(300)}", k.finished)
            @Suppress("UNCHECKED_CAST") val want = (c["events"] as List<List<Number>>).map { it[0].toLong() to onaHz.getValue(it[1].toInt()) }
            val got = changes(env, j0).map { (it.first - j0) to it.second }.filter { it.first < end }
            assertEquals("$file: one pass of the song", want, got)
            // the loop goes round again: the first note of the second pass is on the jiffy the first pass ended
            assertEquals("$file: second pass", end to want[0].second, changes(env, j0).map { (it.first - j0) to it.second }.first { it.first >= end })
        }
    }

    // ------------------------------------------------------------------ Vocabulary

    /**
     * Test-only stand-in for Adam/AutoComplete's dictionary (not bundled: 26 MB): acd.word_lst in its format
     * (ACD_WORD_CHAR, the word, its NUL, two bytes), ACDDefGet's text, and ACDPopUpDef's pop-up as a no-op.
     */
    private val vocabShim = """
        class CAcdShim { U8 *word_lst; I64 num_words; };
        CAcdShim acd;
        U8 *ACDDefGet(U8 *st,I64 def_num=1) { no_warn def_num; return MStrPrint("the meaning of %s",st); }
        U0 ACDPopUpDef(U8 *st,I64 def_num=1,CTask *mem_task=NULL) { no_warn st,def_num,mem_task; }
        U0 AcdShimInit()
        {
          U8 *names[4]={"alpha","beta","gamma","delta"},*p;
          I64 i;
          p=acd.word_lst=CAlloc(256);
          for (i=0;i<4;i++) { *p++=ACD_WORD_CHAR; StrCpy(p,names[i]); p+=StrLen(names[i])+1+2; }
          acd.num_words=4;
        }
        AcdShimInit;
        #include "C:/Apps/Vocabulary/VocabQuiz.HC"
        VocabQuiz;
    """.trimIndent() + "\n"

    @Test fun vocabularyQuizSoundsAsTheOriginal() {
        // Apps/Vocabulary/VocabQuiz.HC: a right answer is Snd(74), a wrong one Snd(46), each 500 jiffies (Sleep(500))
        // then off. The same entropy picks the same right slot, so of the four keys exactly one is right.
        var right = 0
        for (key in "1234") {
            val fs = bundledFs()
            fs.mkdir("C:/Adam/AutoComplete")
            fs.writeFile("C:/Adam/AutoComplete/ACDefs.DATA", ByteArray(16)) // FileFind(ACD_DEF_FILENAME) must succeed
            val env = TestEnv(fs)
            var posted = 0
            val k = run(env, latin1(vocabShim), "C:/Home/VocabShim.HC", 5_000_000_000L) { kk ->
                val ms = kk.now() / 1_000_000
                if (posted == 0 && ms > 1000) { val (ch, sc) = ScenarioTest.keyOf("$key"); kk.post(KInput.Key(ch, sc, true)); kk.post(KInput.Key(ch, sc or Keys.SCF_KEY_UP, false)); posted = 1 }
                if (posted == 1 && ms > 3000) { val (ch, sc) = ScenarioTest.keyOf("ESC"); kk.post(KInput.Key(ch, sc, true)); kk.post(KInput.Key(ch, sc or Keys.SCF_KEY_UP, false)); posted = 2 }
            }
            val text = k.console.plainText()
            assertTrue("key $key: $text", text.contains("Answer:"))
            val c = changes(env, 0)
            val correct = text.contains("Correct")
            assertTrue("key $key: $text", correct xor text.contains("Incorrect"))
            if (correct) right++
            assertEquals("key $key: a tone and its end: $c", 2, c.size)
            assertEquals(onaHz.getValue(if (correct) 74 else 46), c[0].second, 0.0)
            assertEquals(0.0, c[1].second, 0.0)
            // Sleep(500) from the key's jiffy: 500 jiffies
            assertEquals("key $key", 500L, c[1].first - c[0].first)
        }
        assertEquals("exactly one of the four keys is the right answer", 1, right)
    }

    // ------------------------------------------------------------------ ToTheFront

    /**
     * Test-only harness: ToTheFront's files without its DolDoc-bound ones (TTFInit builds the AI menu with CDoc,
     * ToTheFront.HC and TTFDraw run the game window). TTFGlbls, TTFLib, TTFVis, TTFFire and TTFMove compile
     * unmodified; the harness only places two hexes and two units, then calls the original functions.
     */
    private val ttfHarness = """
        Cd("C:/Apps/ToTheFront");;
        #include "C:/Apps/ToTheFront/TTFGlbls.HC"
        #include "C:/Apps/ToTheFront/TTFLib.HC"
        #include "C:/Apps/ToTheFront/TTFVis.HC"
        #include "C:/Apps/ToTheFront/TTFFire.HC"
        #include "C:/Apps/ToTheFront/TTFMove.HC"
        I64 plots;
        Bool CountPlot(U0,I64,I64,I64) { plots++; return TRUE; }
        U0 Harness()
        {
          Unit *a=&units[0][0],*b=&units[1][0];
          I64 j;
          animation_delay=0.5;
          hex_centers[2][2].x=40; hex_centers[2][2].y=40;
          hex_centers[2][3].x=73; hex_centers[2][3].y=49;
          a->num=0; a->player=0; a->row=2; a->col=2; a->life=10; a->infantry=TRUE; a->facing=0;
          b->num=0; b->player=1; b->row=2; b->col=3; b->life=10; b->infantry=FALSE; b->armor=5; b->facing=3;
          plots=0; Line(NULL,40,40,0,73,49,0,&CountPlot);
          "PLOTS:%d\n",plots;
          SleepUntil(10000);
          UnitMoveAnimation(a,2,3,1);                        //infantry: Snd(53), the move, Snd
          SleepUntil(12000);
          UnitMoveAnimation(b,2,2,0);                        //armour: Snd(41) while turning, Snd(34) moving, Snd
          SleepUntil(16000);
          DamageDo(a,100.0);                                 //killed: Noise(1000*animation_delay,74,98)
          "KILL_END:%d\n",cnts.jiffies;
          SleepUntil(20000);
          a->life=10; b->life=10; b->fired=FALSE;
          HexOccupy(TRUE,b,a);                               //Noise(500*d,34,41), then while (scrncast.ona) Yield;
          "OCC_END:%d MUTE:%d\n",cnts.jiffies,music.mute;
        }
        Harness;
    """.trimIndent() + "\n"

    @Test fun toTheFrontMoveAndFireSoundAsTheOriginal() {
        val env = TestEnv(bundledFs())
        val k = run(env, latin1(ttfHarness), "C:/Home/TTFShim.HC", TempleClock.jiffyStartNs(26000))
        val text = k.console.plainText()
        assertTrue(text, k.finished && text.contains("MUTE:0"))
        val plots = Regex("PLOTS:(\\d+)").find(text)!!.groupValues[1].toLong()
        assertTrue(plots > 10)
        val c = changes(env, 10000)
        // infantry move: Snd(53), the move, then off; armour: Snd(41) while it turns, Snd(34) while it moves, then off.
        // Known gap (docs §11.5): UnitMovePlot's Sleep(5*animation_delay) runs inside the native Line's callback, where
        // a task cannot block, so the move takes no time here (TempleOS: 2 jiffies per pixel, $plots pixels)
        assertEquals(listOf(onaHz.getValue(53), 0.0), c.filter { it.first in 10000 until 12000 }.map { it.second })
        val arm = c.filter { it.first in 12000 until 16000 }
        assertEquals(listOf(onaHz.getValue(41), onaHz.getValue(34), 0.0), arm.map { it.second })
        assertEquals(12000L, arm[0].first)
        // the turn is the task's own loop (Sleep(2) per 0.03 rad step): it does take its time
        assertTrue("turning in 0.03 rad steps of 2 jiffies: ${arm[1].first - arm[0].first}", arm[1].first - arm[0].first >= 2 && (arm[1].first - arm[0].first) % 2 == 0L)
        // a kill: Noise(500,74,98) (onas 74..97), Sleep(500), and the speaker off when the noise task ends
        val kill = c.filter { it.first in 16000 until 20000 }
        val killRange = (74..97).map { onaHz.getValue(it) }.toSet()
        assertTrue(kill.dropLast(1).all { it.second in killRange })
        assertEquals(16000L + 501 to 0.0, kill.last())
        // HexOccupy waits on scrncast.ona (Kernel/KMisc.HC Snd keeps it): it returns once the last noise has ended
        val occ = c.filter { it.first >= 20000 }
        val occEnd = Regex("OCC_END:(\\d+)").find(text)!!.groupValues[1].toLong()
        assertEquals(0.0, occ.last().second, 0.0)
        assertTrue("returned at $occEnd, speaker off at ${occ.last().first}", occEnd >= occ.last().first)
        assertTrue(occ.dropLast(1).all { it.second > 0 })
    }
}

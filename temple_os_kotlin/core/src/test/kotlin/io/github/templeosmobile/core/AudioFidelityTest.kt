package io.github.templeosmobile.core

import io.github.templeosmobile.core.holyc.latin1
import io.github.templeosmobile.core.kernel.*
import io.github.templeosmobile.core.ui.Json
import org.junit.Assert.*
import org.junit.Test
import java.io.File

/**
 * TempleOS sound semantics against the independent reference: tools/audio/templeos_snd.py, a port of the original
 * HolyC that matches the original TempleOS jiffy for jiffy in the reference VM. Covers the jiffy clock, Sleep,
 * every Play fixture (shared/test-vectors/audio/play-fixtures.json), the PIT table and the F64 arithmetic as the
 * original printed them, and the Noise/Sweep bookkeeping. Port: AudioFidelityTests.swift.
 * Spec: docs/audio/TEMPLEOS_AUDIO_FIDELITY.md.
 */
class AudioFidelityTest {
    @Suppress("UNCHECKED_CAST")
    private val fx = Json.parse(File(SHARED, "test-vectors/audio/play-fixtures.json").readText()) as Map<String, Any?>

    /** ona -> Hz from the fixture's PIT table (1193182 / count). */
    @Suppress("UNCHECKED_CAST")
    private val onaHz: Map<Int, Double> = (fx["pit_counts"] as List<List<Number>>).associate { it[0].toInt() to it[2].toDouble() } + (0 to 0.0)

    /** The speaker's audible changes as (jiffy, Hz): a setting equal to the current one is not a change. */
    private fun changes(env: TestEnv, fromJiffy: Long = Long.MIN_VALUE): List<Pair<Long, Double>> {
        val out = ArrayList<Pair<Long, Double>>()
        var cur = 0.0
        for (i in env.sounds.indices) {
            val j = TempleClock.jiffyAt(env.soundNowNs[i])
            if (j < fromJiffy) { cur = env.sounds[i]; continue }
            if (env.sounds[i] != cur) { out.add(j to env.sounds[i]); cur = env.sounds[i] }
        }
        return out
    }

    private fun hcString(s: String) = s.replace("\\", "\\\\").replace("\"", "\\\"")

    // ------------------------------------------------------------------ clock

    @Test fun aJiffyIs1192PitClocks() {
        assertEquals(0L, TempleClock.jiffyAt(0))
        assertEquals(999_010L, TempleClock.jiffyStartNs(1))
        assertEquals(999_009_372L, TempleClock.jiffyStartNs(1000))
        // the reference VM: 20019 jiffies in 20 RTC seconds
        assertEquals(20_019L, TempleClock.jiffyAt(20_000_000_000L))
        for (j in listOf(0L, 1L, 2L, 999L, 1000L, 1192L, 1193182L, 86_400_000L, 3_000_000_000L)) {
            val s = TempleClock.jiffyStartNs(j)
            assertEquals(j, TempleClock.jiffyAt(s))
            assertEquals(j - 1, TempleClock.jiffyAt(s - 1))
        }
    }

    @Test fun cntsJiffiesAndSleepCountRealJiffies() {
        // Sleep(1000) from a jiffy boundary is 1000 jiffies: 999.009 ms of kernel time
        val env = TestEnv()
        val k = runHolyC(latin1("SleepUntil(5000);I64 j=cnts.jiffies;Snd(60);Sleep(1000);Snd(62);\"%d\\n\",cnts.jiffies-j;\n"), env = env)
        assertTrue(k.console.plainText(), k.console.plainText().contains("1000"))
        val c = changes(env, 5000)
        assertEquals(listOf(5000L, 6000L), c.take(2).map { it.first })
        val i = env.sounds.indexOfLast { it > 480 }
        assertEquals(TempleClock.jiffyStartNs(6000).toDouble(), env.soundNowNs[i].toDouble(), 50_000.0) // woken at the jiffy, a few instructions later
    }

    @Test fun aSleepLoopWithWorkKeepsItsPeriodAsOnTempleOs() {
        // Kernel/KMisc.HC Sleep = SleepUntil(cnts.jiffies+mS): work done inside the jiffy costs no time, so the loop's
        // period is exactly 10 jiffies (with ~0.3 ms of work per pass, a Sleep counted from "now" drifted 6 ms)
        val env = TestEnv()
        runHolyC(latin1("I64 i,n,s=0;SleepUntil(2000);for(i=0;i<20;i++){for(n=0;n<3000;n++)s+=n;Snd(60+i%2);Sleep(10);}Snd;\n"), env = env)
        val c = changes(env, 2000)
        assertEquals(21, c.size)
        for ((i, e) in c.withIndex()) assertEquals("change $i", 2000L + 10 * i, e.first)
    }

    // ------------------------------------------------------------------ the original's own numbers

    @Test fun pitTableAndFreq2OnaHashLikeTheOriginal() {
        // typed into TempleOS V5.03 in the reference VM, which printed these hashes (docs §4.2)
        val k = runHolyC(latin1("I64 h=0,k;for(k=-128;k<128;k++)if(k)h=h*31+ClampI64(SYS_TIMER_FREQ/Ona2Freq(k),1,U16_MAX);\"H:%X\\n\",h;" +
            "h=0;for(k=1;k<=24000;k++)h=h*31+Freq2Ona(k*0.37);\"F:%X\\n\",h;\n"))
        @Suppress("UNCHECKED_CAST") val h = fx["table_hashes_from_reference_vm"] as Map<String, String>
        val text = k.console.plainText()
        assertTrue(text, text.contains("H:${h["pit_counts"]}"))
        assertTrue(text, text.contains("F:${h["freq2ona_k_0_37"]}"))
        // and the native Snd plays each ona at 1193182/count
        for ((ona, hz) in onaHz) assertEquals("ona $ona", hz, k.natives.speakerFreq(ona), hz * 1e-12)
    }

    @Test fun i64PlusF64RoundsLikeTheOriginal() {
        @Suppress("UNCHECKED_CAST") val a = fx["arith_from_reference_vm"] as Map<String, Any?>
        @Suppress("UNCHECKED_CAST") val p = a["printed"] as Map<String, Number>
        val k = runHolyC(latin1(a["source"] as String + "\"R:%d %d %d %d %d\\n\",a-60000,b-70000,c-300000,d-10,e-1000;\n"))
        val want = listOf("a", "b", "c", "d", "e").joinToString(" ") { p[it]!!.toString() }
        assertTrue(k.console.plainText(), k.console.plainText().contains("R:$want"))
    }

    @Test fun sndKeepsScrncastOnaAsTheOriginal() {
        // Kernel/KMisc.HC Snd: scrncast.ona=ona (muted, Snd does nothing at all); programs read it
        val k = runHolyC(latin1("Snd(60);\"A:%d \",scrncast.ona;Snd(-3);\"B:%d \",scrncast.ona;Mute(ON);\"C:%d \",scrncast.ona;" +
            "Snd(62);\"D:%d \",scrncast.ona;Mute(OFF);Snd(62);\"E:%d \",scrncast.ona;SndRst;\"F:%d\\n\",scrncast.ona;\n"))
        assertTrue(k.console.plainText(), k.console.plainText().contains("A:60 B:-3 C:0 D:0 E:62 F:0"))
    }

    // ------------------------------------------------------------------ Play

    @Test fun everyPlayFixtureMatchesTheReference() {
        @Suppress("UNCHECKED_CAST") val cases = fx["cases"] as List<Map<String, Any?>>
        assertTrue(cases.size > 50)
        val bad = ArrayList<String>()
        for (c in cases) {
            val id = c["id"] as String
            val j0 = (c["j0"] as Number).toLong()
            @Suppress("UNCHECKED_CAST") val strings = c["play"] as List<String>
            val src = StringBuilder("SleepUntil($j0);MusicSettingsRst;music.tempo=${c["tempo"]};music.stacatto_factor=${c["stacatto_factor"]};")
            for (s in strings) src.append("Play(\"").append(hcString(s)).append("\");")
            src.append("\"E:%d O:%d L:%d M:%d/%d\\n\",cnts.jiffies-$j0,music.octave,ToI64(music.note_len*1000000),music.meter_top,music.meter_bottom;\n")
            val env = TestEnv()
            val k = runHolyC(latin1(src.toString()), env = env, maxSteps = 400000)
            @Suppress("UNCHECKED_CAST") val want = (c["events"] as List<List<Number>>).map { it[0].toLong() to onaHz.getValue(it[1].toInt()) }
            var got = changes(env, j0).map { (it.first - j0) to it.second }
            // the program's end turns a note left sounding (a final tie) off: TempleOS Mobile's window adaptation
            if (got.size == want.size + 1 && got.last().second == 0.0 && (want.lastOrNull()?.second ?: 0.0) != 0.0) got = got.dropLast(1)
            if (got.size != want.size || got.indices.any { got[it].first != want[it].first || Math.abs(got[it].second - want[it].second) > 1e-9 * want[it].second }) {
                val i = got.indices.firstOrNull { it >= want.size || got[it].first != want[it].first || Math.abs(got[it].second - want[it].second) > 1e-6 } ?: got.size
                bad.add("$id: ${got.size} changes, reference ${want.size}; first difference at $i: got ${got.getOrNull(i)}, reference ${want.getOrNull(i)}")
                continue
            }
            @Suppress("UNCHECKED_CAST") val st = c["state"] as Map<String, Any?>
            @Suppress("UNCHECKED_CAST") val meter = st["meter"] as List<Number>
            val len = ((st["note_len"] as Number).toDouble() * 1_000_000).toLong() // ToI64 truncates
            val line = "E:${c["end"]} O:${st["octave"]} L:$len M:${meter[0]}/${meter[1]}"
            if (!k.console.plainText().contains(line)) bad.add("$id: wanted '$line' in ${k.console.plainText().takeLast(200)}")
        }
        assertTrue(bad.joinToString("\n"), bad.isEmpty())
    }

    @Test fun soundExampleMatchesTheOriginalJiffyForJiffy() {
        @Suppress("UNCHECKED_CAST")
        val ref = ((Json.parse(File(SHARED, "test-vectors/audio/sound-example.json").readText()) as Map<String, Any?>)["events"] as List<Map<String, Number>>)
        val env = TestEnv()
        val k = runHolyC(File(SHARED, "bundled-fs/Home/Examples/Sound.HC").readBytes(), "C:/Home/Examples/Sound.HC", env)
        assertTrue(k.finished)
        val got = changes(env)
        // Sound.HC starts mid-jiffy; from its first Snd, every change is on the reference's jiffy (the scale's
        // Sleep(150) loop and Play's 180+20 jiffy eighth notes)
        val j0 = got.first().first
        assertEquals(ref.size, got.size)
        for ((i, r) in ref.withIndex()) {
            assertEquals("change $i jiffy", r["jiffy"]!!.toLong(), got[i].first - j0)
            assertEquals("change $i Hz", r["hz"]!!.toDouble(), got[i].second, 1e-3)
        }
    }

    // ------------------------------------------------------------------ Noise, Sweep, music.mute

    @Test fun sweepStepsThroughEveryOnaOnJiffiesAndGivesBackTheSpeaker() {
        val env = TestEnv()
        val k = runHolyC(latin1("SleepUntil(3000);Sweep(300,40,60);Sleep(400);\"M:%d\\n\",music.mute;\n"), env = env)
        assertTrue(k.console.plainText().contains("M:0"))
        val c = changes(env, 3000)
        // Adam/ASnd.HC SE_SWEEP: ona=(1.0-t)*ona1+t*ona2 with t=(tS-t0)/duration, retuned each jiffy (its Sleep(0))
        val t0 = TempleClock.jiffyStartNs(3000)
        val want = ArrayList<Pair<Long, Int>>()
        var last = 0
        var j = 3000L
        while (TempleClock.jiffyStartNs(j) - t0 < 300_000_000L) {
            val t = (TempleClock.jiffyStartNs(j) - t0) / 300e6
            val ona = ((1.0 - t) * 40 + t * 60).toLong().toInt()
            if (ona != last) { want.add(j to ona); last = ona }
            j++
        }
        want.add(j to 0) // the task ends: SoundEffectEndTaskCB -> SndTaskEndCB -> Snd
        assertEquals(want.map { it.first to onaHz.getValue(it.second) }, c)
        assertEquals(20, want.size - 1)
    }

    @Test fun noiseRetunesWithinItsRangeAndEndsOnTime() {
        val env = TestEnv()
        val k = runHolyC(latin1("SleepUntil(3000);Noise(200,40,50);Sleep(300);\"M:%d\\n\",music.mute;\n"), env = env)
        assertTrue(k.console.plainText().contains("M:0"))
        val c = changes(env, 3000)
        val allowed = (40..49).map { onaHz.getValue(it) }.toSet() // RandU16%(50-40)+40: ona 50 is never played
        assertTrue(c.dropLast(1).all { it.second in allowed })
        assertEquals(0.0, c.last().second, 0.0)
        // it ends when tS reaches 200 ms after its start: on the first jiffy at or after that
        assertEquals(3000L + 201, c.last().first)
        assertTrue("retuned many times: ${c.size}", c.size > 100)
    }

    @Test fun aSongIsSilentWhileANoisePlaysAndKeepsItsTime() {
        // Noise/Sweep raise music.mute: Play keeps counting but does not call Snd; the effect's end turns the
        // speaker off and the song is heard again from its next note (Adam/ASnd.HC)
        val env = TestEnv()
        runHolyC(latin1("U0 Song(I64){Play(\"qCDEFG\");}SleepUntil(4000);Spawn(&Song,NULL,\"S\");Sleep(100);Noise(500,70,80);Sleep(2500);\n"), env = env)
        val c = changes(env, 4000).map { (it.first - 4000) to it.second }
        val c4 = onaHz.getValue(51); val e = onaHz.getValue(55); val f = onaHz.getValue(56); val g = onaHz.getValue(58)
        assertEquals(0L to c4, c[0])
        val noise = c.filter { it.first in 100..600 && it.second != 0.0 }
        assertTrue(noise.all { it.second > onaHz.getValue(69) }) // only the noise sounds from 100 to ~600
        assertTrue("D (ona 53) never sounds", c.none { it.second == onaHz.getValue(53) })
        assertEquals(601L to 0.0, c.first { it.first > 100 && it.second == 0.0 })     // the noise task's SndTaskEndCB
        assertEquals(listOf(800L to e, 1160L to 0.0, 1200L to f, 1560L to 0.0, 1600L to g, 1960L to 0.0), c.filter { it.first >= 800 })
    }

    @Test fun overlappingEffectsEachFreeTheirOwnFrameAndGiveBackMusicMute() {
        // each SoundEffectTask keeps its CSoundEffectFrame in its own task's hash table (Kernel/KHashB.HC FramePtr);
        // with one table for all tasks, the first effect to end freed the second's frame, the second's end
        // callback faulted on a double Free before music.mute--, and every later Play was silent
        val env = TestEnv()
        val k = runHolyC(latin1("SleepUntil(3000);Noise(100,40,50);Noise(250,60,70);Sweep(150,80,90);Sleep(400);\"M:%d\\n\",music.mute;Play(\"qC\");\n"), env = env)
        val text = k.console.plainText()
        assertTrue(text, text.contains("M:0"))
        assertFalse(text, text.contains("BadFree") || text.contains("Bad"))
        val c = changes(env, 3000).map { (it.first - 3000) to it.second }
        // the second noise (onas 60..69) runs to its end at 250 ms (jiffy 251); the effects end with the speaker off
        assertTrue(c.any { it.first in 152..250 && it.second in (60..69).map { o -> onaHz.getValue(o) } })
        assertEquals(onaHz.getValue(51), c.first { it.first > 300 }.second, 0.0) // then the song's C sounds
    }

    @Test fun aTerminalCommandsNoiseGivesBackMusicMuteWhenItEnds() {
        val env = TestEnv()
        val k = Kernel(env, "Terminal", shellMode = true)
        k.virtualTime = true
        k.boot()
        fun run(line: String): String {
            val before = k.console.plainText().length
            k.execLine(line)
            val deadline = System.nanoTime() + 20_000_000_000L
            while (k.busy && System.nanoTime() < deadline) k.step(50_000_000)
            return k.console.plainText().substring(before)
        }
        val n0 = env.sounds.size
        run("Noise(2000,40,50);")        // returns at once; the Noise task plays on, as on TempleOS
        repeat(60) { k.step(50_000_000) } // 3 s
        run("music.mute;").let { assertTrue(it, it.contains("ans=0x00000000=0")) }
        val ns = env.soundNowNs.drop(n0).filterIndexed { i, _ -> env.sounds[n0 + i] > 0 }
        assertTrue("the noise played its 2 s: ${(ns.last() - ns.first()) / 1e6} ms", ns.last() - ns.first() > 1_900_000_000L)
        assertEquals("and ended with the speaker off", 0.0, env.sounds.last(), 0.0)
        val n = env.sounds.size
        run("Play(\"qC\");")
        assertTrue("the next song is heard: ${env.sounds.drop(n)}", env.sounds.drop(n).any { Math.abs(it - onaHz.getValue(51)) < 1e-6 })
    }
}

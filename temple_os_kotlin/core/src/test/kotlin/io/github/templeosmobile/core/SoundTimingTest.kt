package io.github.templeosmobile.core

import io.github.templeosmobile.core.holyc.latin1
import org.junit.Assert.*
import org.junit.Test

/**
 * Note timing of the original Play() (Adam/ASnd.HC, in GrLib.HC): at the default tempo of 2.5
 * quarter notes per second a quarter note lasts JIFFY_FREQ*1/2.5 = 400 ms, sounding for
 * stacatto_factor 0.9 of it (360 ms) and silent for the rest (40 ms), via two SleepUntil calls.
 * Regression (docs/fidelity-audit FA-03): the second SleepUntil returned at once, so songs lost
 * every gap and ran 10% fast.
 */
class SoundTimingTest {
    @Test fun playKeepsTempleOsNoteTiming() {
        val env = TestEnv()
        runHolyC(latin1("Play(\"4qCDE\");\n"), env = env)
        val log = env.soundLog.filter { it.second >= 0 }
        val t0 = log.first { it.second > 0 }.first
        // (time from the first note, sounding?) for each tone change
        val events = log.dropWhile { it.second == 0.0 }.map { (it.first - t0) to (it.second > 0) }
        val expected = listOf(0L to true, 360L to false, 400L to true, 760L to false, 800L to true, 1160L to false)
        assertEquals("tone changes: $events", expected.size, events.take(expected.size).size)
        for ((i, e) in expected.withIndex()) {
            val (t, on) = events[i]
            assertEquals("event $i sounding", e.second, on)
            assertTrue("event $i at $t ms, expected ${e.first} ms (all: $events)", Math.abs(t - e.first) <= 5)
        }
    }

    /** A completed GetKey must not leave the wake-up token for the next Sleep (it returned at once). */
    @Test fun sleepAfterAWaitedKeyStillSleeps() {
        // the key arrives while GetKey waits (a second task posts it), so GetKey resumes from a wait
        val k = runHolyC(latin1("U0 Poster(CTask *parent) {Sleep(50);PostMsg(parent,MSG_KEY_DOWN,'a',0x1E);}\n" +
            "FlushMsgs;Spawn(&Poster,Fs);GetKey;F64 t=tS;Sleep(200);\"%d\\n\",ToI64((tS-t)*1000);\n"))
        val ms = k.console.plainText().trim().lines().last().trim().toLong()
        assertTrue("Sleep(200) after GetKey slept $ms ms", ms in 195..260)
    }
}

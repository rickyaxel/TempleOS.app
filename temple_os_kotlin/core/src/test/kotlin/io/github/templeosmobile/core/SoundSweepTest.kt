package io.github.templeosmobile.core

import io.github.templeosmobile.core.kernel.*
import io.github.templeosmobile.core.ui.Json
import org.junit.Assert.*
import org.junit.Test
import java.io.File

/**
 * Sound validation of every catalog program that calls TempleOS sound (docs/audio/data/sound-inventory.json,
 * tools/audio/sound_inventory.py). Each program runs from the bundled drive in virtual time with fixed
 * entropy, driven by its fidelity scenarios (shared/fidelity/scenarios.json), a generic play script, and a
 * targeted script where its sound needs a particular action (shared/test-vectors/audio/sound-sweep.json).
 * Every speaker change is recorded and rendered through PcSpeaker; a program passes when it sounds
 * (audible samples), every setting is a valid PIT tone or off, and the speaker is off once it ended.
 * The Swift port (SoundSweepTests) runs the same scripts; tools/audio/compare_sweeps.py compares the two.
 *
 *   default                        a regression subset (fast)
 *   -Dtempleos.soundsweep=all      every program (results: docs/audio/data/sound-sweep-kotlin.json)
 *   -Dtempleos.soundsweep=<id>,..  chosen catalog ids
 */
class SoundSweepTest {
    companion object {
        val REGRESSION = listOf("example.sound", "game.tictactoe", "game.digits", "game.flapbat", "game.bombergolf")
        const val RATE = 48000
    }

    private class SweepEnv(override val fs: VirtualFs, private val memMb: Int) : KernelEnv {
        /** (kernel ms, Hz) of every speaker change, across all runs of one program (runs are offset). */
        val log = ArrayList<Pair<Double, Double>>()
        var offsetMs = 0.0
        /** Runs whose speaker was still on after the program window closed. */
        var endedSounding = 0
        override fun runtimeFile(name: String): ByteArray? = File(SHARED, "runtime/$name").takeIf { it.exists() }?.readBytes()
        override fun entropy(): Long = 12345
        override val memoryLimit: Int get() = memMb shl 20
        override fun sound(kernel: Kernel, freq: Double, atNs: Long) { log.add(offsetMs + kernel.now() / 1e6 to freq) }
        override fun popupRequested(kernel: Kernel, req: PopupRequest) { req.result = req.items.firstOrNull { it.value != -1L }?.value ?: -1 }
    }

    class ProgramResult(val id: String, val title: String, val status: String, val runs: Int, val changes: Int, val sounding: Int,
                        val distinctHz: Int, val audibleMs: Double, val maxPerSecond: Int, val invalid: Int, val endedSounding: Int,
                        val errors: List<String>, val pass: Boolean, val note: String, val hzSample: List<Double>)

    /** One run: boot, run [steps] (scenario step format), then end the program; returns its exit/end message. */
    private fun run(env: SweepEnv, prog: String, steps: List<List<Any?>>, endWith: Long = 500): String? {
        val k = Kernel(env, prog.substringAfterLast('/'))
        k.virtualTime = true
        val before = env.log.size
        k.boot()
        while (env.log.size > before) env.log.removeAt(env.log.size - 1) // the boot's SndRst is not the program's
        val first = env.log.size
        k.runProgram(prog, env.fs.readFile(prog) ?: return "no file")
        val wallEnd = System.nanoTime() + 90_000_000_000L
        fun advance(ms: Long) {
            val stop = k.now() + ms * 1_000_000
            k.virtualStopAt = stop
            while (k.now() < stop && !k.finished && System.nanoTime() < wallEnd) if (k.step(50_000_000) < 0) break
        }
        fun mouse(x: Int, y: Int, l: Boolean, r: Boolean) = k.post(KInput.Mouse(x, y, l, r))
        advance(1)
        for (s in steps) {
            if (k.finished) break
            when (s[0]) {
                "wait_ms" -> advance((s[1] as Number).toLong())
                "key" -> { val (ch, c) = ScenarioTest.keyOf(s[1] as String); k.post(KInput.Key(ch, c, true)); k.post(KInput.Key(ch, c or Keys.SCF_KEY_UP, false)); advance(40) }
                "key_down" -> { val (ch, c) = ScenarioTest.keyOf(s[1] as String); k.post(KInput.Key(ch, c, true)); advance(1) }
                "key_up" -> { val (ch, c) = ScenarioTest.keyOf(s[1] as String); k.post(KInput.Key(ch, c or Keys.SCF_KEY_UP, false)); advance(1) }
                "hold" -> { val (ch, c) = ScenarioTest.keyOf(s[1] as String); k.post(KInput.Key(ch, c, true)); advance((s[2] as Number).toLong()); k.post(KInput.Key(ch, c or Keys.SCF_KEY_UP, false)); advance(20) }
                "click", "rclick" -> {
                    val x = (s[1] as Number).toInt(); val y = (s[2] as Number).toInt(); val r = s[0] == "rclick"
                    mouse(x, y, !r, r); advance(70); mouse(x, y, false, false); advance(70)
                }
                "press" -> {
                    val x = (s[1] as Number).toInt(); val y = (s[2] as Number).toInt()
                    mouse(x, y, true, false); advance((s[3] as Number).toLong()); mouse(x, y, false, false); advance(50)
                }
                "move" -> { mouse((s[1] as Number).toInt(), (s[2] as Number).toInt(), false, false); advance(30) }
                "drag" -> {
                    val x0 = (s[1] as Number).toInt(); val y0 = (s[2] as Number).toInt(); val x1 = (s[3] as Number).toInt(); val y1 = (s[4] as Number).toInt()
                    mouse(x0, y0, true, false); advance(50)
                    for (j in 1..5) { mouse(x0 + (x1 - x0) * j / 5, y0 + (y1 - y0) * j / 5, true, false); advance(40) }
                    mouse(x1, y1, false, false); advance(50)
                }
                "popup" -> advance(1)
                "menu" -> {
                    val path = s[1] as String
                    var m: MenuSnap? = null
                    for (j in 0 until 40) { m = k.menuSnapshot.firstOrNull { it.path == path }; if (m != null) break; advance(50) }
                    if (m != null) { k.post(KInput.Raw(m.msgCode.toInt(), m.a1, m.a2)); advance(40) }
                }
            }
        }
        advance(endWith)
        val msg = if (k.finished) k.exitMessage else null
        val end = k.now() / 1e6
        k.terminate("done") // the window closes: Kernel.silence
        if (env.log.size > first && env.log.last().second != 0.0) env.endedSounding++
        env.offsetMs += end + 1000
        return msg
    }

    /** Space/Enter, held arrows, clicks and right-clicks on a grid, digits: no ESC, no 'q' (they end games). */
    private fun genericPlay(seconds: Int): List<List<Any?>> {
        val s = ArrayList<List<Any?>>()
        s.add(listOf("wait_ms", 1500))
        val arrows = listOf("SC_CURSOR_LEFT", "SC_CURSOR_UP", "SC_CURSOR_RIGHT", "SC_CURSOR_DOWN")
        for (r in 0 until seconds * 2) {
            when (r % 6) {
                0 -> s.add(listOf("key", "SC_SPACE"))
                1 -> s.add(listOf("hold", arrows[(r / 6) % 4], 250))
                2 -> s.add(listOf("click", 40 + (r * 137) % 560, 40 + (r * 89) % 400))
                3 -> s.add(listOf("key", "SC_ENTER"))
                4 -> s.add(listOf("rclick", 40 + (r * 211) % 560, 40 + (r * 53) % 400))
                5 -> s.add(listOf("key", "${1 + (r / 6) % 3}"))
            }
            s.add(listOf("wait_ms", 260))
        }
        return s
    }

    private fun sweep(ids: Set<String>?): List<ProgramResult> {
        @Suppress("UNCHECKED_CAST")
        val inv = (Json.parse(File(REPO_DOCS, "audio/data/sound-inventory.json").readText()) as Map<String, Any?>)["rows"] as List<Map<String, Any?>>
        @Suppress("UNCHECKED_CAST")
        val scen = (Json.parse(File(SHARED, "fidelity/scenarios.json").readText()) as Map<String, Any?>)["scenarios"] as List<Map<String, Any?>>
        @Suppress("UNCHECKED_CAST")
        val targeted = (Json.parse(File(SHARED, "test-vectors/audio/sound-sweep.json").readText()) as Map<String, Any?>)["programs"] as Map<String, Map<String, Any?>>
        @Suppress("UNCHECKED_CAST")
        val catalog = (Json.parse(File(SHARED, "program-manifests/catalog.json").readText()) as Map<String, Any?>)["programs"] as List<Map<String, Any?>>
        val root = File(SHARED, "bundled-fs")
        val out = ArrayList<ProgramResult>()
        for (row in inv) {
            val id = row["id"] as String
            if (ids != null && id !in ids) continue
            val entry = catalog.first { it["id"] == id }
            val prog = entry["path"] as String
            val status = entry["status"] as String
            val t = targeted[id]
            if (status == "unsupported") {
                out.add(ProgramResult(id, row["title"] as String, status, 0, 0, 0, 0, 0.0, 0, 0, 0, emptyList(), true,
                    "not runnable on TempleOS Mobile (${entry["note"]}): no sound to validate", emptyList()))
                println("SOUNDSWEEP $id unsupported: skipped"); continue
            }
            val env = SweepEnv(LayeredFs(DirBundle(root, File(SHARED, "bundled-fs.index")), java.nio.file.Files.createTempDirectory("sweep").toFile()),
                if (id == "game.talons") 96 else 32)
            val errors = ArrayList<String>()
            var runs = 0
            @Suppress("UNCHECKED_CAST")
            val scripts = ArrayList<List<List<Any?>>>()
            t?.get("steps")?.let { @Suppress("UNCHECKED_CAST") scripts.add(it as List<List<Any?>>) }
            if (t?.get("only_targeted") != true) {
                @Suppress("UNCHECKED_CAST")
                scen.filter { it["program"] == prog && it["slow"] != true }.forEach { scripts.add(it["steps"] as List<List<Any?>>) }
                scripts.add(genericPlay((t?.get("generic_s") as? Number)?.toInt() ?: 20))
            }
            for (st in scripts) {
                val msg = try { run(env, prog, st) } catch (e: Throwable) { "crash: $e" }
                runs++
                if (msg != null && msg != "done" && !msg.startsWith("Stopped") && msg.contains(Regex("crash|fault|Except|error", RegexOption.IGNORE_CASE))) errors.add(msg.take(120))
            }
            val log = env.log
            System.getProperty("templeos.soundsweep.dump")?.let { d -> File(d).mkdirs(); File(d, "$id.txt").writeText(log.joinToString("\n") { "%.3f %.4f".format(java.util.Locale.ROOT, it.first, it.second) }) }
            val sounding = log.count { it.second > 0 }
            val invalid = log.count { !(it.second == 0.0 || (it.second.isFinite() && it.second >= 18.2 && it.second <= 1193182.0)) }
            val endedSounding = env.endedSounding
            // events per second (worst second)
            val perSecond = log.groupingBy { (it.first / 1000).toLong() }.eachCount().values.maxOrNull() ?: 0
            // render: audible time
            var audibleMs = 0.0
            if (sounding > 0) {
                val sp = PcSpeaker(RATE, 20_000_000L, capacity = 4096)
                val base = 10_000_000_000L
                val buf = FloatArray(4800)
                var tNs = base
                var idx = 0
                val endMs = log.last().first + 200
                var frame = 0L
                while ((tNs - base) / 1e6 < endMs) {
                    // post what is due within the next block (keeps the queue small)
                    while (idx < log.size && log[idx].first * 1e6 <= (tNs - base) + 100_000_000L) { sp.post(base + (log[idx].first * 1e6).toLong(), log[idx].second); idx++ }
                    sp.render(buf, 0, buf.size, tNs)
                    audibleMs += buf.count { Math.abs(it) >= PcSpeaker.AMPLITUDE / 2 } * 1000.0 / RATE
                    frame += buf.size; tNs = base + frame * 1_000_000_000L / RATE
                }
            }
            val expectSilent = t?.get("expect_silent") == true
            val pass = errors.isEmpty() && invalid == 0 && endedSounding == 0 && (if (expectSilent) sounding == 0 else audibleMs > 20)
            val note = (t?.get("note") as? String) ?: ""
            val hz = log.map { it.second }.filter { it > 0 }.distinct()
            val r = ProgramResult(id, row["title"] as String, status, runs, log.size, sounding, hz.size, Math.round(audibleMs * 10) / 10.0, perSecond, invalid,
                endedSounding, errors, pass, note, hz.take(8).map { Math.round(it * 100) / 100.0 })
            println("SOUNDSWEEP ${r.id} ${if (r.pass) "PASS" else "FAIL"} runs=${r.runs} changes=${r.changes} tones=${r.sounding} distinct=${r.distinctHz} audible_ms=${r.audibleMs} max_per_s=${r.maxPerSecond} invalid=${r.invalid} ended_sounding=${r.endedSounding} ${r.errors}")
            out.add(r)
        }
        return out
    }

    private val REPO_DOCS = File(SHARED, "../docs")

    @Test fun soundSweep() {
        val sel = System.getProperty("templeos.soundsweep")
        val ids = when (sel) { null -> REGRESSION.toSet(); "all" -> null; else -> sel.split(",").toSet() }
        val res = sweep(ids)
        if (sel == "all") {
            val f = File(REPO_DOCS, "audio/data/sound-sweep-kotlin.json")
            f.writeText(res.joinToString(",\n", "{\"platform\": \"kotlin\", \"results\": [\n", "\n]}\n") { r ->
                "{\"id\":\"${r.id}\",\"title\":\"${r.title}\",\"status\":\"${r.status}\",\"pass\":${r.pass},\"runs\":${r.runs},\"changes\":${r.changes},\"tones\":${r.sounding}," +
                    "\"distinct_hz\":${r.distinctHz},\"audible_ms\":${r.audibleMs},\"max_changes_per_s\":${r.maxPerSecond},\"invalid\":${r.invalid},\"ended_sounding\":${r.endedSounding}," +
                    "\"hz_sample\":${r.hzSample},\"errors\":[${r.errors.joinToString(",") { "\"" + it.replace("\"", "'") + "\"" }}],\"note\":\"${r.note.replace("\"", "'")}\"}"
            })
            println("wrote $f")
        }
        val bad = res.filter { !it.pass }
        assertTrue("programs without valid sound:\n" + bad.joinToString("\n") { "${it.id}: tones=${it.sounding} audible_ms=${it.audibleMs} invalid=${it.invalid} ended_sounding=${it.endedSounding} ${it.errors}" }, bad.isEmpty())
    }
}

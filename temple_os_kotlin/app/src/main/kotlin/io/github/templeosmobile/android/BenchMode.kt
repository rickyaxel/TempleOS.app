package io.github.templeosmobile.android

import android.annotation.SuppressLint
import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.Debug
import android.os.PowerManager
import android.os.Process
import android.os.SystemClock
import android.os.Trace
import android.util.Log
import android.widget.TextView
import io.github.templeosmobile.core.bench.*
import io.github.templeosmobile.core.kernel.LayeredFs
import java.io.File

/**
 * Headless benchmark mode (docs/native-validation), only in the `bench` build type
 * (`com.digitalcircuitstudios.templeosapp.bench`, installed beside the user's app, never over it):
 *
 *   adb shell am start -n com.digitalcircuitstudios.templeosapp.bench/io.github.templeosmobile.android.MainActivity \
 *       --es bench "programs=C:/Apps/X-Caliber/Run.HC;engines=terry,native;secs=4;memmb=128;runs=7;warmup=1;mode=light;tag=xc"
 *
 * Runs the core [ScenarioRunner] (the same deterministic virtual-time scenarios as the host differential
 * tests, so `mode=parity` checkpoint hashes compare with the host's) and reports one JSON line per run to
 * logcat (tag TOSBENCH) and to <external files>/bench/<tag>.jsonl; `mode=parity` also writes every
 * checkpoint to <tag>.<program>.<engine>.json. The process exits when done, so each launch starts cold.
 * Perfetto sees `tos:boot` / `tos:run` trace sections (the build is profileable).
 */
object BenchMode {
    private const val TAG = "TOSBENCH"

    @SuppressLint("SetTextI18n") // bench-only diagnostic text, never shown by store builds
    fun start(activity: Activity, spec: String) {
        val view = TextView(activity).apply { text = "TempleOS bench: $spec"; setTextColor(0xFFFFFFFF.toInt()); setBackgroundColor(0xFF000000.toInt()); textSize = 12f }
        activity.setContentView(view)
        // the run can take many minutes: keep this window's screen on (no global setting is changed)
        activity.window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        Thread({
            try { run(activity, spec) { s -> activity.runOnUiThread { view.text = s } } }
            catch (e: Throwable) { emit(activity, spec.tag(), "{\"event\":\"error\",\"detail\":${q(e.toString())}}") }
            Log.i(TAG, "DONE ${spec.tag()}")
            activity.runOnUiThread { activity.finishAndRemoveTask() }
            Thread.sleep(300)
            Process.killProcess(Process.myPid())
        }, "TempleOS-Bench").apply { priority = Thread.NORM_PRIORITY; start() }
    }

    private fun String.tag() = split(';').firstOrNull { it.startsWith("tag=") }?.substringAfter('=') ?: "bench"

    private fun q(s: String) = "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n") + "\""

    private fun outDir(c: Context) = File(c.getExternalFilesDir(null) ?: c.filesDir, "bench").also { it.mkdirs() }

    private fun emit(c: Context, tag: String, line: String) {
        // logcat lines are limited to about 4 kB: long lines go to the file only
        if (line.length < 3800) Log.i(TAG, line) else Log.i(TAG, line.take(3700) + "…(truncated; see file)")
        File(outDir(c), "$tag.jsonl").appendText(line + "\n")
    }

    /** Resident set size now and its peak (VmHWM) for this process, kB. */
    private fun rssKb(): Pair<Long, Long> {
        var rss = -1L; var hwm = -1L
        try {
            File("/proc/self/status").forEachLine { l ->
                if (l.startsWith("VmRSS:")) rss = l.substringAfter(':').trim().substringBefore(' ').toLong()
                if (l.startsWith("VmHWM:")) hwm = l.substringAfter(':').trim().substringBefore(' ').toLong()
            }
        } catch (_: Exception) {}
        return rss to hwm
    }

    private fun heapUsed() = Runtime.getRuntime().let { it.totalMemory() - it.freeMemory() }

    private fun gcStat(name: String) = Debug.getRuntimeStat(name)?.toLongOrNull() ?: -1L

    private fun conditions(c: Context): String {
        val b = c.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val pm = c.getSystemService(PowerManager::class.java)
        val temp = b?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, -1) ?: -1
        val level = b?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val plugged = b?.getIntExtra(BatteryManager.EXTRA_PLUGGED, -1) ?: -1
        val thermal = if (Build.VERSION.SDK_INT >= 29) pm?.currentThermalStatus ?: -1 else -1
        return "\"battery_temp_c\":${temp / 10.0},\"battery_level\":$level,\"plugged\":$plugged,\"power_save\":${pm?.isPowerSaveMode},\"thermal_status\":$thermal"
    }

    private fun run(c: Context, spec: String, status: (String) -> Unit) {
        val kv = spec.split(';').filter { '=' in it }.associate { it.substringBefore('=').trim() to it.substringAfter('=').trim() }
        val tag = kv["tag"] ?: "bench"
        val programs = (kv["programs"] ?: "C:/Demo/Games/BomberGolf.HC").split(',')
        val engines = (kv["engines"] ?: "terry,native").split(',').map { if (it == "terry") ScenarioEngine.TERRY else ScenarioEngine.NATIVE }
        val secs = kv["secs"]?.toLong() ?: 4L
        val memMb = kv["memmb"]?.toInt() ?: 32
        val runs = kv["runs"]?.toInt() ?: 1
        val warmup = kv["warmup"]?.toInt() ?: 0
        val parity = kv["mode"] == "parity"
        val am = c.getSystemService(ActivityManager::class.java)
        val mi = ActivityManager.MemoryInfo().also { am.getMemoryInfo(it) }
        val pi = c.packageManager.getPackageInfo(c.packageName, 0)
        emit(c, tag, "{\"event\":\"device\",\"tag\":${q(tag)},\"spec\":${q(spec)},\"model\":${q(Build.MODEL)},\"manufacturer\":${q(Build.MANUFACTURER)},\"android\":${q(Build.VERSION.RELEASE)},\"sdk\":${Build.VERSION.SDK_INT}," +
            "\"soc\":${q(if (Build.VERSION.SDK_INT >= 31) Build.SOC_MODEL else Build.HARDWARE)},\"cores\":${Runtime.getRuntime().availableProcessors()},\"ram_mb\":${mi.totalMem shr 20}," +
            "\"memory_class_mb\":${am.memoryClass},\"large_memory_class_mb\":${am.largeMemoryClass},\"max_heap_mb\":${Runtime.getRuntime().maxMemory() shr 20}," +
            "\"package\":${q(c.packageName)},\"version\":${q(pi.versionName ?: "")},\"build_type\":${q(BuildConfig.BUILD_TYPE)},\"git\":${q(BuildConfig.GIT_REV)},\"debuggable\":${(c.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0}," +
            "\"elapsed_since_boot_s\":${SystemClock.elapsedRealtime() / 1000},${conditions(c)}}")

        io.github.templeosmobile.core.purenative.NativePrograms.catalog = io.github.templeosmobile.purekotlin.gen.NativeCatalog
        val runtimeCache = HashMap<String, ByteArray?>()
        val runtime: (String) -> ByteArray? = { name -> synchronized(runtimeCache) { runtimeCache.getOrPut(name) { try { c.assets.open("runtime/$name").use { it.readBytes() } } catch (_: Exception) { null } } } }
        var drives = 0
        val fsFactory = {
            val dir = File(c.cacheDir, "bench-drive-${Process.myPid()}-${drives++}")
            dir.deleteRecursively(); dir.mkdirs()
            LayeredFs(AssetBundle(c.assets), dir)
        }
        val runner = ScenarioRunner(fsFactory, runtime)

        var sample = 0
        for (path in programs) {
            val name = path.substringAfterLast('/').substringBefore('.')
            val schedule = ArrayList<Pair<ScenarioEngine, Boolean>>()
            repeat(warmup) { for (e in engines) schedule.add(e to true) }
            repeat(runs) { i -> for (e in if (i % 2 == 0) engines else engines.reversed()) schedule.add(e to false) }
            for ((engine, isWarmup) in schedule) {
                status("$name ${engine.name.lowercase()} ${if (isWarmup) "warm-up" else "run ${sample + 1}"}")
                System.gc(); Thread.sleep(200)
                val (rss0, _) = rssKb()
                val heap0 = heapUsed()
                val gcCount0 = gcStat("art.gc.gc-count"); val gcTime0 = gcStat("art.gc.gc-time"); val alloc0 = gcStat("art.gc.bytes-allocated")
                val peakRss = java.util.concurrent.atomic.AtomicLong(rss0); val peakHeap = java.util.concurrent.atomic.AtomicLong(heap0)
                val sampling = java.util.concurrent.atomic.AtomicBoolean(true)
                val sampler = Thread({
                    while (sampling.get()) { peakRss.accumulateAndGet(rssKb().first, ::maxOf); peakHeap.accumulateAndGet(heapUsed(), ::maxOf); Thread.sleep(50) }
                }, "bench-mem").also { it.isDaemon = true; it.start() }
                val cpu0 = Process.getElapsedCpuTime()
                val t0 = SystemClock.elapsedRealtimeNanos()
                val heartbeats = ArrayList<String>()
                val r = try {
                    Trace.beginSection("tos:run $name ${engine.name.lowercase()}")
                    runner.run(path, engine, ScenarioScript.named(kv["script"] ?: "sweep", secs * 1000), ScenarioRunner.Options(light = !parity, memMb = memMb,
                        heartbeatMs = 10_000, stallMs = 600_000,
                        onProgress = { p -> heartbeats.add("[${p.virtualMs},${p.wallMs},${p.ticks}]"); status("$name ${engine.name.lowercase()}: ${p.virtualMs} ms of ${secs * 1000}, ${p.wallMs / 1000} s") }))
                } catch (e: Throwable) {
                    sampling.set(false)
                    emit(c, tag, "{\"event\":\"run_failed\",\"program\":${q(path)},\"engine\":${q(engine.name.lowercase())},\"memmb\":$memMb,\"detail\":${q(e.toString())},\"rss_kb\":${rssKb().first}}")
                    continue
                } finally { Trace.endSection() }
                val t1 = SystemClock.elapsedRealtimeNanos()
                val cpu1 = Process.getElapsedCpuTime()
                sampling.set(false); sampler.join(200)
                val (rss1, hwm) = rssKb()
                val k = r.kernel
                val last = r.checkpoints.lastOrNull()
                val purity = if (engine == ScenarioEngine.NATIVE) k.vm.instructionsExecuted else -1
                val st = r.stats
                val line = "{\"event\":\"run\",\"program\":${q(path)},\"engine\":${q(engine.name.lowercase())},\"warmup\":$isWarmup,\"sample\":${if (isWarmup) -1 else sample}," +
                    "\"virtual_ms\":${r.completedMs},\"requested_ms\":${if (kv["script"] == "cartesian") 11_000L else secs * 1000},\"script\":${q(kv["script"] ?: "sweep")},\"completed\":${r.failure == null && r.completedMs == (if (kv["script"] == "cartesian") 11_000L else secs * 1000)},\"exit_category\":${q(k.exitCategory ?: "")},\"dyn_expr_evaluations\":${k.dynExprEvaluations},\"failure\":${r.failure?.let { q(it.kind + ": " + it.detail) } ?: "null"}," +
                    "\"memmb\":$memMb,\"boot_ms\":${st.bootWallNs / 1e6},\"wall_ms\":${(t1 - t0) / 1e6},\"run_wall_ms\":${st.runWallNs / 1e6},\"task_wall_ms\":${st.taskWallNs / 1e6},\"frame_wall_ms\":${st.frameWallNs / 1e6}," +
                    "\"cpu_ms\":${cpu1 - cpu0},\"ticks\":${st.ticks},\"frames\":${st.frames},\"final_hash\":${last?.let { "{\"frame\":${it.frameHash},\"globals\":${it.globalsHash},\"sounds\":${it.sounds},\"sound\":${it.soundHash},\"ticks\":${it.ticks}}" } ?: "null"}," +
                    "\"bytecode_instructions\":$purity,\"arena_bytes\":${st.arenaBytes},\"arena_high_water\":${st.arenaHighWater},\"arena_peak_allocated\":${st.arenaPeakAllocated},\"arena_limit\":${st.arenaLimit}," +
                    "\"rss_before_kb\":$rss0,\"rss_after_kb\":$rss1,\"rss_peak_sampled_kb\":${peakRss.get()},\"vm_hwm_kb\":$hwm,\"heap_before\":$heap0,\"heap_peak_sampled\":${peakHeap.get()}," +
                    "\"gc_count\":${gcStat("art.gc.gc-count") - gcCount0},\"gc_time_ms\":${gcStat("art.gc.gc-time") - gcTime0},\"bytes_allocated\":${gcStat("art.gc.bytes-allocated") - alloc0}," +
                    "\"heartbeats\":[${heartbeats.joinToString(",")}],${conditions(c)}}"
                k.terminate("done")
                emit(c, tag, line)
                if (parity) File(outDir(c), "$tag.$name.${engine.name.lowercase()}.json").writeText(ScenarioRunner.checkpointsJson(r.checkpoints))
                if (!isWarmup && engine == engines.last()) sample++
                c.cacheDir.listFiles()?.filter { it.name.startsWith("bench-drive-") }?.forEach { it.deleteRecursively() }
            }
        }
    }
}

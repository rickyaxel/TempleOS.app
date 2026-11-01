package io.github.templeosmobile.android

import android.app.ActivityManager
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.res.AssetManager
import android.graphics.Paint
import android.graphics.Typeface
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTimestamp
import android.media.AudioTrack
import android.os.Build
import android.os.Process
import android.net.Uri
import android.widget.Toast
import android.util.Log
import io.github.templeosmobile.core.Brand
import io.github.templeosmobile.core.kernel.BundleSource
import io.github.templeosmobile.core.kernel.LayeredFs
import io.github.templeosmobile.core.kernel.PcSpeaker
import io.github.templeosmobile.core.ui.ShellEnv
import io.github.templeosmobile.core.ui.StateStore
import java.io.File
import java.io.IOException
import java.util.concurrent.locks.LockSupport
import kotlin.math.roundToInt

/** The bundled C: drive, read from APK assets ("fs/..."). */
class AssetBundle(private val assets: AssetManager) : BundleSource {
    override fun index(): String = assets.open("bundled-fs.index").use { String(it.readBytes(), Charsets.UTF_8) }
    override fun open(rel: String): ByteArray? = try { assets.open("fs/$rel").use { it.readBytes() } } catch (e: IOException) { null }
}

/** Session state in the app's private files directory, written atomically. */
class FileStateStore(private val file: File) : StateStore {
    override fun load(): String? = if (file.exists()) file.readText() else null
    override fun save(text: String) {
        val tmp = File(file.parentFile, file.name + ".tmp")
        tmp.writeText(text)
        if (!tmp.renameTo(file)) { file.delete(); tmp.renameTo(file) }
    }
}

/**
 * The device side of TempleOS's PC speaker on Android: one streaming float AudioTrack at the output's
 * native rate, fed by [PcSpeaker] (core), which turns the kernel's time-stamped speaker settings into
 * samples (docs/audio/TEMPLEOS_SOUND.md). The track only runs while a program sounds: after half a second
 * of silence it pauses and its thread waits for the next tone (no polling). [tone] runs on kernel threads
 * for every speaker change (Noise and Sweep make about a thousand a second): it queues the setting and
 * wakes the thread only when it sleeps.
 *
 * No audio focus is requested: the beeps mix with other apps' audio, as short game sounds do, at the
 * media volume (USAGE_GAME). Debug builds can record what was rendered ([capture], `--ez soundcapture true`).
 */
class ToneGenerator(context: Context, private val capture: File? = null) {
    private val am = context.getSystemService(AudioManager::class.java)
    private val rate = am?.getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE)?.toIntOrNull()?.takeIf { it in 8000..192000 } ?: 48000
    /** The output's own buffer size: one write per burst keeps the latency low without extra wake-ups. */
    private val burst = am?.getProperty(AudioManager.PROPERTY_OUTPUT_FRAMES_PER_BUFFER)?.toIntOrNull()?.takeIf { it in 32..4096 } ?: 256
    val speaker = PcSpeaker(rate, 40_000_000L)
    @Volatile private var running = true
    /** True while the thread waits for a tone; only then does [tone] take the lock to wake it. */
    @Volatile private var idle = false
    private val lock = Object()
    private val thread = Thread({ loop() }, "TempleOS-Snd").apply { isDaemon = true; start() }

    fun tone(f: Double, atNs: Long) {
        speaker.post(atNs, f)
        // post() sets pendingSound before idle is read, and the thread sets idle before it checks
        // pendingSound (all volatile): a tone that starts now is never missed
        if (idle && f > 0.0) synchronized(lock) { lock.notifyAll() }
    }

    fun release() {
        running = false
        synchronized(lock) { lock.notifyAll() }
        thread.join(250)
    }

    private fun newTrack(): AudioTrack? = try {
        val min = AudioTrack.getMinBufferSize(rate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_FLOAT)
        AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_GAME).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
            .setAudioFormat(AudioFormat.Builder().setSampleRate(rate).setEncoding(AudioFormat.ENCODING_PCM_FLOAT).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
            .setBufferSizeInBytes(maxOf(min, 4 * burst * 4))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .apply { if (Build.VERSION.SDK_INT >= 26) setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY) }
            .build().takeIf { it.state == AudioTrack.STATE_INITIALIZED }
    } catch (e: Exception) { Log.w(TAG, "no audio output: $e"); null }

    private fun loop() {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
        val buf = FloatArray(burst)
        val rec = capture?.let { WavCapture(it, rate) }
        var track: AudioTrack? = null
        var playing = false
        val ts = AudioTimestamp()
        var written = 0L // frames written to the current track (its playback head counts the same frames)
        var ahead = 0L
        var underruns = 0
        try {
            while (running) {
                if (track == null) {
                    track = newTrack()
                    if (track == null) { waitForTone(); continue }
                    // low latency: start at four bursts (getMinBufferSize asks for ~80 ms on some phones) and grow by
                    // a burst after each underrun, as Android's latency tuning does
                    track.setBufferSizeInFrames(minOf(track.bufferCapacityInFrames, 4 * burst))
                    ahead = track.bufferSizeInFrames.toLong()
                    underruns = track.underrunCount
                    // the buffer is rendered ahead of time; 10 ms more covers the kernel's wake-up jitter
                    speaker.latencyNs = (ahead + burst) * 1_000_000_000L / rate + JITTER_NS
                    written = 0
                    Log.i(TAG, "output rate=$rate burst=$burst buffer=${track.bufferSizeInFrames} latency_ms=${speaker.latencyNs / 1_000_000}")
                }
                // never more than one buffer ahead of the playback head: some outputs (the emulator) take far more
                // before write() blocks, and a setting due sooner than the queued audio would come too late
                var queued = 0L
                if (playing) {
                    queued = written - (track.playbackHeadPosition.toLong() and 0xFFFFFFFFL)
                    if (queued > ahead) { LockSupport.parkNanos((queued - ahead) * 1_000_000_000L / rate); continue }
                }
                // when these samples will play, from the track's presentation timestamp (frames actually heard and
                // when): the speaker follows the device's clock. Until the output reports one, no clock is used.
                var playNs = System.nanoTime()
                var clock = false
                if (playing && track.getTimestamp(ts) && ts.framePosition > 0) {
                    playNs = ts.nanoTime + (written - ts.framePosition) * 1_000_000_000L / rate
                    clock = true
                    rec?.clock(ts.nanoTime, ts.framePosition)
                }
                speaker.render(buf, 0, burst, playNs, clock)
                rec?.add(buf, burst)
                val w = track.write(buf, 0, burst, AudioTrack.WRITE_BLOCKING)
                if (w > 0) written += w
                // start after the first write, so the track does not begin with an underrun
                if (!playing && w >= 0) { track.play(); playing = true; underruns = track.underrunCount }
                if (track.underrunCount > underruns) {
                    underruns = track.underrunCount
                    if (ahead + burst <= track.bufferCapacityInFrames) {
                        track.setBufferSizeInFrames((ahead + burst).toInt())
                        ahead = track.bufferSizeInFrames.toLong()
                        speaker.latencyNs = (ahead + burst) * 1_000_000_000L / rate + JITTER_NS
                        Log.i(TAG, "underrun: buffer=$ahead latency_ms=${speaker.latencyNs / 1_000_000}")
                    }
                }
                if (w < 0) {
                    // the output went away (audio server restart, device change): a new track, a new timeline
                    track.release(); track = null; playing = false; speaker.restart()
                    continue
                }
                if (speaker.silentFrames >= rate / 2 && !speaker.pendingSound) {
                    track.pause(); track.flush(); playing = false; speaker.restart()
                    track.stop(); written = 0 // stop() resets the playback head; play() starts it again
                    rec?.save()
                    waitForTone()
                }
            }
        } catch (e: InterruptedException) {
        } catch (e: RuntimeException) {
            Log.w(TAG, "sound stopped: $e")
        } finally {
            track?.let { try { it.stop() } catch (_: IllegalStateException) {}; it.release() }
            rec?.save()
        }
    }

    private fun waitForTone() = synchronized(lock) {
        idle = true
        while (running && !speaker.pendingSound) lock.wait()
        idle = false
    }

    companion object {
        private const val TAG = "TempleOS-Snd"
        private const val JITTER_NS = 10_000_000L
    }
}

/**
 * Debug builds: the samples the speaker rendered while it ran, as 16-bit mono WAVs: [file] holds the last
 * burst (from the output's start to its idle stop), `<name>-all.wav` every burst of the process (2 min max).
 */
private class WavCapture(private val file: File, private val rate: Int) {
    private var data = ShortArray(rate * 10)
    private var n = 0
    private var burstStart = 0

    fun add(b: FloatArray, count: Int) {
        if (n + count > data.size) {
            if (data.size >= rate * 120) return
            data = data.copyOf(minOf(data.size * 2, rate * 120))
            if (n + count > data.size) return
        }
        for (i in 0 until count) data[n + i] = (b[i] * 32767f).roundToInt().coerceIn(-32768, 32767).toShort()
        n += count
    }

    private var t0 = 0L; private var f0 = 0L; private var t1 = 0L; private var f1 = 0L

    /** Presentation timestamps of this burst: their slope is the device's sample rate on System.nanoTime. */
    fun clock(atNs: Long, frame: Long) {
        if (t0 == 0L || frame < f0) { t0 = atNs; f0 = frame }
        t1 = atNs; f1 = frame
    }

    fun save() {
        val hz = if (t1 > t0 + 500_000_000L) (f1 - f0) * 1e9 / (t1 - t0) else 0.0
        try { File(file.parentFile, file.nameWithoutExtension + ".json").writeText("{\"rate\": $rate, \"device_hz\": ${"%.1f".format(java.util.Locale.ROOT, hz)}}\n") } catch (_: IOException) {}
        t0 = 0L
        write(file, burstStart, n)
        write(File(file.parentFile, file.nameWithoutExtension + "-all.wav"), 0, n)
        burstStart = n
    }

    private fun write(f: File, from: Int, to: Int) {
        val bytes = (to - from) * 2
        val out = java.nio.ByteBuffer.allocate(44 + bytes).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        out.put("RIFF".toByteArray()).putInt(36 + bytes).put("WAVE".toByteArray())
        out.put("fmt ".toByteArray()).putInt(16).putShort(1).putShort(1).putInt(rate).putInt(rate * 2).putShort(2).putShort(16)
        out.put("data".toByteArray()).putInt(bytes)
        for (i in from until to) out.putShort(data[i])
        try {
            val tmp = File(f.parentFile, f.name + ".tmp")
            tmp.writeBytes(out.array())
            tmp.renameTo(f)
        } catch (e: IOException) { Log.w("TempleOS-Snd", "capture: $e") }
    }
}

/**
 * The platform text engine for UI text the TempleOS font cannot show (Surface.TextRun): system
 * fonts with full fallback (CJK, Arabic, Indic, ...), 10 logical px, drawn under the canvas's
 * integer scale so the text is sharp at device resolution.
 */
val textPaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.SUBPIXEL_TEXT_FLAG).apply {
    typeface = Typeface.DEFAULT_BOLD
    textSize = 10f
    isLinearText = true
}

class AndroidShellEnv(private val context: Context, soundCapture: File? = null, private val onRender: () -> Unit) : ShellEnv {
    override fun processCpuNs(): Long = android.os.Process.getElapsedCpuTime() * 1_000_000L

    private val assets = context.assets
    private val runtimeCache = HashMap<String, ByteArray?>()
    override val fs = LayeredFs(AssetBundle(assets), File(context.filesDir, "drive"))
    override val stateStore = FileStateStore(File(context.filesDir, "session.txt"))
    val sound = ToneGenerator(context, soundCapture)

    @Synchronized override fun runtimeFile(name: String): ByteArray? {
        runtimeCache[name]?.let { return it }
        val path = if (name == "catalog.json") name else "runtime/$name"
        val b = try { assets.open(path).use { it.readBytes() } } catch (e: IOException) { null }
        // language catalogs and vocabularies are decoded once by their owners; keeping their bytes would hold every language visited
        if (!name.startsWith("l10n/")) runtimeCache[name] = b
        return b
    }

    override fun tone(freq: Double, atNs: Long) = sound.tone(freq, atNs)

    /** MotionEvent.eventTime is uptime, not wall-clock time. */
    override fun nowMs(): Long = android.os.SystemClock.uptimeMillis()

    override fun clipboardGet(): String? {
        val cm = context.getSystemService(ClipboardManager::class.java) ?: return null
        return cm.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(context)?.toString()
    }

    override fun clipboardSet(s: String) {
        context.getSystemService(ClipboardManager::class.java)?.setPrimaryClip(ClipData.newPlainText("TempleOS", s))
    }

    override fun openPrivacyPolicy() {
        try {
            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(Brand.PRIVACY_URL))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (_: ActivityNotFoundException) {
            // A device without a browser still gets the fixed URL, without crashing the app.
            clipboardSet(Brand.PRIVACY_URL)
            Toast.makeText(context, Brand.PRIVACY_URL, Toast.LENGTH_LONG).show()
        }
    }

    /** The app's languages: the per-app language (Android 13+) or the device list, most preferred first. */
    override fun preferredLanguages(): List<String> {
        val l = context.resources.configuration.locales
        return (0 until l.size()).map { l[it].toLanguageTag() }
    }

    override fun deviceRegion(): String? =
        android.content.res.Resources.getSystem().configuration.locales.takeIf { !it.isEmpty }?.get(0)?.country?.ifEmpty { null }

    /** Measures with the same paint [TempleView] draws text runs with (see [textPaint]). */
    @Synchronized override fun measureText(s: String): Int = kotlin.math.ceil(textPaint.measureText(s)).toInt()

    override fun requestRender() = onRender()

    /**
     * Each program gets its own HolyC heap; larger on devices with more memory per app (TempleOS has no
     * per-program limit). Talons, the largest, needs 65 MiB to start and about 67 MiB after 15 minutes of play
     * (docs/native-validation: its 34 MiB of globals plus 213,931 terrain panels, as on TempleOS), so the
     * 256 MB class gets 72 MiB (it had 64, just too little). The heap grows on demand and growing copies it
     * (old and new array live at once: 64 + 72 MiB), which a 256 MB app heap holds; 96 MiB needs 384 MB.
     */
    override val memoryLimitBytes: Int =
        (context.getSystemService(ActivityManager::class.java)?.memoryClass ?: 0).let {
            if (it >= 384) 96 shl 20 else if (it >= 256) 72 shl 20 else 32 shl 20
        }
}

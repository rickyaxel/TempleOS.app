package io.github.templeosmobile.android

import android.annotation.SuppressLint
import android.content.Intent
import android.content.pm.ActivityInfo
import android.app.Activity
import android.content.pm.ApplicationInfo
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.window.OnBackInvokedDispatcher
import io.github.templeosmobile.core.ui.Launch
import io.github.templeosmobile.core.ui.Shell
import java.io.File

/**
 * The single Activity. It hosts one [Shell] (the TempleOS Mobile desktop) in a
 * [TempleView]. The session (open windows, editor drafts, settings) is saved
 * whenever the app goes to the background and restored on the next launch.
 */
class MainActivity : Activity() {
    private lateinit var env: AndroidShellEnv
    private lateinit var shell: Shell
    private lateinit var view: TempleView
    private lateinit var systemBars: SystemBarsAdapter
    private var benchOnly = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // device validation (bench build type only): headless deterministic benchmark, no shell, no saved state
        val bench = if (BuildConfig.BENCH) intent?.getStringExtra("bench") else null
        if (bench != null) { benchOnly = true; BenchMode.start(this, bench); return }
        systemBars = SystemBarsAdapter(window).also { it.install() }
        // benchmarks: adb shell am start ... --ez perflog true (one perf line per second in logcat)
        if (automation && intent?.getBooleanExtra("perflog", false) == true) Shell.perfLog = true
        // sound checks (debug builds): --ez soundcapture true records the speaker's samples to
        // <external files>/sound-capture.wav (tools/audio/analyze_capture.py)
        val capture = if ((applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0 && intent?.getBooleanExtra("soundcapture", false) == true)
            File(getExternalFilesDir(null) ?: filesDir, "sound-capture.wav") else null
        env = AndroidShellEnv(this, capture) { if (::view.isInitialized) view.kick() }
        // Pure Kotlin mode: the bundled programs' ahead-of-time Kotlin translations (Settings > Engine)
        io.github.templeosmobile.core.purenative.NativePrograms.catalog = io.github.templeosmobile.purekotlin.gen.NativeCatalog
        shell = Shell(env).also { it.awaitingRestore = true } // until onFirstLayout has read the saved session
        view = TempleView(this, shell)
        view.systemBars = systemBars
        view.onFirstLayout = {
            // benchmarks: --ez nosession true starts with no restored windows (ColorOS refuses `pm clear` from adb)
            if (!automation || intent?.getBooleanExtra("nosession", false) != true) shell.restoreSession()
            else shell.awaitingRestore = false // test tools: start empty and save as usual
            // benchmarks: --es engine native|terry selects the engine (Settings > Engine) for automated runs
            if (automation) when (intent?.getStringExtra("engine")) {
                "native" -> shell.settings.engine = io.github.templeosmobile.core.ui.Settings.ENGINE_NATIVE
                "terry" -> shell.settings.engine = io.github.templeosmobile.core.ui.Settings.ENGINE_TERRY
            }
            if (BuildConfig.BENCH) applyInputTestSettings(intent)
            // An empty session shows the exact four-line intro until MENU is used.
            view.relayout() // settings (display scale) may have changed
        }
        setContentView(view)
        view.requestFocus()
        if (Build.VERSION.SDK_INT >= 33) {
            onBackInvokedDispatcher.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT) { handleBack() }
        }
    }

    /**
     * Test-tool intent extras (perflog, nosession, engine) are honoured only by debuggable and bench builds.
     * The launcher activity is exported, so in a store build any app could send them, and `nosession` would
     * let the next save in onPause replace the user's session (windows, editor drafts, settings) with an empty one.
     */
    private val automation get() = BuildConfig.BENCH || (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0

    /** Bench-only UI automation: app-local orientation/language/recreation, never global device settings. */
    @SuppressLint("SourceLockedOrientationActivity")
    private fun applyInputTestSettings(request: Intent?) {
        if (!BuildConfig.BENCH || benchOnly) return
        when (request?.getStringExtra("inputOrientation")) {
            "landscape" -> requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
            "portrait" -> requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            "user" -> requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_FULL_USER
        }
        request?.getStringExtra("inputLanguage")?.let { shell.settings.language = it; shell.applyLanguage(); shell.invalidate() }
    }

    override fun onNewIntent(request: Intent) {
        super.onNewIntent(request)
        if (!BuildConfig.BENCH || benchOnly) return
        intent = request
        applyInputTestSettings(request)
        if (request.getBooleanExtra("inputRecreate", false)) {
            request.removeExtra("inputRecreate")
            shell.saveSession(); recreate()
        }
    }

    private fun handleBack() {
        if (benchOnly) return
        if (!shell.back()) moveTaskToBack(true)
        view.kick()
    }

    // Only reached below API 33; API 33+ uses the OnBackInvokedCallback registered in
    // onCreate (verified with the back gesture on Android 16). Lint cannot see that.
    @Deprecated("Used below API 33")
    @Suppress("DEPRECATION")
    @SuppressLint("GestureBackNavigation")
    override fun onBackPressed() = handleBack()

    /** Device or per-app language changed (the activity is kept): re-resolve, keep every window. */
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (benchOnly) return
        shell.applyLanguage()
        systemBars.invalidate()
        shell.invalidate() // re-render: the bars are applied after it
        view.kick()
    }

    override fun onResume() {
        super.onResume()
        if (benchOnly) return
        shell.onForeground()
        systemBars.invalidate()
        shell.invalidate()
        view.resume()
    }

    override fun onPause() {
        if (benchOnly) { super.onPause(); return }
        shell.onBackground()
        view.pause()
        super.onPause()
    }

    override fun onDestroy() {
        if (benchOnly) { super.onDestroy(); return }
        // Stop every HolyC program thread; the session was saved in onPause.
        shell.windows.toList().forEach { it.app.close() }
        env.sound.release()
        super.onDestroy()
    }
}

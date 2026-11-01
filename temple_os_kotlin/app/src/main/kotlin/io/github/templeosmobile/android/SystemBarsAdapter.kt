package io.github.templeosmobile.android

import android.graphics.Color
import android.os.Build
import android.view.View
import android.view.Window
import android.view.WindowInsets
import android.view.WindowInsetsController
import io.github.templeosmobile.core.ui.ChangeGate
import io.github.templeosmobile.core.ui.SystemChrome

/**
 * The status and navigation bars (layer C). The app draws edge to edge: both bars are
 * transparent and the shell paints the regions under them in the color of the TempleOS surface
 * that owns each edge ([SystemChrome]), so the gesture handle or the three buttons sit on the
 * TempleOS screen itself, with no strip of another color. This adapter only:
 *
 * - makes the window edge to edge with transparent bars, without the navigation-bar contrast scrim
 *   (Android 10+ draws an 80% scrim behind three-button navigation by default; on Android 15+ it was
 *   the near-black strip under a dark-gray desktop). Readability comes from the icon color instead;
 * - picks dark or light navigation icons for the color under the bar, on the edge where the system
 *   reports it (three-button bars move to a side in landscape). Every palette color keeps at least
 *   4.5:1 contrast with the chosen icons ([SystemChrome.prefersDarkIcons]);
 * - calls the window only when that choice changes ([ChangeGate]), never per frame.
 *
 * While the device keyboard is up, its window draws and styles the navigation region (the system
 * takes the IME window's bar appearance), so nothing is changed then.
 *
 * Framework APIs only (the app has no AndroidX): `WindowInsetsController` from API 30, the
 * `View.SYSTEM_UI_FLAG_*` flags on API 26-29.
 */
class SystemBarsAdapter(private val window: Window) {
    private var navEdge = SystemChrome.Edge.BOTTOM
    private val gate = ChangeGate<Boolean> { dark -> setDarkNavigationIcons(dark) }

    /** Called once from onCreate, before the content view is set. */
    @Suppress("DEPRECATION")
    fun install() {
        if (Build.VERSION.SDK_INT >= 30) {
            window.setDecorFitsSystemWindows(false)
        } else {
            // HIDE_NAVIGATION here is a layout flag: the content extends under the (still shown) navigation bar
            window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_LAYOUT_STABLE or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
        }
        // deprecated on Android 15+, where it still tints three-button navigation (at 80% alpha): keep it clear
        window.navigationBarColor = Color.TRANSPARENT
        if (Build.VERSION.SDK_INT in 28..34) window.navigationBarDividerColor = Color.TRANSPARENT
        if (Build.VERSION.SDK_INT >= 29) window.isNavigationBarContrastEnforced = false
    }

    /** The navigation bar's edge from the current insets (bottom, or a side in landscape). */
    @Suppress("DEPRECATION")
    fun onInsets(insets: WindowInsets) {
        val (l, r, b) = if (Build.VERSION.SDK_INT >= 30) {
            val n = insets.getInsets(WindowInsets.Type.navigationBars()); Triple(n.left, n.right, n.bottom)
        } else Triple(insets.systemWindowInsetLeft, insets.systemWindowInsetRight, insets.systemWindowInsetBottom)
        navEdge = when {
            b > 0 || (l == 0 && r == 0) -> SystemChrome.Edge.BOTTOM
            r >= l -> SystemChrome.Edge.RIGHT
            else -> SystemChrome.Edge.LEFT
        }
    }

    /** Applies the appearance for [chrome] (after each render; does nothing when it is unchanged). */
    fun apply(chrome: SystemChrome) {
        if (chrome.deviceKeyboard) return
        gate.offer(chrome.darkIconsAt(navEdge))
    }

    /** The window may have lost or reset its appearance (resume, configuration change): apply again. */
    fun invalidate() = gate.reset()

    @Suppress("DEPRECATION")
    private fun setDarkNavigationIcons(dark: Boolean) {
        if (Build.VERSION.SDK_INT >= 30) {
            val c = window.insetsController ?: return
            c.setSystemBarsAppearance(if (dark) WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS else 0, WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS)
        } else if (Build.VERSION.SDK_INT >= 26) { // API 24-25 navigation bars have no dark icons
            val v = window.decorView
            val flags = v.systemUiVisibility
            v.systemUiVisibility = if (dark) flags or View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR else flags and View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR.inv()
        }
    }
}

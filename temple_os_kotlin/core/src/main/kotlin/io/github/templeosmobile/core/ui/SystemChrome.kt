package io.github.templeosmobile.core.ui

import io.github.templeosmobile.core.kernel.Palette

/**
 * What the TempleOS screen shows next to the regions the operating system draws over it: the
 * Android navigation bar or gesture handle, the iPhone home indicator, and the side gutters of a
 * landscape screen (a side navigation bar or a display cutout). The shell resolves it on every
 * render from what it actually drew ([Shell.systemChrome]) and paints those regions in these
 * colors, so a transparent system bar shows the TempleOS surface that owns the edge. The platform
 * adapters (Android `SystemBarsAdapter`, iOS `TempleViewController`) only translate it to
 * system calls: icon contrast, window background, home-gesture deferral.
 *
 * Colors are palette indices (the shell draws only [Palette.STD] colors).
 */
data class SystemChrome(
    /** Painted under the bottom system region (navigation bar, gesture handle, home indicator). */
    val bottom: Int,
    /** Painted in the left and right safe-area gutters beside the content. */
    val side: Int,
    /** What owns the bottom edge (for tests and diagnostics). */
    val owner: Owner,
    /**
     * The device keyboard covers the bottom edge. On Android its window then draws and styles the
     * navigation region; the adapter leaves that to the system.
     */
    val deviceKeyboard: Boolean = false,
    /** The focused app asks for the bottom-edge system gestures to be deferred (its controls sit there). */
    val defersEdgeGestures: Boolean = false,
) {
    enum class Owner { DESKTOP, WINDOW, APP_OVERRIDE, POPUP, KEY_ROW, KEYBOARD }

    /** Where the platform reports its navigation bar (landscape three-button bars sit on a side). */
    enum class Edge { BOTTOM, LEFT, RIGHT }

    /** The color under a navigation bar on [edge]. */
    fun colorAt(edge: Edge) = if (edge == Edge.BOTTOM) bottom else side

    /** True when dark system icons read better than light ones on the color at [edge]. */
    fun darkIconsAt(edge: Edge) = prefersDarkIcons(colorAt(edge))

    /**
     * A surface that may own the bottom edge: a window, an overlay or a bottom bar, with the color
     * it shows along its bottom row. [rect] is in logical pixels.
     */
    class Layer(val rect: Rect, val color: Int, val owner: Owner)

    companion object {
        /**
         * WCAG contrast: dark icons when black contrasts more with [color] than white does, i.e. a
         * relative luminance above sqrt(1.05 * 0.05) - 0.05 = 0.179. Every palette color then keeps at
         * least 4.5:1 against the chosen icon color (LTBLUE, the closest call, gets white at 5.1:1).
         */
        fun prefersDarkIcons(color: Int): Boolean = luminance(Palette.STD[color and 15]) > 0.1791

        /** WCAG 2 relative luminance of an ARGB color. */
        fun luminance(argb: Int): Double {
            fun lin(c: Int): Double { val v = c / 255.0; return if (v <= 0.04045) v / 12.92 else Math.pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin((argb shr 16) and 0xFF) + 0.7152 * lin((argb shr 8) and 0xFF) + 0.0722 * lin(argb and 0xFF)
        }

        /**
         * Resolves the edge colors. [content] are windows (bottom to top) judged against [contentBottom],
         * the bottom of the desktop area; [bars] are bottom bars and popups (bottom to top) judged against
         * [usableBottom], the top of the system region or device keyboard. A layer owns an edge when it
         * reaches it across the whole usable width ([left] to [right]): a centered dialog or a floating
         * window does not, so the surface beneath keeps the edge. The side gutters follow the content.
         */
        fun resolve(
            desktop: Int, content: List<Layer>, contentBottom: Int, bars: List<Layer>, usableBottom: Int,
            left: Int, right: Int, deviceKeyboard: Boolean = false, defersEdgeGestures: Boolean = false,
        ): SystemChrome {
            fun owns(l: Layer, edge: Int) = l.rect.bottom >= edge && l.rect.x <= left && l.rect.right >= right && l.rect.w > 0 && l.rect.h > 0
            val c = content.lastOrNull { owns(it, contentBottom) }
            val sideColor = c?.color ?: desktop
            val b = bars.lastOrNull { owns(it, usableBottom) }
            return SystemChrome(
                bottom = b?.color ?: sideColor, side = sideColor,
                owner = b?.owner ?: c?.owner ?: Owner.DESKTOP,
                deviceKeyboard = deviceKeyboard, defersEdgeGestures = defersEdgeGestures,
            )
        }
    }
}

/**
 * Passes a value on only when it differs from the last one passed (platform adapters: a window
 * appearance call per actual change, never per frame). [reset] forces the next value through,
 * e.g. after the window was recreated or returned from the background.
 */
class ChangeGate<T>(private val apply: (T) -> Unit) {
    private var last: T? = null
    private var primed = false
    /** Returns true if [value] was applied. */
    fun offer(value: T): Boolean {
        if (primed && value == last) return false
        last = value; primed = true
        apply(value)
        return true
    }
    fun reset() { primed = false }
}

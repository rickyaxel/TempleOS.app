package io.github.templeosmobile.android

import android.graphics.Rect as ARect
import android.os.Build
import android.os.Bundle
import android.view.MotionEvent
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityManager
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityNodeProvider
import android.text.SpannableString
import android.text.Spanned
import android.text.style.LocaleSpan
import io.github.templeosmobile.core.ui.A11yNode
import io.github.templeosmobile.core.ui.L10n
import io.github.templeosmobile.core.ui.Shell

/**
 * Platform adapter: the shell's accessibility nodes ([A11yNode]) as TalkBack virtual views of
 * the single TempleView. Clicking a node taps its center, so TalkBack users drive exactly the
 * same UI as touch users. Changes in Android accessibility APIs belong in this file.
 */
class AccessibilityAdapter(private val view: TempleView, private val shell: Shell) {
    /** A label tagged with the UI language, so TalkBack speaks it with the right voice even when it differs from the system's. */
    private fun spoken(label: String): CharSequence {
        val id = L10n.locale?.id ?: return label
        return SpannableString(label).apply { setSpan(LocaleSpan(java.util.Locale.forLanguageTag(id)), 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE) }
    }

    /** The shell's [A11yNode]s as virtual views; ids are indices into the last snapshot. */
    private var a11yNodes: List<A11yNode> = emptyList()
    private var a11yFocused = NO_NODE
    private var a11yHovered = NO_NODE
    private var a11ySent = -1L
    private val a11yManager get() = view.context.getSystemService(AccessibilityManager::class.java)

    private fun nodeAt(x: Float, y: Float): Int {
        val lx = (x / view.pxPerLogical).toInt(); val ly = (y / view.pxPerLogical).toInt()
        // the smallest node under the finger (keys and buttons before the text around them)
        return a11yNodes.indices.filter { a11yNodes[it].rect.contains(lx, ly) }.minByOrNull { a11yNodes[it].rect.w * a11yNodes[it].rect.h } ?: NO_NODE
    }

    private fun sendNodeEvent(id: Int, type: Int) {
        val m = a11yManager ?: return
        if (!m.isEnabled) return
        @Suppress("DEPRECATION") val ev = if (Build.VERSION.SDK_INT >= 30) AccessibilityEvent(type) else AccessibilityEvent.obtain(type)
        ev.setSource(view, id)
        ev.packageName = view.context.packageName
        a11yNodes.getOrNull(id)?.let { ev.contentDescription = spoken(it.label) }
        view.parent?.requestSendAccessibilityEvent(view, ev)
    }

    /** Called each frame: tells TalkBack when what is on screen changed. */
    fun sync() {
        val m = a11yManager ?: return
        if (!m.isEnabled || shell.a11yVersion == a11ySent) return
        a11ySent = shell.a11yVersion
        val now = shell.accessibilityNodes()
        // renders are frequent (a blinking caret); only announce real changes
        val same = now.size == a11yNodes.size && now.indices.all { i ->
            val x = now[i]; val y = a11yNodes[i]
            x.label == y.label && x.selected == y.selected && x.rect.x == y.rect.x && x.rect.y == y.rect.y && x.rect.w == y.rect.w && x.rect.h == y.rect.h
        }
        a11yNodes = now
        if (a11yFocused >= a11yNodes.size) a11yFocused = NO_NODE
        if (!same) view.sendAccessibilityEvent(AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED)
    }

    val provider = object : AccessibilityNodeProvider() {
        @Suppress("DEPRECATION")
        override fun createAccessibilityNodeInfo(id: Int): AccessibilityNodeInfo? {
            if (id == HOST_VIEW_ID) {
                val info = AccessibilityNodeInfo.obtain(view)
                view.onInitializeAccessibilityNodeInfo(info)
                if (BuildConfig.DEBUG || BuildConfig.BENCH) info.contentDescription = "TempleOS input;${view.imeDiagnostics.state}"
                a11yNodes = shell.accessibilityNodes()
                for (i in a11yNodes.indices) info.addChild(view, i)
                return info
            }
            val n = a11yNodes.getOrNull(id) ?: return null
            val info = AccessibilityNodeInfo.obtain(view, id)
            info.setParent(view)
            info.packageName = view.context.packageName
            info.className = if (n.button) "android.widget.Button" else "android.widget.TextView"
            if (n.button) info.contentDescription = spoken(n.label) else info.text = spoken(n.label)
            val b = ARect(n.rect.x * view.pxPerLogical, n.rect.y * view.pxPerLogical, (n.rect.x + n.rect.w) * view.pxPerLogical, (n.rect.y + n.rect.h) * view.pxPerLogical)
            info.setBoundsInParent(b)
            val loc = IntArray(2); view.getLocationOnScreen(loc)
            b.offset(loc[0], loc[1]); info.setBoundsInScreen(b)
            info.isEnabled = true; info.isVisibleToUser = true; info.isFocusable = true
            info.isClickable = n.button; info.isSelected = n.selected
            if (n.button) info.addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_CLICK)
            info.isAccessibilityFocused = id == a11yFocused
            info.addAction(if (id == a11yFocused) AccessibilityNodeInfo.AccessibilityAction.ACTION_CLEAR_ACCESSIBILITY_FOCUS
                else AccessibilityNodeInfo.AccessibilityAction.ACTION_ACCESSIBILITY_FOCUS)
            return info
        }

        override fun performAction(id: Int, action: Int, args: Bundle?): Boolean {
            if (id == HOST_VIEW_ID) return view.performAccessibilityAction(action, args)
            val n = a11yNodes.getOrNull(id) ?: return false
            return when (action) {
                AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS -> {
                    a11yFocused = id; view.invalidate(); sendNodeEvent(id, AccessibilityEvent.TYPE_VIEW_ACCESSIBILITY_FOCUSED); true
                }
                AccessibilityNodeInfo.ACTION_CLEAR_ACCESSIBILITY_FOCUS -> {
                    if (a11yFocused == id) a11yFocused = NO_NODE
                    sendNodeEvent(id, AccessibilityEvent.TYPE_VIEW_ACCESSIBILITY_FOCUS_CLEARED); true
                }
                AccessibilityNodeInfo.ACTION_CLICK -> {
                    if (!n.button) return false
                    shell.accessibilityActivate(n); view.kick()
                    sendNodeEvent(id, AccessibilityEvent.TYPE_VIEW_CLICKED); true
                }
                else -> false
            }
        }
    }

    /** Touch exploration: TalkBack sends hover events; announce the node under the finger. */
    fun hover(e: MotionEvent): Boolean {
        val m = a11yManager
        if (m == null || !m.isEnabled || !m.isTouchExplorationEnabled) return false
        if (a11yNodes.isEmpty()) a11yNodes = shell.accessibilityNodes()
        val id = if (e.actionMasked == MotionEvent.ACTION_HOVER_EXIT) NO_NODE else nodeAt(e.x, e.y)
        if (id != a11yHovered) {
            if (a11yHovered != NO_NODE) sendNodeEvent(a11yHovered, AccessibilityEvent.TYPE_VIEW_HOVER_EXIT)
            a11yHovered = id
            if (id != NO_NODE) sendNodeEvent(id, AccessibilityEvent.TYPE_VIEW_HOVER_ENTER)
        }
        return true
    }

    private companion object { const val NO_NODE = Int.MIN_VALUE }
}

package io.github.templeosmobile.android

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect as ARect
import android.graphics.Region
import android.os.Build
import android.view.Choreographer
import android.view.KeyEvent
import android.view.accessibility.AccessibilityNodeProvider
import android.view.MotionEvent
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsAnimation
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import io.github.templeosmobile.core.kernel.Keys
import io.github.templeosmobile.core.kernel.Palette
import io.github.templeosmobile.core.ui.FrameSource
import io.github.templeosmobile.core.ui.PointerEvent
import io.github.templeosmobile.core.ui.Ptr
import io.github.templeosmobile.core.ui.Shell

/**
 * Draws the shell's indexed framebuffer scaled by an integer factor (nearest
 * neighbour) plus program frames, and turns touch and hardware-keyboard
 * input into shell events. Everything runs on the UI thread.
 */
@SuppressLint("ViewConstructor")
class TempleView(context: Context, private val shell: Shell) : View(context), Choreographer.FrameCallback {
    private var scale = 3
    private var bmp: Bitmap? = null
    private var argb = IntArray(0)
    private var drawnVersion = -1L
    private val crisp = Paint().apply { isFilterBitmap = false }
    private val remainderPaint = Paint()
    private val smooth = Paint().apply { isFilterBitmap = true }
    private val frames = HashMap<FrameSource, FrameBitmap>()
    private var looping = false
    private var idleFrames = 0
    private var insetL = 0; private var insetT = 0; private var insetR = 0; private var insetB = 0
    val imeDiagnostics = ImeDiagnostics(shell)
    private val physicalDown = HashMap<Int, Pair<Int, Long>>()
    var onFirstLayout: (() -> Unit)? = null
    /** Status and navigation bars: follow the shell's [io.github.templeosmobile.core.ui.SystemChrome] after each render. */
    var systemBars: SystemBarsAdapter? = null

    private class FrameBitmap(val bmp: Bitmap, val idx: ByteArray, val argb: IntArray) { var version = -1L }

    init {
        isFocusable = true
        isFocusableInTouchMode = true
        setOnApplyWindowInsetsListener { _, insets -> applyInsets(insets); insets }
        if (Build.VERSION.SDK_INT >= 30) {
            setWindowInsetsAnimationCallback(object : WindowInsetsAnimation.Callback(DISPATCH_MODE_CONTINUE_ON_SUBTREE) {
                override fun onProgress(insets: WindowInsets, runningAnimations: MutableList<WindowInsetsAnimation>): WindowInsets {
                    imeDiagnostics.observe(insets.isVisible(WindowInsets.Type.ime()), hasWindowFocus())
                    return insets
                }
            })
        } else {
            // Legacy Android has no IME visibility type: diagnose large occlusions, corroborated by device-level sampling.
            val visibleFrame = android.graphics.Rect()
            viewTreeObserver.addOnGlobalLayoutListener {
                getWindowVisibleDisplayFrame(visibleFrame)
                imeDiagnostics.observe(rootView.height - visibleFrame.bottom > 160 * resources.displayMetrics.density, hasWindowFocus())
            }
        }
    }

    // ------------------------------------------------------------ layout

    @Suppress("DEPRECATION")
    private fun applyInsets(insets: WindowInsets) {
        systemBars?.onInsets(insets)
        if (Build.VERSION.SDK_INT >= 30) {
            val bars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
            imeDiagnostics.observe(insets.isVisible(WindowInsets.Type.ime()), hasWindowFocus())
            insetL = bars.left; insetT = bars.top; insetR = bars.right; insetB = bars.bottom
        } else {
            insetL = insets.systemWindowInsetLeft; insetT = insets.systemWindowInsetTop
            insetR = insets.systemWindowInsetRight; insetB = insets.systemWindowInsetBottom
        }
        relayout()
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) { relayout() }

    fun relayout() {
        val w = width; val h = height
        if (w <= 0 || h <= 0) return
        val chosen = shell.settings.uiScale
        scale = if (chosen > 0) chosen else maxOf(1, minOf(w, h) / 360)
        while (scale > 1 && (w / scale < 320 || h / scale < 240)) scale--
        fun up(v: Int) = (v + scale - 1) / scale
        // dp per logical px: the menu layer sizes its text and touch targets from it (MenuMetrics)
        shell.resize(w / scale, h / scale, up(insetT), up(insetB), up(insetL), up(insetR), 0, scale / resources.displayMetrics.density.toDouble())
        onFirstLayout?.let { onFirstLayout = null; it() }
        kick()
    }

    // ------------------------------------------------------------ frame loop

    fun resume() { imeDiagnostics.lifecycle = "resumed"; paused = false; requestFocus(); requestApplyInsets(); kick() }
    fun pause() { imeDiagnostics.lifecycle = "paused"; paused = true; releasePhysicalKeys(); if (looping) { Choreographer.getInstance().removeFrameCallback(this); looping = false; delayed = false } }

    /**
     * Between [pause] and [resume] no frame loop runs. Kicks still arrive then (a program's render
     * request, Back moving the task to the background), and each one restarted the 100 ms idle poll,
     * which kept running for as long as the app stayed in the background.
     */
    private var paused = false

    /**
     * Ensures the frame loop runs at display rate (any thread). Exactly one callback is pending at a
     * time: a kick while one is posted for the next vsync does nothing, and a kick during the slow idle
     * poll replaces it with an immediate one (input must not wait up to 100 ms).
     */
    fun kick() {
        if (Thread.currentThread() !== context.mainLooper.thread) { post { kick() }; return }
        if (paused) return
        idleFrames = 0
        if (looping && delayed) { Choreographer.getInstance().removeFrameCallback(this); looping = false }
        if (!looping) { looping = true; delayed = false; loopRestarted = true; Choreographer.getInstance().postFrameCallback(this) }
    }

    /** The next callback follows an idle pause, not a stall (UiFrameStats). */
    private var loopRestarted = true
    /** The pending callback is the 100 ms idle poll. */
    private var delayed = false

    override fun doFrame(frameTimeNanos: Long) {
        looping = false; delayed = false
        shell.uiFrames.frame(System.nanoTime(), loopRestarted); loopRestarted = false
        var changed = shell.tick()
        if (changed) systemBars?.apply(shell.systemChrome)
        a11y.sync()
        val overlays = shell.overlays()
        for (o in overlays) if (o.source.frameVersion != frames[o.source]?.version) changed = true
        if (changed) { invalidate(); idleFrames = 0 } else idleFrames++
        // shell.tick() may have kicked (invalidate -> requestRender): that callback is the next one. A second
        // one used to be posted here too, so doFrame ran two or three times per vsync while a program ran.
        if (looping) return
        // Programs and the console publish without notifying; keep polling while
        // anything can change, slowing down after a second of idleness.
        looping = true
        if (overlays.isNotEmpty() || idleFrames < 60) Choreographer.getInstance().postFrameCallback(this)
        else { delayed = true; loopRestarted = true; Choreographer.getInstance().postFrameCallbackDelayed(this, 100) }
    }

    /**
     * Localized UI text the TempleOS font cannot show: drawn by Android's text engine (shaping,
     * bidi, font fallback) at device resolution, clipped to its row and hidden under every
     * window, menu or keyboard drawn above it. The canvas is already scaled to logical px.
     */
    /** Half the line height above the baseline, per px of text size: centres a line on the 8 px TempleOS text row. */
    private val lineCentre = textPaint.fontMetrics.let { -(it.ascent + it.descent) / 2f / textPaint.textSize }

    /** Drawing paint (UI thread); [textPaint] itself measures for the kernel threads (AndroidShellEnv.measureText). */
    private val runPaint = Paint(textPaint)
    private val inkRect = android.graphics.Rect()
    /** Fitted [size, ink top, ink bottom] (px from the baseline) by text and sizes; [fit]. */
    private val fits = object : LinkedHashMap<String, FloatArray>(64, 0.75f, true) {
        override fun removeEldestEntry(e: MutableMap.MutableEntry<String, FloatArray>?) = size > 512
    }

    /**
     * The size for [text] at [size] whose ink fits in [maxInk] logical px: the size itself unless the script's marks
     * reach further (Burmese, Thai, stacked Vietnamese, Devanagari), then just small enough. The ink is measured on
     * the shaped string at 16x (getTextBounds rounds to whole px) and scaled back.
     */
    private fun fit(text: String, size: Float, maxInk: Float): FloatArray {
        val key = "$size|$maxInk|$text"
        fits[key]?.let { return it }
        fun measure(sz: Float): FloatArray {
            runPaint.textSize = sz * 16f
            runPaint.getTextBounds(text, 0, text.length, inkRect)
            return floatArrayOf(sz, inkRect.top / 16f, inkRect.bottom / 16f)
        }
        var f = measure(size)
        val h = f[2] - f[1]
        if (h > maxInk && h > 0f) f = measure(size * maxInk / h)
        fits[key] = f
        return f
    }

    /** An overlay's frame buffers: allocated once per overlay source, then reused by every draw. */
    private fun newFrame(w: Int, h: Int) = FrameBitmap(Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888), ByteArray(w * h), IntArray(w * h))

    @Suppress("DEPRECATION")
    private fun clipOut(canvas: Canvas, l: Float, t: Float, r: Float, b: Float) {
        if (Build.VERSION.SDK_INT >= 26) canvas.clipOutRect(l, t, r, b) else canvas.clipRect(l, t, r, b, Region.Op.DIFFERENCE)
    }

    private fun drawTextRuns(canvas: Canvas, s: io.github.templeosmobile.core.ui.Surface) {
        if (s.runs.isEmpty()) return
        val p = runPaint
        for (r in s.runs) {
            canvas.save()
            canvas.clipRect(r.clip.x.toFloat(), r.clip.y.toFloat(), r.clip.right.toFloat(), r.clip.bottom.toFloat())
            for (o in s.occluders) if (o.z > r.z) clipOut(canvas, o.rect.x.toFloat(), o.rect.y.toFloat(), o.rect.right.toFloat(), o.rect.bottom.toFloat())
            // menu text is magnified like the TempleOS glyphs beside it (TextRun.scale); its line is centred on the
            // 8-row TempleOS text row, and ink that would leave the part of the row's box that stays visible
            // (Surface.runInkBox) is moved inside it, or the size reduced just enough (docs/typography/TEMPLEOS_TYPOGRAPHY.md §4)
            val (bt, bb) = io.github.templeosmobile.core.ui.Surface.runInkBox(r, s.occluders)
            val boxTop = bt.toFloat(); val boxBottom = bb.toFloat()
            val f = fit(r.text, 10f * r.scale, boxBottom - boxTop)
            p.textSize = f[0]
            p.color = Palette.STD[r.fg and 15]
            p.textAlign = if (r.rtl) Paint.Align.RIGHT else Paint.Align.LEFT
            var base = r.y + 4f * r.scale + lineCentre * f[0]
            if (base + f[1] < boxTop) base = boxTop - f[1]
            if (base + f[2] > boxBottom) base = boxBottom - f[2]
            canvas.drawText(r.text, (if (r.rtl) r.x + r.w else r.x).toFloat(), base, p)
            canvas.restore()
        }
    }

    override fun onDraw(canvas: Canvas) {
        val s = shell.surface
        val sw = s.width; val sh = s.height
        var b = bmp
        if (b == null || b.width != sw || b.height != sh) {
            b = Bitmap.createBitmap(sw, sh, Bitmap.Config.ARGB_8888); bmp = b
            argb = IntArray(sw * sh); drawnVersion = -1
        }
        if (drawnVersion != s.version) {
            val px = s.px; val pal = Palette.STD
            for (i in 0 until minOf(px.size, argb.size)) argb[i] = pal[px[i].toInt() and 15]
            b.setPixels(argb, 0, sw, 0, 0, sw, sh)
            drawnVersion = s.version
        }
        // the few device pixels right of and below the integer-scaled surface continue its gutters
        val chrome = shell.systemChrome
        canvas.drawColor(Palette.STD[chrome.side])
        if (chrome.bottom != chrome.side) {
            remainderPaint.color = Palette.STD[chrome.bottom]
            canvas.drawRect(0f, (sh * scale).toFloat(), width.toFloat(), height.toFloat(), remainderPaint)
        }
        canvas.save()
        canvas.scale(scale.toFloat(), scale.toFloat())
        canvas.drawBitmap(b, 0f, 0f, crisp)
        drawTextRuns(canvas, s)
        canvas.restore()
        val live = liveSources; live.clear()
        for (o in shell.overlays()) {
            val src = o.source
            live.add(src)
            val fb = frames.getOrPut(src) { newFrame(src.frameW, src.frameH) }
            if (fb.version != src.frameVersion) {
                fb.version = src.copyFrame(fb.idx)
                val pal = src.palette
                for (i in fb.idx.indices) fb.argb[i] = pal[fb.idx[i].toInt() and 15]
                fb.bmp.setPixels(fb.argb, 0, src.frameW, 0, 0, src.frameW, src.frameH)
            }
            val r = o.rect
            val dst = overlayDst
            dst.set(r.x * scale, r.y * scale, (r.x + r.w) * scale, (r.y + r.h) * scale)
            overlaySrc.set(o.src.x, o.src.y, o.src.x + o.src.w, o.src.y + o.src.h)
            canvas.drawBitmap(fb.bmp, overlaySrc, dst, if (shell.settings.crispScaling) crisp else smooth)
        }
        frames.keys.retainAll(live)
        live.clear()
    }

    // Reused by onDraw (no per-frame allocations).
    private val liveSources = HashSet<FrameSource>()
    private val overlayDst = ARect()
    private val overlaySrc = ARect()

    // ------------------------------------------------------------ touch

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(e: MotionEvent): Boolean {
        fun send(action: Int, i: Int) =
            shell.pointer(PointerEvent(action, (e.getX(i) / scale).toInt(), (e.getY(i) / scale).toInt(), e.getPointerId(i), maxOf(1L, e.eventTime)))
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> send(Ptr.DOWN, e.actionIndex)
            MotionEvent.ACTION_MOVE -> for (i in 0 until e.pointerCount) send(Ptr.MOVE, i)
            MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> send(Ptr.UP, e.actionIndex)
            MotionEvent.ACTION_CANCEL -> for (i in 0 until e.pointerCount) send(Ptr.CANCEL, i)
        }
        if (e.actionMasked == MotionEvent.ACTION_UP) performClick()
        kick()
        return true
    }

    override fun performClick(): Boolean { super.performClick(); return true }

    // ------------------------------------------------------------ keyboard

    fun releasePhysicalKeys() { physicalDown.clear(); shell.releaseInputOwnership() }

    override fun onWindowFocusChanged(hasWindowFocus: Boolean) {
        super.onWindowFocusChanged(hasWindowFocus)
        if (!hasWindowFocus) { releasePhysicalKeys(); shell.suspendInput() } else { shell.resumeInput(); requestApplyInsets() }
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        if (keyCode == KeyEvent.KEYCODE_BACK || keyCode == KeyEvent.KEYCODE_VOLUME_UP || keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) return super.onKeyDown(keyCode, event)
        val (ch, sc) = HardwareKeyAdapter.map(keyCode, event) ?: return super.onKeyDown(keyCode, event)
        // the shell repeats held keys at TempleOS's rate; Android's own repeats are dropped
        if (event.repeatCount == 0 && !physicalDown.containsKey(keyCode)) {
            physicalDown[keyCode] = ch to sc; shell.hardwareKey(ch, sc, true)
        }
        kick(); return true
    }

    /** Key releases (TempleOS MSG_KEY_UP and kbd.down_bitmap): without them a held key stayed down. */
    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean {
        if (keyCode == KeyEvent.KEYCODE_BACK || keyCode == KeyEvent.KEYCODE_VOLUME_UP || keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) return super.onKeyUp(keyCode, event)
        val (ch, sc) = HardwareKeyAdapter.map(keyCode, event) ?: return super.onKeyUp(keyCode, event)
        physicalDown.remove(keyCode)?.let { held ->
            if (physicalDown.values.none { it.second and 255 == held.second and 255 }) shell.hardwareKey(held.first, held.second, false)
        }
        kick(); return true
    }



    // ------------------------------------------------------------ platform adapters

    override fun onCheckIsTextEditor() = false

    /** A focusable physical-key recipient, never an Android text editor or IME client. */
    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection? {
        imeDiagnostics.connectionProbe()
        return null
    }

    internal val pxPerLogical get() = scale

    private val a11y = AccessibilityAdapter(this, shell)

    override fun getAccessibilityNodeProvider(): AccessibilityNodeProvider = a11y.provider

    override fun dispatchHoverEvent(e: MotionEvent): Boolean = a11y.hover(e) || super.dispatchHoverEvent(e)
}

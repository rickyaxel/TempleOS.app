package io.github.templeosmobile.core.kernel

import io.github.templeosmobile.core.Brand
import io.github.templeosmobile.core.holyc.*
import java.util.concurrent.ConcurrentLinkedQueue

/** Services a kernel needs from its environment. */
interface KernelEnv {
    /** Reads system runtime files: "Prelude.HC", "PreludeDefines.HC", "font8x8.bin". */
    fun runtimeFile(name: String): ByteArray?
    /** The virtual filesystem (C:/ paths), or null if unavailable. */
    val fs: VirtualFs?
    fun nanoTime(): Long = System.nanoTime()
    fun epochMillis(): Long = System.currentTimeMillis()
    fun utcOffsetMillis(): Long = java.util.TimeZone.getDefault().getOffset(System.currentTimeMillis()).toLong()
    /** Program arena limit in bytes. */
    val memoryLimit: Int get() = 32 shl 20
    /**
     * The PC speaker (Kernel/KMisc.HC Snd): [freq] Hz from [atNs] on, 0 = off; one setting at a time, each
     * lasting until the next. [atNs] is on the [nanoTime] clock: the time TempleOS would have made the
     * change (see [Kernel.speaker]), which can be a little before the call.
     */
    fun sound(kernel: Kernel, freq: Double, atNs: Long) {}
    /** The host paused (true) or resumed (false) the kernel (window menu, background, hidden window). */
    fun paused(kernel: Kernel, paused: Boolean) {}
    /** Ed(file) from HolyC: ask the system to open the editor. */
    fun openEditor(kernel: Kernel, path: String) {}
    /** Man/Help/DocLink: open a document viewer. */
    fun openDocument(kernel: Kernel, path: String) {}
    /** A popup was requested; UIs show it (and later call answerPopup). Tests may answer at once. */
    fun popupRequested(kernel: Kernel, req: PopupRequest) {}
    /** Seed for the random generator (entropy source). */
    fun entropy(): Long = System.nanoTime() xor System.currentTimeMillis()
}

/** A modal choice requested by a program (TempleOS PopUp* functions). */
class PopupRequest(val header: String, val footer: String, val items: List<Item>) {
    class Item(val label: String, val value: Long, val bg: Int = -1)
    @Volatile var result: Long? = null
}

/** Input event delivered from the UI thread. Coordinates are program pixels (0..639,0..479). */
sealed class KInput {
    class Key(val ch: Int, val sc: Long, val down: Boolean) : KInput()
    class Mouse(val x: Int, val y: Int, val lb: Boolean, val rb: Boolean, val wheel: Int = 0) : KInput()
    object Break : KInput()
    /** Terminal: compile and run a command line on the shell task. */
    class Exec(val line: String) : KInput()
    /** A raw TempleOS message (menu selections). */
    class Raw(val code: Int, val a1: Long, val a2: Long) : KInput()
}

/** A program menu entry as seen by the UI (snapshot of the HolyC CMenu). */
class MenuSnap(val path: String, val label: String, val msgCode: Long, val a1: Long, val a2: Long, val checked: Boolean, val isDir: Boolean)

/**
 * One TempleOS "machine" for a single program window: a VM with the system
 * prelude, cooperative tasks, the window's console document, its 640x480
 * indexed screen, input messages and timing. Driven by [step] from one thread.
 */
class Kernel(val env: KernelEnv, val name: String, val shellMode: Boolean = false) {
    companion object {
        const val W = 640
        const val H = 480
        const val READY = 0
        const val SLEEP = 1
        /**
         * The shortest wait [step] asks for: a task due sooner is woken that much later at most (it was
         * 1 ms, which made every Sleep about 0.7 ms long on a phone, and songs drift; docs/audio).
         */
        const val WAKE_FLOOR_NS = 100_000L
        /** The most of a late wake-up a task's clock hides ([taskNow]). */
        const val MAX_LATE_NS = 20_000_000L
        const val WAIT_MSG = 2
        const val WAIT_FRAME = 3
        const val SUSPENDED = 4
        const val DEAD = 5
        const val WAIT_POPUP = 6
        const val FRAME_NS = 33_333_333L
        const val SLICE = 4000
        /**
         * A task that computes this long without yielding is preempted once so its window keeps
         * updating (TempleOS, which never preempts, would freeze the screen until it yields).
         */
        const val WATCHDOG_NS = 250_000_000L
        /** Kernel/KernelA.HH CTask.display_flags bits. */
        const val DISPLAYF_SHOW = 0
        const val DISPLAYF_NO_BORDER = 3
        /** Kernel/KernelA.HH message codes and window inhibit flags used by the window manager. */
        const val MSG_MS_MOVE = 4; const val MSG_MS_L_DOWN = 5; const val MSG_MS_L_UP = 6
        const val MSG_MS_L_D_DOWN = 7; const val MSG_MS_L_D_UP = 8; const val MSG_MS_R_DOWN = 9
        const val MSG_MS_R_UP = 10; const val MSG_MS_R_D_DOWN = 11; const val MSG_MS_R_D_UP = 12
        const val WIF_SELF_MS_L = 0x8L; const val WIF_SELF_MS_R = 0x20L; const val WIF_SELF_GRAB_SCROLL = 0x200L
        const val WIF_FOCUS_TASK_CTRLS = 0x40000L; const val WIF_FOCUS_TASK_GRAB_SCROLL = 0x2000000L
        const val WIF_FOCUS_TASK_MS_L = 0x80000L; const val WIF_FOCUS_TASK_MS_L_D = 0x100000L
        const val WIF_FOCUS_TASK_MS_R = 0x200000L; const val WIF_FOCUS_TASK_MS_R_D = 0x400000L
        /** WIG_USER_TASK_DFT (a terminal, where programs run) and WIG_TASK_DFT (Spawn). */
        const val WIG_USER_TASK_DFT = 0x1000L
        const val WIG_TASK_DFT = 0x52F3FFL
        /** Kernel/KMathB.HC LIN_CONGRUE_A/C and Kernel/KernelA.HH TASKf_NONTIMER_RAND. */
        const val LIN_CONGRUE_A = 6364136223846793005L
        const val LIN_CONGRUE_C = 1442695040888963407L
        const val TASKF_NONTIMER_RAND = 14
        private val COMPILER_CH = chCode("Compiler")
        private val STD_PALETTE = Palette.STD.copyOf(16)

        /** Shared lexed prelude defines (immutable tokens) to speed up boot. */
        @Volatile private var definesCache: Map<String, List<Token>>? = null
    }

    val vm = Vm(1 shl 20, env.memoryLimit)
    val mem get() = vm.mem
    val prog get() = vm.prog
    val console = Console()
    val fmt = Formatter(vm.mem)

    /** TempleOS DEFINE strings and lists (HTT_DEFINE_STR): data and sub-entry pointers live in the arena. */
    class DefStr(val data: Int, val cnt: Int, val subs: Int)
    val defineStrs = HashMap<String, DefStr>()

    fun defineSub(sub: Long, name: String): Int {
        val d = defineStrs[name] ?: return -1
        if (sub < 0 || sub >= d.cnt) return 0
        return mem.ld8(d.subs + sub.toInt() * 8).toInt()
    }

    init {
        vm.callbackBreak = ::pollBreakInCallback
        vm.callbackYield = ::yieldInCallback
        vm.sliceContinuation = ::continueSlice
        fmt.defineSub = { sub, nameAddr ->
            if (nameAddr == 0L) null else {
                val r = defineSub(sub, mem.readStr(nameAddr))
                if (r <= 0) null else mem.readStrBytes(r.toLong())
            }
        }
    }
    lateinit var font: ByteArray
    val tasks = ArrayList<Task>()
    val vga by lazy {VgaFramebuffer(this)}
    var current: Task? = null
        private set
    var mainTask: Task? = null
        private set
    private var nextTaskId = 1
    private val inputQ = ConcurrentLinkedQueue<KInput>()
    @Volatile var stopRequested = false
    @Volatile var finished = false
        private set
    var exitMessage: String? = null
        private set
    /** Why the program ended, one [ExitCategory] (the same on every engine for the same failure); null while it runs. */
    var exitCategory: String? = null
        private set
    var defines: MutableMap<String, List<Token>> = HashMap()

    // --- time
    private var bootNs = 0L
    /** When true (tests), sleeping fast-forwards time instead of waiting. */
    var virtualTime = false
    private var vtime = 0L
    fun now(): Long = if (virtualTime) vtime else env.nanoTime() - bootNs - pausedNs

    /**
     * Time the program spent paused (window menu > Pause, the app in the background, a hidden
     * window). TempleOS has no pause, so a paused program must not see that time pass: its timers,
     * physics and scores continue where they stopped (BomberGolf, CastleFrankenstein, RawHide).
     */
    @Volatile private var pausedNs = 0L
    @Volatile private var pausedAt = 0L

    /** Called by the runner when it pauses (true) or resumes (false) the kernel. */
    fun clockPaused(p: Boolean) {
        val t = env.nanoTime()
        if (p) { if (pausedAt == 0L) pausedAt = t }
        else if (pausedAt != 0L) { pausedNs += t - pausedAt; pausedAt = 0L }
    }
    /** cnts.jiffies now: one jiffy is 1192 PIT clocks, 0.999009 ms ([TempleClock]). */
    fun jiffies(): Long = TempleClock.jiffyAt(now())

    // --- graphics state
    /** Set when a program pushes/pops a menu (the UI rebuilds its menu bar). */
    @Volatile var menuChanged = false

    /** Set once the program uses graphics (DCAlias, draw_it, Gr*, text layer). */
    @Volatile var graphicsUsed = false
    /** True while every runnable task is blocked waiting for keyboard/mouse messages. */
    @Volatile var waitingForKey = false
    val textCells = IntArray(TEXT_COLS * TEXT_ROWS)
    private val frameBuf = ByteArray(W * H)
    /** Published frame for the UI (indexed 8-bit, palette in [palette]). */
    val published = ByteArray(W * H)
    @Volatile var publishedVersion = 0L
        private set
    /**
     * Screen rect of the main task's window in [published] (x, y, w, h; border included when
     * the window has one), written with the frame under [publishLock]. The UI shows this part of
     * the 640x480 screen, so programs keep TempleOS's window coordinates (Adam/Win.HC).
     */
    val publishedWindow = intArrayOf(0, 0, W, H)
    val palette = IntArray(16).also { System.arraycopy(Palette.STD, 0, it, 0, 16) }
    var frameCount = 0L
        private set
    private var nextFrameAt = 0L
    var fps = 0.0
        private set
    /** Frame composition and task timing (frame-rate readout, benchmarks). */
    val frameStats = FrameStats()
    /** Speaker frequency changes Snd() passed to the platform (benchmarks, perf log). */
    @Volatile var speakerChanges = 0L
    private var lastSpeakerNs = Long.MIN_VALUE

    /**
     * Sets the PC speaker for [t]'s Snd(). The change is dated when TempleOS would have made it: a task
     * woken from Sleep/SleepUntil runs at its jiffy there, here as late as the host thread woke ([Task.lateNs],
     * about 1 ms, more under load), so that much is taken off. Rests and notes then keep the program's own
     * timing (Play's 20 ms gaps), whatever the wake-up jitter. One kernel's changes never go back in time.
     */
    fun speaker(t: Task?, freq: Double) {
        var at = env.nanoTime() - (t?.lateNs ?: 0L)
        if (at < lastSpeakerNs) at = lastSpeakerNs
        lastSpeakerNs = at
        env.sound(this, freq, at)
    }

    /**
     * The program is gone (ended, stopped, closed): its speaker setting is off. TempleOS leaves a tone a
     * program left on sounding after it ends; here a window that ended never keeps sounding.
     */
    fun silence() = env.sound(this, 0.0, env.nanoTime())

    /**
     * Entry of TempleOS's sound-effect task (Adam/ASnd.HC SoundEffectTask, spawned by Noise() and
     * Sweep()); tasks started there get [Task.speakerTask] (see the Sleep native).
     */
    var soundEffectFp = 0L
        private set

    // --- message queue (TempleOS task messages)
    class Msg(val code: Int, val a1: Long, val a2: Long)
    val msgs = ArrayDeque<Msg>()

    // --- offsets resolved after the prelude is compiled
    lateinit var o: Offsets
    lateinit var gfx: Gfx
    lateinit var raster: Raster
    lateinit var natives: Natives
    lateinit var sys: NativesSys

    val TEXT_COLS get() = 80
    val TEXT_ROWS get() = 60

    // ------------------------------------------------------------ boot

    /** Compiles the system prelude and initialises the TempleOS globals. */
    lateinit var sources: SourceServices
        private set
    val dictionary: TempleDictionary by lazy {TempleDictionary(this)}
    lateinit var documents: DocumentRuntime
        private set

    fun boot() {
        bootNs = env.nanoTime()
        font = env.runtimeFile("font8x8.bin") ?: error("font8x8.bin missing")
        natives = Natives(this)
        natives.register(vm.natives)
        sys = NativesSys(this)
        sys.register(vm.natives)
        documents=DocumentRuntime(this);documents.register(vm.natives)
        sources=SourceServices(this);sources.register(vm.natives)
        val provider = SourceProvider { path ->
            val n = path.substringAfterLast('/')
            env.runtimeFile(n)
        }
        val cached = definesCache
        val nb = native
        if (nb != null) {
            val init = nb.bootPrelude(this)
            o = Offsets(this)
            gfx = Gfx(this)
            raster = Raster(this)
            runInit(init)
            initGlobals()
        } else if (cached != null) {
            val prelude = env.runtimeFile("Prelude.HC") ?: error("Prelude.HC missing")
            defines = HashMap(cached)
            // skip the #include of the defines: compile a copy of the prelude without it
            val txt = latin1(prelude).replace("#include \"PreludeDefines.HC\"", "")
            val init = prog.compile(SourceFile.parse("::/Prelude.HC", latin1(txt)), "C:/Runtime", provider, defines, allowNative = true)
            o = Offsets(this)
            gfx = Gfx(this)
            raster = Raster(this)
            runInit(init)
            initGlobals()
        } else {
            val prelude = env.runtimeFile("Prelude.HC") ?: error("Prelude.HC missing")
            val init = prog.compile(SourceFile.parse("::/Prelude.HC", prelude), "C:/Runtime", provider, defines, allowNative = true)
            definesCache = HashMap(defines)
            o = Offsets(this)
            gfx = Gfx(this)
            raster = Raster(this)
            runInit(init)
            initGlobals()
        }
        soundEffectFp = (prog.globals["SoundEffectTask"] as? FuncSym)?.let { prog.funcPtr(it) } ?: 0L
        console.setColors(Console.DFT_FG, Console.DFT_BG)
        prog.evalAtCompileTime = { e ->
            try {
                val f = prog.compileExprFunc(e)
                val t = current?.takeIf { it.state != DEAD } ?: adamTask
                if (t == null) null else vm.callFunction(t, prog.funcPtr(f))
            } catch (ex: RuntimeException) { null }
        }
        prog.serviceHandler={if(it=="dictionary") dictionary.initialize()}
        preludeGlobals = prog.globals.entries.filter { it.value is GlobalSym }.mapTo(HashSet()) { it.key }
    }

    /**
     * Names of the system's global variables (the prelude's), recorded at the end of [boot]: the
     * native dynamic expression engine lets ExePrint text use only the program's own globals.
     */
    var preludeGlobals: Set<String> = emptySet()
        private set

    /** Native evaluation of ExePrint/ExePrint2 text in a native kernel (core/dynexpr), with its cache and counters. */
    val dynExpr: io.github.templeosmobile.core.dynexpr.DynExprEngine by lazy { io.github.templeosmobile.core.dynexpr.DynExprEngine(this) }
    /** ExePrint/ExePrint2 calls evaluated natively by [dynExpr] (provenance). */
    val dynExprEvaluations: Long get() = dynExpr.stats.evaluations
    /** Texts [dynExpr] lexed, parsed and checked (the rest came from its cache). */
    val dynExprCompiles: Long get() = dynExpr.stats.compiles

    private fun initGlobals() {
        vm.exceptChOff = o.task("except_ch")
        vm.catchExceptOff = o.task("catch_except")
        jiffiesAddr = o.cntsAddr + o.member("CCntsGlbls", "jiffies")
        timerAddr = o.cntsAddr + o.member("CCntsGlbls", "timer")
        mem.st8(o.cntsAddr + o.member("CCntsGlbls", "time_stamp_freq"), 1_000_000_000L)
        mem.st8(o.cntsAddr + o.member("CCntsGlbls", "time_stamp_kHz_freq"), 1_000_000L)
        // winmgr.fps
        mem.st8(o.winmgrAddr + o.member("CWinMgrGlbls", "fps"), 30.0.toRawBits())
        mem.st8(o.msAddr + o.member("CMsStateGlbls", "dbl_time"), 0.350.toRawBits()) // Kernel/SerialDev/Mouse.HC
        // a wheel mouse, as TempleOS finds on a PC (and on QEMU's PS/2 mouse); the WHL buttons and
        // pointer wheels turn it
        mem.st1(o.msAddr + o.member("CMsStateGlbls", "has_wheel"), 1)
        mem.st1(o.msAddr + o.member("CMsStateGlbls", "show"), 1)
        // Kernel/SerialDev/Mouse.HC MsHardInit: the pointer starts in the middle of the screen (programs
        // that draw at the pointer, like TicTacToe's cursor, show it there at once; reference VM)
        val ms = o.msAddr
        mem.st8(ms + o.msPos, (W / 2).toLong()); mem.st8(ms + o.msPos + 8, (H / 2).toLong())
        mem.st8(ms + o.msPresnap, (W / 2).toLong()); mem.st8(ms + o.msPresnap + 8, (H / 2).toLong())
        mem.st8(ms + o.msPosText, (W / 2 / 8).toLong()); mem.st8(ms + o.msPosText + 8, (H / 2 / 8).toLong())
        hwLastX = (W / 2).toLong(); hwLastY = (H / 2).toLong()
        qPresnapX = (W / 2).toLong(); qPresnapY = (H / 2).toLong()
        mem.st8(o.global("sys_mobile_platform"), prog.stringAddr(latin1(Brand.APP_NAME)).toLong())
        gfx.initScreens()
        val textG = o.global("text")
        mem.st8(textG + o.member("CTextGlbls", "rows"), TEXT_ROWS.toLong())
        mem.st8(textG + o.member("CTextGlbls", "cols"), TEXT_COLS.toLong())
        mem.st8(textG + o.member("CTextGlbls", "font"), gfx.fontAddr.toLong())
        val bc = textG + o.member("CTextGlbls", "border_chars")
        for (i in 2..13) mem.st1(bc + i, i.toLong())
        val cpu = mem.calloc(o.cls("CCPU").size.toLong())
        hostCpuAddr = cpu
        mem.st8(cpu + o.member("CCPU", "addr"), cpu.toLong())
        mem.st8(o.global("Gs"), cpu.toLong())
        callHolyC("GrSetUpPens")
    }

    private fun runInit(init: FuncSym) {
        val t = newTask("Prelude", null)
        vm.pushCall(t, init.index.toLong(), LongArray(0))
        setCurrent(t)
        var guard = 0
        while (true) {
            val r = vm.run(t, 1_000_000)
            if (r == Vm.R_DONE) break
            if (r == Vm.R_DEAD) error("prelude failed: ${t.deathMessage}")
            if (++guard > 1000) error("prelude did not finish")
        }
        tasks.remove(t)
        adamTask = t
        t.state = READY
        mem.st8(o.global("adam_task"), t.fsAddr.toLong())
    }

    /**
     * Calls a HolyC function by name with all arguments supplied (no defaults), on [task], else on the
     * current task, else on the Adam task. Never on a task that has ended: its stack may already belong to
     * a new task (a frame pushed there overwrote a just-spawned Noise task's argument: BadMem in Whap).
     */
    fun callHolyC(name: String, vararg args: Long, task: Task? = null): Long {
        val f = prog.globals[name] as? FuncSym ?: error("HolyC function $name missing")
        val t = task ?: current?.takeIf { it.state != DEAD } ?: adamTask ?: error("no task")
        val saved = current
        try {
            if (task != null) setCurrent(task)
            return vm.callFunction(t, prog.funcPtr(f), *args)
        } finally {
            if (task != null && saved != null) setCurrent(saved)
        }
    }

    var adamTask: Task? = null
        private set

    // ------------------------------------------------------------ tasks

    fun newTask(name: String, parent: Task?): Task {
        val t = Task(vm, nextTaskId++, name)
        if (::o.isInitialized) {
            val sz = o.cls("CTask").size.toLong()
            val fs = mem.calloc(sz)
            t.fsAddr = fs
            val m = mem
            m.st8(fs + o.task("addr"), fs.toLong())
            m.st4(fs + o.task("task_signature"), chCode("TskS"))
            m.st8(fs + o.task("task_num"), t.id.toLong())
            m.st8(fs + o.task("rand_seed"), rng.nextLong())
            val nm = latin1(name)
            val tn = fs + o.task("task_name")
            for (i in 0 until minOf(nm.size, 31)) m.st1(tn + i, nm[i].toLong())
            val tt = fs + o.task("task_title")
            for (i in 0 until minOf(nm.size, 100)) m.st1(tt + i, nm[i].toLong())
            m.st1(fs + o.task("text_attr"), ((Console.DFT_BG shl 4) or Console.DFT_FG).toLong())
            m.st1(fs + o.task("border_attr"), ((Console.DFT_BG shl 4) or 1).toLong())
            // Kernel/KTask.HC: Spawn gives WIG_TASK_DFT; a program runs in the user's terminal task (WIG_USER_TASK_DFT)
            m.st4(fs + o.task("win_inhibit"), if (parent != null) WIG_TASK_DFT else WIG_USER_TASK_DFT)
            if (parent != null && parent.fsAddr != 0) {
                m.st8(fs + o.task("parent_task"), parent.fsAddr.toLong())
                m.st8(fs + o.task("cur_dir"), m.ld8(parent.fsAddr + o.task("cur_dir")))
            } else {
                m.st8(fs + o.task("cur_dir"), prog.stringAddr(latin1("C:/Home")).toLong())
            }
            setWindow(t)
            if (adamTask != null || prog.globals.containsKey("MobileTaskInit")) {
                try { callHolyC("MobileTaskInit", fs.toLong(), task = adamTask ?: t) } catch (e: RuntimeException) {}
            }
        }
        t.state = READY
        tasks.add(t)
        return t
    }

    /**
     * Initial window: a maximized TempleOS terminal with its border (what WinMax gives a bordered
     * window: text columns 1..78, rows 2..58, so pix 8..631 x 16..471). Programs then change it
     * with the original WinBorder/WinMax/WinHorz/WinVert (Prelude.HC).
     */
    fun setWindow(t: Task) {
        val m = mem; val fs = t.fsAddr
        val l = 1L; val r = (TEXT_COLS - 2).toLong(); val top = 2L; val b = (TEXT_ROWS - 2).toLong()
        m.st8(fs + o.task("win_left"), l); m.st8(fs + o.task("win_right"), r)
        m.st8(fs + o.task("win_top"), top); m.st8(fs + o.task("win_bottom"), b)
        m.st8(fs + o.task("win_width"), r - l + 1); m.st8(fs + o.task("win_height"), b - top + 1)
        m.st8(fs + o.task("pix_left"), l * 8); m.st8(fs + o.task("pix_right"), (r + 1) * 8 - 1)
        m.st8(fs + o.task("pix_width"), (r - l + 1) * 8)
        m.st8(fs + o.task("pix_top"), top * 8); m.st8(fs + o.task("pix_bottom"), (b + 1) * 8 - 1)
        m.st8(fs + o.task("pix_height"), (b - top + 1) * 8)
        m.st4(fs + o.task("display_flags"), 1L shl DISPLAYF_SHOW)
    }

    /** Window of task [fs] in text cells: (left, top, right, bottom, hasBorder). */
    private fun windowCells(fs: Int): IntArray {
        val m = mem
        val border = m.ld4(fs + o.task("display_flags")) and (1L shl DISPLAYF_NO_BORDER) == 0L
        // program-writable: clamp to the screen (a TempleOS window never extends past it)
        fun cl(v: Long, hi: Int) = v.coerceIn(-1L, hi.toLong()).toInt()
        return intArrayOf(cl(m.ld8(fs + o.task("win_left")), TEXT_COLS), cl(m.ld8(fs + o.task("win_top")), TEXT_ROWS),
            cl(m.ld8(fs + o.task("win_right")), TEXT_COLS), cl(m.ld8(fs + o.task("win_bottom")), TEXT_ROWS), if (border) 1 else 0)
    }

    fun setCurrent(t: Task) {
        current = t
        if (::o.isInitialized) mem.st8(o.fsGlobal, t.fsAddr.toLong())
    }

    fun taskByFs(addr: Long): Task? = tasks.firstOrNull { it.fsAddr.toLong() == addr }
        ?: (if (adamTask?.fsAddr?.toLong() == addr) adamTask else null)

    // ------------------------------------------------------------ program loading

    /** Compiles [src] (a .HC file) and starts it as the main task. */
    private var launchEntry:String?=null
    private var launchArgs=LongArray(0)
    fun runProgram(path: String, src: ByteArray) {
        env.runtimeFile("home-profile.tsv")?.let {bytes ->
            for(line in latin1(bytes).lines()) {
                val fields=line.split('\t');if(fields.size!=2 || !path.startsWith(fields[0],true)) continue
                val home=Paths.normalize("C:/Home",fields[1]) ?: continue
                if(home.startsWith("C:/Home/") && env.fs?.isDir(home)==false) env.fs?.mkdir(home)
            }
        }
        val dir = path.substringBeforeLast('/', "C:/Home")
        val t = newTask(path.substringAfterLast('/').substringBefore('.'), null)
        mainTask = t
        setCurrent(t)
        termInit(t)
        env.runtimeFile("program-launch.tsv")?.let {data ->
            val row=latin1(data).lines().map {it.split('\t')}.firstOrNull {it.size>=3 && it[0].equals(path,true)}
            if(row!=null) {
                launchEntry=row[2];launchArgs=row.drop(3).take(8).map {arg ->
                    if(arg.startsWith("i")) arg.drop(1).toLong()
                    else prog.stringAddr(arg.drop(1).chunked(2).map {it.toInt(16).toByte()}.toByteArray()).toLong()
                }.toLongArray()
                if(row[1]=="adam-resident") {mem.st8(o.global("adam_task"),t.fsAddr.toLong());mem.st8(o.global("sys_winmgr_task"),t.fsAddr.toLong())}
            }
        }
        mem.st8(t.fsAddr + o.task("cur_dir"), prog.stringAddr(latin1(dir)).toLong())
        try {
            session = native?.session(this) ?: prog.session(SourceFile.parse(path, src), dir, vfsProvider(), defines)
            if (!advanceSession(t)) { t.state = DEAD; finished = true }
        } catch (e: CompileError) {
            compileFailed(t, e)
        } catch (f: VmFault) { // e.g. allocating a string constant in a corrupted heap, or globals that do not fit
            loadFailed(t, f)
        }
    }

    /** A fault while the program's source was compiled or its translated image loaded (not raised by its code). */
    private fun loadFailed(t: Task, f: VmFault) {
        classifyDeath(t, ExitCategory.of(f.ch, f.message, loading = true))
        taskDied(t, f.message ?: "fault")
    }

    /**
     * A program runs in the user's terminal task, which Adam/DolDoc/DocTerm.HC DocTermNew gives the
     * window's two scroll bars (WinScrollsInit): they are drawn on the border, take clicks and the
     * wheel there, and programs such as ScrollBars and Transform read their positions.
     */
    private fun termInit(t: Task) {
        if (prog.globals.containsKey("WinScrollsInit"))
            try { callHolyC("WinScrollsInit", t.fsAddr.toLong(), task = t) } catch (_: RuntimeException) {}
    }

    /** The unit being executed on the main task, chunk by chunk (TempleOS JIT order). */
    private var session: ChunkSource? = null

    /**
     * Translator (build time): compiles the rest of the program's source without running it, as the
     * translator compiles every program, once the program has run past the point where its source
     * depended on run-time state. Returns the number of chunks compiled.
     */
    fun compileRestOfProgram(): Int {
        var n = 0
        while (true) {
            val s = session ?: return n
            if (s.next() == null) { session = null; return n }
            n++
        }
    }

    /**
     * Pure Kotlin mode: the prelude and the program come from their ahead-of-time translation
     * (purenative), and no HolyC is compiled or interpreted in this kernel. Set before [boot].
     */
    var native: io.github.templeosmobile.core.purenative.NativeBinding? = null
        set(v) { check(!::natives.isInitialized) { "set native before boot" }; field = v }

    /** True when this kernel runs translated native code (Pure Kotlin mode). */
    val isNative get() = native != null

    private fun compileFailed(t: Task, e: CompileError) {
        console.write("\$RED\$Compile error: ${e.message}\$FG\$\n")
        exitMessage = e.message
        if (!shellMode) exitCategory = ExitCategory.COMPILE_ERROR
        session = null
        if (shellMode) { busy = false; t.state = DEAD; shellPrompt() } else { t.state = DEAD; finished = true; tasks.clear() }
    }

    /** Compiles and queues the next chunk of the session on [t]. Returns false when done. */
    private fun advanceSession(t: Task): Boolean {
        val s = session ?: return false
        var args=LongArray(0)
        val f = s.next() ?: run {
            val entry=launchEntry;launchEntry=null
            if(entry==null) {session=null;return false}
            args=launchArgs
            prog.globals[entry] as? FuncSym ?: throw CompileError("Launch entry point missing: $entry")
        }
        chunkStartNs = now()
        t.depth = 0; t.sp = 0; t.hCount = 0; t.handlerBase = 0
        t.msp = t.mspBase; t.fp = t.mspBase
        vm.pushCall(t, f.index.toLong(), args)
        t.state = READY
        return true
    }

    /** Shell mode: compiles and runs one command line on the shell task. */
    fun execLine(line: String): Boolean {
        val t = mainTask ?: newTask("Terminal", null).also { mainTask = it; setCurrent(it); termInit(it) }
        if (t.state != DEAD && t.depth > 0) return false // still running
        val dir = curDir(t)
        try {
            session = prog.session(SourceFile.parse("C:/Home/Cmd.HC", latin1(line + "\n")), dir, vfsProvider(), defines, answers = true)
            t.deathMessage = null
            answerKind = -1
            busy = true
            if (!advanceSession(t)) { busy = false; t.state = DEAD; shellPrompt(); return true }
        } catch (f: VmFault) {
            console.write("\$RED\$${f.message}\$FG\$\n")
            session = null
            t.state = DEAD
            busy = false
            return false
        } catch (e: CompileError) {
            console.write("\$RED\$${e.message}\$FG\$\n")
            session = null
            t.state = DEAD
            busy = false
            return false
        }
        return true
    }

    /** True while a shell command is executing. */
    @Volatile var busy = false
        private set

    fun curDir(t: Task): String = mem.readStr(mem.ld8(t.fsAddr + o.task("cur_dir"))).ifEmpty { "C:/Home" }

    fun vfsProvider() = SourceProvider { path -> env.fs?.readFile(path) }

    // ------------------------------------------------------------ input (UI thread)

    @Volatile var lastInteractionNanos=0L
        private set

    fun post(e: KInput) {
        inputQ.add(e)
        wakeLock?.let { synchronized(it) { (it as Object).notifyAll() } }
    }

    /** Monitor the runner waits on; notified by [post]. */
    var wakeLock: Any? = null

    private var lastLb = false
    private var lastRb = false

    private var lbDownFrame = 0L
    private var rbDownFrame = 0L
    private var deferredMouse: KInput.Mouse? = null
    private val keyDownFrame = LongArray(256)
    private val pendingKeyUps = HashSet<Int>()

    private fun releaseKeyBit(bit: Int) {
        val bm = o.kbdAddr + o.member("CKbdStateGlbls", "down_bitmap")
        val bm2 = o.kbdAddr + o.member("CKbdStateGlbls", "down_bitmap2")
        val mask = 1L shl (bit and 7)
        mem.st1(bm + (bit shr 3), mem.ld1(bm + (bit shr 3)) and mask.inv())
        mem.st1(bm2 + (bit shr 3), mem.ld1(bm2 + (bit shr 3)) and mask.inv())
    }

    /**
     * The mouse driver's update of the ms globals (Kernel/SerialDev/Mouse.HC MsUpdate, MsHardSpeedSet).
     * [e] is in screen pixels (the UI maps touches into [publishedWindow]). Messages are queued once
     * per frame by [queueInputMsgs], as TempleOS's window manager does.
     */
    private fun applyMouse(e: KInput.Mouse) {
        val ms = o.msAddr
        val z = mem.ld8(ms + o.msPos + 16) + e.wheel
        msUpdate(e.x.toLong(), e.y.toLong(), z, e.lb, e.rb)
    }

    private var hwLastX = 0L; private var hwLastY = 0L; private var hwLastAt = 0L
    private var hwSpeed = 0.0
    private var msEvt = false

    /** Kernel/SerialDev/Mouse.HC MsUpdate (including grid snap) plus the hardware speed (pixels per second). */
    fun msUpdate(x0: Long, y0: Long, z: Long, lb: Boolean, rb: Boolean) {
        val ms = o.msAddr
        val grid=o.global("ms_grid")
        fun snap(v:Long,axis:String):Long {if(mem.ld1(grid+o.member("CGridGlbls","snap"))==0L) return v
            val step=Double.fromBits(mem.ld8(grid+o.member("CGridGlbls",axis)));val off=Double.fromBits(mem.ld8(grid+o.member("CGridGlbls",axis+"_offset")))
            return if(step>0 && step.isFinite() && off.isFinite()) (kotlin.math.truncate(v/step)*step+off).toLong() else v}
        val x = snap(x0,"x").coerceIn(0, (W - 1).toLong()); val y = snap(y0,"y").coerceIn(0, (H - 1).toLong())
        val moved = x != mem.ld8(ms + o.msPos) || y != mem.ld8(ms + o.msPos + 8) || z != mem.ld8(ms + o.msPos + 16)
        mem.st8(ms + o.msPresnap, x0); mem.st8(ms + o.msPresnap + 8, y0); mem.st8(ms + o.msPresnap + 16, z)
        mem.st8(ms + o.msPos, x); mem.st8(ms + o.msPos + 8, y); mem.st8(ms + o.msPos + 16, z)
        mem.st8(ms + o.msPosText, x / 8); mem.st8(ms + o.msPosText + 8, y / 8)
        val changed = moved || (mem.ld1(ms + o.msLb) != 0L) != lb || (mem.ld1(ms + o.msRb) != 0L) != rb
        mem.st1(ms + o.msLb, if (lb) 1 else 0)
        mem.st1(ms + o.msRb, if (rb) 1 else 0)
        val sca = o.kbdAddr + o.member("CKbdStateGlbls", "scan_code")
        var sc = mem.ld8(sca) and (Keys.SCF_MS_L_DOWN or Keys.SCF_MS_R_DOWN).inv()
        if (lb) sc = sc or Keys.SCF_MS_L_DOWN
        if (rb) sc = sc or Keys.SCF_MS_R_DOWN
        mem.st8(sca, sc)
        if (lb && !lastLb) lbDownFrame = frameCount
        if (rb && !lastRb) rbDownFrame = frameCount
        lastLb = lb; lastRb = rb
        if (moved) { // MsHardSpeedSet: distance over the time since the last motion (or boot)
            val now = now()
            val dd = (x - hwLastX) * (x - hwLastX) + (y - hwLastY) * (y - hwLastY)
            if (dd != 0L && now > hwLastAt) hwSpeed = Math.sqrt(dd.toDouble()) * 1e9 / (now - hwLastAt)
            hwLastX = x; hwLastY = y; hwLastAt = now
        }
        if (changed) msEvt = true
    }

    /** Adam/Win.HC WinMsUpdate: ms.speed follows the hardware while it moves and decays by 5% a frame. */
    private fun winMsUpdate() {
        val ms = o.msAddr
        val sp = o.member("CMsStateGlbls", "speed")
        if (msEvt) {
            mem.st8(ms + sp, hwSpeed.toRawBits())
            mem.st8(ms + o.member("CMsStateGlbls", "timestamp"), now())
            msEvt = false
        } else mem.st8(ms + sp, (java.lang.Double.longBitsToDouble(mem.ld8(ms + sp)) * 0.95).toRawBits())
    }

    // Adam/WinMgr.HC WinQueIPMsgs state (ms.left_dbl_time etc.) and its ms_last buttons.
    private var leftDblAt = 0L; private var leftDbl = false; private var leftDownSent = false
    private var rightDblAt = 0L; private var rightDbl = false; private var rightDownSent = false
    private var singleLx = 0L; private var singleLy = 0L; private var singleRx = 0L; private var singleRy = 0L
    private var qLastLb = false; private var qLastRb = false
    private var qPresnapX = 0L; private var qPresnapY = 0L
    private var grabbing = false; private var grabX = 0L; private var grabY = 0L; private var grabZ = 0L

    /**
     * One window manager pass over the mouse (Adam/WinMgr.HC WinMgrTask, once per frame):
     * CTRL + left drag scrolls the window ("grab scroll", CTRL + right button resets it) unless the
     * task sets WIF_SELF_GRAB_SCROLL; otherwise the messages of WinQueIPMsgs are queued, except while
     * the pointer is on one of the task's controls (the control gets the click instead).
     */
    private fun queueInputMsgs() {
        val t = mainTask ?: return
        val fs = t.fsAddr
        val inhibit = mem.ld4(fs + o.task("win_inhibit"))
        val ms = o.msAddr
        val ctrlHeld = mem.ld8(o.kbdAddr + o.member("CKbdStateGlbls", "scan_code")) and Keys.SCF_CTRL != 0L
        if (ctrlHeld && inhibit and (WIF_SELF_GRAB_SCROLL or WIF_FOCUS_TASK_GRAB_SCROLL) == 0L) {
            val x = mem.ld8(ms + o.msPos); val y = mem.ld8(ms + o.msPos + 8); val z = mem.ld8(ms + o.msPos + 16)
            if (lastLb) {
                if (!grabbing) {
                    grabbing = true
                    grabX = x - mem.ld8(fs + o.task("scroll_x")); grabY = y - mem.ld8(fs + o.task("scroll_y")); grabZ = z - mem.ld8(fs + o.task("scroll_z"))
                }
                mem.st8(fs + o.task("scroll_x"), (x - grabX) and 7L.inv())
                mem.st8(fs + o.task("scroll_y"), (y - grabY) and 7L.inv())
                mem.st8(fs + o.task("scroll_z"), z - grabZ)
            } else {
                grabbing = false
                if (lastRb) { mem.st8(fs + o.task("scroll_x"), 0); mem.st8(fs + o.task("scroll_y"), 0); mem.st8(fs + o.task("scroll_z"), 0) }
            }
            // the window manager stays in its grab loop: no messages, and the button edges are used up
            qLastLb = lastLb; qLastRb = lastRb
            qPresnapX = mem.ld8(ms + o.msPresnap); qPresnapY = mem.ld8(ms + o.msPresnap + 8)
            return
        }
        grabbing = false
        val que = inhibit and WIF_FOCUS_TASK_CTRLS != 0L || !msOnCtrl(t)
        val px = mem.ld8(ms + o.msPresnap); val py = mem.ld8(ms + o.msPresnap + 8)
        if (px != qPresnapX || py != qPresnapY) {
            qPresnapX = px; qPresnapY = py
            if (que) {
                val x = mem.ld8(ms + o.msPos); val y = mem.ld8(ms + o.msPos + 8)
                enqueue(Msg(MSG_MS_MOVE, x - mem.ld8(fs + o.task("pix_left")) - mem.ld8(fs + o.task("scroll_x")),
                    y - mem.ld8(fs + o.task("pix_top")) - mem.ld8(fs + o.task("scroll_y"))))
            }
        }
        queueButtonMsgs(que)
    }

    /** True when ms.pos is on one of [t]'s controls (CtrlInside, Adam/Ctrls/CtrlsA.HC). */
    private fun msOnCtrl(t: Task): Boolean =
        try { callHolyC("MobileTaskHasCtrls", t.fsAddr.toLong(), task = t) != 0L && callHolyC("MobileMsInCtrl", t.fsAddr.toLong(), task = t) != 0L }
        catch (_: RuntimeException) { false }

    /**
     * Button messages exactly as TempleOS's window manager queues them (Adam/WinMgr.HC WinQueIPMsgs),
     * run after every mouse event and every frame. Unless the focus task sets WIF_FOCUS_TASK_MS_L_D
     * (WIG_DBL_CLICK, part of WIG_TASK_DFT), a click is held for ms.dbl_time (0.350 s) to see whether a
     * second one follows: then MSG_MS_L_D_DOWN/UP, else a late MSG_MS_L_DOWN at the first click's
     * position. A double click inside the window of a task that does not set WIF_SELF_MS_L is the ESC
     * key (right button: SHIFT-ESC), as the WinMgr task does for document windows.
     */
    private fun queueButtonMsgs(que: Boolean) {
        val t = mainTask ?: return
        val fs = t.fsAddr
        val inhibit = mem.ld4(fs + o.task("win_inhibit"))
        val ms = o.msAddr
        val x = mem.ld8(ms + o.msPos); val y = mem.ld8(ms + o.msPos + 8)
        val ox = mem.ld8(fs + o.task("pix_left")) + mem.ld8(fs + o.task("scroll_x"))
        val oy = mem.ld8(fs + o.task("pix_top")) + mem.ld8(fs + o.task("scroll_y"))
        val a1 = x - ox; val a2 = y - oy
        // ms.dbl_time is program-writable: only a sane value is used
        val dblS = java.lang.Double.longBitsToDouble(mem.ld8(ms + o.member("CMsStateGlbls", "dbl_time")))
        val dbl = if (dblS.isFinite() && dblS > 0 && dblS < 1e6) (dblS * 1e9).toLong() else 0L
        val now = now()
        val lb = lastLb; val rb = lastRb
        fun enqueue(m: Msg) { if (que) this.enqueue(m) }
        fun inside() = x in mem.ld8(fs + o.task("pix_left"))..mem.ld8(fs + o.task("pix_right")) &&
            y in mem.ld8(fs + o.task("pix_top"))..mem.ld8(fs + o.task("pix_bottom"))
        // left button
        if (leftDblAt != 0L) {
            if (now > leftDblAt) {
                if (leftDbl) {
                    if (!leftDownSent) { enqueue(Msg(MSG_MS_L_D_DOWN, a1, a2)); leftDownSent = true }
                    if (!lb) {
                        enqueue(Msg(MSG_MS_L_D_UP, a1, a2)); leftDblAt = 0
                        if (inhibit and (WIF_SELF_MS_L or WIF_FOCUS_TASK_MS_L) == 0L && inside()) enqueue(Msg(2, Keys.CH_ESC.toLong(), 0))
                    }
                } else {
                    if (!leftDownSent) { enqueue(Msg(MSG_MS_L_DOWN, singleLx - ox, singleLy - oy)); leftDownSent = true }
                    if (!lb) { enqueue(Msg(MSG_MS_L_UP, a1, a2)); leftDblAt = 0 }
                }
            } else if (lb && !qLastLb) { leftDblAt = now; leftDbl = true }
        } else if (inhibit and WIF_FOCUS_TASK_MS_L_D != 0L) {
            if (lb && !qLastLb) enqueue(Msg(MSG_MS_L_DOWN, a1, a2))
            else if (!lb && qLastLb) enqueue(Msg(MSG_MS_L_UP, a1, a2))
        } else if (lb && !qLastLb) {
            leftDbl = false; leftDownSent = false; leftDblAt = now + dbl; singleLx = x; singleLy = y
        }
        // right button
        if (rightDblAt != 0L) {
            if (now > rightDblAt) {
                if (rightDbl) {
                    if (!rightDownSent) { enqueue(Msg(MSG_MS_R_D_DOWN, a1, a2)); rightDownSent = true }
                    if (!rb) {
                        enqueue(Msg(MSG_MS_R_D_UP, a1, a2)); rightDblAt = 0
                        if (inhibit and (WIF_SELF_MS_R or WIF_FOCUS_TASK_MS_R) == 0L && inside()) enqueue(Msg(2, Keys.CH_SHIFT_ESC.toLong(), 0))
                    }
                } else {
                    if (!rightDownSent) { enqueue(Msg(MSG_MS_R_DOWN, singleRx - ox, singleRy - oy)); rightDownSent = true }
                    if (!rb) { enqueue(Msg(MSG_MS_R_UP, a1, a2)); rightDblAt = 0 }
                }
            } else if (rb && !qLastRb) { rightDblAt = now; rightDbl = true }
        } else if (inhibit and WIF_FOCUS_TASK_MS_R_D != 0L) {
            if (rb && !qLastRb) enqueue(Msg(MSG_MS_R_DOWN, a1, a2))
            else if (!rb && qLastRb) enqueue(Msg(MSG_MS_R_UP, a1, a2))
        } else if (rb && !qLastRb) {
            rightDbl = false; rightDownSent = false; rightDblAt = now + dbl; singleRx = x; singleRy = y
        }
        qLastLb = lb; qLastRb = rb
    }

    private fun processInput() {
        while (true) {
            val e = inputQ.poll() ?: break
            lastInteractionNanos=now()
            if(e !is KInput.Mouse)menuRefreshFrames=2
            when (e) {
                is KInput.Key -> {
                    val code = (e.sc and 0xFF).toInt()
                    // Kernel/SerialDev/Keyboard.HC KbdBuildSC: SHIFT/CTRL/ALT held down are flags of every
                    // scan code until released, and ASCII comes from the scan code (KbdMsgsQue)
                    when (code) {
                        Keys.SC_SHIFT -> heldMods = if (e.down) heldMods or Keys.SCF_SHIFT else heldMods and Keys.SCF_SHIFT.inv()
                        Keys.SC_CTRL -> heldMods = if (e.down) heldMods or Keys.SCF_CTRL else heldMods and Keys.SCF_CTRL.inv()
                        Keys.SC_ALT -> heldMods = if (e.down) heldMods or Keys.SCF_ALT else heldMods and Keys.SCF_ALT.inv()
                    }
                    var esc = e.sc; var ech = e.ch
                    if (heldMods and esc.inv() != 0L) {
                        esc = esc or heldMods
                        Keys.scanCode2Char(esc and (Keys.SCF_SHIFT or Keys.SCF_CTRL or 0x7F)).let { if (it != 0) ech = it }
                    }
                    // CTRL-ALT-letter (ESC='t', TAB='n') is the system's, never the program's (KbdBuildSC)
                    if (e.down && esc and Keys.SCF_CTRL != 0L && esc and Keys.SCF_ALT != 0L) {
                        val c = when (code) { Keys.SC_ESC -> 't'.code; Keys.SC_TAB -> 'n'.code; else -> Keys.scanCode2Char(code.toLong()) }
                        if (c in 'a'.code..'z'.code) { ctrlAlt(c.toChar()); continue }
                    }
                    val sc = esc and 0xFF
                    val bm = o.kbdAddr + o.member("CKbdStateGlbls", "down_bitmap")
                    val bm2 = o.kbdAddr + o.member("CKbdStateGlbls", "down_bitmap2")
                    val bit = sc.toInt()
                    // down_bitmap: merged scan code; down_bitmap2: the raw one, with bit 7 for E0 keys
                    val bit2 = if (Keys.isE0(bit)) bit or 0x80 else bit
                    val w = bm + (bit shr 3)
                    val w2 = bm2 + (bit2 shr 3)
                    val mask = 1L shl (bit and 7)
                    val mask2 = 1L shl (bit2 and 7)
                    if (e.down) {
                        // the quick-tap latch below counts from the first press, not from typematic repeats:
                        // a held key's release must clear the bit at once (TempleOS clears it before queuing
                        // the key-up, so Titanium's gun does not re-tilt)
                        if (mem.ld1(w) and mask == 0L) keyDownFrame[bit] = frameCount
                        mem.st1(w, mem.ld1(w) or mask); mem.st1(w2, mem.ld1(w2) or mask2)
                        mem.st8(o.kbdAddr + o.member("CKbdStateGlbls", "last_down_scan_code"), esc)
                        mem.st8(o.kbdAddr + o.member("CKbdStateGlbls", "cnt"), mem.ld8(o.kbdAddr + o.member("CKbdStateGlbls", "cnt")) + 1)
                        pendingKeyUps.remove(bit)
                    } else if (frameCount < keyDownFrame[bit] + 2) {
                        // key latching (as for mouse clicks): programs that poll the key
                        // bitmap once per frame (FlapBat) must see a quick tap
                        pendingKeyUps.add(bit)
                    } else {
                        mem.st1(w, mem.ld1(w) and mask.inv()); mem.st1(w2, mem.ld1(w2) and mask2.inv())
                    }
                    // kbd.scan_code keeps the mouse button bits (MsUpdate) and the held modifiers
                    val sca = o.kbdAddr + o.member("CKbdStateGlbls", "scan_code")
                    val msBits = mem.ld8(sca) and (Keys.SCF_MS_L_DOWN or Keys.SCF_MS_R_DOWN)
                    mem.st8(sca, (esc and (Keys.SCF_MS_L_DOWN or Keys.SCF_MS_R_DOWN).inv()) or msBits or heldMods)
                    mem.st8(o.kbdAddr + o.member("CKbdStateGlbls", "timestamp"), now())
                    enqueue(Msg(if (e.down) 2 else 3, ech.toLong(), esc))
                }
                is KInput.Mouse -> {
                    // Click latching: programs often poll ms.lb once per frame (Demo/Games/
                    // TicTacToe). A press released before two frame boundaries have passed
                    // would be invisible, so the release waits (later events replace it).
                    val early = (!e.lb && lastLb && frameCount < lbDownFrame + 2) ||
                        (!e.rb && lastRb && frameCount < rbDownFrame + 2)
                    if (early && !(e.lb || e.rb)) { deferredMouse = e; continue }
                    deferredMouse?.let { deferredMouse = null; applyMouse(it) }
                    applyMouse(e)
                }
                is KInput.Break -> { stopAll = true; breakMain() }
                is KInput.Raw -> {
                    if (e.code == -2) { // MSG_KEY_DOWN_UP
                        enqueue(Msg(2, e.a1, e.a2)); enqueue(Msg(3, e.a1, e.a2 or Keys.SCF_KEY_UP))
                    } else enqueue(Msg(e.code, e.a1, e.a2))
                }
                is KInput.Exec -> {
                    if (busy) enqueue(Msg(2, 0, 0)) else execLine(e.line)
                }
            }
        }
    }

    private val taskMessages=HashMap<Int,ArrayDeque<Msg>>()
    var focusTask:Task?=null
        private set
    fun focus(task:Task?) {if(task!=null && task.state!=DEAD) {focusTask=task;mem.st8(o.global("sys_focus_task"),task.fsAddr.toLong())}}
    fun messageQueue(task:Task?=current):ArrayDeque<Msg> = if(task==null || task===mainTask) msgs else taskMessages.getOrPut(task.id) {ArrayDeque()}
    fun takeMessage(mask:Long,task:Task?=current):Msg? {
        val queue=messageQueue(task)
        while(queue.isNotEmpty()) {val m=queue.removeFirst();if(m.code in 0..63 && mask ushr m.code and 1L!=0L) return m}
        return null
    }
    fun enqueueTo(task:Task?,m:Msg) {
        val target=task ?: mainTask
        val queue=messageQueue(target)
        if(queue.size>=256) queue.removeFirst()
        queue.addLast(m)
        if(target?.state==WAIT_MSG) {target.state=READY;target.resumed=true}
    }
    private fun enqueue(m:Msg) {enqueueTo(focusTask?.takeIf {it.state!=DEAD} ?: mainTask,m)}


    /** Ctrl-Alt-C / Stop: raise 'Break' in the foreground task. */
    fun breakMain() {
        val t = mainTask ?: return
        if (t.state == DEAD) return
        pendingBreak = true
    }

    private var pendingBreak = false
    private var breakAt = 0L

    /** CTRL-ALT-C (scan code 0x2E), with CTRL/ALT from the key itself or held down. */
    private fun isBreakKey(e: KInput.Key): Boolean {
        val sc = e.sc or heldMods
        return e.down && sc and Keys.SCF_CTRL != 0L && sc and Keys.SCF_ALT != 0L &&
            ((e.sc and 0xFF) == 0x2EL || e.ch == 'c'.code || e.ch == 'C'.code || e.ch == 3)
    }

    /** SHIFT/CTRL/ALT flags of the modifier keys held down (from their key events). */
    private var heldMods = 0L

    /**
     * Kernel/KeyDev.HC CTRL-ALT keys: C breaks the program and X kills it (the window's Stop);
     * M toggles mute. The others (debugger, task switching, fonts, new terminal...) have no
     * counterpart in a single program window and are swallowed, as TempleOS does for every letter.
     */
    var onCtrlAlt: ((Char) -> Unit)? = null
    private fun ctrlAlt(c: Char) {
        when (c) {
            'c' -> breakMain()
            'm' -> natives.toggleMute()
            else -> onCtrlAlt?.invoke(c)
        }
    }

    /** True while [frame] runs draw_it callbacks. */
    private var inFrame = false

    /** The task [runTask] is running (callbacks on it may yield, see [yieldInCallback]). */
    private var steppingTask: Task? = null
    private var yielding = false

    /**
     * V-17: called by [Vm.callFunction] between slices of a callback that a native made on the
     * task being stepped (QSort comparator, Line plot, ExeFile...). The native's frames are on
     * the host stack, so the kernel cannot return from step(); it keeps the machine running
     * from here instead: input, a due frame (without that task's draw_it) and one slice for
     * every other ready task. Not re-entrant: callbacks inside those slices do not yield.
     */
    private fun yieldInCallback(t: Task) {
        if (yielding || inFrame || t !== steppingTask) return
        yielding = true
        try {
            processInput()
            updateClock()
            if (now() >= nextFrameAt) { inFrame = true; try { frame() } finally { inFrame = false } }
            wakeTasks()
            for (o in tasks.toList()) if (o !== t && o.state == READY && o.nestLevel == 0) runTask(o)
        } finally {
            setCurrent(t)
            yielding = false
        }
        // another task ended this one (Kill, or the program ended): unwind the native silently
        if (t.state == DEAD) throw VmKill("task ended")
    }

    /**
     * Called by [Vm.callFunction] between slices of a HolyC callback that a native or the
     * frame invoked (QSort comparator, Line plot, draw_it). The kernel cannot switch tasks
     * there, so Break is taken out of the input queue and raised inside the callback (V-17).
     * A draw_it callback gets it too (which disables draw_it); the main task still owes it.
     */
    private fun pollBreakInCallback(t: Task): Boolean {
        var seen = pendingBreak
        val it = inputQ.iterator()
        while (it.hasNext()) {
            val e = it.next()
            if (e is KInput.Break || (e is KInput.Key && isBreakKey(e))) { it.remove(); seen = true; if (e is KInput.Break) stopAll = true }
        }
        if (!seen) return false
        pendingBreak = true
        if (inFrame) return true
        if (t !== mainTask) return false
        pendingBreak = false
        breakAt = now()
        return true
    }

    // ------------------------------------------------------------ scheduler

    /**
     * Runs tasks for up to [budgetNs]. Returns the nanoseconds until the kernel
     * next needs to run (0 = runnable now), or -1 if the program has finished.
     */
    fun step(budgetNs: Long): Long {
        if (stopRequested) { terminate("Stopped."); return -1 }
        if (finished && !shellMode) { vm.engine?.shutdown(); return -1 }
        val start = env.nanoTime()
        stepStart = start; stepBudget = budgetNs
        processInput()
        if (pendingBreak) {
            pendingBreak = false
            val t = mainTask
            if (t != null && t.state != DEAD) {
                breakAt = now()
                if (!vm.inject(t, chCode("Break"))) { taskDied(t, "Break") } else if (t.state != SUSPENDED) t.state = READY
            }
        }
        while (true) {
            if (virtualTime && now() >= virtualStopAt) return 0
            if (deadStacks.isNotEmpty()) releaseDeadStacks()
            updateClock()
            // non-preemptive (Doc/Welcome.DD "non-preemptive multi-tasking"): a task that has not yielded
            // keeps running; no frame (draw_it) and no other task until it Yields, sleeps, waits or ends
            val cur = inFlight?.takeIf { it.state == READY && it in tasks }
            if (cur == null) inFlight = null
            else if (now() - inFlightSince < WATCHDOG_NS) {
                taskR0 = now()
                val w0 = env.nanoTime()
                inStepLoop = true
                try { runTask(cur) } finally { inStepLoop = false; wallTaskNs += env.nanoTime() - w0 }
                // (a native task may have continued on its own thread: taskR0 is its last slice's start)
                val r1 = now()
                busyNs += r1 - taskR0
                taskOwedNs -= r1 - taskR0
                frameStats.task(r1 - taskR0)
                if (finished && !shellMode) return -1
                if (env.nanoTime() - start >= budgetNs) return 0
                if (inputQ.isNotEmpty()) processInput()
                continue
            } else inFlightSince = now() // watchdog: let one frame and the other tasks run, then continue it
            if (now() >= nextFrameAt && taskOwedNs <= 0) {
                val f0 = now()
                val w0 = env.nanoTime()
                inFrame = true
                try { frame() } finally { inFrame = false; wallFrameNs += env.nanoTime() - w0 }
                val f1 = now()
                busyNs += f1 - f0
                frameStats.frame(f1 - f0)
                // Fairness: when composing a frame (draw_it, blits) takes longer than the frame interval,
                // the tasks get at least as much time as the frame took before the next one, so the frame
                // rate drops instead of the program starving (slow devices, heavy draw_it). Only tasks that
                // want the CPU are owed that time: with none ready the next frame follows at once (it used
                // to wait anyway, which halved the frame rate of slow frames for nothing).
                if (f1 + (f1 - f0) > nextFrameAt) taskOwedNs = f1 - f0
            }
            wakeTasks()
            val t = pickReady()
            waitingForKey = t == null && tasks.any { it.state == WAIT_MSG }
            if (t == null) {
                // no task wants the owed time: compose the next frame now, but within this step's budget
                // (frames slower than the frame interval would otherwise follow each other forever here)
                if (taskOwedNs > 0) { taskOwedNs = 0; if (env.nanoTime() - start < budgetNs) continue }
                val wait = nextWakeIn()
                if (virtualTime && wait > 0) {
                    vtime += minOf(wait, FRAME_NS)
                    if (tasks.any { it.state == SLEEP || it.state == WAIT_FRAME }) continue
                    return 0
                }
                return if (allDone()) -1 else wait
            }
            taskR0 = now()
            val w0 = env.nanoTime()
            inStepLoop = true
            try { runTask(t) } finally { inStepLoop = false; wallTaskNs += env.nanoTime() - w0 }
            val r1 = now()
            busyNs += r1 - taskR0
            taskOwedNs -= r1 - taskR0
            frameStats.task(r1 - taskR0)
            if (finished && !shellMode) return -1
            if (env.nanoTime() - start >= budgetNs) return 0
            if (inputQ.isNotEmpty()) processInput()
        }
    }

    // ------------------------------------------------------------ native fast path

    /** The current step's start and budget, and the start of the slice step() is running ([continueSlice]). */
    private var stepStart = 0L
    private var stepBudget = 0L
    private var taskR0 = 0L
    /** True while step()'s loop runs a task (not a nested runTask from a callback, not boot). */
    private var inStepLoop = false
    private var runDepth = 0
    private var sliceBefore = 0L
    private var sliceBeforeTicks = 0L

    /**
     * Native engine (purenative): [t]'s slice has just ended (budget or yield) on its own thread. When the
     * scheduler's next decision would be to run [t] again at once — nothing else can happen first: no frame
     * due, no input, no other task ready or waking, no step budget used up — this does exactly the
     * bookkeeping step() and runTask() would do between the two slices, in the same order, and returns the
     * next slice's budget: the task continues without a thread switch. Otherwise it changes nothing and
     * returns 0 (the task hands the CPU back and the scheduler decides). The interpreter never calls it.
     */
    fun continueSlice(t: Task): Int {
        if (!inStepLoop || runDepth != 1 || steppingTask !== t || current !== t) return 0
        if (t.state != READY || stopRequested || finished || pendingBreak || shellMode) return 0
        if (inputQ.isNotEmpty() || deadStacks.isNotEmpty() || t !in tasks) return 0
        // --- prospective values (nothing mutated yet)
        val ticks = vm.ticksExecuted - sliceBeforeTicks
        val dv = if (virtualTime) (if (virtualCostTicks || vm.engine != null) ticks * virtualNsPerTick else (vm.instructionsExecuted - sliceBefore) * virtualNsPerInstr) else 0L
        val nowAfter = if (virtualTime) vtime + dv else env.nanoTime() - bootNs - pausedNs
        val budgetOut = !t.yielded // ran out of its slice without yielding: it keeps the CPU (inFlight)
        if (env.nanoTime() - stepStart >= stepBudget) return 0
        if (virtualTime && nowAfter >= virtualStopAt) return 0
        val inFlightSince1 = if (budgetOut) (if (inFlight !== t) nowAfter.let { if (virtualTime) vtime else it } else inFlightSince) else inFlightSince
        if (budgetOut) {
            if (nowAfter - inFlightSince1 >= WATCHDOG_NS) return 0 // the watchdog lets a frame and the others run
        } else {
            val other = inFlight?.takeIf { it !== t && it.state == READY && it in tasks }
            if (other != null) return 0
            val owed = taskOwedNs - (nowAfter - taskR0)
            if (nowAfter >= nextFrameAt && owed <= 0) return 0
            for (o in tasks) when (o.state) {
                SLEEP -> if (nowAfter >= o.wakeAt) return 0
                WAIT_FRAME -> if (frameCount > o.blockToken) return 0
                WAIT_MSG -> if (messageQueue(o).isNotEmpty()) return 0
                WAIT_POPUP -> if (popup?.result != null) return 0
            }
            val n = tasks.size
            var pick: Task? = null
            for (i in 0 until n) { val c = tasks[(rr + i) % n]; if (c.state == READY) { pick = c; break } }
            if (pick !== t) return 0
        }
        // --- runTask's end (R_SLICE)
        steppingTask = null
        if (budgetOut) { if (inFlight !== t) { inFlight = t; inFlightSince = now() } }
        else inFlight = null // (it was t, or a task that is not ready: the loop drops it)
        sliceTrace?.invoke(t, Vm.R_SLICE, ticks)
        if (virtualTime) vtime += dv
        // --- step(): after the slice
        val r1 = now()
        busyNs += r1 - taskR0
        taskOwedNs -= r1 - taskR0
        frameStats.task(r1 - taskR0)
        // --- step(): the loop's next pass up to runTask(t)
        updateClock()
        if (!budgetOut) {
            // (no frame, no wake-ups: checked above); pickReady chooses t
            val n = tasks.size
            for (i in 0 until n) { if (tasks[(rr + i) % n] === t) { rr = (rr + i + 1) % maxOf(n, 1); break } }
            waitingForKey = false
        }
        taskR0 = now()
        // --- runTask(t)'s start
        updateClock(t)
        setCurrent(t)
        sliceBefore = vm.instructionsExecuted
        sliceBeforeTicks = vm.ticksExecuted
        sliceTrace?.invoke(t, -1, 0)
        steppingTask = t
        t.yielded = false
        return SLICE
    }

    /**
     * Host wall-clock time the kernel thread spent running tasks and composing frames (draw_it, ODEs,
     * blits), even in virtual time, where [now] does not move during a frame (benchmarks split them).
     */
    var wallTaskNs = 0L
        private set
    var wallFrameNs = 0L
        private set

    /** Time tasks and frames used since the last frame, for Gs->idle_factor. */
    private var busyNs = 0L
    /** Task time still owed after a frame that took longer than the frame interval (fairness). */
    private var taskOwedNs = 0L
    private var idleSince = 0L

    /** The task that ran out of slice without yielding (it keeps the CPU), and since when. */
    private var inFlight: Task? = null
    private var inFlightSince = 0L

    private var rr = 0
    private fun pickReady(): Task? {
        val n = tasks.size
        for (i in 0 until n) {
            val t = tasks[(rr + i) % n]
            if (t.state == READY) { rr = (rr + i + 1) % maxOf(n, 1); return t }
        }
        return null
    }

    private fun wakeTasks() {
        val now = now()
        for (t in tasks) {
            when (t.state) {
                SLEEP -> if (now >= t.wakeAt) { t.state = READY; t.resumed = true; t.lateNs = minOf(now - t.wakeAt, MAX_LATE_NS) }
                WAIT_FRAME -> if (frameCount > t.blockToken) { t.state = READY; t.resumed = true; t.lateNs = 0 }
                WAIT_MSG -> if (messageQueue(t).isNotEmpty()) { t.state = READY; t.resumed = true; t.lateNs = 0 }
                WAIT_POPUP -> if (popup?.result != null) { t.state = READY; t.resumed = true; t.lateNs = 0 }
            }
        }
    }

    private fun nextWakeIn(): Long {
        val now = now()
        var w = nextFrameAt - now
        for (t in tasks) if (t.state == SLEEP) w = minOf(w, t.wakeAt - now)
        if (!graphicsUsed && tasks.none { it.state == WAIT_FRAME || it.state == SLEEP }) {
            // idle console program waiting for input: sleep long (input wakes us)
            w = if (tasks.any { it.state == WAIT_MSG }) 500_000_000L else w
        }
        return maxOf(w, WAKE_FLOOR_NS)
    }

    private fun allDone() = tasks.none { it.state != DEAD } && !shellMode

    /** Virtual-time cost per instruction (tests): models a ~100M instr/s device. */
    var virtualNsPerInstr = 10L
    /**
     * Virtual-time cost per budget tick (a backward branch or a HolyC call), used instead of the
     * instruction count when [virtualCostTicks] is set or the kernel is native (which counts no
     * instructions). Both engines charge ticks at the same points, so a program then takes the same
     * virtual time interpreted and native (parity tests).
     */
    var virtualNsPerTick = 250L
    var virtualCostTicks = false
    /** Tests: called before (result -1) and after every task slice with its result (Vm.R_*) and the budget ticks it used. */
    var sliceTrace: ((Task, Int, Long) -> Unit)? = null
    /** Virtual-time mode: step() returns once now() reaches this (deterministic test stepping). */
    var virtualStopAt = Long.MAX_VALUE

    private fun runTask(t: Task) {
        // the clock as this task sees it: cnts.jiffies stays within a jiffy of real time, as TempleOS's timer
        // interrupt keeps it (a frame composed since the scheduler's updateClock once shifted a whole Play by 8 ms)
        updateClock(t)
        setCurrent(t)
        sliceBefore = vm.instructionsExecuted
        sliceBeforeTicks = vm.ticksExecuted
        sliceTrace?.invoke(t, -1, 0)
        val outer = steppingTask
        steppingTask = t
        t.yielded = false
        runDepth++
        val r = try {
            vm.run(t, SLICE)
        } catch (k: VmKill) {
            if (t.state != DEAD) taskDied(t, k.message ?: "killed")
            return
        } catch (u: VmUncaught) {
            classifyDeath(t, ExitCategory.of(u.ch, u.message, loading = false))
            taskDied(t, u.message ?: "exception"); return
        } catch (e: StackOverflowError) {
            classifyDeath(t, ExitCategory.RESOURCE_LIMIT_EXCEEDED)
            taskDied(t, "host stack overflow"); return
        } catch (e: RuntimeException) {
            classifyDeath(t, ExitCategory.INTERNAL_RUNTIME_ERROR)
            taskDied(t, "internal error: $e"); return
        } finally {
            runDepth--
            steppingTask = outer
        }
        // (continueSlice may have run further slices of a native task: their counters start here)
        val before = sliceBefore
        val beforeTicks = sliceBeforeTicks
        // a slice that ran out (no Yield/Sleep/wait) leaves the task mid-computation: it keeps the CPU
        if (r == Vm.R_SLICE && !t.yielded && t.state == READY) { if (inFlight !== t) { inFlight = t; inFlightSince = now() } }
        else if (inFlight === t) inFlight = null
        when (r) {
            Vm.R_SLICE -> if (t.state == READY || t.state == DEAD) {} else {}
            Vm.R_BLOCKED -> {}
            Vm.R_DONE -> {
                if (t === mainTask && session != null) {
                    if (shellMode) {
                        answerKind = session!!.answerKind; answer = t.result; answerNs = now() - chunkStartNs
                    }
                    try {
                        if (!advanceSession(t)) taskEnded(t, null)
                    } catch (e: CompileError) { compileFailed(t, e) } catch (f: VmFault) { loadFailed(t, f) }
                } else taskEnded(t, null)
            }
            Vm.R_DEAD -> {
                if(t.deathCode==0L && t.deathMessage?.startsWith("Unhandled exception ''")==true) {taskEnded(t,null);return}
                classifyDeath(t, ExitCategory.of(t.deathCode, t.deathMessage, loading = false))
                taskDied(t, t.deathMessage ?: "unhandled exception")
            }
        }
        if (t.state == DEAD && t.depth >= 0 && r != Vm.R_DONE && r != Vm.R_DEAD) taskEnded(t, null)
        sliceTrace?.invoke(t, r, vm.ticksExecuted - beforeTicks)
        if (virtualTime) {
            vtime += if (virtualCostTicks || vm.engine != null) (vm.ticksExecuted - beforeTicks) * virtualNsPerTick
            else (vm.instructionsExecuted - before) * virtualNsPerInstr
        }
    }

    /**
     * ExePrint caught a compile error (Compiler/CMain.HC ExePutS: try ... catch on 'Compiler'): as on TempleOS, the
     * task's Fs->except_ch is left at 'Compiler' (VM probe: shared/test-vectors/dynexpr/cartesian-vm-results.json).
     */
    fun compileErrorCaught(t: Task) { if (t.fsAddr != 0) mem.st8(t.fsAddr + o.task("except_ch"), COMPILER_CH) }

    /** Records why the program ends when its main task dies of [category] (the first cause wins). */
    private fun classifyDeath(t: Task, category: String) {
        if (t === mainTask && !shellMode && exitCategory == null) exitCategory = category
    }

    private fun taskDied(t: Task, msg: String) {
        if (msg.contains("'Break'") || msg == "Break") console.write("\n\$RED\$Program stopped (Break).\$FG\$\n")
        else console.write("\n\$RED\$$msg\$FG\$\n")
        taskEnded(t, msg)
    }

    fun taskEnded(t: Task, msg: String?) {
        if (t.state == DEAD && !tasks.contains(t)) return
        t.state = DEAD
        // task_end_cb (e.g. SndTaskEndCB)
        val cb = mem.ld8(t.fsAddr + o.task("task_end_cb"))
        if (cb != 0L) {
            mem.st8(t.fsAddr + o.task("task_end_cb"), 0)
            try { setCurrent(t); vm.callFunction(t, cb) } catch (_: RuntimeException) {}
        }
        sources.taskGone(t)
        taskMessages.remove(t.id)
        if(focusTask===t) focusTask=mainTask?.takeIf {it!==t && it.state!=DEAD}
        if (!(shellMode && t === mainTask)) sys.taskGone(t.fsAddr.toLong()) // the terminal task outlives its commands
        if (!(shellMode && t === mainTask)) vm.engine?.taskGone(t)
        if (t === mainTask) {
            if(!shellMode)menuSnapshot=emptyList();menuChanged=true
            if (shellMode || stopAll) silence()
            if (shellMode) {
                if (msg == null) printAnswer()
                busy = false
                t.depth = 0; t.sp = 0; t.hCount = 0
                t.state = READY
                // children die with the command, each through its task_end_cb as Kernel/KTask.HC TaskEnd kills
                // them (a song task's SndTaskEndCB). Noise and Sweep tasks play on, as every task a command
                // spawns does on TempleOS: they end by themselves, and their SoundEffectEndTaskCB gives back the
                // music.mute that Noise/Sweep took (killed before they ran, it never came back: Play went silent).
                // The window's Stop ends them too.
                for (c in tasks.toList()) if (c !== t && c.state != DEAD && (!c.speakerTask || stopAll)) taskEnded(c, null)
                for (c in tasks.toList()) if (c !== t && (!c.speakerTask || stopAll)) { c.state = DEAD; tasks.remove(c); deadStacks.add(c.mspBase) }
                setCurrent(t)
                t.state = DEAD
                shellPrompt()
            } else {
                exitMessage = msg
                if (exitCategory == null) exitCategory = if (msg == null) ExitCategory.NORMAL else if (msg == "Break" || msg.contains("'Break'")) ExitCategory.STOPPED else ExitCategory.UNHANDLED_EXCEPTION
                mainEnded = true
                tasks.remove(t)
                deadStacks.add(t.mspBase)
                // TempleOS runs a program in the user's terminal task: when its code returns (or is broken
                // with CTRL-ALT-C) the tasks it spawned keep running there (CharAnimation's Animate task).
                // The window's Stop ends them all, as closing the terminal would.
                if (stopAll || tasks.none { it.state != DEAD }) endProgram()
            }
        } else {
            tasks.remove(t)
            deadStacks.add(t.mspBase) // released by step() once the task can no longer run
            if (mainEnded && tasks.none { it.state != DEAD }) endProgram()
        }
    }

    /** True once the main task's code has returned; spawned tasks may still be running. */
    var mainEnded = false
        private set
    /** Set by the window's Stop (KInput.Break): ending the main task ends every task. */
    private var stopAll = false

    private fun endProgram() {
        for (c in tasks) { c.state = DEAD; vm.engine?.taskGone(c) }
        tasks.clear()
        sys.allTasksGone()
        silence()
        // one last frame, so output printed just before the end is on the screen (Demo/Graphics/Extents.HC)
        // (compose draws the text cells laid out by the previous pass, so two passes)
        if (graphicsUsed && !stopAll) try { compose(); compose() } catch (_: RuntimeException) {}
        finished = true
    }

    /** Stacks of ended tasks (TempleOS frees a task's stack when it dies; they were leaked: OutMem after ~110 Spawns). */
    private val deadStacks = ArrayList<Int>()

    private fun releaseDeadStacks() {
        // the task that ran last may be one of them: Fs must not keep pointing at a task whose stack is reused
        if (current?.state == DEAD) adamTask?.let { setCurrent(it) }
        for (p in deadStacks) mem.freeStack(p)
        deadStacks.clear()
    }

    // Command-line answer (TempleOS Fs->answer, answer_type, answer_time).
    private var answerKind = -1
    private var answer = 0L
    private var answerNs = 0L
    private var chunkStartNs = 0L

    /** Prints the answer line exactly as TempleOS's CmdLinePmt (Compiler/CMisc.HC) does. */
    private fun printAnswer() {
        if (answerKind < 0) return
        val secs = java.lang.Double.doubleToRawLongBits(answerNs / 1e9)
        val (f, args) = when (answerKind) {
            Program.ANS_F64 -> "%8.6fs ansf=%15.7g\n" to longArrayOf(secs, answer)
            Program.ANS_INT -> "%8.6fs ans=0x%08X=%d\n" to longArrayOf(secs, answer, answer)
            else -> "%8.6fs\n" to longArrayOf(secs)
        }
        console.write(fmt.format(latin1(f), args, 0, args.size))
        answerKind = -1
    }

    var onShellIdle: (() -> Unit)? = null
    private fun shellPrompt() { onShellIdle?.invoke() }

    fun terminate(msg: String) {
        vm.engine?.let { e -> for (t in tasks) e.taskGone(t); mainTask?.let { e.taskGone(it) }; e.shutdown() }
        if (finished) return
        silence()
        for (t in tasks) t.state = DEAD
        tasks.clear()
        finished = true
        busy = false
        exitMessage = msg
        if (exitCategory == null) exitCategory = ExitCategory.STOPPED
    }

    /** Called by natives to block the current task. */
    fun block(t: Task, state: Int) {
        if (t.nestLevel > 0) return // never block inside callbacks
        t.state = state
        t.blocked = true
    }

    // ------------------------------------------------------------ popups

    /** The open popup, shown by the UI; answered with [answerPopup]. */
    @Volatile var popup: PopupRequest? = null

    /** Called by the UI thread with the chosen value (or -1 = cancel). */
    fun answerPopup(value: Long) {
        lastInteractionNanos=now()
        popup?.result = value
        wakeLock?.let { synchronized(it) { (it as Object).notifyAll() } }
    }

    // ------------------------------------------------------------ line input (GetStr)

    var lineReady = false

    // ------------------------------------------------------------ clock & frames

    /** cnts.jiffies and cnts.timer in the arena (updateClock runs before every task slice). */
    /** Kernel-owned CPU telemetry address; a program may overwrite its visible Gs global. */
    private var hostCpuAddr = 0
    private var jiffiesAddr = 0
    private var timerAddr = 0

    private fun updateClock(t: Task? = null) {
        val n = if (t == null) now() else taskNow(t)
        if (jiffiesAddr == 0) return // before initGlobals
        mem.st8(jiffiesAddr, TempleClock.jiffyAt(n))
        mem.st8(timerAddr, n / 1000)
    }

    /**
     * The time [t] sees (cnts.jiffies, tS, Sleep, SleepUntil): TempleOS's timer interrupt wakes a task at its
     * jiffy, so a task the host woke late runs as if on time, its clock behind by that lateness (at most
     * [MAX_LATE_NS]; a longer stall is not hidden). Play and Sleep loops then keep their rhythm instead of
     * adding every late wake-up to the song (docs/audio/TEMPLEOS_SOUND.md).
     */
    fun taskNow(t: Task): Long = now() - t.lateNs

    private var lastFrameNs = 0L

    private fun frame() {
        val now = now()
        nextFrameAt = maxOf(nextFrameAt + FRAME_NS, now + FRAME_NS / 2)
        if (lastFrameNs != 0L) {
            val dt = (now - lastFrameNs).coerceAtLeast(1)
            fps = fps * 0.9 + (1e9 / dt) * 0.1
        }
        lastFrameNs = now
        frameCount++
        deferredMouse?.let {
            if ((!lastLb || frameCount >= lbDownFrame + 2) && (!lastRb || frameCount >= rbDownFrame + 2)) { deferredMouse = null; applyMouse(it) }
        }
        if (pendingKeyUps.isNotEmpty()) pendingKeyUps.removeAll { bit -> (frameCount >= keyDownFrame[bit] + 2).also { if (it) releaseKeyBit(bit) } }
        winMsUpdate()
        queueInputMsgs()
        mem.st8(o.winmgrAddr + o.member("CWinMgrGlbls", "updates"), frameCount)
        mem.st8(o.winmgrAddr + o.member("CWinMgrGlbls", "fps"), (if (fps > 0) fps else 30.0).toRawBits())
        // Gs->idle_factor: the share of the last frame no task wanted the CPU (TempleOS measures it in
        // the idle task); the window manager sizes the ODE time budget with it (Adam/Gr/GrScrn.HC)
        val span = now - idleSince
        if (span > 0 && idleSince != 0L)
            mem.st8(hostCpuAddr + o.member("CCPU", "idle_factor"), (1.0 - busyNs.toDouble() / span).coerceIn(0.0, 1.0).toRawBits())
        busyNs = 0; idleSince = now
        try {documents.refreshDynamic()} catch(f:VmFault) {mainTask?.let {classifyDeath(it,ExitCategory.of(f.ch,f.message,loading=false));taskDied(it,"DolDoc callback: ${f.message}")}}
        val menuPointer=menuOwner()?.let {mem.ld8(it.fsAddr+o.task("cur_menu"))} ?: 0L
        if(menuChanged || menuPointer!=lastMenuPointer)menuRefreshFrames=2
        if(menuRefreshFrames>0 || frameCount%15==1L) {
            snapshotMenu();lastMenuPointer=menuPointer;menuChanged=false;menuRefreshFrames=maxOf(0,menuRefreshFrames-1)
        }
        if (!graphicsUsed) for (t in tasks) if (t.state != DEAD && mem.ld8(t.fsAddr + o.task("draw_it")) != 0L) { graphicsUsed = true; break }
        // TempleOS has one screen for text and graphics: a program that draws on gr.dc, shows a control
        // or changes the palette is shown as that screen, not as a text console
        if (!graphicsUsed && (gfx.screenTouched() || !palette.contentEquals(STD_PALETTE) || gfx.textLayerTouched() ||
                mainTask?.let { m -> m.state != DEAD && try { callHolyC("MobileTaskHasOwnCtrls", m.fsAddr.toLong(), task = m) != 0L } catch (_: RuntimeException) { false } } == true))
            graphicsUsed = true
        if (graphicsUsed) {
            // the screen and its DCs live in the program's arena: a program that overwrote their pointers
            // (wild writes) faults here, and dies of it like any HolyC fault, inside its own arena (F-5)
            try { compose() } catch (f: VmFault) {
                val m = mainTask ?: tasks.firstOrNull() ?: return
                classifyDeath(m, ExitCategory.of(f.ch, f.message, loading = false))
                taskDied(m, "Unhandled exception '${vm.chStr(f.ch)}' in the window manager: ${f.message}")
            }
        }
    }

    /** Latest program menu (Fs->cur_menu of the main task), for the UI. */
    @Volatile var menuSnapshot: List<MenuSnap> = emptyList()
    private var lastMenuPointer=-1L
    private var menuRefreshFrames=0
        private set

    /** Adam/Menu.HC MenuTask: inherit the focused task's nearest parent menu. */
    private fun menuOwner():Task? {
        var task=focusTask?.takeIf {it.state!=DEAD} ?: mainTask
        var depth=0
        while(task!=null && depth++<64) {
            if(task.state!=DEAD && mem.ld8(task.fsAddr+o.task("cur_menu"))!=0L)return task
            task=taskByFs(mem.ld8(task.fsAddr+o.task("parent_task")))
        }
        return null
    }
    private fun snapshotMenu() {
        val t = menuOwner() ?: run {menuSnapshot=emptyList();return}
        if (t.state == DEAD) { menuSnapshot = emptyList(); return }
        val menu = mem.ld8(t.fsAddr + o.task("cur_menu"))
        if (menu == 0L) { if (menuSnapshot.isNotEmpty()) menuSnapshot = emptyList(); return }
        val out = ArrayList<MenuSnap>()
        fun walk(e0: Long, prefix: String, depth: Int) {
            var e = e0; var n = 0
            while (e != 0L && n++ < 64 && depth < 4) {
                val a = e.toInt()
                val name = mem.readStr(a + o.member("CMenuEntry", "name").toLong())
                val isDir = mem.ld1(a + o.member("CMenuEntry", "dir")) != 0L
                val path = if (prefix.isEmpty()) name else "$prefix/$name"
                out.add(MenuSnap(path, name, mem.ld8(a + o.member("CMenuEntry", "msg_code")), mem.ld8(a + o.member("CMenuEntry", "arg1")),
                    mem.ld8(a + o.member("CMenuEntry", "arg2")), mem.ld1(a + o.member("CMenuEntry", "checked")) != 0L, isDir))
                if (isDir) walk(mem.ld8(a + o.member("CMenuEntry", "sub")), path, depth + 1)
                e = mem.ld8(a + o.member("CMenuEntry", "next"))
            }
        }
        try { walk(mem.ld8(menu.toInt() + o.member("CMenu", "sub")), "", 0) } catch (_: RuntimeException) { return }
        menuSnapshot = out
    }

    /** Guards [published] between the kernel thread and the UI. */
    val publishLock = Object()

    /** TempleOS screen update: text layer, draw_it callbacks, then gr.dc on top. */
    fun captureScreen():ByteArray {compose();return published.copyOf()}

    private fun compose() {
        vga.sync()
        val main = mainTask ?: tasks.firstOrNull() ?: return
        // 1. text layer -> pixels
        gfx.renderText(textCells, frameBuf)
        val spriteWin = windowCells(main.fsAddr)
        console.renderSprites(frameBuf, W, spriteWin[0] * 8, spriteWin[1] * 8,
            spriteWin[2] - spriteWin[0] + 1, spriteWin[3] - spriteWin[1] + 1)
        // 2. rebuild text cells for the next frame as TempleOS's GrUpdateTaskWin does: the window
        // border (TextBorder), the window filled with text_attr (TextRect), then the document
        val attr = mem.ld1(main.fsAddr + o.task("text_attr")).toInt()
        val win = windowCells(main.fsAddr)
        layoutWindowText(win, attr, mem.ld1(main.fsAddr + o.task("border_attr")).toInt())
        gfx.copyTextCellsToArena(textCells)
        gfx.loadScreen(frameBuf)
        // 3. ODEs, draw_it callbacks and controls of live tasks (Adam/Gr/GrScrn.HC GrUpdateTasks: the
        // ODE time of this frame is summed in winmgr.ode_time and budgets the next frame's)
        mem.st8(o.winmgrAddr + o.member("CWinMgrGlbls", "ode_time"), 0.0.toRawBits())
        for (t in tasks.toList()) {
            if (t.state == DEAD) continue
            if (t.nestLevel > 0) continue // inside a native's callback (V-17): its HolyC state is mid-call
            frameDuties(t)
            val fp = mem.ld8(t.fsAddr + o.task("draw_it"))
            if (fp == 0L) { drawCtrls(t); continue }
            val dc = gfx.aliasForDraw(t)
            val saved = current
            try {
                setCurrent(t)
                vm.callFunction(t, fp, t.fsAddr.toLong(), dc.toLong())
            } catch (u: VmUncaught) {
                mem.st8(t.fsAddr + o.task("draw_it"), 0)
                console.write("\n\$RED\$Exception in draw_it: ${u.message}\$FG\$\n")
            } catch (k: VmKill) {
                mem.st8(t.fsAddr + o.task("draw_it"), 0)
                console.write("\n\$RED\$draw_it: ${k.message}\$FG\$\n")
            } catch (f: VmFault) {
                // e.g. a corrupted Fs->draw_it pointer: the program's fault, not the kernel's
                mem.st8(t.fsAddr + o.task("draw_it"), 0)
                console.write("\n\$RED\$Exception in draw_it: ${f.message}\$FG\$\n")
            } finally {
                gfx.freeDrawAlias(dc)
                saved?.let { setCurrent(it) }
            }
            drawCtrls(t)
        }
        val mouseDraw=mem.ld8(o.grAddr+o.member("CGrGlbls","fp_draw_ms"))
        if(mouseDraw!=0L && main.state!=DEAD && mem.ld1(o.msAddr+o.member("CMsStateGlbls","show"))!=0L) {
            val saved=current;val dc=gfx.aliasForDraw(main)
            try {setCurrent(main);vm.callFunction(main,mouseDraw,dc,mem.ld8(o.msAddr+o.msPos)-mem.ld8(main.fsAddr+o.task("pix_left")),mem.ld8(o.msAddr+o.msPos+8)-mem.ld8(main.fsAddr+o.task("pix_top")))}
            finally {gfx.freeDrawAlias(dc);saved?.let {setCurrent(it)}}
        }
        // window-manager work: on the Adam task, as TempleOS runs it in its WinMgr task
        try { callHolyC("MobileOdeFrameEnd", task = adamTask) } catch (_: RuntimeException) {}
        gfx.copyTextCellsFromArena(textCells)
        // 4. persistent gr.dc on top, then publish with the window rect the UI shows
        val b = win[4]
        val x0 = ((win[0] - b) * 8).coerceIn(0, W); val y0 = ((win[1] - b) * 8).coerceIn(0, H)
        val x1 = ((win[2] + 1 + b) * 8).coerceIn(0, W); val y1 = ((win[3] + 1 + b) * 8).coerceIn(0, H)
        synchronized(publishLock) {
            var changed = gfx.composeAndPublish(published) || publishedVersion == 0L
            val r = if (x1 - x0 >= 8 && y1 - y0 >= 8) intArrayOf(x0, y0, x1 - x0, y1 - y0) else intArrayOf(0, 0, W, H)
            if (!r.contentEquals(publishedWindow)) { System.arraycopy(r, 0, publishedWindow, 0, 4); changed = true }
            if (changed) publishedVersion++
        }
    }

    private var docCells = IntArray(0)

    /**
     * Text layer for the next frame: blank screen, [win]'s border (Adam/Gr/GrTextBase.HC TextBorder,
     * solid because the window has the focus), and the console document in the window's text area.
     */
    private fun layoutWindowText(win: IntArray, attr: Int, borderAttr: Int) {
        java.util.Arrays.fill(textCells, 0)
        val l = win[0]; val t = win[1]; val r = win[2]; val bt = win[3]
        fun put(x: Int, y: Int, d: Int) { if (x in 0 until TEXT_COLS && y in 0 until TEXT_ROWS) textCells[y * TEXT_COLS + x] = d }
        if (win[4] != 0) {
            val a = borderAttr shl 8
            val bc = o.global("text") + o.member("CTextGlbls", "border_chars")
            fun ch(i: Int) = mem.ld1(bc + i).toInt() + a
            put(l - 1, t - 1, ch(7)); put(r + 1, t - 1, ch(9)); put(l - 1, bt + 1, ch(11)); put(r + 1, bt + 1, ch(13))
            for (i in l..r) { put(i, t - 1, ch(3)); put(i, bt + 1, ch(3)) }
            for (i in t..bt) { put(l - 1, i, ch(5)); put(r + 1, i, ch(5)) }
        }
        val cols = r - l + 1; val rows = bt - t + 1
        if (cols <= 0 || rows <= 0) return
        if (docCells.size < cols * rows) docCells = IntArray(cols * rows)
        console.renderCells(docCells, cols, rows, attr)
        for (y in 0 until rows) for (x in 0 until cols) put(l + x, t + y, docCells[y * cols + x])
    }

    /** ODE integration and control mouse routing for [t] (TempleOS WinMgr duties). */
    private fun frameDuties(t: Task) {
        val saved = current
        try {
            setCurrent(t)
            if (mem.ld8(t.fsAddr + o.task("next_ode")) != (t.fsAddr + o.task("next_ode")).toLong())
                callHolyC("ODEsUpdate", t.fsAddr.toLong(), task = t)
            if (callHolyC("MobileTaskHasCtrls", t.fsAddr.toLong(), task = t) != 0L) {
                callHolyC("CtrlsUpdate", t.fsAddr.toLong(), task = t)
                if (t === mainTask) callHolyC("MobileCtrlsMs", t.fsAddr.toLong(), task = t)
            }
        } catch (u: VmUncaught) {
            console.write("\n\$RED\$Exception in window manager: ${u.message}\$FG\$\n")
            mem.st8(t.fsAddr + o.task("next_ode"), (t.fsAddr + o.task("next_ode")).toLong())
            mem.st8(t.fsAddr + o.task("last_ode"), (t.fsAddr + o.task("next_ode")).toLong())
        } catch (k: VmKill) {
        } finally { saved?.let { setCurrent(it) } }
    }

    private fun drawCtrls(t: Task) {
        try {
            if (callHolyC("MobileTaskHasCtrls", t.fsAddr.toLong(), task = t) != 0L) {
                // the terminal's own scroll bars alone do not make a text program a graphics one
                if (!graphicsUsed && callHolyC("MobileTaskHasOwnCtrls", t.fsAddr.toLong(), task = t) != 0L) graphicsUsed = true
                callHolyC("DrawCtrls", t.fsAddr.toLong(), task = t)
            }
        } catch (_: RuntimeException) {}
    }

    // ------------------------------------------------------------ random

    val rng = java.util.SplittableRandom(0)
    private val randSeedOff by lazy { o.task("rand_seed") }
    private val taskFlagsOff by lazy { o.task("task_flags") }

    /**
     * Kernel/KMathB.HC RandU64 and friends: advances [t]'s own `rand_seed` with TempleOS's linear congruence
     * and, unless Seed(n != 0) set TASKf_NONTIMER_RAND, XORs in the time stamp counter (GetTSC: the task's
     * clock here, deterministic in virtual time), as every TempleOS task does. Returns the new seed; the
     * callers take their slice of it (RandU16 the low 16 bits...). Verified against the original
     * (shared/test-vectors/reference-vm/rng.json): the app used one global splitmix64 before.
     */
    fun nextRand(t: Task?): Long {
        val task = t ?: current ?: return 0
        val fs = task.fsAddr
        var res = mem.ld8(fs + randSeedOff)
        res = ((LIN_CONGRUE_A * res) xor ((res and 0xFFFFFFFF0000L) shr 16)) + LIN_CONGRUE_C
        if ((mem.ld4(fs + taskFlagsOff) ushr TASKF_NONTIMER_RAND) and 1L == 0L) res = res xor taskNow(task)
        mem.st8(fs + randSeedOff, res)
        return res
    }

    /** Kernel/KMathB.HC Seed(seed, task): a fixed seed (and no more TSC) or, for 0, back to timer-based. */
    fun seed(t: Task, seed: Long, taskAddr: Long): Long {
        val fs = if (taskAddr != 0L) mem.check(taskAddr, 8) else t.fsAddr
        val fl = mem.ld4(fs + taskFlagsOff)
        return if (seed != 0L) {
            mem.st4(fs + taskFlagsOff, fl or (1L shl TASKF_NONTIMER_RAND))
            mem.st8(fs + randSeedOff, seed); seed
        } else {
            mem.st4(fs + taskFlagsOff, fl and (1L shl TASKF_NONTIMER_RAND).inv())
            val s = mem.ld8(fs + randSeedOff) xor taskNow(taskByFs(fs.toLong()) ?: t)
            mem.st8(fs + randSeedOff, s); s
        }
    }
}

/** Arena offsets of prelude classes and globals used by the host. */
class Offsets(private val k: Kernel) {
    private val prog = k.prog
    // The prelude's own definitions, taken right after it compiled. A program may redefine or
    // forward-declare a prelude class (`class CTask;`) or shadow a global; the host keeps using the
    // prelude layout, as TempleOS's kernel code keeps its compiled offsets. Names the prelude does
    // not define fall back to the live tables.
    private val preludeClasses = HashMap(prog.classes)
    private val preludeGlobals = HashMap(prog.globals)
    fun cls(name: String) = preludeClasses[name] ?: prog.classes[name] ?: error("prelude class $name missing")
    fun member(c: String, m: String): Int = cls(c).find(m)?.offset ?: error("$c.$m missing")
    fun task(m: String) = member("CTask", m)
    fun dc(m: String) = member("CDC", m)
    fun global(n: String): Int = ((preludeGlobals[n] ?: prog.globals[n]) as? GlobalSym)?.addr ?: error("global $n missing")
    val fsGlobal = global("Fs")
    val msAddr = global("ms")
    val kbdAddr = global("kbd")
    val grAddr = global("gr")
    val winmgrAddr = global("winmgr")
    val cntsAddr = global("cnts")
    val msPos = member("CMsStateGlbls", "pos")
    val msPosText = member("CMsStateGlbls", "pos_text")
    val msPresnap = member("CMsStateGlbls", "presnap")
    val msLb = member("CMsStateGlbls", "lb")
    val msRb = member("CMsStateGlbls", "rb")
}

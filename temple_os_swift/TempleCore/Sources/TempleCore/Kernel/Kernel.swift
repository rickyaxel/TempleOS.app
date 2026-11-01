import Foundation

// Port of kernel/Kernel.kt (class Kernel, class Offsets). KernelEnv,
// PopupRequest, KInput and MenuSnap are in KernelTypes.swift.

/** Kotlin String.substringBeforeLast(c, missing). */
private func kSubstringBeforeLast(_ s: String, _ c: Character, _ missing: String) -> String {
    guard let i = s.lastIndex(of: c) else { return missing }
    return String(s[..<i])
}

/**
 * One TempleOS "machine" for a single program window: a VM with the system
 * prelude, cooperative tasks, the window's console document, its 640x480
 * indexed screen, input messages and timing. Driven by [step] from one thread.
 *
 * Threading: everything runs on the kernel thread except [post], [answerPopup],
 * [stopRequested], and reads of the published frame / menu snapshot / palette
 * by the UI. Kotlin `@Volatile` Bool/Int fields are plain vars; reference-typed
 * shared fields (menuSnapshot, popup, exitMessage, palette) are lock-protected.
 */
public final class Kernel {
    public static let W = 640
    public static let H = 480
    public static let READY = 0
    public static let SLEEP = 1
    /**
     * The shortest wait [step] asks for: a task due sooner is woken that much later at most (it was
     * 1 ms, which made every Sleep about 0.7 ms long on a phone, and songs drift; docs/audio).
     */
    public static let WAKE_FLOOR_NS: Int64 = 100_000
    /** The most of a late wake-up a task's clock hides ([taskNow]). */
    public static let MAX_LATE_NS: Int64 = 20_000_000
    public static let WAIT_MSG = 2
    public static let WAIT_FRAME = 3
    public static let SUSPENDED = 4
    public static let DEAD = 5
    public static let WAIT_POPUP = 6
    public static let FRAME_NS: Int64 = 33_333_333
    public static let SLICE = 4000
    /** Kernel/KernelA.HH CTask.display_flags bits. */
    public static let DISPLAYF_SHOW = 0
    public static let DISPLAYF_NO_BORDER = 3
    /**
     * A task that computes this long without yielding is preempted once so its window keeps
     * updating (TempleOS, which never preempts, would freeze the screen until it yields).
     */
    public static let WATCHDOG_NS: Int64 = 250_000_000
    /** Kernel/KernelA.HH message codes and window inhibit flags used by the window manager. */
    public static let MSG_MS_MOVE = 4, MSG_MS_L_DOWN = 5, MSG_MS_L_UP = 6, MSG_MS_L_D_DOWN = 7, MSG_MS_L_D_UP = 8
    public static let MSG_MS_R_DOWN = 9, MSG_MS_R_UP = 10, MSG_MS_R_D_DOWN = 11, MSG_MS_R_D_UP = 12
    public static let WIF_SELF_MS_L: Int64 = 0x8, WIF_SELF_MS_R: Int64 = 0x20, WIF_SELF_GRAB_SCROLL: Int64 = 0x200
    public static let WIF_FOCUS_TASK_CTRLS: Int64 = 0x40000, WIF_FOCUS_TASK_GRAB_SCROLL: Int64 = 0x200_0000
    public static let WIF_FOCUS_TASK_MS_L: Int64 = 0x80000, WIF_FOCUS_TASK_MS_L_D: Int64 = 0x100000
    public static let WIF_FOCUS_TASK_MS_R: Int64 = 0x200000, WIF_FOCUS_TASK_MS_R_D: Int64 = 0x400000
    /** WIG_USER_TASK_DFT (a terminal, where programs run) and WIG_TASK_DFT (Spawn). */
    public static let WIG_USER_TASK_DFT: Int64 = 0x1000
    public static let WIG_TASK_DFT: Int64 = 0x52F3FF
    /** Kernel/KMathB.HC LIN_CONGRUE_A/C and Kernel/KernelA.HH TASKf_NONTIMER_RAND. */
    public static let LIN_CONGRUE_A: Int64 = 6364136223846793005
    public static let LIN_CONGRUE_C: Int64 = 1442695040888963407
    public static let TASKF_NONTIMER_RAND = 14
    static let COMPILER_CH = chCode("Compiler")
    static let STD_PALETTE: [Int32] = Array(Palette.STD[0..<16])

    /** Shared lexed prelude defines (immutable tokens) to speed up boot. */
    private static var definesCache: [String: [Token]]?
    private static let definesCacheLock = NSLock()

    public let env: KernelEnv
    public let name: String
    public let shellMode: Bool

    public let vm: Vm
    public var mem: Arena { vm.mem }
    public var prog: Program { vm.prog }
    public let console = Console()
    public let fmt: Formatter
    public var font: [UInt8]!
    public var tasks: [HTask] = []
    public lazy var vga=VgaFramebuffer(self)
    public private(set) var current: HTask?
    public private(set) var mainTask: HTask?
    private var nextTaskId = 1
    private let inputQ = LockedQueue<KInput>()
    /** Kotlin @Volatile. */
    public var stopRequested = false
    /** Kotlin @Volatile. */
    public private(set) var finished = false
    public private(set) var exitMessage: String? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _exitMessage }
        set { stateLock.lock(); _exitMessage = newValue; stateLock.unlock() }
    }
    private var _exitMessage: String?
    /** Why the program ended, one ExitCategory (the same on every engine for the same failure); nil while it runs. */
    public private(set) var exitCategory: String? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _exitCategory }
        set { stateLock.lock(); _exitCategory = newValue; stateLock.unlock() }
    }
    private var _exitCategory: String?
    /** Kotlin `MutableMap<String, List<Token>>`: shared by reference with the lexer. */
    public var defines = Ref<[String: [Token]]>([:])

    /** Guards the reference-typed fields read by the UI thread. */
    private let stateLock = NSLock()

    // --- time
    private var bootNs: Int64 = 0
    /** When true (tests), sleeping fast-forwards time instead of waiting. */
    public var virtualTime = false
    private var vtime: Int64 = 0
    public func now() -> Int64 { virtualTime ? vtime : env.nanoTime() &- bootNs &- pausedNs }

    /**
     * Time the program spent paused (window menu > Pause, the app in the background, a hidden
     * window). TempleOS has no pause, so a paused program must not see that time pass: its timers,
     * physics and scores continue where they stopped (BomberGolf, CastleFrankenstein, RawHide).
     */
    private var pausedNs: Int64 = 0
    private var pausedAt: Int64 = 0
    private let pauseLock = NSLock()

    /** Called by the runner when it pauses (true) or resumes (false) the kernel. */
    public func clockPaused(_ p: Bool) {
        pauseLock.lock(); defer { pauseLock.unlock() }
        let t = env.nanoTime()
        if p { if pausedAt == 0 { pausedAt = t } }
        else if pausedAt != 0 { pausedNs &+= t &- pausedAt; pausedAt = 0 }
    }
    /** cnts.jiffies now: one jiffy is 1192 PIT clocks, 0.999009 ms ([TempleClock]). */
    public func jiffies() -> Int64 { TempleClock.jiffyAt(now()) }

    // --- graphics state
    /** Set when a program pushes/pops a menu (the UI rebuilds its menu bar). Kotlin @Volatile. */
    public var menuChanged = false

    /** Set once the program uses graphics (DCAlias, draw_it, Gr*, text layer). Kotlin @Volatile. */
    public var graphicsUsed = false
    /** True while every runnable task is blocked waiting for keyboard/mouse messages. Kotlin @Volatile. */
    public var waitingForKey = false
    /** Text layer cells (TEXT_COLS * TEXT_ROWS), Kotlin IntArray. */
    public var textCells = [Int](repeating: 0, count: 80 * 60)
    private let frameBuf: UnsafeMutablePointer<UInt8>
    /** Published frame for the UI (indexed 8-bit W*H, palette in [palette]). Guarded by [publishLock]. */
    public let published: UnsafeMutablePointer<UInt8>
    /** Kotlin @Volatile. */
    public private(set) var publishedVersion: Int64 = 0
    /**
     * Screen rect of the main task's window in [published] (x, y, w, h; border included when
     * the window has one), written with the frame under [publishLock]. The UI shows this part of
     * the 640x480 screen, so programs keep TempleOS's window coordinates (Adam/Win.HC).
     */
    public private(set) var publishedWindow: [Int] = [0, 0, Kernel.W, Kernel.H]
    public var palette: [Int32] {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _palette }
        set { stateLock.lock(); _palette = newValue; stateLock.unlock() }
    }
    private var _palette: [Int32] = Array(Palette.STD[0..<16])
    public private(set) var frameCount: Int64 = 0
    private var nextFrameAt: Int64 = 0
    public private(set) var fps = 0.0
    /** Frame composition and task timing (frame-rate readout, benchmarks). */
    public let frameStats = FrameStats()
    /** Speaker frequency changes Snd() passed to the platform (benchmarks, perf log). */
    public var speakerChanges: Int64 = 0
    private var lastSpeakerNs = Int64.min

    /**
     * Sets the PC speaker for [t]'s Snd(). The change is dated when TempleOS would have made it: a task
     * woken from Sleep/SleepUntil runs at its jiffy there, here as late as the host thread woke ([HTask.lateNs],
     * about 1 ms, more under load), so that much is taken off. Rests and notes then keep the program's own
     * timing (Play's 20 ms gaps), whatever the wake-up jitter. One kernel's changes never go back in time.
     */
    func speaker(_ t: HTask?, _ freq: Double) {
        var at = env.nanoTime() &- (t?.lateNs ?? 0)
        if at < lastSpeakerNs { at = lastSpeakerNs }
        lastSpeakerNs = at
        env.sound(self, freq, at)
    }

    /**
     * The program is gone (ended, stopped, closed): its speaker setting is off. TempleOS leaves a tone a
     * program left on sounding after it ends; here a window that ended never keeps sounding.
     */
    public func silence() { env.sound(self, 0.0, env.nanoTime()) }

    /**
     * Entry of TempleOS's sound-effect task (Adam/ASnd.HC SoundEffectTask, spawned by Noise() and
     * Sweep()); tasks started there get [HTask.speakerTask] (see the Sleep native).
     */
    public private(set) var soundEffectFp: Int64 = 0

    // --- message queue (TempleOS task messages)
    public final class Msg {
        public let code: Int
        public let a1: Int64
        public let a2: Int64
        public init(_ code: Int, _ a1: Int64, _ a2: Int64) { self.code = code; self.a1 = a1; self.a2 = a2 }
    }
    /** Kotlin ArrayDeque<Msg> (removeFirst / addLast -> append). */
    public var msgs: [Msg] = []

    // --- offsets resolved after the prelude is compiled
    public var o: Offsets!
    public var gfx: Gfx!
    public var raster: Raster!
    public var natives: Natives!
    public var sys: NativesSys!

    public var TEXT_COLS: Int { 80 }
    public var TEXT_ROWS: Int { 60 }

    public init(_ env: KernelEnv, _ name: String, shellMode: Bool = false) {
        self.env = env
        self.name = name
        self.shellMode = shellMode
        vm = Vm(1 << 20, env.memoryLimit)
        fmt = Formatter(vm.mem)
        frameBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: Kernel.W * Kernel.H)
        frameBuf.initialize(repeating: 0, count: Kernel.W * Kernel.H)
        published = UnsafeMutablePointer<UInt8>.allocate(capacity: Kernel.W * Kernel.H)
        published.initialize(repeating: 0, count: Kernel.W * Kernel.H)
        vm.callbackBreak = { [unowned self] t in self.pollBreakInCallback(t) }
        vm.callbackYield = { [unowned self] t in try self.yieldInCallback(t) }
        vm.sliceContinuation = { [unowned self] t in self.continueSlice(t) }
        fmt.defineSub = { [unowned self] sub, nameAddr in
            if nameAddr == 0 { return nil }
            let r = self.defineSub(sub, try self.mem.readStr(nameAddr))
            return r <= 0 ? nil : try self.mem.readStrBytes(Int64(r))
        }
    }

    /** TempleOS DEFINE strings and lists (HTT_DEFINE_STR): data and sub-entry pointers live in the arena. */
    public final class DefStr {
        public let data: Int, cnt: Int, subs: Int
        public init(_ data: Int, _ cnt: Int, _ subs: Int) { self.data = data; self.cnt = cnt; self.subs = subs }
    }
    public var defineStrs: [String: DefStr] = [:]

    public func defineSub(_ sub: Int64, _ name: String) -> Int {
        guard let d = defineStrs[name] else { return -1 }
        if sub < 0 || sub >= Int64(d.cnt) { return 0 }
        return Int(mem.ld8(d.subs + Int(sub) * 8))
    }

    deinit {
        vm.engine?.dispose()
        frameBuf.deallocate()
        published.deallocate()
    }

    // ------------------------------------------------------------ boot

    /** Compiles the system prelude and initialises the TempleOS globals. */
    public private(set) var sources:SourceServices!
    public lazy var dictionary = TempleDictionary(self)
    public private(set) var documents: DocumentRuntime!

    public func boot() throws {
        bootNs = env.nanoTime()
        guard let fnt = env.runtimeFile("font8x8.bin") else { throw VmKill("font8x8.bin missing") }
        font = fnt
        natives = Natives(self)
        natives.register(vm.natives)
        sys = NativesSys(self)
        sys.register(vm.natives)
        documents=DocumentRuntime(self);documents.register(vm.natives)
        sources=SourceServices(self);sources.register(vm.natives)
        let env = self.env
        let provider = ClosureSourceProvider { path in
            let n = path.substringAfterLast("/")
            return env.runtimeFile(n)
        }
        Kernel.definesCacheLock.lock()
        let cached = Kernel.definesCache
        Kernel.definesCacheLock.unlock()
        if let nb = native {
            let initF = try nb.bootPrelude(self)
            o = try Offsets(self)
            gfx = try Gfx(self)
            raster = try Raster(self)
            try runInit(initF)
            try initGlobals()
        } else if let cached = cached {
            guard let prelude = env.runtimeFile("Prelude.HC") else { throw VmKill("Prelude.HC missing") }
            defines = Ref(cached)
            // skip the #include of the defines: compile a copy of the prelude without it
            let txt = latin1(prelude).replacingOccurrences(of: "#include \"PreludeDefines.HC\"", with: "")
            let initF = try prog.compile(SourceFile.parse("::/Prelude.HC", latin1(txt)), "C:/Runtime", provider, defines, allowNative: true)
            o = try Offsets(self)
            gfx = try Gfx(self)
            raster = try Raster(self)
            try runInit(initF)
            try initGlobals()
        } else {
            guard let prelude = env.runtimeFile("Prelude.HC") else { throw VmKill("Prelude.HC missing") }
            let initF = try prog.compile(SourceFile.parse("::/Prelude.HC", prelude), "C:/Runtime", provider, defines, allowNative: true)
            Kernel.definesCacheLock.lock()
            Kernel.definesCache = defines.value
            Kernel.definesCacheLock.unlock()
            o = try Offsets(self)
            gfx = try Gfx(self)
            raster = try Raster(self)
            try runInit(initF)
            try initGlobals()
        }
        soundEffectFp = (prog.globals["SoundEffectTask"] as? FuncSym).map { prog.funcPtr($0) } ?? 0
        console.setColors(Console.DFT_FG, Console.DFT_BG)
        prog.evalAtCompileTime = { [unowned self] e in
            do {
                let f = try self.prog.compileExprFunc(e)
                guard let t = self.current.flatMap({ $0.state != Kernel.DEAD ? $0 : nil }) ?? self.adamTask else { return nil }
                return try self.vm.callFunction(t, self.prog.funcPtr(f))
            } catch let c as CompileError {
                throw c // Kotlin catches only RuntimeException
            } catch { return nil }
        }
        prog.serviceHandler = { [unowned self] name in if name == "dictionary" {try self.dictionary.initialize()} }
        preludeGlobals = Set(prog.globals.compactMap { $0.value is GlobalSym ? $0.key : nil })
    }

    /**
     * Names of the system's global variables (the prelude's), recorded at the end of [boot]: the
     * native dynamic expression engine lets ExePrint text use only the program's own globals.
     */
    public private(set) var preludeGlobals: Set<String> = []

    /** Native evaluation of ExePrint/ExePrint2 text in a native kernel (DynExpr), with its cache and counters. */
    public lazy var dynExpr: DynExprEngine = DynExprEngine(self)
    /** ExePrint/ExePrint2 calls evaluated natively by [dynExpr] (provenance). */
    public var dynExprEvaluations: Int64 { dynExpr.stats.evaluations }
    /** Texts [dynExpr] lexed, parsed and checked (the rest came from its cache). */
    public var dynExprCompiles: Int64 { dynExpr.stats.compiles }

    private func initGlobals() throws {
        vm.exceptChOff = o.task("except_ch")
        vm.catchExceptOff = o.task("catch_except")
        jiffiesAddr = o.cntsAddr + o.member("CCntsGlbls", "jiffies")
        timerAddr = o.cntsAddr + o.member("CCntsGlbls", "timer")
        mem.st8(o.cntsAddr + o.member("CCntsGlbls", "time_stamp_freq"), 1_000_000_000)
        mem.st8(o.cntsAddr + o.member("CCntsGlbls", "time_stamp_kHz_freq"), 1_000_000)
        // winmgr.fps
        mem.st8(o.winmgrAddr + o.member("CWinMgrGlbls", "fps"), bits(30.0))
        mem.st8(o.msAddr + o.member("CMsStateGlbls", "dbl_time"), bits(0.350)) // Kernel/SerialDev/Mouse.HC
        // a wheel mouse, as TempleOS finds on a PC (and on QEMU's PS/2 mouse); the WHL buttons and
        // pointer wheels turn it
        mem.st1(o.msAddr + o.member("CMsStateGlbls", "has_wheel"), 1)
        mem.st1(o.msAddr + o.member("CMsStateGlbls", "show"), 1)
        // Kernel/SerialDev/Mouse.HC MsHardInit: the pointer starts in the middle of the screen (programs
        // that draw at the pointer, like TicTacToe's cursor, show it there at once; reference VM)
        let ms = o.msAddr
        let cx = Int64(Kernel.W / 2), cy = Int64(Kernel.H / 2)
        mem.st8(ms + o.msPos, cx); mem.st8(ms + o.msPos + 8, cy)
        mem.st8(ms + o.msPresnap, cx); mem.st8(ms + o.msPresnap + 8, cy)
        mem.st8(ms + o.msPosText, cx / 8); mem.st8(ms + o.msPosText + 8, cy / 8)
        hwLastX = cx; hwLastY = cy
        qPresnapX = cx; qPresnapY = cy
        mem.st8(o.global("sys_mobile_platform"), Int64(try prog.stringAddr(latin1(Brand.appName))))
        try gfx.initScreens()
        let textG = o.global("text")
        mem.st8(textG + o.member("CTextGlbls", "rows"), Int64(TEXT_ROWS))
        mem.st8(textG + o.member("CTextGlbls", "cols"), Int64(TEXT_COLS))
        mem.st8(textG + o.member("CTextGlbls", "font"), Int64(gfx.fontAddr))
        let bc = textG + o.member("CTextGlbls", "border_chars")
        for i in 2...13 { mem.st1(bc + i, Int64(i)) }
        let cpu = try mem.calloc(Int64(o.cls("CCPU").size))
        hostCpuAddr = cpu
        mem.st8(cpu + o.member("CCPU", "addr"), Int64(cpu))
        mem.st8(o.global("Gs"), Int64(cpu))
        try callHolyC("GrSetUpPens")
    }

    private func runInit(_ initF: FuncSym) throws {
        let t = try newTask("Prelude", nil)
        try vm.pushCall(t, Int64(initF.index), [])
        setCurrent(t)
        var guardN = 0
        while true {
            let r = try vm.run(t, 1_000_000)
            if r == Vm.R_DONE { break }
            if r == Vm.R_DEAD { throw VmKill("prelude failed: \(t.deathMessage ?? "null")") }
            guardN += 1
            if guardN > 1000 { throw VmKill("prelude did not finish") }
        }
        removeTask(t)
        adamTask = t
        t.state = Kernel.READY
        mem.st8(o.global("adam_task"), Int64(t.fsAddr))
    }

    /** Calls a HolyC function by name with all arguments supplied (no defaults). */
    @discardableResult
    public func callHolyC(_ name: String, _ args: Int64..., task: HTask? = nil) throws -> Int64 {
        return try callHolyC(name, args, task: task)
    }

    /**
     * Calls a HolyC function by name with all arguments supplied (no defaults), on [task], else on the
     * current task, else on the Adam task. Never on a task that has ended: its stack may already belong to
     * a new task (a frame pushed there overwrote a just-spawned Noise task's argument: BadMem in Whap).
     */
    @discardableResult
    public func callHolyC(_ name: String, _ args: [Int64], task: HTask? = nil) throws -> Int64 {
        guard let f = prog.globals[name] as? FuncSym else { throw VmKill("HolyC function \(name) missing") }
        let live = current.flatMap { $0.state != Kernel.DEAD ? $0 : nil }
        guard let t = task ?? live ?? adamTask else { throw VmKill("no task") }
        let saved = current
        defer { if task != nil, let s = saved { setCurrent(s) } }
        if let tk = task { setCurrent(tk) }
        return try vm.callFunction(t, prog.funcPtr(f), args)
    }

    public private(set) var adamTask: HTask?

    // ------------------------------------------------------------ tasks

    private func removeTask(_ t: HTask) {
        if let i = tasks.firstIndex(where: { $0 === t }) { tasks.remove(at: i) }
    }

    public func newTask(_ name: String, _ parent: HTask?) throws -> HTask {
        let id = nextTaskId
        nextTaskId += 1
        let t = try HTask(vm, id, name)
        if o != nil {
            let sz = Int64(o.cls("CTask").size)
            let fs = try mem.calloc(sz)
            t.fsAddr = fs
            let m = mem
            m.st8(fs + o.task("addr"), Int64(fs))
            m.st4(fs + o.task("task_signature"), chCode("TskS"))
            m.st8(fs + o.task("task_num"), Int64(t.id))
            m.st8(fs + o.task("rand_seed"), rng.nextLong())
            let nm = latin1(name)
            let tn = fs + o.task("task_name")
            for i in 0..<min(nm.count, 31) { m.st1(tn + i, Int64(nm[i])) }
            let tt = fs + o.task("task_title")
            for i in 0..<min(nm.count, 100) { m.st1(tt + i, Int64(nm[i])) }
            m.st1(fs + o.task("text_attr"), Int64((Console.DFT_BG << 4) | Console.DFT_FG))
            m.st1(fs + o.task("border_attr"), Int64((Console.DFT_BG << 4) | 1))
            // Kernel/KTask.HC: Spawn gives WIG_TASK_DFT; a program runs in the user's terminal task (WIG_USER_TASK_DFT)
            m.st4(fs + o.task("win_inhibit"), parent != nil ? Kernel.WIG_TASK_DFT : Kernel.WIG_USER_TASK_DFT)
            if let parent = parent, parent.fsAddr != 0 {
                m.st8(fs + o.task("parent_task"), Int64(parent.fsAddr))
                m.st8(fs + o.task("cur_dir"), m.ld8(parent.fsAddr + o.task("cur_dir")))
            } else {
                m.st8(fs + o.task("cur_dir"), Int64(try prog.stringAddr(latin1("C:/Home"))))
            }
            setWindow(t)
            if adamTask != nil || prog.globals["MobileTaskInit"] != nil {
                do { try callHolyC("MobileTaskInit", Int64(fs), task: adamTask ?? t) } catch {}
            }
        }
        t.state = Kernel.READY
        tasks.append(t)
        return t
    }

    /** Window geometry: every program window is a maximized 640x480 client. */
    /**
     * Initial window: a maximized TempleOS terminal with its border (what WinMax gives a bordered
     * window: text columns 1..78, rows 2..58, so pix 8..631 x 16..471). Programs then change it
     * with the original WinBorder/WinMax/WinHorz/WinVert (Prelude.HC).
     */
    public func setWindow(_ t: HTask) {
        let m = mem, fs = t.fsAddr
        let l: Int64 = 1, r = Int64(TEXT_COLS - 2), top: Int64 = 2, b = Int64(TEXT_ROWS - 2)
        m.st8(fs + o.task("win_left"), l); m.st8(fs + o.task("win_right"), r)
        m.st8(fs + o.task("win_top"), top); m.st8(fs + o.task("win_bottom"), b)
        m.st8(fs + o.task("win_width"), r - l + 1); m.st8(fs + o.task("win_height"), b - top + 1)
        m.st8(fs + o.task("pix_left"), l * 8); m.st8(fs + o.task("pix_right"), (r + 1) * 8 - 1)
        m.st8(fs + o.task("pix_width"), (r - l + 1) * 8)
        m.st8(fs + o.task("pix_top"), top * 8); m.st8(fs + o.task("pix_bottom"), (b + 1) * 8 - 1)
        m.st8(fs + o.task("pix_height"), (b - top + 1) * 8)
        m.st4(fs + o.task("display_flags"), 1 << Int64(Kernel.DISPLAYF_SHOW))
    }

    /** Window of task [fs] in text cells: (left, top, right, bottom, hasBorder). */
    private func windowCells(_ fs: Int) -> [Int] {
        let m = mem
        let border = m.ld4(fs + o.task("display_flags")) & (1 << Int64(Kernel.DISPLAYF_NO_BORDER)) == 0
        // program-writable: clamp to the screen (a TempleOS window never extends past it)
        func cl(_ v: Int64, _ hi: Int) -> Int { Int(min(max(v, -1), Int64(hi))) }
        return [cl(m.ld8(fs + o.task("win_left")), TEXT_COLS), cl(m.ld8(fs + o.task("win_top")), TEXT_ROWS),
                cl(m.ld8(fs + o.task("win_right")), TEXT_COLS), cl(m.ld8(fs + o.task("win_bottom")), TEXT_ROWS), border ? 1 : 0]
    }

    public func setCurrent(_ t: HTask) {
        current = t
        if o != nil { mem.st8(o.fsGlobal, Int64(t.fsAddr)) }
    }

    public func taskByFs(_ addr: Int64) -> HTask? {
        if let t = tasks.first(where: { Int64($0.fsAddr) == addr }) { return t }
        if let a = adamTask, Int64(a.fsAddr) == addr { return a }
        return nil
    }

    // ------------------------------------------------------------ program loading

    /** Compiles [src] (a .HC file) and starts it as the main task. */
    private var launchEntry:String?
    private var launchArgs:[Int64]=[]
    public func runProgram(_ path: String, _ src: [UInt8]) throws {
        if let bytes=env.runtimeFile("home-profile.tsv") {
            for line in latin1(bytes).split(separator:"\n") {
                let fields=line.split(separator:"\t");if fields.count != 2 || !path.lowercased().hasPrefix(fields[0].lowercased()) {continue}
                if let home=Paths.normalize("C:/Home",String(fields[1])),home.hasPrefix("C:/Home/"),let fs=env.fs,!fs.isDir(home) {try fs.mkdir(home)}
            }
        }
        let dir = kSubstringBeforeLast(path, "/", "C:/Home")
        let t = try newTask(path.substringAfterLast("/").substringBefore("."), nil)
        mainTask = t
        setCurrent(t)
        termInit(t)
        if let data=env.runtimeFile("program-launch.tsv"),let row=latin1(data).components(separatedBy:"\n").map({$0.components(separatedBy:"\t")}).first(where:{$0.count>=3 && $0[0].caseInsensitiveCompare(path) == .orderedSame}) {
            launchEntry=row[2];launchArgs=[]
            for arg in row.dropFirst(3).prefix(8) {
                if arg.hasPrefix("i") {launchArgs.append(Int64(arg.dropFirst()) ?? 0)}
                else {let chars=Array(arg.dropFirst());var bytes:[UInt8]=[];var at=0;while at+1<chars.count {bytes.append(UInt8(String(chars[at...at+1]),radix:16) ?? 0);at+=2};launchArgs.append(Int64(try prog.stringAddr(bytes)))}
            }
            if row[1]=="adam-resident" {mem.st8(o.global("adam_task"),Int64(t.fsAddr));mem.st8(o.global("sys_winmgr_task"),Int64(t.fsAddr))}
        }
        mem.st8(t.fsAddr + o.task("cur_dir"), Int64(try prog.stringAddr(latin1(dir))))
        do {
            session = try native?.session(self) ?? prog.session(SourceFile.parse(path, src), dir, vfsProvider(), defines)
            if !(try advanceSession(t)) { t.state = Kernel.DEAD; finished = true }
        } catch let e as CompileError {
            compileFailed(t, e)
        } catch let f as VmFault { // e.g. allocating a string constant in a corrupted heap, or globals that do not fit
            loadFailed(t, f)
        }
    }

    /** A fault while the program's source was compiled or its translated image loaded (not raised by its code). */
    private func loadFailed(_ t: HTask, _ f: VmFault) {
        classifyDeath(t, ExitCategory.of(f.ch, f.message, loading: true))
        taskDied(t, f.message)
    }

    /** ExePrint caught a compile error: Fs->except_ch is left at 'Compiler', as on TempleOS (Kernel.kt compileErrorCaught). */
    public func compileErrorCaught(_ t: HTask) { if t.fsAddr != 0 { mem.st8(t.fsAddr + o.task("except_ch"), Kernel.COMPILER_CH) } }

    /** Records why the program ends when its main task dies of [category] (the first cause wins). */
    private func classifyDeath(_ t: HTask, _ category: String) {
        if t === mainTask && !shellMode && exitCategory == nil { exitCategory = category }
    }

    /**
     * A program runs in the user's terminal task, which Adam/DolDoc/DocTerm.HC DocTermNew gives the
     * window's two scroll bars (WinScrollsInit): they are drawn on the border, take clicks and the
     * wheel there, and programs such as ScrollBars and Transform read their positions.
     */
    private func termInit(_ t: HTask) {
        if prog.globals["WinScrollsInit"] != nil { _ = try? callHolyC("WinScrollsInit", Int64(t.fsAddr), task: t) }
    }

    /** The unit being executed on the main task, chunk by chunk (TempleOS JIT order). */
    private var session: ChunkSource?

    /**
     * Pure Swift mode: the prelude and the program come from their ahead-of-time translation
     * (purenative), and no HolyC is compiled or interpreted in this kernel. Set before [boot].
     */
    public var native: NativeBinding? {
        willSet { precondition(natives == nil, "set native before boot") }
    }

    /** True when this kernel runs translated native code (Pure Swift mode). */
    public var isNative: Bool { native != nil }

    private func compileFailed(_ t: HTask, _ e: CompileError) {
        console.write("$RED$Compile error: \(e.message)$FG$\n")
        exitMessage = e.message
        if !shellMode { exitCategory = ExitCategory.COMPILE_ERROR }
        session = nil
        if shellMode { busy = false; t.state = Kernel.DEAD; shellPrompt() } else { t.state = Kernel.DEAD; finished = true; tasks.removeAll() }
    }

    /** Compiles and queues the next chunk of the session on [t]. Returns false when done. */
    private func advanceSession(_ t: HTask) throws -> Bool {
        guard let s = session else { return false }
        var args:[Int64]=[]
        let f:FuncSym
        if let next=try s.next() {f=next}
        else {
            guard let entry=launchEntry else {session=nil;return false}
            launchEntry=nil;args=launchArgs
            guard let fn=prog.globals[entry] as? FuncSym else {throw CompileError("Launch entry point missing: \(entry)")};f=fn
        }
        chunkStartNs = now()
        t.depth = 0; t.sp = 0; t.hCount = 0; t.handlerBase = 0
        t.msp = t.mspBase; t.fp = t.mspBase
        try vm.pushCall(t, Int64(f.index), args)
        t.state = Kernel.READY
        return true
    }

    /** Shell mode: compiles and runs one command line on the shell task. */
    @discardableResult
    public func execLine(_ line: String) throws -> Bool {
        let t: HTask
        if let mt = mainTask { t = mt } else { t = try newTask("Terminal", nil); mainTask = t; setCurrent(t); termInit(t) }
        if t.state != Kernel.DEAD && t.depth > 0 { return false } // still running
        let dir = try curDir(t)
        do {
            session = prog.session(SourceFile.parse("C:/Home/Cmd.HC", latin1(line + "\n")), dir, vfsProvider(), defines, answers: true)
            t.deathMessage = nil
            answerKind = -1
            busy = true
            if !(try advanceSession(t)) { busy = false; t.state = Kernel.DEAD; shellPrompt(); return true }
        } catch let f as VmFault {
            console.write("$RED$\(f.message)$FG$\n")
            session = nil
            t.state = Kernel.DEAD
            busy = false
            return false
        } catch let e as CompileError {
            console.write("$RED$\(e.message)$FG$\n")
            session = nil
            t.state = Kernel.DEAD
            busy = false
            return false
        }
        return true
    }

    /** True while a shell command is executing. Kotlin @Volatile. */
    public private(set) var busy = false

    public func curDir(_ t: HTask) throws -> String {
        let s = try mem.readStr(mem.ld8(t.fsAddr + o.task("cur_dir")))
        return s.isEmpty ? "C:/Home" : s
    }

    public func vfsProvider() -> SourceProvider {
        let env = self.env
        return ClosureSourceProvider { path in env.fs?.readFile(path) }
    }

    // ------------------------------------------------------------ input (UI thread)

    private var _lastInteractionNanos:Int64=0
    public private(set) var lastInteractionNanos:Int64 {
        get {stateLock.lock();defer {stateLock.unlock()};return _lastInteractionNanos}
        set {stateLock.lock();_lastInteractionNanos=newValue;stateLock.unlock()}
    }

    public func post(_ e: KInput) {
        inputQ.add(e)
        wakeLock?.notifyAllLocked()
    }

    /** Monitor the runner waits on; notified by [post]. */
    public var wakeLock: Monitor?

    private var lastLb = false
    private var lastRb = false

    private var lbDownFrame: Int64 = 0
    private var rbDownFrame: Int64 = 0
    private var deferredMouse: (Int, Int, Bool, Bool, Int)?
    private var keyDownFrame = [Int64](repeating: 0, count: 256)
    private var pendingKeyUps = Set<Int>()

    private func releaseKeyBit(_ bit: Int) {
        let bm = o.kbdAddr + o.member("CKbdStateGlbls", "down_bitmap")
        let bm2 = o.kbdAddr + o.member("CKbdStateGlbls", "down_bitmap2")
        let mask: Int64 = 1 << Int64(bit & 7)
        mem.st1(bm + (bit >> 3), mem.ld1(bm + (bit >> 3)) & ~mask)
        mem.st1(bm2 + (bit >> 3), mem.ld1(bm2 + (bit >> 3)) & ~mask)
    }

    /**
     * The mouse driver's update of the ms globals (Kernel/SerialDev/Mouse.HC MsUpdate, MsHardSpeedSet).
     * ([mx], [my]) is in screen pixels (the UI maps touches into [publishedWindow]). Messages are queued
     * once per frame by [queueInputMsgs], as TempleOS's window manager does.
     */
    private func applyMouse(_ mx: Int, _ my: Int, _ lb: Bool, _ rb: Bool, _ wheel: Int) {
        let z = mem.ld8(o.msAddr + o.msPos + 16) &+ Int64(wheel)
        msUpdate(Int64(mx), Int64(my), z, lb, rb)
    }

    private var hwLastX: Int64 = 0, hwLastY: Int64 = 0, hwLastAt: Int64 = 0
    private var hwSpeed = 0.0
    private var msEvt = false

    /** Kernel/SerialDev/Mouse.HC MsUpdate (including grid snap) plus the hardware speed (pixels per second). */
    public func msUpdate(_ x0: Int64, _ y0: Int64, _ z: Int64, _ lb: Bool, _ rb: Bool) {
        let ms = o.msAddr
        let grid=o.global("ms_grid")
        func snap(_ value:Int64,_ axis:String)->Int64 {
            if mem.ld1(grid+o.member("CGridGlbls","snap"))==0 {return value}
            let step=d(mem.ld8(grid+o.member("CGridGlbls",axis))),off=d(mem.ld8(grid+o.member("CGridGlbls",axis+"_offset")))
            if step>0 && step.isFinite && off.isFinite {let v=(Double(value)/step).rounded(.towardZero)*step+off;return Int64(min(max(v,Double(Int32.min)),Double(Int32.max)))};return value
        }
        let x = min(max(snap(x0,"x"), 0), Int64(Kernel.W - 1)), y = min(max(snap(y0,"y"), 0), Int64(Kernel.H - 1))
        let moved = x != mem.ld8(ms + o.msPos) || y != mem.ld8(ms + o.msPos + 8) || z != mem.ld8(ms + o.msPos + 16)
        mem.st8(ms + o.msPresnap, x0); mem.st8(ms + o.msPresnap + 8, y0); mem.st8(ms + o.msPresnap + 16, z)
        mem.st8(ms + o.msPos, x); mem.st8(ms + o.msPos + 8, y); mem.st8(ms + o.msPos + 16, z)
        mem.st8(ms + o.msPosText, x / 8); mem.st8(ms + o.msPosText + 8, y / 8)
        let changed = moved || (mem.ld1(ms + o.msLb) != 0) != lb || (mem.ld1(ms + o.msRb) != 0) != rb
        mem.st1(ms + o.msLb, lb ? 1 : 0)
        mem.st1(ms + o.msRb, rb ? 1 : 0)
        let sca = o.kbdAddr + o.member("CKbdStateGlbls", "scan_code")
        var sc = mem.ld8(sca) & ~(Keys.SCF_MS_L_DOWN | Keys.SCF_MS_R_DOWN)
        if lb { sc |= Keys.SCF_MS_L_DOWN }
        if rb { sc |= Keys.SCF_MS_R_DOWN }
        mem.st8(sca, sc)
        if lb && !lastLb { lbDownFrame = frameCount }
        if rb && !lastRb { rbDownFrame = frameCount }
        lastLb = lb; lastRb = rb
        if moved { // MsHardSpeedSet: distance over the time since the last motion (or boot)
            let now = self.now()
            let dd = (x - hwLastX) * (x - hwLastX) + (y - hwLastY) * (y - hwLastY)
            if dd != 0 && now > hwLastAt { hwSpeed = Double(dd).squareRoot() * 1e9 / Double(now - hwLastAt) }
            hwLastX = x; hwLastY = y; hwLastAt = now
        }
        if changed { msEvt = true }
    }

    /** Adam/Win.HC WinMsUpdate: ms.speed follows the hardware while it moves and decays by 5% a frame. */
    private func winMsUpdate() {
        let ms = o.msAddr
        let sp = o.member("CMsStateGlbls", "speed")
        if msEvt {
            mem.st8(ms + sp, Int64(bitPattern: hwSpeed.bitPattern))
            mem.st8(ms + o.member("CMsStateGlbls", "timestamp"), now())
            msEvt = false
        } else {
            mem.st8(ms + sp, Int64(bitPattern: (Double(bitPattern: UInt64(bitPattern: mem.ld8(ms + sp))) * 0.95).bitPattern))
        }
    }

    // Adam/WinMgr.HC WinQueIPMsgs state (ms.left_dbl_time etc.) and its ms_last buttons.
    private var leftDblAt: Int64 = 0, leftDbl = false, leftDownSent = false
    private var rightDblAt: Int64 = 0, rightDbl = false, rightDownSent = false
    private var singleLx: Int64 = 0, singleLy: Int64 = 0, singleRx: Int64 = 0, singleRy: Int64 = 0
    private var qLastLb = false, qLastRb = false
    private var qPresnapX: Int64 = 0, qPresnapY: Int64 = 0
    private var grabbing = false, grabX: Int64 = 0, grabY: Int64 = 0, grabZ: Int64 = 0

    /**
     * One window manager pass over the mouse (Adam/WinMgr.HC WinMgrTask, once per frame):
     * CTRL + left drag scrolls the window ("grab scroll", CTRL + right button resets it) unless the
     * task sets WIF_SELF_GRAB_SCROLL; otherwise the messages of WinQueIPMsgs are queued, except while
     * the pointer is on one of the task's controls (the control gets the click instead).
     */
    private func queueInputMsgs() {
        guard let t = mainTask else { return }
        let fs = t.fsAddr
        let inhibit = mem.ld4(fs + o.task("win_inhibit"))
        let ms = o.msAddr
        let ctrlHeld = mem.ld8(o.kbdAddr + o.member("CKbdStateGlbls", "scan_code")) & Keys.SCF_CTRL != 0
        if ctrlHeld && inhibit & (Kernel.WIF_SELF_GRAB_SCROLL | Kernel.WIF_FOCUS_TASK_GRAB_SCROLL) == 0 {
            let x = mem.ld8(ms + o.msPos), y = mem.ld8(ms + o.msPos + 8), z = mem.ld8(ms + o.msPos + 16)
            if lastLb {
                if !grabbing {
                    grabbing = true
                    grabX = x &- mem.ld8(fs + o.task("scroll_x")); grabY = y &- mem.ld8(fs + o.task("scroll_y")); grabZ = z &- mem.ld8(fs + o.task("scroll_z"))
                }
                mem.st8(fs + o.task("scroll_x"), (x &- grabX) & ~7)
                mem.st8(fs + o.task("scroll_y"), (y &- grabY) & ~7)
                mem.st8(fs + o.task("scroll_z"), z &- grabZ)
            } else {
                grabbing = false
                if lastRb { mem.st8(fs + o.task("scroll_x"), 0); mem.st8(fs + o.task("scroll_y"), 0); mem.st8(fs + o.task("scroll_z"), 0) }
            }
            // the window manager stays in its grab loop: no messages, and the button edges are used up
            qLastLb = lastLb; qLastRb = lastRb
            qPresnapX = mem.ld8(ms + o.msPresnap); qPresnapY = mem.ld8(ms + o.msPresnap + 8)
            return
        }
        grabbing = false
        let que = inhibit & Kernel.WIF_FOCUS_TASK_CTRLS != 0 || !msOnCtrl(t)
        let px = mem.ld8(ms + o.msPresnap), py = mem.ld8(ms + o.msPresnap + 8)
        if px != qPresnapX || py != qPresnapY {
            qPresnapX = px; qPresnapY = py
            if que {
                let x = mem.ld8(ms + o.msPos), y = mem.ld8(ms + o.msPos + 8)
                enqueue(Msg(Kernel.MSG_MS_MOVE, x &- mem.ld8(fs + o.task("pix_left")) &- mem.ld8(fs + o.task("scroll_x")),
                            y &- mem.ld8(fs + o.task("pix_top")) &- mem.ld8(fs + o.task("scroll_y"))))
            }
        }
        queueButtonMsgs(que)
    }

    /** True when ms.pos is on one of [t]'s controls (CtrlInside, Adam/Ctrls/CtrlsA.HC). */
    private func msOnCtrl(_ t: HTask) -> Bool {
        do {
            return try callHolyC("MobileTaskHasCtrls", Int64(t.fsAddr), task: t) != 0 && callHolyC("MobileMsInCtrl", Int64(t.fsAddr), task: t) != 0
        } catch { return false }
    }

    /**
     * Button messages exactly as TempleOS's window manager queues them (Adam/WinMgr.HC WinQueIPMsgs).
     * Unless the focus task sets WIF_FOCUS_TASK_MS_L_D (WIG_DBL_CLICK, part of WIG_TASK_DFT), a click is
     * held for ms.dbl_time (0.350 s) to see whether a second one follows: then MSG_MS_L_D_DOWN/UP, else a
     * late MSG_MS_L_DOWN at the first click's position. A double click inside the window of a task that
     * does not set WIF_SELF_MS_L is the ESC key (right button: SHIFT-ESC), as the WinMgr task does for
     * document windows.
     */
    private func queueButtonMsgs(_ que: Bool) {
        guard let t = mainTask else { return }
        let fs = t.fsAddr
        let inhibit = mem.ld4(fs + o.task("win_inhibit"))
        let ms = o.msAddr
        let x = mem.ld8(ms + o.msPos), y = mem.ld8(ms + o.msPos + 8)
        let ox = mem.ld8(fs + o.task("pix_left")) &+ mem.ld8(fs + o.task("scroll_x"))
        let oy = mem.ld8(fs + o.task("pix_top")) &+ mem.ld8(fs + o.task("scroll_y"))
        let a1 = x &- ox, a2 = y &- oy
        // ms.dbl_time is program-writable: only a sane value is converted
        let dblS = Double(bitPattern: UInt64(bitPattern: mem.ld8(ms + o.member("CMsStateGlbls", "dbl_time"))))
        let dbl: Int64 = dblS.isFinite && dblS > 0 && dblS < 1e6 ? Int64(dblS * 1e9) : 0
        let now = self.now()
        let lb = lastLb, rb = lastRb
        func q(_ m: Msg) { if que { enqueue(m) } }
        func inside() -> Bool {
            x >= mem.ld8(fs + o.task("pix_left")) && x <= mem.ld8(fs + o.task("pix_right")) &&
                y >= mem.ld8(fs + o.task("pix_top")) && y <= mem.ld8(fs + o.task("pix_bottom"))
        }
        // left button
        if leftDblAt != 0 {
            if now > leftDblAt {
                if leftDbl {
                    if !leftDownSent { q(Msg(Kernel.MSG_MS_L_D_DOWN, a1, a2)); leftDownSent = true }
                    if !lb {
                        q(Msg(Kernel.MSG_MS_L_D_UP, a1, a2)); leftDblAt = 0
                        if inhibit & (Kernel.WIF_SELF_MS_L | Kernel.WIF_FOCUS_TASK_MS_L) == 0 && inside() { q(Msg(2, Int64(Keys.CH_ESC), 0)) }
                    }
                } else {
                    if !leftDownSent { q(Msg(Kernel.MSG_MS_L_DOWN, singleLx &- ox, singleLy &- oy)); leftDownSent = true }
                    if !lb { q(Msg(Kernel.MSG_MS_L_UP, a1, a2)); leftDblAt = 0 }
                }
            } else if lb && !qLastLb { leftDblAt = now; leftDbl = true }
        } else if inhibit & Kernel.WIF_FOCUS_TASK_MS_L_D != 0 {
            if lb && !qLastLb { q(Msg(Kernel.MSG_MS_L_DOWN, a1, a2)) }
            else if !lb && qLastLb { q(Msg(Kernel.MSG_MS_L_UP, a1, a2)) }
        } else if lb && !qLastLb {
            leftDbl = false; leftDownSent = false; leftDblAt = now &+ dbl; singleLx = x; singleLy = y
        }
        // right button
        if rightDblAt != 0 {
            if now > rightDblAt {
                if rightDbl {
                    if !rightDownSent { q(Msg(Kernel.MSG_MS_R_D_DOWN, a1, a2)); rightDownSent = true }
                    if !rb {
                        q(Msg(Kernel.MSG_MS_R_D_UP, a1, a2)); rightDblAt = 0
                        if inhibit & (Kernel.WIF_SELF_MS_R | Kernel.WIF_FOCUS_TASK_MS_R) == 0 && inside() { q(Msg(2, Int64(Keys.CH_SHIFT_ESC), 0)) }
                    }
                } else {
                    if !rightDownSent { q(Msg(Kernel.MSG_MS_R_DOWN, singleRx &- ox, singleRy &- oy)); rightDownSent = true }
                    if !rb { q(Msg(Kernel.MSG_MS_R_UP, a1, a2)); rightDblAt = 0 }
                }
            } else if rb && !qLastRb { rightDblAt = now; rightDbl = true }
        } else if inhibit & Kernel.WIF_FOCUS_TASK_MS_R_D != 0 {
            if rb && !qLastRb { q(Msg(Kernel.MSG_MS_R_DOWN, a1, a2)) }
            else if !rb && qLastRb { q(Msg(Kernel.MSG_MS_R_UP, a1, a2)) }
        } else if rb && !qLastRb {
            rightDbl = false; rightDownSent = false; rightDblAt = now &+ dbl; singleRx = x; singleRy = y
        }
        qLastLb = lb; qLastRb = rb
    }

    private func processInput() throws {
        while true {
            guard let e = inputQ.poll() else { break }
            lastInteractionNanos=now()
            if case .mouse = e {} else {menuRefreshFrames=2}
            switch e {
            case .key(let ch0, let esc0, let down):
                let code = Int(esc0 & 0xFF)
                // Kernel/SerialDev/Keyboard.HC KbdBuildSC: SHIFT/CTRL/ALT held down are flags of every
                // scan code until released, and ASCII comes from the scan code (KbdMsgsQue)
                switch code {
                case Keys.SC_SHIFT: heldMods = down ? heldMods | Keys.SCF_SHIFT : heldMods & ~Keys.SCF_SHIFT
                case Keys.SC_CTRL: heldMods = down ? heldMods | Keys.SCF_CTRL : heldMods & ~Keys.SCF_CTRL
                case Keys.SC_ALT: heldMods = down ? heldMods | Keys.SCF_ALT : heldMods & ~Keys.SCF_ALT
                default: break
                }
                var esc = esc0, ch = ch0
                if heldMods & ~esc != 0 {
                    esc |= heldMods
                    let c = Keys.scanCode2Char(esc & (Keys.SCF_SHIFT | Keys.SCF_CTRL | 0x7F))
                    if c != 0 { ch = c }
                }
                // CTRL-ALT-letter (ESC='t', TAB='n') is the system's, never the program's (KbdBuildSC)
                if down && esc & Keys.SCF_CTRL != 0 && esc & Keys.SCF_ALT != 0 {
                    let c = code == Keys.SC_ESC ? 116 : code == Keys.SC_TAB ? 110 : Keys.scanCode2Char(Int64(code))
                    if c >= 97 && c <= 122 { ctrlAlt(Character(UnicodeScalar(UInt8(c)))); continue }
                }
                let sc = esc & 0xFF
                let bm = o.kbdAddr + o.member("CKbdStateGlbls", "down_bitmap")
                let bm2 = o.kbdAddr + o.member("CKbdStateGlbls", "down_bitmap2")
                let bit = Int(sc)
                // down_bitmap: merged scan code; down_bitmap2: the raw one, with bit 7 for E0 keys
                let bit2 = Keys.isE0(bit) ? bit | 0x80 : bit
                let w = bm + (bit >> 3)
                let w2 = bm2 + (bit2 >> 3)
                let mask: Int64 = 1 << Int64(bit & 7)
                let mask2: Int64 = 1 << Int64(bit2 & 7)
                if down {
                    // the quick-tap latch below counts from the first press, not from typematic repeats:
                    // a held key's release must clear the bit at once (TempleOS clears it before queuing
                    // the key-up, so Titanium's gun does not re-tilt)
                    if mem.ld1(w) & mask == 0 { keyDownFrame[bit] = frameCount }
                    mem.st1(w, mem.ld1(w) | mask); mem.st1(w2, mem.ld1(w2) | mask2)
                    mem.st8(o.kbdAddr + o.member("CKbdStateGlbls", "last_down_scan_code"), esc)
                    mem.st8(o.kbdAddr + o.member("CKbdStateGlbls", "cnt"), mem.ld8(o.kbdAddr + o.member("CKbdStateGlbls", "cnt")) &+ 1)
                    pendingKeyUps.remove(bit)
                } else if frameCount < keyDownFrame[bit] + 2 {
                    // key latching (as for mouse clicks): programs that poll the key
                    // bitmap once per frame (FlapBat) must see a quick tap
                    pendingKeyUps.insert(bit)
                } else {
                    mem.st1(w, mem.ld1(w) & ~mask); mem.st1(w2, mem.ld1(w2) & ~mask2)
                }
                // kbd.scan_code keeps the mouse button bits (MsUpdate) and the held modifiers
                let sca = o.kbdAddr + o.member("CKbdStateGlbls", "scan_code")
                let msBits = mem.ld8(sca) & (Keys.SCF_MS_L_DOWN | Keys.SCF_MS_R_DOWN)
                mem.st8(sca, (esc & ~(Keys.SCF_MS_L_DOWN | Keys.SCF_MS_R_DOWN)) | msBits | heldMods)
                mem.st8(o.kbdAddr + o.member("CKbdStateGlbls", "timestamp"), now())
                enqueue(Msg(down ? 2 : 3, Int64(ch), esc))
            case .mouse(let mx, let my, let lb, let rb, let wheel):
                // Click latching: programs often poll ms.lb once per frame (Demo/Games/
                // TicTacToe). A press released before two frame boundaries have passed
                // would be invisible, so the release waits (later events replace it).
                let early = (!lb && lastLb && frameCount < lbDownFrame + 2) || (!rb && lastRb && frameCount < rbDownFrame + 2)
                if early && !(lb || rb) { deferredMouse = (mx, my, lb, rb, wheel); continue }
                if let d = deferredMouse { deferredMouse = nil; applyMouse(d.0, d.1, d.2, d.3, d.4) }
                applyMouse(mx, my, lb, rb, wheel)
            case .breakKey:
                stopAll = true
                breakMain()
            case .raw(let code, let a1, let a2):
                if code == -2 { // MSG_KEY_DOWN_UP
                    enqueue(Msg(2, a1, a2)); enqueue(Msg(3, a1, a2 | Keys.SCF_KEY_UP))
                } else { enqueue(Msg(code, a1, a2)) }
            case .exec(let line):
                if busy { enqueue(Msg(2, 0, 0)) } else { try execLine(line) }
            }
        }
    }

    private var taskMessages: [Int:[Msg]] = [:]
    public private(set) var focusTask: HTask?
    public func focus(_ task:HTask?) {
        if let task=task,task.state != Kernel.DEAD {focusTask=task;mem.st8(o.global("sys_focus_task"),Int64(task.fsAddr))}
    }
    public func messageCount(_ task:HTask?) -> Int {task == nil || task === mainTask ? msgs.count : (taskMessages[task!.id]?.count ?? 0)}
    public func clearMessages() {if let task=current,task !== mainTask {taskMessages[task.id]=[]} else {msgs.removeAll()}}
    public func takeMessage(_ mask:Int64) -> Msg? {
        while messageCount(current)>0 {
            let message:Msg
            if let task=current,task !== mainTask {message=taskMessages[task.id]!.removeFirst()} else {message=msgs.removeFirst()}
            if message.code>=0 && message.code<64 && (ushr(mask,message.code)&1) != 0 {return message}
        }
        return nil
    }
    public func enqueueTo(_ task:HTask?,_ message:Msg) {
        let target=task ?? mainTask
        if let target=target,target !== mainTask {var queue=taskMessages[target.id] ?? [];if queue.count>=256 {queue.removeFirst()};queue.append(message);taskMessages[target.id]=queue}
        else {if msgs.count>=256 {msgs.removeFirst()};msgs.append(message)}
        if let target=target,target.state==Kernel.WAIT_MSG {target.state=Kernel.READY;target.resumed=true}
    }
    private func enqueue(_ message:Msg) {enqueueTo(focusTask?.state != Kernel.DEAD ? focusTask : mainTask,message)}


    /** Ctrl-Alt-C / Stop: raise 'Break' in the foreground task. */
    public func breakMain() {
        guard let t = mainTask else { return }
        if t.state == Kernel.DEAD { return }
        pendingBreak = true
    }

    private var pendingBreak = false
    private var breakAt: Int64 = 0

    /** CTRL-ALT-C (scan code 0x2E), with CTRL/ALT from the key itself or held down. */
    private func isBreakKey(_ ch: Int, _ esc: Int64, _ down: Bool) -> Bool {
        let sc = esc | heldMods
        return down && sc & Keys.SCF_CTRL != 0 && sc & Keys.SCF_ALT != 0 &&
            ((esc & 0xFF) == 0x2E || ch == 99 || ch == 67 || ch == 3)
    }

    /** SHIFT/CTRL/ALT flags of the modifier keys held down (from their key events). */
    private var heldMods: Int64 = 0

    /**
     * Kernel/KeyDev.HC CTRL-ALT keys: C breaks the program and X kills it (the window's Stop);
     * M toggles mute. The others (debugger, task switching, fonts, new terminal...) have no
     * counterpart in a single program window and are swallowed, as TempleOS does for every letter.
     */
    public var onCtrlAlt: ((Character) -> Void)?
    private func ctrlAlt(_ c: Character) {
        switch c {
        case "c": breakMain()
        case "m": natives.toggleMute()
        default: onCtrlAlt?(c)
        }
    }

    /** True while [frame] runs draw_it callbacks. */
    private var inFrame = false

    /** The task [runTask] is running (callbacks on it may yield, see [yieldInCallback]). */
    private var steppingTask: HTask?
    private var yielding = false

    /**
     * V-17: called by [Vm.callFunction] between slices of a callback that a native made on the
     * task being stepped (QSort comparator, Line plot, ExeFile...). The native's frames are on
     * the host stack, so the kernel cannot return from step(); it keeps the machine running
     * from here instead: input, a due frame (without that task's draw_it) and one slice for
     * every other ready task. Not re-entrant: callbacks inside those slices do not yield.
     */
    private func yieldInCallback(_ t: HTask) throws {
        if yielding || inFrame || t !== steppingTask { return }
        yielding = true
        do {
            defer { setCurrent(t); yielding = false }
            try processInput()
            updateClock()
            if now() >= nextFrameAt {
                inFrame = true
                defer { inFrame = false }
                try frame()
            }
            wakeTasks()
            for o in tasks where o !== t && o.state == Kernel.READY && o.nestLevel == 0 { try runTask(o) }
        }
        // another task ended this one (Kill, or the program ended): unwind the native silently
        if t.state == Kernel.DEAD { throw VmKill("task ended") }
    }

    /**
     * Called by [Vm.callFunction] between slices of a HolyC callback that a native or the
     * frame invoked (QSort comparator, Line plot, draw_it). The kernel cannot switch tasks
     * there, so Break is taken out of the input queue and raised inside the callback (V-17).
     * A draw_it callback gets it too (which disables draw_it); the main task still owes it.
     */
    private func pollBreakInCallback(_ t: HTask) -> Bool {
        let removed = inputQ.removeAll { e in
            switch e {
            case .breakKey: self.stopAll = true; return true
            case .key(let ch, let esc, let down): return self.isBreakKey(ch, esc, down)
            default: return false
            }
        }
        if !pendingBreak && removed == 0 { return false }
        pendingBreak = true
        if inFrame { return true }
        if t !== mainTask { return false }
        pendingBreak = false
        breakAt = now()
        return true
    }

    // ------------------------------------------------------------ scheduler

    /**
     * Runs tasks for up to [budgetNs]. Returns the nanoseconds until the kernel
     * next needs to run (0 = runnable now), or -1 if the program has finished.
     */
    public func step(_ budgetNs: Int64) throws -> Int64 {
        if stopRequested { terminate("Stopped."); return -1 }
        if finished && !shellMode { vm.engine?.shutdown(); return -1 }
        let start = env.nanoTime()
        stepStart = start; stepBudget = budgetNs
        try processInput()
        if pendingBreak {
            pendingBreak = false
            if let t = mainTask, t.state != Kernel.DEAD {
                breakAt = now()
                if !vm.inject(t, chCode("Break")) { taskDied(t, "Break") } else if t.state != Kernel.SUSPENDED { t.state = Kernel.READY }
            }
        }
        while true {
            if virtualTime && now() >= virtualStopAt { return 0 }
            if !deadStacks.isEmpty { releaseDeadStacks() }
            updateClock()
            // non-preemptive (Doc/Welcome.DD "non-preemptive multi-tasking"): a task that has not yielded
            // keeps running; no frame (draw_it) and no other task until it Yields, sleeps, waits or ends
            let cur = inFlight.flatMap { f in f.state == Kernel.READY && tasks.contains(where: { $0 === f }) ? f : nil }
            if cur == nil { inFlight = nil }
            else if now() - inFlightSince < Kernel.WATCHDOG_NS {
                taskR0 = now()
                let w0 = env.nanoTime()
                inStepLoop = true
                do { defer { inStepLoop = false; wallTaskNs &+= env.nanoTime() &- w0 }; try runTask(cur!) }
                // (a native task may have continued on its own thread: taskR0 is its last slice's start)
                let r1 = now()
                busyNs &+= r1 &- taskR0
                taskOwedNs &-= r1 &- taskR0
                frameStats.task(r1 &- taskR0)
                if finished && !shellMode { return -1 }
                if env.nanoTime() - start >= budgetNs { return 0 }
                if inputQ.isNotEmpty { try processInput() }
                continue
            } else { inFlightSince = now() } // watchdog: let one frame and the other tasks run, then continue it
            if now() >= nextFrameAt && taskOwedNs <= 0 {
                let f0 = now()
                let w0 = env.nanoTime()
                inFrame = true
                defer { inFrame = false; wallFrameNs &+= env.nanoTime() &- w0 }
                try frame()
                let f1 = now()
                busyNs &+= f1 &- f0
                frameStats.frame(f1 &- f0)
                // Fairness: when composing a frame (draw_it, blits) takes longer than the frame interval,
                // the tasks get at least as much time as the frame took before the next one, so the frame
                // rate drops instead of the program starving (slow devices, heavy draw_it). Only tasks that
                // want the CPU are owed that time: with none ready the next frame follows at once (it used
                // to wait anyway, which halved the frame rate of slow frames for nothing).
                if f1 &+ (f1 &- f0) > nextFrameAt { taskOwedNs = f1 &- f0 }
            }
            wakeTasks()
            let t = pickReady()
            waitingForKey = t == nil && tasks.contains { $0.state == Kernel.WAIT_MSG }
            guard let rt = t else {
                // no task wants the owed time: compose the next frame now, but within this step's budget
                // (frames slower than the frame interval would otherwise follow each other forever here)
                if taskOwedNs > 0 { taskOwedNs = 0; if env.nanoTime() - start < budgetNs { continue } }
                let wait = nextWakeIn()
                if virtualTime && wait > 0 {
                    vtime += min(wait, Kernel.FRAME_NS)
                    if tasks.contains(where: { $0.state == Kernel.SLEEP || $0.state == Kernel.WAIT_FRAME }) { continue }
                    return 0
                }
                return allDone() ? -1 : wait
            }
            taskR0 = now()
            let w0 = env.nanoTime()
            inStepLoop = true
            do { defer { inStepLoop = false; wallTaskNs &+= env.nanoTime() &- w0 }; try runTask(rt) }
            let r1 = now()
            busyNs &+= r1 &- taskR0
            taskOwedNs &-= r1 &- taskR0
            frameStats.task(r1 &- taskR0)
            if finished && !shellMode { return -1 }
            if env.nanoTime() - start >= budgetNs { return 0 }
            if inputQ.isNotEmpty { try processInput() }
        }
    }

    // MARK: native fast path (port of Kernel.continueSlice)

    private var stepStart: Int64 = 0
    private var stepBudget: Int64 = 0
    private var taskR0: Int64 = 0
    /** True while step()'s loop runs a task (not a nested runTask from a callback, not boot). */
    private var inStepLoop = false
    private var runDepth = 0
    private var sliceBefore: Int64 = 0
    private var sliceBeforeTicks: Int64 = 0

    /**
     * Native engine (PureNative): [t]'s slice has just ended (budget or yield) on its own thread. When the
     * scheduler's next decision would be to run [t] again at once — nothing else can happen first: no frame
     * due, no input, no other task ready or waking, no step budget used up — this does exactly the
     * bookkeeping step() and runTask() would do between the two slices, in the same order, and returns the
     * next slice's budget: the task continues without a thread switch. Otherwise it changes nothing and
     * returns 0 (the task hands the CPU back and the scheduler decides). The interpreter never calls it.
     */
    public func continueSlice(_ t: HTask) -> Int {
        if !inStepLoop || runDepth != 1 || steppingTask !== t || current !== t { return 0 }
        if t.state != Kernel.READY || stopRequested || finished || pendingBreak || shellMode { return 0 }
        if inputQ.isNotEmpty || !deadStacks.isEmpty || !tasks.contains(where: { $0 === t }) { return 0 }
        // prospective values (nothing mutated yet)
        let ticks = vm.ticksExecuted - sliceBeforeTicks
        let dv: Int64 = virtualTime ? ((virtualCostTicks || vm.engine != nil) ? ticks * virtualNsPerTick : (vm.instructionsExecuted - sliceBefore) * virtualNsPerInstr) : 0
        let nowAfter = virtualTime ? vtime + dv : env.nanoTime() &- bootNs &- pausedNs
        let budgetOut = !t.yielded // ran out of its slice without yielding: it keeps the CPU (inFlight)
        if env.nanoTime() - stepStart >= stepBudget { return 0 }
        if virtualTime && nowAfter >= virtualStopAt { return 0 }
        if budgetOut {
            let since1 = inFlight !== t ? (virtualTime ? vtime : nowAfter) : inFlightSince
            if nowAfter - since1 >= Kernel.WATCHDOG_NS { return 0 } // the watchdog lets a frame and the others run
        } else {
            if let o = inFlight, o !== t, o.state == Kernel.READY, tasks.contains(where: { $0 === o }) { return 0 }
            let owed = taskOwedNs &- (nowAfter &- taskR0)
            if nowAfter >= nextFrameAt && owed <= 0 { return 0 }
            for o in tasks {
                switch o.state {
                case Kernel.SLEEP: if nowAfter >= o.wakeAt { return 0 }
                case Kernel.WAIT_FRAME: if frameCount > o.blockToken { return 0 }
                case Kernel.WAIT_MSG: if messageCount(o)>0 { return 0 }
                case Kernel.WAIT_POPUP: if popup?.result != nil { return 0 }
                default: break
                }
            }
            let n = tasks.count
            var pick: HTask?
            for i in 0..<n { let c = tasks[(rr + i) % n]; if c.state == Kernel.READY { pick = c; break } }
            if pick !== t { return 0 }
        }
        // runTask's end (R_SLICE)
        steppingTask = nil
        if budgetOut { if inFlight !== t { inFlight = t; inFlightSince = now() } }
        else { inFlight = nil } // (it was t, or a task that is not ready: the loop drops it)
        sliceTrace?(t, Vm.R_SLICE, ticks)
        if virtualTime { vtime += dv }
        // step(): after the slice
        let r1 = now()
        busyNs &+= r1 &- taskR0
        taskOwedNs &-= r1 &- taskR0
        frameStats.task(r1 &- taskR0)
        // step(): the loop's next pass up to runTask(t)
        updateClock()
        if !budgetOut {
            let n = tasks.count
            for i in 0..<n where tasks[(rr + i) % n] === t { rr = (rr + i + 1) % max(n, 1); break }
            waitingForKey = false
        }
        taskR0 = now()
        // runTask(t)'s start
        updateClock(t)
        setCurrent(t)
        sliceBefore = vm.instructionsExecuted
        sliceBeforeTicks = vm.ticksExecuted
        sliceTrace?(t, -1, 0)
        steppingTask = t
        t.yielded = false
        return Kernel.SLICE
    }

    /**
     * Host wall-clock time the kernel thread spent running tasks and composing frames (draw_it, ODEs,
     * blits), even in virtual time, where `now()` does not move during a frame (benchmarks split them).
     */
    public private(set) var wallTaskNs: Int64 = 0
    public private(set) var wallFrameNs: Int64 = 0

    /** Time tasks and frames used since the last frame, for Gs->idle_factor. */
    private var busyNs: Int64 = 0
    /** Task time still owed after a frame that took longer than the frame interval (fairness). */
    private var taskOwedNs: Int64 = 0
    private var idleSince: Int64 = 0

    /** The task that ran out of slice without yielding (it keeps the CPU), and since when. */
    private var inFlight: HTask?
    private var inFlightSince: Int64 = 0

    private var rr = 0
    private func pickReady() -> HTask? {
        let n = tasks.count
        for i in 0..<n {
            let t = tasks[(rr + i) % n]
            if t.state == Kernel.READY { rr = (rr + i + 1) % max(n, 1); return t }
        }
        return nil
    }

    private func wakeTasks() {
        let now = self.now()
        for t in tasks {
            switch t.state {
            case Kernel.SLEEP: if now >= t.wakeAt { t.state = Kernel.READY; t.resumed = true; t.lateNs = min(now - t.wakeAt, Kernel.MAX_LATE_NS) }
            case Kernel.WAIT_FRAME: if frameCount > t.blockToken { t.state = Kernel.READY; t.resumed = true; t.lateNs = 0 }
            case Kernel.WAIT_MSG: if messageCount(t)>0 { t.state = Kernel.READY; t.resumed = true; t.lateNs = 0 }
            case Kernel.WAIT_POPUP: if popup?.result != nil { t.state = Kernel.READY; t.resumed = true; t.lateNs = 0 }
            default: break
            }
        }
    }

    private func nextWakeIn() -> Int64 {
        let now = self.now()
        var w = nextFrameAt - now
        for t in tasks where t.state == Kernel.SLEEP { w = min(w, t.wakeAt - now) }
        if !graphicsUsed && !tasks.contains(where: { $0.state == Kernel.WAIT_FRAME || $0.state == Kernel.SLEEP }) {
            // idle console program waiting for input: sleep long (input wakes us)
            w = tasks.contains(where: { $0.state == Kernel.WAIT_MSG }) ? 500_000_000 : w
        }
        return max(w, Kernel.WAKE_FLOOR_NS)
    }

    private func allDone() -> Bool { !tasks.contains(where: { $0.state != Kernel.DEAD }) && !shellMode }

    /** Virtual-time cost per instruction (tests): models a ~100M instr/s device. */
    public var virtualNsPerInstr: Int64 = 10
    /**
     * Virtual-time cost per budget tick (a backward branch or a HolyC call), used instead of the
     * instruction count when [virtualCostTicks] is set or the kernel is native (which counts no
     * instructions). Both engines charge ticks at the same points, so a program then takes the same
     * virtual time interpreted and native (parity tests).
     */
    public var virtualNsPerTick: Int64 = 250
    public var virtualCostTicks = false
    /** Tests: called before (result -1) and after every task slice with its result (Vm.R_*) and the budget ticks it used. */
    public var sliceTrace: ((HTask, Int, Int64) -> Void)?
    /** Virtual-time mode: step() returns once now() reaches this (deterministic test stepping). */
    public var virtualStopAt: Int64 = Int64.max

    private func runTask(_ t: HTask) throws {
        // the clock as this task sees it: cnts.jiffies stays within a jiffy of real time, as TempleOS's timer
        // interrupt keeps it (a frame composed since the scheduler's updateClock once shifted a whole Play by 8 ms)
        updateClock(t)
        setCurrent(t)
        sliceBefore = vm.instructionsExecuted
        sliceBeforeTicks = vm.ticksExecuted
        sliceTrace?(t, -1, 0)
        let r: Int
        let outer = steppingTask
        steppingTask = t
        t.yielded = false
        runDepth += 1
        do {
            // restored as soon as the slice ends (Kotlin's finally), before the R_DONE handling: a task_end_cb
            // run by taskEnded must not yield into other tasks (it did here: the scheduling then differed)
            defer { steppingTask = outer; runDepth -= 1 }
            r = try vm.run(t, Kernel.SLICE)
        } catch let k as VmKill {
            if t.state != Kernel.DEAD { taskDied(t, k.message) }
            return
        } catch let u as VmUncaught {
            classifyDeath(t, ExitCategory.of(u.ch, u.message, loading: false))
            taskDied(t, u.message); return
        } catch let c as CompileError {
            throw c // Kotlin: CompileError is not a RuntimeException
        } catch {
            classifyDeath(t, ExitCategory.INTERNAL_RUNTIME_ERROR)
            taskDied(t, "internal error: \(errorMessage(error))"); return
        }
        // (continueSlice may have run further slices of a native task: their counters start here)
        let before = sliceBefore
        let beforeTicks = sliceBeforeTicks
        // a slice that ran out (no Yield/Sleep/wait) leaves the task mid-computation: it keeps the CPU
        if r == Vm.R_SLICE && !t.yielded && t.state == Kernel.READY { if inFlight !== t { inFlight = t; inFlightSince = now() } }
        else if inFlight === t { inFlight = nil }
        switch r {
        case Vm.R_SLICE: break
        case Vm.R_BLOCKED: break
        case Vm.R_DONE:
            if t === mainTask && session != nil {
                if shellMode {
                    answerKind = session!.answerKind; answer = t.result; answerNs = now() &- chunkStartNs
                }
                do {
                    if !(try advanceSession(t)) { taskEnded(t, nil) }
                } catch let e as CompileError { compileFailed(t, e) } catch let f as VmFault { loadFailed(t, f) }
            } else { taskEnded(t, nil) }
        case Vm.R_DEAD:
            if t.deathCode == 0 && t.deathMessage?.hasPrefix("Unhandled exception ''") == true {taskEnded(t,nil);return}
            classifyDeath(t, ExitCategory.of(t.deathCode, t.deathMessage, loading: false))
            taskDied(t, t.deathMessage ?? "unhandled exception")
        default: break
        }
        if t.state == Kernel.DEAD && t.depth >= 0 && r != Vm.R_DONE && r != Vm.R_DEAD { taskEnded(t, nil) }
        sliceTrace?(t, r, vm.ticksExecuted - beforeTicks)
        if virtualTime {
            vtime += (virtualCostTicks || vm.engine != nil) ? (vm.ticksExecuted - beforeTicks) * virtualNsPerTick
                : (vm.instructionsExecuted - before) * virtualNsPerInstr
        }
    }

    private func taskDied(_ t: HTask, _ msg: String) {
        if msg.contains("'Break'") || msg == "Break" { console.write("\n$RED$Program stopped (Break).$FG$\n") }
        else { console.write("\n$RED$\(msg)$FG$\n") }
        taskEnded(t, msg)
    }

    public func taskEnded(_ t: HTask, _ msg: String?) {
        if t.state == Kernel.DEAD && !tasks.contains(where: { $0 === t }) { return }
        t.state = Kernel.DEAD
        // task_end_cb (e.g. SndTaskEndCB)
        let cb = mem.ld8(t.fsAddr + o.task("task_end_cb"))
        if cb != 0 {
            mem.st8(t.fsAddr + o.task("task_end_cb"), 0)
            do { setCurrent(t); try vm.callFunction(t, cb) } catch {}
        }
        sources.taskGone(t)
        taskMessages.removeValue(forKey:t.id)
        if focusTask === t {focusTask=mainTask !== t ? mainTask : nil}
        if !(shellMode && t === mainTask) { sys.taskGone(Int64(t.fsAddr)) } // the terminal task outlives its commands
        if !(shellMode && t === mainTask) { vm.engine?.taskGone(t) }
        if t === mainTask {
            if !shellMode {menuSnapshot=[]};menuChanged=true
            if shellMode || stopAll { silence() }
            if shellMode {
                if msg == nil { printAnswer() }
                busy = false
                t.depth = 0; t.sp = 0; t.hCount = 0
                t.state = Kernel.READY
                // children die with the command, each through its task_end_cb as Kernel/KTask.HC TaskEnd kills
                // them (a song task's SndTaskEndCB). Noise and Sweep tasks play on, as every task a command
                // spawns does on TempleOS: they end by themselves, and their SoundEffectEndTaskCB gives back the
                // music.mute that Noise/Sweep took (killed before they ran, it never came back: Play went silent).
                // The window's Stop ends them too.
                for c in tasks where c !== t && c.state != Kernel.DEAD && (!c.speakerTask || stopAll) { taskEnded(c, nil) }
                for c in tasks where c !== t && (!c.speakerTask || stopAll) { c.state = Kernel.DEAD; deadStacks.append(c.mspBase) }
                tasks.removeAll { $0 !== t && (!$0.speakerTask || stopAll) }
                setCurrent(t)
                t.state = Kernel.DEAD
                shellPrompt()
            } else {
                exitMessage = msg
                if exitCategory == nil {
                    exitCategory = msg == nil ? ExitCategory.NORMAL : (msg == "Break" || msg!.contains("'Break'")) ? ExitCategory.STOPPED : ExitCategory.UNHANDLED_EXCEPTION
                }
                mainEnded = true
                removeTask(t)
                deadStacks.append(t.mspBase)
                // TempleOS runs a program in the user's terminal task: when its code returns (or is broken
                // with CTRL-ALT-C) the tasks it spawned keep running there (CharAnimation's Animate task).
                // The window's Stop ends them all, as closing the terminal would.
                if stopAll || !tasks.contains(where: { $0.state != Kernel.DEAD }) { endProgram() }
            }
        } else {
            removeTask(t)
            deadStacks.append(t.mspBase) // released by step() once the task can no longer run
            if mainEnded && !tasks.contains(where: { $0.state != Kernel.DEAD }) { endProgram() }
        }
    }

    /** True once the main task's code has returned; spawned tasks may still be running. */
    public private(set) var mainEnded = false
    /** Set by the window's Stop (KInput.breakKey): ending the main task ends every task. */
    private var stopAll = false

    private func endProgram() {
        for c in tasks { c.state = Kernel.DEAD; vm.engine?.taskGone(c) }
        tasks.removeAll()
        sys.allTasksGone()
        silence()
        // one last frame, so output printed just before the end is on the screen (Demo/Graphics/Extents.HC);
        // compose draws the text cells laid out by the previous pass, so two passes
        if graphicsUsed && !stopAll { try? compose(); try? compose() }
        finished = true
    }

    /** Stacks of ended tasks (TempleOS frees a task's stack when it dies; they were leaked: OutMem after ~110 Spawns). */
    private var deadStacks: [Int] = []

    private func releaseDeadStacks() {
        // the task that ran last may be one of them: Fs must not keep pointing at a task whose stack is reused
        if current?.state == Kernel.DEAD, let a = adamTask { setCurrent(a) }
        for p in deadStacks { mem.freeStack(p) }
        deadStacks.removeAll()
    }

    // Command-line answer (TempleOS Fs->answer, answer_type, answer_time).
    private var answerKind = -1
    private var answer: Int64 = 0
    private var answerNs: Int64 = 0
    private var chunkStartNs: Int64 = 0

    /** Prints the answer line exactly as TempleOS's CmdLinePmt (Compiler/CMisc.HC) does. */
    private func printAnswer() {
        if answerKind < 0 { return }
        let secs = Int64(bitPattern: (Double(answerNs) / 1e9).bitPattern)
        let f: String; let args: [Int64]
        switch answerKind {
        case Program.ANS_F64: f = "%8.6fs ansf=%15.7g\n"; args = [secs, answer]
        case Program.ANS_INT: f = "%8.6fs ans=0x%08X=%d\n"; args = [secs, answer, answer]
        default: f = "%8.6fs\n"; args = [secs]
        }
        if let out = try? fmt.format(latin1(f), args, 0, args.count) { console.write(out) }
        answerKind = -1
    }

    public var onShellIdle: (() -> Void)?
    private func shellPrompt() { onShellIdle?() }

    public func terminate(_ msg: String) {
        if let e = vm.engine {
            for t in tasks { e.taskGone(t) }
            if let m = mainTask { e.taskGone(m) }
            e.shutdown()
        }
        if finished { return }
        silence()
        for t in tasks { t.state = Kernel.DEAD }
        tasks.removeAll()
        finished = true
        busy = false
        exitMessage = msg
        if exitCategory == nil { exitCategory = ExitCategory.STOPPED }
    }

    /** Called by natives to block the current task. */
    public func block(_ t: HTask, _ state: Int) {
        if t.nestLevel > 0 { return } // never block inside callbacks
        t.state = state
        t.blocked = true
    }

    // ------------------------------------------------------------ popups

    /** The open popup, shown by the UI; answered with [answerPopup]. Kotlin @Volatile. */
    public var popup: PopupRequest? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _popup }
        set { stateLock.lock(); _popup = newValue; stateLock.unlock() }
    }
    private var _popup: PopupRequest?

    /** Called by the UI thread with the chosen value (or -1 = cancel). */
    public func answerPopup(_ value: Int64) {
        lastInteractionNanos=now()
        popup?.result = value
        wakeLock?.notifyAllLocked()
    }

    // ------------------------------------------------------------ line input (GetStr)

    public var lineReady = false

    // ------------------------------------------------------------ clock & frames

    /** cnts.jiffies and cnts.timer in the arena (updateClock runs before every task slice). */
    /** Kernel-owned telemetry address; never trust the program-writable Gs global for host writes. */
    private var hostCpuAddr = 0
    private var jiffiesAddr = 0
    private var timerAddr = 0

    private func updateClock(_ t: HTask? = nil) {
        let n = t.map { taskNow($0) } ?? now()
        if jiffiesAddr == 0 { return } // before initGlobals
        mem.st8(jiffiesAddr, TempleClock.jiffyAt(n))
        mem.st8(timerAddr, n / 1000)
    }

    /**
     * The time [t] sees (cnts.jiffies, tS, Sleep, SleepUntil): TempleOS's timer interrupt wakes a task at its
     * jiffy, so a task the host woke late runs as if on time, its clock behind by that lateness (at most
     * [MAX_LATE_NS]; a longer stall is not hidden). Play and Sleep loops then keep their rhythm instead of
     * adding every late wake-up to the song (docs/audio/TEMPLEOS_SOUND.md).
     */
    public func taskNow(_ t: HTask) -> Int64 { now() &- t.lateNs }

    private var lastFrameNs: Int64 = 0

    /** The main task shows controls of its own (Prelude MobileTaskHasOwnCtrls). */
    private func ownCtrls() -> Bool {
        guard let m = mainTask, m.state != Kernel.DEAD else { return false }
        return ((try? callHolyC("MobileTaskHasOwnCtrls", Int64(m.fsAddr), task: m)) ?? 0) != 0
    }

    private func frame() throws {
        let now = self.now()
        nextFrameAt = max(nextFrameAt + Kernel.FRAME_NS, now + Kernel.FRAME_NS / 2)
        if lastFrameNs != 0 {
            let dt = max(now - lastFrameNs, 1)
            fps = fps * 0.9 + (1e9 / Double(dt)) * 0.1
        }
        lastFrameNs = now
        frameCount += 1
        if let d = deferredMouse, (!lastLb || frameCount >= lbDownFrame + 2) && (!lastRb || frameCount >= rbDownFrame + 2) {
            deferredMouse = nil; applyMouse(d.0, d.1, d.2, d.3, d.4)
        }
        if !pendingKeyUps.isEmpty {
            for bit in pendingKeyUps where frameCount >= keyDownFrame[bit] + 2 { releaseKeyBit(bit); pendingKeyUps.remove(bit) }
        }
        winMsUpdate()
        queueInputMsgs()
        mem.st8(o.winmgrAddr + o.member("CWinMgrGlbls", "updates"), frameCount)
        mem.st8(o.winmgrAddr + o.member("CWinMgrGlbls", "fps"), bits(fps > 0 ? fps : 30.0))
        // Gs->idle_factor: the share of the last frame no task wanted the CPU (TempleOS measures it in
        // the idle task); the window manager sizes the ODE time budget with it (Adam/Gr/GrScrn.HC)
        let span = now &- idleSince
        if span > 0 && idleSince != 0 {
            mem.st8(hostCpuAddr + o.member("CCPU", "idle_factor"), bits(min(max(1.0 - Double(busyNs) / Double(span), 0.0), 1.0)))
        }
        busyNs = 0; idleSince = now
        do {try documents.refreshDynamic()} catch let f as VmFault {if let task=mainTask {classifyDeath(task,ExitCategory.of(f.ch,f.message,loading:false));taskDied(task,"DolDoc callback: \(f.message)")}}
        let menuPointer=menuOwner().map {mem.ld8($0.fsAddr+o.task("cur_menu"))} ?? 0
        if menuChanged || menuPointer != lastMenuPointer {menuRefreshFrames=2}
        if menuRefreshFrames>0 || frameCount % 15 == 1 {
            snapshotMenu();lastMenuPointer=menuPointer;menuChanged=false;menuRefreshFrames=max(0,menuRefreshFrames-1)
        }
        if !graphicsUsed {
            for t in tasks where t.state != Kernel.DEAD && mem.ld8(t.fsAddr + o.task("draw_it")) != 0 { graphicsUsed = true; break }
        }
        // TempleOS has one screen for text and graphics: a program that draws on gr.dc, shows a control
        // or changes the palette is shown as that screen, not as a text console
        // (the HolyC check runs only when the others are false, as in Kotlin: it executes on the main task)
        if !graphicsUsed && (gfx.screenTouched() || palette != Kernel.STD_PALETTE || gfx.textLayerTouched() || ownCtrls()) { graphicsUsed = true }
        if graphicsUsed {
            // the screen and its DCs live in the program's arena: a program that overwrote their pointers
            // (wild writes) faults here, and dies of it like any HolyC fault, inside its own arena (F-5)
            do { try compose() } catch let f as VmFault {
                guard let m = mainTask ?? tasks.first else { return }
                classifyDeath(m, ExitCategory.of(f.ch, f.message, loading: false))
                taskDied(m, "Unhandled exception '\(vm.chStr(f.ch))' in the window manager: \(f.message)")
            }
        }
    }

    /** Latest program menu (Fs->cur_menu of the main task), for the UI. Kotlin @Volatile. */
    public private(set) var menuSnapshot: [MenuSnap] {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _menuSnapshot }
        set { stateLock.lock(); _menuSnapshot = newValue; stateLock.unlock() }
    }
    private var _menuSnapshot: [MenuSnap] = []
    private var lastMenuPointer:Int64 = -1
    private var menuRefreshFrames=0

    /** Kotlin LongArray reads that throw (ArrayIndexOutOfBounds) outside the arena. */
    private func safeLd1(_ a: Int) throws -> Int64 {
        if a < 0 || a + 1 > mem.size { throw VmIndexOutOfBounds() }
        return mem.ld1(a)
    }
    private func safeLd8(_ a: Int) throws -> Int64 {
        if a < 0 || a + 8 > mem.size { throw VmIndexOutOfBounds() }
        return mem.ld8(a)
    }

    /** Adam/Menu.HC MenuTask: inherit a menu from the focused task's parents. */
    private func menuOwner()->HTask? {
        var task=focusTask
        if task == nil || task?.state == Kernel.DEAD {task=mainTask}
        var depth=0
        while let t=task,depth<64 {
            depth+=1
            if t.state != Kernel.DEAD && mem.ld8(t.fsAddr+o.task("cur_menu")) != 0 {return t}
            task=taskByFs(mem.ld8(t.fsAddr+o.task("parent_task")))
        }
        return nil
    }
    private func snapshotMenu() {
        guard let t = menuOwner() else {menuSnapshot=[];return}
        if t.state == Kernel.DEAD { menuSnapshot = []; return }
        let menu = mem.ld8(t.fsAddr + o.task("cur_menu"))
        if menu == 0 { if !menuSnapshot.isEmpty { menuSnapshot = [] }; return }
        var out: [MenuSnap] = []
        func walk(_ e0: Int64, _ prefix: String, _ depth: Int) throws {
            var e = e0, n = 0
            while e != 0 && n < 64 && depth < 4 {
                n += 1
                let a = Int(Int32(truncatingIfNeeded: e))
                let name = try mem.readStr(Int64(a + o.member("CMenuEntry", "name")))
                let isDir = try safeLd1(a + o.member("CMenuEntry", "dir")) != 0
                let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
                out.append(MenuSnap(path, name, try safeLd8(a + o.member("CMenuEntry", "msg_code")), try safeLd8(a + o.member("CMenuEntry", "arg1")),
                                    try safeLd8(a + o.member("CMenuEntry", "arg2")), try safeLd1(a + o.member("CMenuEntry", "checked")) != 0, isDir))
                if isDir { try walk(try safeLd8(a + o.member("CMenuEntry", "sub")), path, depth + 1) }
                e = try safeLd8(a + o.member("CMenuEntry", "next"))
            }
        }
        do { try walk(try safeLd8(Int(Int32(truncatingIfNeeded: menu)) + o.member("CMenu", "sub")), "", 0) } catch { return }
        menuSnapshot = out
    }

    /** Guards [published] between the kernel thread and the UI. */
    public let publishLock = Monitor()

    /** TempleOS screen update: text layer, draw_it callbacks, then gr.dc on top. */
    public func captureScreen() throws -> [UInt8] {try compose();return Array(UnsafeBufferPointer(start:published,count:640*480))}

    private func compose() throws {
        try vga.sync()
        guard let main = mainTask ?? tasks.first else { return }
        // 1. text layer -> pixels
        gfx.renderText(textCells, frameBuf)
        let spriteWin = windowCells(main.fsAddr)
        console.renderSprites(frameBuf, Kernel.W, spriteWin[0] * 8, spriteWin[1] * 8,
            spriteWin[2] - spriteWin[0] + 1, spriteWin[3] - spriteWin[1] + 1)
        // 2. rebuild text cells for the next frame as TempleOS's GrUpdateTaskWin does: the window
        // border (TextBorder), the window filled with text_attr (TextRect), then the document
        let attr = Int(mem.ld1(main.fsAddr + o.task("text_attr")))
        let win = windowCells(main.fsAddr)
        layoutWindowText(win, attr, Int(mem.ld1(main.fsAddr + o.task("border_attr"))))
        gfx.copyTextCellsToArena(textCells)
        try gfx.loadScreen(frameBuf, Kernel.W * Kernel.H)
        // 3. ODEs, draw_it callbacks and controls of live tasks (Adam/Gr/GrScrn.HC GrUpdateTasks: the
        // ODE time of this frame is summed in winmgr.ode_time and budgets the next frame's)
        mem.st8(o.winmgrAddr + o.member("CWinMgrGlbls", "ode_time"), bits(0.0))
        for t in Array(tasks) {
            if t.state == Kernel.DEAD { continue }
            if t.nestLevel > 0 { continue } // inside a native's callback (V-17): its HolyC state is mid-call
            try frameDuties(t)
            let fp = mem.ld8(t.fsAddr + o.task("draw_it"))
            if fp == 0 { drawCtrls(t); continue }
            let dc = try gfx.aliasForDraw(t)
            let saved = current
            do {
                defer {
                    gfx.freeDrawAlias(dc)
                    if let s = saved { setCurrent(s) }
                }
                do {
                    setCurrent(t)
                    try vm.callFunction(t, fp, Int64(t.fsAddr), dc)
                } catch let u as VmUncaught {
                    mem.st8(t.fsAddr + o.task("draw_it"), 0)
                    console.write("\n$RED$Exception in draw_it: \(u.message)$FG$\n")
                } catch let k as VmKill {
                    mem.st8(t.fsAddr + o.task("draw_it"), 0)
                    console.write("\n$RED$draw_it: \(k.message)$FG$\n")
                } catch let f as VmFault {
                    // e.g. a corrupted Fs->draw_it pointer: the program's fault, not the kernel's
                    mem.st8(t.fsAddr + o.task("draw_it"), 0)
                    console.write("\n$RED$Exception in draw_it: \(f.message)$FG$\n")
                }
            }
            drawCtrls(t)
        }
        let mouseDraw=mem.ld8(o.grAddr+o.member("CGrGlbls","fp_draw_ms"))
        if mouseDraw != 0 && main.state != Kernel.DEAD && mem.ld1(o.msAddr+o.member("CMsStateGlbls","show")) != 0 {
            let saved=current,dc=try gfx.aliasForDraw(main)
            defer {gfx.freeDrawAlias(dc);if let saved=saved {setCurrent(saved)}}
            setCurrent(main);try vm.callFunction(main,mouseDraw,dc,mem.ld8(o.msAddr+o.msPos)-mem.ld8(main.fsAddr+o.task("pix_left")),mem.ld8(o.msAddr+o.msPos+8)-mem.ld8(main.fsAddr+o.task("pix_top")))
        }
        // window-manager work: on the Adam task, as TempleOS runs it in its WinMgr task
        _ = try? callHolyC("MobileOdeFrameEnd", task: adamTask)
        gfx.copyTextCellsFromArena(&textCells)
        // 4. persistent gr.dc on top, then publish with the window rect the UI shows
        let b = win[4]
        let x0 = min(max((win[0] - b) * 8, 0), Kernel.W), y0 = min(max((win[1] - b) * 8, 0), Kernel.H)
        let x1 = min(max((win[2] + 1 + b) * 8, 0), Kernel.W), y1 = min(max((win[3] + 1 + b) * 8, 0), Kernel.H)
        try publishLock.sync {
            var changed = try gfx.composeAndPublish(published) || publishedVersion == 0
            let r = x1 - x0 >= 8 && y1 - y0 >= 8 ? [x0, y0, x1 - x0, y1 - y0] : [0, 0, Kernel.W, Kernel.H]
            if r != publishedWindow { publishedWindow = r; changed = true }
            if changed { publishedVersion += 1 }
        }
    }

    private var docCells: [Int] = []

    /**
     * Text layer for the next frame: blank screen, [win]'s border (Adam/Gr/GrTextBase.HC TextBorder,
     * solid because the window has the focus), and the console document in the window's text area.
     */
    private func layoutWindowText(_ win: [Int], _ attr: Int, _ borderAttr: Int) {
        for i in 0..<textCells.count { textCells[i] = 0 }
        let l = win[0], t = win[1], r = win[2], bt = win[3]
        let cols80 = TEXT_COLS, rows60 = TEXT_ROWS
        func put(_ x: Int, _ y: Int, _ d: Int) { if x >= 0 && x < cols80 && y >= 0 && y < rows60 { textCells[y * cols80 + x] = d } }
        if win[4] != 0 {
            let a = borderAttr << 8
            let bc = o.global("text") + o.member("CTextGlbls", "border_chars")
            func ch(_ i: Int) -> Int { Int(mem.ld1(bc + i)) + a }
            put(l - 1, t - 1, ch(7)); put(r + 1, t - 1, ch(9)); put(l - 1, bt + 1, ch(11)); put(r + 1, bt + 1, ch(13))
            if l <= r { for i in l...r { put(i, t - 1, ch(3)); put(i, bt + 1, ch(3)) } }
            if t <= bt { for i in t...bt { put(l - 1, i, ch(5)); put(r + 1, i, ch(5)) } }
        }
        let cols = r - l + 1, rows = bt - t + 1
        if cols <= 0 || rows <= 0 { return }
        if docCells.count < cols * rows { docCells = [Int](repeating: 0, count: cols * rows) }
        console.renderCells(&docCells, cols, rows, attr)
        for y in 0..<rows { for x in 0..<cols { put(l + x, t + y, docCells[y * cols + x]) } }
    }

    /** ODE integration and control mouse routing for [t] (TempleOS WinMgr duties). */
    private func frameDuties(_ t: HTask) throws {
        let saved = current
        defer { if let s = saved { setCurrent(s) } }
        do {
            setCurrent(t)
            if mem.ld8(t.fsAddr + o.task("next_ode")) != Int64(t.fsAddr + o.task("next_ode")) {
                try callHolyC("ODEsUpdate", Int64(t.fsAddr), task: t)
            }
            if try callHolyC("MobileTaskHasCtrls", Int64(t.fsAddr), task: t) != 0 {
                try callHolyC("CtrlsUpdate", Int64(t.fsAddr), task: t)
                if t === mainTask { try callHolyC("MobileCtrlsMs", Int64(t.fsAddr), task: t) }
            }
        } catch let u as VmUncaught {
            console.write("\n$RED$Exception in window manager: \(u.message)$FG$\n")
            mem.st8(t.fsAddr + o.task("next_ode"), Int64(t.fsAddr + o.task("next_ode")))
            mem.st8(t.fsAddr + o.task("last_ode"), Int64(t.fsAddr + o.task("next_ode")))
        } catch is VmKill {
        }
    }

    private func drawCtrls(_ t: HTask) {
        do {
            if try callHolyC("MobileTaskHasCtrls", Int64(t.fsAddr), task: t) != 0 {
                // the terminal's own scroll bars alone do not make a text program a graphics one
                if !graphicsUsed, try callHolyC("MobileTaskHasOwnCtrls", Int64(t.fsAddr), task: t) != 0 { graphicsUsed = true }
                try callHolyC("DrawCtrls", Int64(t.fsAddr), task: t)
            }
        } catch {}
    }

    // ------------------------------------------------------------ random

    /** java.util.SplittableRandom(seed): splitmix64 with the golden gamma (used for task rand_seed). */
    public final class SplittableRandom {
        private var seed: Int64
        public init(_ seed: Int64) { self.seed = seed }
        public func nextLong() -> Int64 {
            seed = seed &+ -0x61c8864680b583eb
            var z = seed
            z = (z ^ ushr(z, 30)) &* -0x40a7b892e31b1a47
            z = (z ^ ushr(z, 27)) &* -0x6b2fb644ecceee15
            return z ^ ushr(z, 31)
        }
    }

    public let rng = SplittableRandom(0)
    private lazy var randSeedOff: Int = o.task("rand_seed")
    private lazy var taskFlagsOff: Int = o.task("task_flags")

    /**
     * Kernel/KMathB.HC RandU64 and friends (Kernel.kt nextRand): [t]'s own rand_seed through TempleOS's linear
     * congruence, XOR'ed with the time stamp counter (the task's clock) unless Seed(n != 0) set TASKf_NONTIMER_RAND.
     */
    public func nextRand(_ t: HTask?) -> Int64 {
        guard let task = t ?? current else { return 0 }
        let fs = task.fsAddr
        var res = mem.ld8(fs + randSeedOff)
        res = ((Kernel.LIN_CONGRUE_A &* res) ^ ((res & 0xFFFFFFFF0000) >> 16)) &+ Kernel.LIN_CONGRUE_C
        if (ushr(mem.ld4(fs + taskFlagsOff), Int64(Kernel.TASKF_NONTIMER_RAND)) & 1) == 0 { res ^= taskNow(task) }
        mem.st8(fs + randSeedOff, res)
        return res
    }

    /** Kernel/KMathB.HC Seed(seed, task): a fixed seed (and no more TSC) or, for 0, back to timer-based. */
    public func seed(_ t: HTask, _ seed: Int64, _ taskAddr: Int64) throws -> Int64 {
        let fs = taskAddr != 0 ? try mem.check(taskAddr, 8) : t.fsAddr
        let fl = mem.ld4(fs + taskFlagsOff)
        if seed != 0 {
            mem.st4(fs + taskFlagsOff, fl | (Int64(1) << Int64(Kernel.TASKF_NONTIMER_RAND)))
            mem.st8(fs + randSeedOff, seed); return seed
        }
        mem.st4(fs + taskFlagsOff, fl & ~(Int64(1) << Int64(Kernel.TASKF_NONTIMER_RAND)))
        let s = mem.ld8(fs + randSeedOff) ^ taskNow(taskByFs(Int64(fs)) ?? t)
        mem.st8(fs + randSeedOff, s); return s
    }
}

/** Arena offsets of prelude classes and globals used by the host. */
public final class Offsets {
    private let prog: Program

    private static func clsOf(_ prog: Program, _ name: String) throws -> ClassType {
        guard let c = prog.classes[name] else { throw VmKill("prelude class \(name) missing") }
        return c
    }
    private static func memberOf(_ prog: Program, _ c: String, _ m: String) throws -> Int {
        guard let mm = try clsOf(prog, c).find(m) else { throw VmKill("\(c).\(m) missing") }
        return mm.offset
    }
    private static func globalOf(_ prog: Program, _ n: String) throws -> Int {
        guard let g = prog.globals[n] as? GlobalSym else { throw VmKill("global \(n) missing") }
        return g.addr
    }

    // The prelude's own definitions, taken right after it compiled. A program may redefine or
    // forward-declare a prelude class (`class CTask;`) or shadow a global; the host keeps using the
    // prelude layout, as TempleOS's kernel code keeps its compiled offsets. Names the prelude does
    // not define fall back to the live tables. (Before, the user's class was found here, and the
    // missing member trapped the whole app.)
    private let preludeClasses: [String: ClassType]
    private let preludeGlobals: [String: Sym]

    /**
     * Lookups after boot: the prelude is fixed, so a missing name is a build
     * bug (Kotlin throws IllegalStateException); these trap instead of throwing.
     */
    public func cls(_ name: String) -> ClassType {
        if let c = preludeClasses[name] { return c }
        do { return try Offsets.clsOf(prog, name) } catch { fatalError(errorMessage(error)) }
    }
    public func member(_ c: String, _ m: String) -> Int {
        guard let mm = cls(c).find(m) else { fatalError("\(c).\(m) missing") }
        return mm.offset
    }
    public func task(_ m: String) -> Int { member("CTask", m) }
    public func dc(_ m: String) -> Int { member("CDC", m) }
    public func global(_ n: String) -> Int {
        if let g = preludeGlobals[n] as? GlobalSym { return g.addr }
        do { return try Offsets.globalOf(prog, n) } catch { fatalError(errorMessage(error)) }
    }

    public let fsGlobal: Int
    public let msAddr: Int
    public let kbdAddr: Int
    public let grAddr: Int
    public let winmgrAddr: Int
    public let cntsAddr: Int
    public let msPos: Int
    public let msPosText: Int
    public let msPresnap: Int
    public let msLb: Int
    public let msRb: Int

    public init(_ k: Kernel) throws {
        let p: Program = k.prog
        prog = p
        preludeClasses = p.classes
        preludeGlobals = p.globals
        fsGlobal = try Offsets.globalOf(p, "Fs")
        msAddr = try Offsets.globalOf(p, "ms")
        kbdAddr = try Offsets.globalOf(p, "kbd")
        grAddr = try Offsets.globalOf(p, "gr")
        winmgrAddr = try Offsets.globalOf(p, "winmgr")
        cntsAddr = try Offsets.globalOf(p, "cnts")
        msPos = try Offsets.memberOf(p, "CMsStateGlbls", "pos")
        msPosText = try Offsets.memberOf(p, "CMsStateGlbls", "pos_text")
        msPresnap = try Offsets.memberOf(p, "CMsStateGlbls", "presnap")
        msLb = try Offsets.memberOf(p, "CMsStateGlbls", "lb")
        msRb = try Offsets.memberOf(p, "CMsStateGlbls", "rb")
    }
}

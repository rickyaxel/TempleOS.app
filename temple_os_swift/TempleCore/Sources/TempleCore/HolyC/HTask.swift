import Foundation

/**
 * A cooperative HolyC task: operand stack, call frames and exception handlers.
 * Port of `Task` in holyc/Vm.kt (renamed: Swift Concurrency owns `Task`).
 * Arrays are unsafe pointers so the interpreter indexes them without checks;
 * Kotlin `t.st[a]` reads the same in Swift.
 */
public final class HTask {
    public static let STACK_WORDS = 8192
    /** Extra words after the operand stack: the VM faults when sp passes STACK_WORDS - 4
     *  (checked before every instruction; one instruction pushes at most 2 words), and
     *  natives may read a few argument slots above sp. */
    public static let STACK_GUARD = 64
    public static let MAX_DEPTH = 2048
    public static let MAX_HANDLERS = 256
    public static let MEM_STACK = 256 * 1024

    public unowned let vm: Vm
    public let id: Int
    public let name: String

    public let st = UnsafeMutablePointer<Int64>.allocate(capacity: HTask.STACK_WORDS + HTask.STACK_GUARD)
    public var sp = 0
    public var pc = 0
    public var fp = 0
    public var msp = 0
    public let mspBase: Int
    public let mspLimit: Int

    public let fRet = UnsafeMutablePointer<Int>.allocate(capacity: HTask.MAX_DEPTH)
    public let fFp = UnsafeMutablePointer<Int>.allocate(capacity: HTask.MAX_DEPTH)
    public let fMsp = UnsafeMutablePointer<Int>.allocate(capacity: HTask.MAX_DEPTH)
    public var depth = 0

    public let hPc = UnsafeMutablePointer<Int>.allocate(capacity: HTask.MAX_HANDLERS)
    public let hSp = UnsafeMutablePointer<Int>.allocate(capacity: HTask.MAX_HANDLERS)
    public let hFp = UnsafeMutablePointer<Int>.allocate(capacity: HTask.MAX_HANDLERS)
    public let hMsp = UnsafeMutablePointer<Int>.allocate(capacity: HTask.MAX_HANDLERS)
    public let hDepth = UnsafeMutablePointer<Int>.allocate(capacity: HTask.MAX_HANDLERS)
    public var hCount = 0
    public var handlerBase = 0

    /** Set by a native to suspend the task; the native is re-executed on resume. */
    public var blocked = false
    /** Set by the scheduler when a blocked task is woken (the native re-runs). */
    public var resumed = false
    /** Set by a native to end the current time slice after it returns. */
    public var yieldReq = false
    /** True when the last [Vm.run] ended because the task yielded (not because its slice ran out). */
    public var yielded = false
    public var result: Int64 = 0
    public var faultPc = 0
    public var deathMessage: String?
    /** The exception code that ended the task (with [deathMessage]); 0 if unknown. */
    public var deathCode: Int64 = 0
    public var nestLevel = 0

    /** Arena address of this task's CTask struct (the HolyC `Fs`). */
    public var fsAddr = 0

    /** Scheduler/kernel owned state. */
    public var state = 0
    public var wakeAt: Int64 = 0
    /** How late the scheduler woke this task from its last timed sleep (0 for other wake-ups), in ns. */
    public var lateNs: Int64 = 0
    public var blockToken: Int64 = 0
    /** Started on TempleOS's SoundEffectTask (Noise/Sweep): its Sleep(0) is paced (Natives Sleep). */
    public var speakerTask = false
    public var userData: AnyObject?

    // ---- native execution (purenative NativeRuntime): unused by the bytecode interpreter
    /** Budget ticks left in this slice (the VM keeps its budget in a local). */
    public var budget = 0
    /** Slices a nested callback has run (the VM's callFunction guard). */
    public var nestGuard = 0
    /** Exception injected while suspended (Break), raised when the task resumes. */
    public var pendingFault: Int64?
    /** The engine's per-task state (its thread). */
    public var engineData: AnyObject?

    public init(_ vm: Vm, _ id: Int, _ name: String) throws {
        self.vm = vm; self.id = id; self.name = name
        st.initialize(repeating: 0, count: HTask.STACK_WORDS + HTask.STACK_GUARD)
        for p in [fRet, fFp, fMsp] { p.initialize(repeating: 0, count: HTask.MAX_DEPTH) }
        for p in [hPc, hSp, hFp, hMsp, hDepth] { p.initialize(repeating: 0, count: HTask.MAX_HANDLERS) }
        mspBase = try vm.mem.allocStack(Int64(HTask.MEM_STACK))
        mspLimit = mspBase + HTask.MEM_STACK
        msp = mspBase; fp = mspBase
    }

    deinit {
        st.deallocate()
        for p in [fRet, fFp, fMsp, hPc, hSp, hFp, hMsp, hDepth] { p.deallocate() }
    }
}

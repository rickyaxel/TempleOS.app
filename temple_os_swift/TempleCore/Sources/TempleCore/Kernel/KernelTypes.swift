import Foundation

// Shared declarations from the top of kernel/Kernel.kt.

/** Services a kernel needs from its environment. */
public protocol KernelEnv: AnyObject {
    /** Reads system runtime files: "Prelude.HC", "PreludeDefines.HC", "font8x8.bin". */
    func runtimeFile(_ name: String) -> [UInt8]?
    /** The virtual filesystem (C:/ paths), or nil if unavailable. */
    var fs: VirtualFs? { get }
    func nanoTime() -> Int64
    func epochMillis() -> Int64
    func utcOffsetMillis() -> Int64
    /** Program arena limit in bytes. */
    var memoryLimit: Int { get }
    /**
     * The PC speaker (Kernel/KMisc.HC Snd): [freq] Hz from [atNs] on, 0 = off; one setting at a time, each
     * lasting until the next. [atNs] is on the [nanoTime] clock: the time TempleOS would have made the
     * change (see [Kernel.speaker]), which can be a little before the call.
     */
    func sound(_ kernel: Kernel, _ freq: Double, _ atNs: Int64)
    /** The host paused (true) or resumed (false) the kernel (window menu, background, hidden window). */
    func paused(_ kernel: Kernel, _ paused: Bool)
    /** Ed(file) from HolyC: ask the system to open the editor. */
    func openEditor(_ kernel: Kernel, _ path: String)
    /** Man/Help/DocLink: open a document viewer. */
    func openDocument(_ kernel: Kernel, _ path: String)
    /** A popup was requested; UIs show it (and later call answerPopup). Tests may answer at once. */
    func popupRequested(_ kernel: Kernel, _ req: PopupRequest)
    /** Seed for the random generator (entropy source). */
    func entropy() -> Int64
}

public extension KernelEnv {
    func nanoTime() -> Int64 { monoNanos() }
    func epochMillis() -> Int64 { epochMillisNow() }
    func utcOffsetMillis() -> Int64 { Int64(TimeZone.current.secondsFromGMT()) * 1000 }
    var memoryLimit: Int { 32 << 20 }
    func sound(_ kernel: Kernel, _ freq: Double, _ atNs: Int64) {}
    func paused(_ kernel: Kernel, _ paused: Bool) {}
    func openEditor(_ kernel: Kernel, _ path: String) {}
    func openDocument(_ kernel: Kernel, _ path: String) {}
    func popupRequested(_ kernel: Kernel, _ req: PopupRequest) {}
    func entropy() -> Int64 { monoNanos() ^ epochMillisNow() }
}

/** A modal choice requested by a program (TempleOS PopUp* functions). */
public final class PopupRequest {
    public final class Item {
        public let label: String
        public let value: Int64
        public let bg: Int
        public init(_ label: String, _ value: Int64, _ bg: Int = -1) { self.label = label; self.value = value; self.bg = bg }
    }
    public let header: String
    public let footer: String
    public let items: [Item]
    /** Kotlin `@Volatile var result: Long?` (set by the UI thread, read by the kernel). */
    public var result: Int64? {
        get { lock.lock(); defer { lock.unlock() }; return _result }
        set { lock.lock(); _result = newValue; lock.unlock() }
    }
    private var _result: Int64?
    private let lock = NSLock()
    public init(_ header: String, _ footer: String, _ items: [Item]) { self.header = header; self.footer = footer; self.items = items }
}

/**
 * Input event delivered from the UI thread. Coordinates are program pixels
 * (0..639, 0..479). Kotlin `KInput.Key(ch, sc, down)` is `.key(ch:sc:down:)`,
 * `KInput.Break` is `.breakKey`, `KInput.Exec(line)` is `.exec(line)`.
 */
public enum KInput {
    case key(ch: Int, sc: Int64, down: Bool)
    case mouse(x: Int, y: Int, lb: Bool, rb: Bool, wheel: Int = 0)
    case breakKey
    /** Terminal: compile and run a command line on the shell task. */
    case exec(String)
    /** A raw TempleOS message (menu selections). */
    case raw(code: Int, a1: Int64, a2: Int64)
}

/** A program menu entry as seen by the UI (snapshot of the HolyC CMenu). */
public final class MenuSnap {
    public let path: String, label: String, msgCode: Int64, a1: Int64, a2: Int64, checked: Bool, isDir: Bool
    public init(_ path: String, _ label: String, _ msgCode: Int64, _ a1: Int64, _ a2: Int64, _ checked: Bool, _ isDir: Bool) {
        self.path = path; self.label = label; self.msgCode = msgCode; self.a1 = a1; self.a2 = a2; self.checked = checked; self.isDir = isDir
    }
}

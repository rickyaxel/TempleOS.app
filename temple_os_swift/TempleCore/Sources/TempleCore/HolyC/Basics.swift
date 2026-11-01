import Foundation

// Shared helpers for the Swift port of temple_os_kotlin/core. See
// temple_os_swift/PORTING.md for the Kotlin -> Swift conventions.

/** Bytes left on the current thread's stack (Darwin stacks grow down from pthread_get_stackaddr_np). */
@inline(__always) public func stackRemaining() -> Int {
    var probe: UInt8 = 0
    return withUnsafePointer(to: &probe) { p in
        let top = UInt(bitPattern: pthread_get_stackaddr_np(pthread_self()))
        let size = UInt(pthread_get_stacksize_np(pthread_self()))
        let here = UInt(bitPattern: p)
        return here > top &- size ? Int(here &- (top &- size)) : 0
    }
}

/** Stack kept free by the compiler's recursion guard. */
public let STACK_RESERVE = 256 * 1024

/**
 * Recursion guard for the parser and code generator: deeply nested source is a
 * compile error, never a host stack overflow (which would kill the app). The
 * Kotlin version converts the JVM's recoverable StackOverflowError instead.
 */
@inline(__always) public func checkStack() throws {
    if stackRemaining() < STACK_RESERVE { throw CompileError(DEEP_NESTING) }
}
public let DEEP_NESTING = "program too deeply nested"

// MARK: - Errors

/** A HolyC exception raised by the runtime (catchable by try/catch). */
public struct VmFault: Error, CustomStringConvertible {
    public let ch: Int64
    public let message: String
    /** Where it happened, "Function (file:line)", when the thrower knows it (natively translated code). */
    public var whereText: String?
    public init(_ ch: Int64, _ message: String, whereText: String? = nil) { self.ch = ch; self.message = message; self.whereText = whereText }
    public var description: String { message }
}

/** Uncatchable termination (stop request, resource limit). */
public struct VmKill: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/** Exception that escaped a nested callback (propagated to the caller's context). */
public struct VmUncaught: Error, CustomStringConvertible {
    public let ch: Int64
    public let message: String
    public init(_ ch: Int64, _ message: String) { self.ch = ch; self.message = message }
    public var description: String { message }
}

public struct CompileError: Error, CustomStringConvertible {
    public let bare: String
    public let file: String
    public let line: Int
    public init(_ msg: String, _ file: String = "", _ line: Int = 0) { bare = msg; self.file = file; self.line = line }
    public var message: String { file.isEmpty ? bare : "\(file):\(line): \(bare)" }
    public var description: String { message }
}

/** The text of any error, like Kotlin's Throwable.message. */
public func errorMessage(_ e: Error) -> String {
    switch e {
    case let f as VmFault: return f.message
    case let k as VmKill: return k.message
    case let u as VmUncaught: return u.message
    case let c as CompileError: return c.message
    case let f as FsError: return f.message
    default: return String(describing: e)
    }
}

// MARK: - Integer and float helpers (Kotlin/JVM semantics)

/** Kotlin `ushr` on Long. */
@inlinable @inline(__always) public func ushr(_ x: Int64, _ n: Int64) -> Int64 { Int64(bitPattern: UInt64(bitPattern: x) &>> UInt64(n & 63)) }
@inlinable @inline(__always) public func ushr(_ x: Int64, _ n: Int) -> Int64 { Int64(bitPattern: UInt64(bitPattern: x) &>> UInt64(n & 63)) }

/** Raw bits of an F64 held in a 64-bit HolyC value. */
@inlinable @inline(__always) public func d(_ v: Int64) -> Double { Double(bitPattern: UInt64(bitPattern: v)) }
@inlinable @inline(__always) public func bits(_ x: Double) -> Int64 { Int64(bitPattern: x.bitPattern) }

public func u2f(_ v: Int64) -> Double { Double(UInt64(bitPattern: v)) }

/** x86 CVTTSD2SI semantics: truncate; NaN/out-of-range -> 0x8000000000000000. */
public func f2i(_ x: Double) -> Int64 {
    if x.isNaN || x >= 9.223372036854775807E18 || x < -9.223372036854775808E18 { return Int64.min }
    return Int64(x)
}

public func ipow(_ b0: Int64, _ e0: Int64) -> Int64 {
    if e0 < 0 { return b0 == 1 ? 1 : (b0 == -1 ? ((e0 & 1) == 0 ? 1 : -1) : 0) }
    var r: Int64 = 1, b = b0, e = e0
    while e != 0 {
        if e & 1 != 0 { r = r &* b }
        b = b &* b; e = ushr(e, 1)
    }
    return r
}

/** Kotlin Long division semantics (MIN / -1 == MIN, no trap). Caller checks zero. */
@inline(__always) public func sdiv(_ a: Int64, _ b: Int64) -> Int64 { b == -1 ? 0 &- a : a / b }
@inline(__always) public func smod(_ a: Int64, _ b: Int64) -> Int64 { b == -1 ? 0 : a % b }

public func hex(_ v: Int64) -> String { String(UInt64(bitPattern: v), radix: 16) }

/** Little-endian character constant: "Break" -> 'Break'. */
public func chCode(_ s: String) -> Int64 {
    var v: Int64 = 0
    for c in latin1(s).reversed() { v = (v &<< 8) | Int64(c) }
    return v
}

// MARK: - Latin-1 text (TempleOS uses 8-bit characters)

public func latin1(_ s: String) -> [UInt8] { s.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) } }

public func latin1<C: Collection>(_ b: C) -> String where C.Element == UInt8 {
    var s = String.UnicodeScalarView()
    for c in b { s.append(Unicode.Scalar(c)) }
    return String(s)
}

public func latin1(_ b: [UInt8], _ off: Int, _ len: Int) -> String { latin1(b[off..<(off + len)]) }

/** The Latin-1 code of a one-character string literal: code("A") == 65. */
@inline(__always) public func code(_ c: Unicode.Scalar) -> Int { Int(c.value) }

// MARK: - Time

private let startNanos = DispatchTime.now().uptimeNanoseconds
public func monoNanos() -> Int64 {
    let base = startNanos // initialize the (lazy) global before reading the clock
    return Int64(bitPattern: DispatchTime.now().uptimeNanoseconds &- base) &+ 1_000_000_000
}
public func epochMillisNow() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

// MARK: - Containers

/**
 * Growable Int32 buffer used for bytecode. Storage is an unsafe pointer so the
 * interpreter can read it without bounds or uniqueness checks; when it grows,
 * old buffers are retired but kept alive, so a running interpreter that still
 * holds the old pointer reads valid (stale) memory exactly like the Kotlin VM
 * holding the old IntArray.
 */
public final class IntList {
    public private(set) var data: UnsafeMutablePointer<Int32>
    public private(set) var capacity: Int
    public private(set) var size = 0
    private var retired: [UnsafeMutablePointer<Int32>] = []

    public init(_ cap: Int = 1024) {
        capacity = max(16, cap)
        data = UnsafeMutablePointer<Int32>.allocate(capacity: capacity)
        data.initialize(repeating: 0, count: capacity)
    }
    deinit {
        data.deallocate()
        for p in retired { p.deallocate() }
    }
    public func add(_ v: Int) {
        if size == capacity {
            let n = capacity * 2
            let nd = UnsafeMutablePointer<Int32>.allocate(capacity: n)
            nd.initialize(repeating: 0, count: n)
            nd.update(from: data, count: size)
            retired.append(data)
            data = nd; capacity = n
        }
        data[size] = Int32(truncatingIfNeeded: v); size += 1
    }
    public subscript(i: Int) -> Int {
        get { Int(data[i]) }
        set { data[i] = Int32(truncatingIfNeeded: newValue) }
    }
}

/** Thread-safe FIFO (Kotlin ConcurrentLinkedQueue). */
public final class LockedQueue<T> {
    private var items: [T] = []
    private var head = 0
    private let lock = NSLock()
    public init() {}
    public func add(_ v: T) { lock.lock(); items.append(v); lock.unlock() }
    public func poll() -> T? {
        lock.lock(); defer { lock.unlock() }
        if head >= items.count { return nil }
        let v = items[head]; head += 1
        if head > 64 && head * 2 > items.count { items.removeFirst(head); head = 0 }
        return v
    }
    public var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return head >= items.count }
    public var isNotEmpty: Bool { !isEmpty }
    public func clear() { lock.lock(); items.removeAll(); head = 0; lock.unlock() }
    /** Kotlin: iterator().remove() over a ConcurrentLinkedQueue. Returns the number removed. */
    @discardableResult public func removeAll(where match: (T) -> Bool) -> Int {
        lock.lock(); defer { lock.unlock() }
        if head > 0 { items.removeFirst(head); head = 0 }
        let n = items.count
        items.removeAll(where: match)
        return n - items.count
    }
}

/** A Java-style monitor: synchronized + wait(ms) + notifyAll (NSCondition). */
public final class Monitor {
    private let cond = NSCondition()
    public init() {}
    @inline(__always) public func sync<R>(_ body: () throws -> R) rethrows -> R {
        cond.lock(); defer { cond.unlock() }
        return try body()
    }
    /** Must be called inside sync. */
    public func wait(ms: Int64) { _ = cond.wait(until: Date(timeIntervalSinceNow: Double(max(ms, 0)) / 1000)) }
    /** Must be called inside sync. */
    public func wait(ns: Int64) { _ = cond.wait(until: Date(timeIntervalSinceNow: Double(max(ns, 0)) / 1e9)) }
    /** Must be called inside sync. */
    public func notifyAll() { cond.broadcast() }
    public func notifyAllLocked() { cond.lock(); cond.broadcast(); cond.unlock() }
}

/** A mutable box giving reference semantics to a value. */
public final class Ref<T> {
    public var value: T
    public init(_ v: T) { value = v }
}

// MARK: - Small Kotlin stdlib equivalents

extension Array {
    @inlinable public mutating func removeLastOrNil() -> Element? { isEmpty ? nil : removeLast() }
    @inlinable public func getOrNil(_ i: Int) -> Element? { i >= 0 && i < count ? self[i] : nil }
}

extension String {
    /** Kotlin substringAfterLast(c) (whole string when absent). */
    public func substringAfterLast(_ c: Character) -> String {
        guard let i = lastIndex(of: c) else { return self }
        return String(self[index(after: i)...])
    }
    /** Kotlin substringAfterLast(c, missing). */
    public func substringAfterLast(_ c: Character, _ missing: String) -> String {
        guard let i = lastIndex(of: c) else { return missing }
        return String(self[index(after: i)...])
    }
    public func substringBefore(_ c: Character) -> String {
        guard let i = firstIndex(of: c) else { return self }
        return String(self[..<i])
    }
    public func substringBefore(_ c: Character, _ missing: String) -> String {
        guard let i = firstIndex(of: c) else { return missing }
        return String(self[..<i])
    }
    public func substringAfter(_ c: Character) -> String {
        guard let i = firstIndex(of: c) else { return self }
        return String(self[index(after: i)...])
    }
    public func substringAfter(_ c: Character, _ missing: String) -> String {
        guard let i = firstIndex(of: c) else { return missing }
        return String(self[index(after: i)...])
    }
    /** Kotlin take(n). */
    public func take(_ n: Int) -> String { n <= 0 ? "" : String(prefix(n)) }
    public func takeLast(_ n: Int) -> String { n <= 0 ? "" : String(suffix(n)) }
    public func drop(_ n: Int) -> String { String(dropFirst(max(0, n))) }
    public func trimmed() -> String { trimmingCharacters(in: .whitespacesAndNewlines) }
    public func trimEnd(_ c: Character) -> String {
        var s = Substring(self)
        while s.last == c { s = s.dropLast() }
        return String(s)
    }
    public func startsWith(_ p: String, ignoreCase: Bool = false) -> Bool {
        ignoreCase ? lowercased().hasPrefix(p.lowercased()) : hasPrefix(p)
    }
    public func endsWith(_ p: String, ignoreCase: Bool = false) -> Bool {
        ignoreCase ? lowercased().hasSuffix(p.lowercased()) : hasSuffix(p)
    }
    public func equalsIgnoreCase(_ o: String) -> Bool { lowercased() == o.lowercased() }
    /** Kotlin padStart for numbers formatting. */
    public func padStart(_ n: Int, _ c: Character = " ") -> String { count >= n ? self : String(repeating: c, count: n - count) + self }
    public func padEnd(_ n: Int, _ c: Character = " ") -> String { count >= n ? self : self + String(repeating: c, count: n - count) }
}

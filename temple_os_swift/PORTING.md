# Kotlin → Swift porting conventions (TempleCore)

`temple_os_swift/TempleCore` is a line-for-line port of `temple_os_kotlin/core`
(package `io.github.templeosmobile.core`). The Kotlin code is the reference:
same algorithms, same names, same comments (trimmed is fine), same behaviour
bit-for-bit (HolyC programs must produce identical output and pixels on both
platforms). Do not "improve" logic while porting; if you find a real bug in
the Kotlin code, port it faithfully and report it.

Layout: `Sources/TempleCore/HolyC/*.swift` (holyc package),
`Sources/TempleCore/Kernel/*.swift` (kernel), `Sources/TempleCore/UI/*.swift` (ui).
One Swift file per Kotlin file, same base name, unless noted.
Swift language mode 5, `import Foundation` only (no UIKit/AppKit/SwiftUI).

## Already ported (shared foundation — do not redefine, do not edit)

| Swift file | Contents |
|---|---|
| HolyC/Basics.swift | VmFault, VmKill, VmUncaught, CompileError, errorMessage(e), ushr, d(), bits(), u2f, f2i, ipow, sdiv/smod, hex, chCode, latin1(String)->[UInt8], latin1(bytes)->String, latin1(b,off,len), monoNanos(), epochMillisNow(), IntList, LockedQueue, Monitor, Ref, String helpers (substringAfterLast/Before/After, take, takeLast, drop, trimmed, trimEnd, startsWith/endsWith(ignoreCase:), equalsIgnoreCase, padStart/padEnd), Array.removeLastOrNil/getOrNil |
| HolyC/Arena.swift | Arena (raw byte memory; API below) |
| HolyC/Ast.swift | Sym/LocalSym/GlobalSym/FuncSym, Expr subclasses, Stmt subclasses, Init/ExprInit/ListInit |
| HolyC/Types.swift | HType (= Kotlin Type), VoidType, IntType, F64Type, PtrType, ArrType, Member, ClassType, Param, FuncType, Types |
| HolyC/Op.swift | Op constants + Op.operands, SwitchTable |
| HolyC/Quicken.swift | Quick constants + Quick.quicken(code, from, to) |
| HolyC/HTask.swift | HTask (= Kotlin Task in Vm.kt) |
| Kernel/KernelTypes.swift | KernelEnv protocol (+defaults), PopupRequest(+Item), KInput enum, MenuSnap |
| Kernel/VirtualFs.swift | FsEntry, FsError, VirtualFs protocol, Paths |
| Kernel/Keys.swift | Keys, Palette |
| UI/AppBase.swift | Ptr, PointerEvent, MenuItem, FrameSource, Overlay, App (open base class) |

Read those files before writing code that uses them.

### Renames forced by Swift

| Kotlin | Swift |
|---|---|
| `Type` (holyc type base class) | `HType` |
| `Task` (HolyC task) | `HTask` |
| `Index` (expr) | `IndexExpr` |
| `T` (token kind enum in Lexer.kt) | `TokKind` (cases `.IDENT, .INT, .FLOAT, .STR, .CHAR, .PUNCT, .INS_BIN, .EOF`) |
| `object Nop` | `NopStmt.shared` (test with `is NopStmt`) |
| `VoidType` / `F64Type` objects as values | `VoidType.shared` / `F64Type.shared` (`Types.U0`, `Types.F64`); type tests stay `is VoidType` / `is F64Type` |
| `For.init`, `LocalInit.init`, `GlobalInit.init` | `initS`, `initV`, `initV` |
| `Param.default` | `defaultExpr` |
| `ClassType.members[k] = m` | `addMember(m)` / `setMember(k, m)`; `members.values` → `memberList`; `ct.size = n` → `ct.sizeValue = n` |
| `KInput.Key(ch, sc, down)` | `.key(ch:sc:down:)` |
| `KInput.Mouse(x, y, lb, rb, wheel)` | `.mouse(x:y:lb:rb:wheel:)` |
| `KInput.Break` | `.breakKey` |
| `KInput.Exec(line)` / `KInput.Raw(code, a1, a2)` | `.exec(line)` / `.raw(code:a1:a2:)` |
| `PopupRequest.Item(label, value, bg)` | `PopupRequest.Item(label, value, bg)` |
| Kotlin `Pair<A, B>` | Swift tuple `(A, B)`; destructuring `let (a, b) = ...` |
| `data class FsEntry(...)` | `struct FsEntry` with positional init `FsEntry(name, path, isDir, size, modified, readOnly)` |
| `Rect` (data class) | `struct Rect` (ported in UI/Surface.swift with `x, y, w, h`, `right`, `bottom`, `contains`, `inset`) |

Any other Kotlin keyword/stdlib collision: append a suffix and list it in your report.

## Types

| Kotlin | Swift |
|---|---|
| `Long` | `Int64` |
| `Int` | `Int` (64-bit). Where Kotlin relies on 32-bit truncation (e.g. `.toInt()` of a value that may not fit, then `.toLong()` to sign-extend), write `Int64(Int32(truncatingIfNeeded: x))` |
| `Byte` / `ByteArray` | `UInt8` / `[UInt8]`. `b.toInt() and 0xFF` → `Int(b)`; `x.toByte()` → `UInt8(truncatingIfNeeded: x)`; sign extension `.toByte().toLong()` → `Int64(Int8(truncatingIfNeeded: x))`; `.toShort().toLong()` → `Int64(Int16(truncatingIfNeeded: x))`; `.toInt().toLong()` → `Int64(Int32(truncatingIfNeeded: x))` |
| `IntArray` / `LongArray` | `[Int]` / `[Int64]` (or unsafe pointers in hot code, see Performance) |
| `Double` / `Boolean` / `String` | `Double` / `Bool` / `String` |
| `Char` | Prefer `UInt8`/`Int` codes. Kotlin strings hold Latin-1 text; convert with `latin1(...)` |
| `List`/`ArrayList` | `[T]` |
| `HashMap`/`LinkedHashMap` | `[K: V]` — if Kotlin iteration order matters (LinkedHashMap), keep a parallel ordered key array |
| `Any?` | `Any?` / `AnyObject?` |
| `Nothing` return | `throws -> Never` |

### Integer semantics (critical)

Kotlin Long arithmetic wraps; Swift traps. **All Int64 arithmetic that can
overflow uses wrapping operators**: `&+ &- &*`, shifts `&<<` and `&>>`
(Kotlin `shl`/`shr` mask the count to 6 bits, exactly like `&<<`/`&>>`).
Kotlin `ushr` → `ushr(x, n)` (Basics). `inv()` → `~x`. `and/or/xor` → `& | ^`.
Division: Kotlin `a / b` with b == -1 and a == Long.MIN_VALUE gives MIN_VALUE;
Swift traps → use `sdiv(a, b)` / `smod(a, b)` wherever the divisor can be -1
(caller still checks zero). `java.lang.Long.divideUnsigned/remainderUnsigned/compareUnsigned`
→ convert to `UInt64(bitPattern:)` and back. `Long.MIN_VALUE` → `Int64.min`.
`Math.abs(Long.MIN_VALUE)` is MIN in Kotlin → use `x < 0 ? 0 &- x : x`.
Double→Long `x.toLong()` saturates in Kotlin (NaN → 0): never write `Int64(x)`
on untrusted doubles; use `f2i` where the Kotlin code does, otherwise a saturating helper.
`Double.toRawBits()` → `bits(x)`; `java.lang.Double.longBitsToDouble(v)` / Kotlin `d(v)` → `d(v)`.
Plain `Int` arithmetic on sizes/indices can use normal operators.

## Language mapping

- `class X` → `final class X` (unless subclassed). `open class` / `abstract class` → `class`/`open class`; abstract members → `fatalError("abstract")` bodies.
- `object X` → `enum X` with `static` members (stateless) or `static var` state.
- `companion object { const val A = 1 }` → `static let A = 1` on the type. Refer to them as `X.A` (Swift needs the type prefix inside instance methods too, or `Self.A`).
- `sealed class` hierarchies → class hierarchies matched with `switch x { case let a as A: ... }` / `if let a = x as? A`. Small closed data-only hierarchies may become enums (KInput already is).
- `interface` → `protocol` (`AnyObject`-constrained when stored or compared by identity); default methods → protocol extension.
- `fun interface SourceProvider` → `protocol SourceProvider: AnyObject { func read(_ path: String) -> [UInt8]? }` plus `final class ClosureSourceProvider: SourceProvider` wrapping a closure.
- Lambdas → closures; Kotlin trailing-lambda calls translate directly.
- `when` → `switch`/`if` chains. `in a..b` → `a...b ~= x` or explicit comparisons. `until` → `..<`.
- `lateinit var` → implicitly unwrapped optional `var x: T!`. `by lazy` → `lazy var`.
- `?.let { }` → `if let`. `?:` → `??` (or `guard let ... else`).
- `==` on objects without `equals` means identity → `===`. Strings and numbers: `==`.
- Default/named parameters: keep them; Swift calls use labels only if you declare them. Prefer unlabeled positional parameters (`_ x:`) mirroring Kotlin calls, except where Kotlin call sites use named args (then use the same label).
- `vararg args: Long` → `_ args: Int64...` and an overload taking `[Int64]` when arrays are forwarded (`*args`).
- Exceptions: `throw` → `throw`. Any function that can throw (directly or by calling something that throws) is marked `throws`, and calls use `try`. `try { } catch (e: VmFault) { }` → `do { } catch let e as VmFault { }`. `finally` → `defer` (or explicit code on both paths). Error message text: `errorMessage(e)`.
- `java.lang.RuntimeException`/`IllegalStateException`/`error(...)` used for internal bugs → `fatalError(...)` only if Kotlin would crash the app; if Kotlin catches it somewhere (e.g. `catch (e: Throwable)` / `Exception`), throw a Swift error instead (`VmKill(msg)` is fine for "internal error" cases).
- `println` → `print`.
- `String.format("%02d", n)` → `String(format: "%02ld", n)` for `Int`, `"%lld"` for `Int64`, or `padStart`.
- `StringBuilder` → `var s = ""` / `[UInt8]` buffer.
- `System.nanoTime()` → `monoNanos()`; `System.currentTimeMillis()` → `epochMillisNow()`.
- `Thread { }` → `Thread { }` (Foundation) + `.start()`; `@Volatile var` → plain `var` (document it); `synchronized(lock) { }` → `Monitor.sync { }` (or `NSLock`); `@Synchronized` methods → an `NSRecursiveLock` locked at the start of each public method; `lock.wait(ms)` → `monitor.wait(ms:)` inside `sync`; `notifyAll()` → `notifyAll()` inside `sync`. `ConcurrentLinkedQueue` → `LockedQueue`.
- `java.io.File` → `FileManager`/`URL`/`Data` (`try? Data(contentsOf:)`, atomic writes: write to temp + `rename`/`replaceItemAt`).
- `java.util.Random` → do not use; the kernel has its own generator.
- Collections passed around and mutated through another reference in Kotlin (e.g. `val l = map.getOrPut(k) { ArrayList() }; l.add(x)`) **must** write back in Swift (`map[k, default: []].append(x)`) — Swift arrays/dictionaries are values.

## Arena API (HolyC/Arena.swift)

`check(_ a: Int64, _ n: Int) throws -> Int`, `ld1/ld2/ld4/ld8(_ a: Int) -> Int64` (zero-extended, like Kotlin),
`st1/st2/st4/st8(_ a: Int, _ v: Int64)`, `getByte(_ a: Int) -> Int`, `copy(dst, src, n)`, `fill(dst, b, n)`,
`readBytes(a, n) -> [UInt8]`, `writeBytes(a, bytes, off = 0, len = nil)`, `strLen(a) throws -> Int`,
`readStr(_ a: Int64) throws -> String`, `readStrBytes(_ a: Int64) throws -> [UInt8]`,
`malloc(_ n: Int64) throws -> Int`, `calloc(_ n: Int64) throws -> Int`, `free(_ a: Int64) throws`,
`msize(_ a: Int64) throws -> Int64`, `size`, `maxBytes`, `allocated`, `heapTop`, `base` (raw pointer), `ptr(a)`.
Kotlin `m.words` (LongArray) has no equivalent: use `base`/`ptr` with `memcpy` for snapshots.

## Performance rules (VM, Raster, Gfx, Console hot paths)

- Mark classes `final`; tiny helpers `@inline(__always)`.
- In the interpreter loop use `UnsafeMutablePointer` locals (`code.data`, `t.st`) — never Swift arrays.
- **`switch` cases in the interpreter must be integer literals** (`case 13: // LD8`), not `Op.LD8`:
  matching against `static let` constants compiles to a comparison chain instead of a jump table.
  Keep the Kotlin opcode name in a comment on every case.
- Avoid closures, existentials (`any Protocol`), `String` work and ARC traffic inside per-pixel or per-instruction loops.
- Pixel buffers: `UnsafeMutablePointer<UInt8>` (or `[UInt8]` accessed through `withUnsafeMutableBufferPointer` outside the inner loop).

## Reporting

When done, list: files written, any API you had to assume from files owned by
someone else (exact Swift signatures), any Kotlin behaviour you could not port
1:1, and any renames beyond this table.

## Swift-first: foldable and adaptive layout (not yet in the Kotlin core)

`UI/DisplayLayout.swift` (DisplayGeometry, DisplayLayout) and the parts of `Shell`, `Widgets`,
`Keyboard`, `ProgramApp`, `TerminalApp` and `EditorApp` that use it were written for the iPhone
Duo (docs/foldable/IPHONE_DUO_ADAPTATION.md) and have no Kotlin counterpart yet. Without reserved
regions or corner insets (every `Shell.resize` caller, all shared tests), the Swift shell lays out
pixel-identically to the Kotlin one at phone sizes. Differences at other sizes are listed in that
document (desktop mode from the usable size, client-shape program layout, keyboard rows from the
short-viewport rule). The perf line's trailing `kernel_frames=` field is also Swift-only. Port
these to `temple_os_kotlin/core` together when Android foldables are taken on.


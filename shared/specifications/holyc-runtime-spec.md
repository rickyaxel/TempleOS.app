# HolyC Runtime Specification (TempleOS Mobile)

This is the single authoritative specification that both native runtimes
(`temple_os_kotlin/core` and `temple_os_swift/TempleCore`) implement. When
behaviour here differs from original TempleOS it is called out as an
**Adaptation**. Conformance is checked by `shared/test-vectors/holyc/*.HC`
(each file carries its expected output, see *Test vectors* below).

## 1. Pipeline

```
source bytes (Latin-1 / CP437, may contain DolDoc + binary attachments)
  -> DolDoc source splitter (text part, binary records)
  -> Lexer (DolDoc-aware, preprocessor integrated)
  -> Parser (recursive descent + precedence climbing, typed AST)
  -> Code generator (typed, stack bytecode)
  -> VM (sandboxed, cooperative tasks, bounded memory arena)
  -> Host API (native functions declared by the system prelude)
```

No native machine code is generated. There is no JIT and no executable memory.

## 2. Source format

* Bytes are decoded 1:1 (Latin-1). Bytes 128..255 are identifier characters
  (TempleOS uses CP437 letters such as `θ` (0xE9) and `π` (0xE3) in identifiers).
* A NUL byte ends the text part. What follows is a sequence of DolDoc binary
  records: `U32 num, U32 flags, U32 size, U32 use_cnt, U8 data[size]`
  (little endian), as written by TempleOS `DocSave`.
* DolDoc commands `$...$` in the text part:
  * `$$` is a literal `$`.
  * Inside a string or char literal, a command is kept verbatim (`$FG,2$`), so
    printing the string later interprets it (TempleOS `LexDollar`).
  * Outside literals: `$IB,"<n>",BI=n$` yields an *insert-binary* token whose
    value is a pointer to a private copy of binary record `n`; `$IS,...,BI=n$`
    yields the record size as an integer; `$TX,"text"$` yields its text; every
    other command (`$SP$`, `$LK$`, `$FG$`, ...) is skipped. A formatting command
    between identifier characters does not split the identifier
    (`θ$SY,3$n$SY,0$` is the identifier `θn`), because TempleOS lexes the
    document's text, not its commands.

## 3. Preprocessor

Supported: `#define NAME tokens` (object-like only — HolyC has no function
macros), `#undef`, `#include "file"` (virtual filesystem, relative to the
including file, depth limit 16), `#ifdef`, `#ifndef`, `#if <const expr>`,
`#else`, `#endif`, `#ifaot`/`#ifjit` (`#ifjit` is true), `#help_index`,
`#help_file`, `#assert` (ignored).
A backslash at the end of a directive line continues it on the next line.
Unsupported (compile error with explanation): `#exe {...}`.

## 4. Types

| Type | Size | Notes |
|---|---|---|
| `U0`/`I0` | 0 | void |
| `I8 U8 I16 U16 I32 U32 I64 U64` | 1/2/4/8 | two's complement, little endian |
| `Bool` | 1 | stored as U8 |
| `F64` | 8 | IEEE-754 double |
| pointers | 8 | logical addresses inside the program arena |
| arrays | n*elem | decay to pointer |
| classes/unions | sum of members | **packed**, no implicit padding (as TempleOS) |

Integer types are intrinsic unions: `x.u8[i]`, `x.i16[i]`, `x.u32[1]`, ...
access sub-integers of any integer lvalue.

All integer arithmetic is 64-bit. Values loaded from narrower types are sign- or
zero-extended. Division, modulo and right shift are unsigned when either
operand is `U64` (or a pointer); otherwise signed. **Comparisons** are unsigned
when either operand has *any* unsigned type, `U8`…`U64` or a pointer
(TempleOS `OptLib.HC` `OptFixupBinaryOp1`). If either operand is `F64` the
operation is floating-point. Integer division by zero raises exception
`'DivZero'`; so do `I64_MIN/-1` and `I64_MIN%-1` (x86 `#DE`, `Kernel/KInts.HC`).
Shifts use the low 6 bits of the count (x86 rule).

Assignment value: `a=b` evaluates to the *converted-but-not-truncated* value of
`b` (TempleOS: `j1=i1=0x12345678` leaves `j1==0x12345678`).

F64 to integer conversion truncates toward zero; NaN and out-of-range values
produce `0x8000000000000000` (x86 `CVTTSD2SI` behaviour).

## 5. Operators (precedence, highest first)

```
postfix  () [] . -> ++ -- (Type)cast
prefix   - + ! ~ * & ++ -- sizeof offset
1        `  >>  <<          (` is power: right assoc among `, result always F64
                             (OptPass012.HC IC_POWER); -x`y is -(x`y))
2        *  /  %
3        &
4        ^
5        |
6        +  -
7        <  >  <=  >=       (chainable: a<b<=c  ==  a<b && b<=c, b evaluated once)
8        ==  !=             (any comparison following another chains:
                             2<3==1 == 2<3 && 3==1, PrsExp.HC ICF_PUSH_CMP)
9        &&
10       ^^                 (logical xor)
11       ||
12       = += -= *= /= %= &= |= ^= <<= >>=   (right assoc)
```

There is no `?:` operator. A comma operator is accepted in `for` clauses and
expression statements.

## 6. Statements

`if/else`, `while`, `do/while`, `for`, `switch` / `switch []` (with
`case a...b:` ranges, empty `case:` auto-numbering, `default:`, and
`start:`/`end:` sub-switch groups), `break`, `continue` (accepted as an
extension), `return`, `goto`/labels, `try {} catch {}`, blocks, declarations
anywhere, `lock {}` (plain block), `no_warn a,b;` (ignored).

* A statement that is a string literal prints: `"fmt",args;` calls `Print`.
  `"" fmt,args;` uses a variable format.
* A statement that is a char constant calls `PutChars`.
* A function name used without `(` is a call with default arguments.
* Code outside functions runs in order after the unit is compiled.
* `asm {}` is a compile error: *inline x86 assembly is not supported*.
* A class/union definition may be followed directly by the next declaration
  without `;`; a declarator list may end with a comma (`I64 a,b,;`).

## 7. Functions

Default arguments may appear anywhere and are expressions evaluated at the call
site; arguments may be skipped (`F(,3)`). Variadic functions (`...`) see
`I64 argc` and `I64 argv[]`; variadic arguments are passed as raw 64-bit values
(F64 as its bit pattern). Function pointers are obtained with `&Name`, may be
stored in variables and members, and are called with `p(args)` or `(*p)(args)`.

**Adaptation (falling off the end):** TempleOS returns whatever is in RAX when
a non-`U0` function reaches its closing brace without `return`. Programs rely on
this, so when the last statement of such a function is an expression statement,
its value is returned (as if `return expr;`); otherwise the result is 0. The
prelude's `QueIns`/`QueInsRev` return the inserted entry, which is what the
TempleOS compiler's inline code leaves in RAX.

## 8. Exceptions

`throw(I64 ch=0)` sets `Fs->except_ch`, clears `Fs->catch_except` and transfers
control to the innermost `catch`. If the catch block finishes without setting
`Fs->catch_except=TRUE` the exception propagates to the next outer handler.
`PutExcept()` prints the exception and sets `catch_except`. An exception with no
handler terminates the task with a report.
**Adaptation:** the stack is unwound to the handler before its catch block runs
(TempleOS runs catch blocks before unwinding).

Runtime faults become catchable exceptions: `'DivZero'`, `'BadMem'` (invalid
address), `'BadFree'`, `'StkOver'`. The Stop control first raises `'Break'`
(as Ctrl-Alt-C does) and terminates the task if it has not ended within 1.5 s.
Resource-limit violations (instruction budget in callbacks, arena exhausted)
are not catchable.

## 9. Memory model (sandbox)

Each running program owns one **arena**: a byte array, little-endian, addresses
`0..size`. Pointers are integers into this arena — never host addresses.

```
0x0000_0000 .. 0x0001_0000   guard page: any access faults ('BadMem')
0x0001_0000 .. heapStart     system area (prelude globals, string literals)
                             task stacks are allocated from the heap
heapStart   .. arenaLimit    heap (MAlloc/CAlloc/Free), grows on demand
```

* Every load/store is bounds checked: `addr >= 0x10000 && addr+width <= size`.
* Heap blocks carry a 16-byte header (size, magic|flags). `Free` validates the
  header: double free or foreign pointer raises `'BadFree'`. `MSize` returns the
  usable size (power-of-two rounded, like TempleOS for large blocks).
* The arena grows by doubling up to the program limit (32 MiB; 64 MiB on
  devices with more memory). Exceeding it raises `'OutMem'`.
* Function pointers are encoded as `0x7FFF_0000_0000_0000 | index`; they are not
  dereferenceable. Calling a non-function value raises `'BadCall'`.

## 10. Execution and scheduling

* Each program runs on its own VM thread with cooperative **tasks** (`Spawn`).
  The scheduler switches tasks at `Yield`, `Sleep`, `Refresh`, blocking input
  calls, and after an instruction slice (preemption at backward jumps/calls).
* Stop/limit checks happen at every backward jump and call.
* Frame callbacks (`Fs->draw_it`, ~30 Hz) run nested on the owning task's stacks
  at scheduler boundaries; blocking calls inside callbacks return immediately.
* Limits per task (`'StkOver'` when exceeded): call depth 2048 frames, locals
  stack 256 KiB, operand stack 8192 words, 256 nested `try` blocks.
* Virtual time (tests): `now()` advances 10 ns per executed instruction plus
  idle waits; `virtualStopAt` makes stepping deterministic, so both runtimes
  produce identical frames for identical input.

## 11. Host capability surface

User code can only reach host functions declared by the bundled system prelude
(`shared/runtime/Prelude.HC`) with the `native` keyword, which is accepted only
while compiling the prelude. The surface is: console text, formatting, memory
(arena only), math, time, input (keyboard/mouse messages), graphics (per-program
framebuffers), sound (tone generator), and the virtual filesystem (logical
`C:/` paths, quota-enforced, bundled layer read-only). There is no networking,
no process creation, no host reflection, no dynamic library loading.

## 12. Test vectors

`shared/test-vectors/holyc/NAME.HC` contains a program and, after a line
`//EXPECT:` (and until end of file), the exact expected console output with each
line prefixed by `//`. Vectors marked `//EXPECT-ERROR:` must fail with an error
message containing the given text. Both runtimes run every vector in their unit
tests.

## Verification-pass amendments (2026-10-16)

- **Runtime library** (`Kernel/KUtils.HC`, `StrA.HC`, `StrScan.HC`):
  - `MemCpy`, `MemSet` and `MemSetU16/U32/I64` return `dst+cnt×size`.
  - `MemCpy` copies forward byte by byte, so an overlapping forward copy replicates bytes.
  - Counts are 64-bit; a negative or oversized count raises `'BadMem'`.
  - `MemCmp`, `StrCmp`, `StrICmp`, `StrNCmp` and `StrNICmp` return -1, 0 or 1.
  - `Str2I64`, `StrUtil`, `LstMatch` and `StrCpy` follow the original sources.
- **Command line:** after each command the shell prints TempleOS's answer line:
  - `"%8.6fs ans=0x%08X=%d"` for integer results;
  - `"%8.6fs ansf=%15.7g"` for F64 results;
  - the time only, for `U0` results and declarations (`CmdLinePmt`, `Compiler/CMisc.HC`).
- **Keys:** cursor, Home, End, PgUp, PgDn, Ins and Del arrive with their `SC_*` code in
  `sc.u8[0]`, without the `SCF_E0_PREFIX` bit (`KbdBuildSC` remaps E0 keys).
- **Limits** (exceeding one raises a compile error or a HolyC exception, never a host failure):
  - expression tree height ≤ 5,000;
  - compiler recursion bounded by stack;
  - 1,000,000 tokens per macro use;
  - console lines wrap at 1,024 columns;
  - formatted strings ≤ 16 MiB, and widths and repeat counts ≤ 1,048,576;
  - 64-bit memory-operation counts.
- **Tasks:** ended tasks free their stack. A task stack is not a heap block for
  `Free`/`MSize` (`'BadFree'`).

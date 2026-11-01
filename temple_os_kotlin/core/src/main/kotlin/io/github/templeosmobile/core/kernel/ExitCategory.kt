package io.github.templeosmobile.core.kernel

import io.github.templeosmobile.core.holyc.Arena
import io.github.templeosmobile.core.holyc.Vm
import io.github.templeosmobile.core.holyc.chCode

/**
 * Why a program ended, as one cross-engine category (docs/native-validation). Pure Terry and the
 * native engines word their messages differently (an interpreter names the HolyC function and line, a
 * native kernel the translated function); the category is what they must agree on, and what tests,
 * benchmarks and the UI compare. The engine's own message stays in [Kernel.exitMessage].
 *
 * Distinct failures stay distinct: a program whose static image does not fit the configured program
 * memory ([INSUFFICIENT_PROGRAM_MEMORY], raised while its source is compiled or its translated data
 * segment is loaded) is not a run-time allocation that failed ([ALLOCATION_FAILED]), nor an access
 * outside the program's memory ([INVALID_MEMORY_ACCESS]), nor corrupted allocator metadata
 * ([HEAP_CORRUPTION]).
 */
object ExitCategory {
    /** The program's code returned (and every task it spawned ended). */
    const val NORMAL = "NORMAL"
    /** Break, the window's Stop, or the host ended the program. */
    const val STOPPED = "STOPPED"
    /** HolyC that does not compile (interpreter, or the native dynamic expression engine). */
    const val COMPILE_ERROR = "COMPILE_ERROR"
    /** The program's globals, constants or data segment do not fit the configured program memory (load time). */
    const val INSUFFICIENT_PROGRAM_MEMORY = "INSUFFICIENT_PROGRAM_MEMORY"
    /** A run-time MAlloc/CAlloc (or stack) needed more than the configured program memory ('OutMem'). */
    const val ALLOCATION_FAILED = "ALLOCATION_FAILED"
    /** A read or write outside the program's memory ('BadMem'). */
    const val INVALID_MEMORY_ACCESS = "INVALID_MEMORY_ACCESS"
    /** Allocator metadata found corrupted, or a bad pointer freed ('BadFree'). */
    const val HEAP_CORRUPTION = "HEAP_CORRUPTION"
    /** Integer division by zero ('DivZero'). */
    const val ARITHMETIC_FAULT = "ARITHMETIC_FAULT"
    /** A fixed limit of the runtime: call depth ('StkOver'), task count ('TooMany'), output size. */
    const val RESOURCE_LIMIT_EXCEEDED = "RESOURCE_LIMIT_EXCEEDED"
    /** A HolyC exception nobody caught (thrown by the program or the runtime). */
    const val UNHANDLED_EXCEPTION = "UNHANDLED_EXCEPTION"
    /** A failure of the host runtime itself (a bug), not of the HolyC program. */
    const val INTERNAL_RUNTIME_ERROR = "INTERNAL_RUNTIME_ERROR"

    private val TOO_MANY = chCode("TooMany")
    private val BREAK = chCode("Break")
    private val COMPILER = chCode("Compiler")

    /**
     * The category of an exception [code] that ended a task. [loading]: raised while the program's
     * source was compiled or its translated image loaded, not by its running code.
     */
    fun of(code: Long, message: String?, loading: Boolean): String = when (code) {
        Arena.OUT_MEM -> if (loading) INSUFFICIENT_PROGRAM_MEMORY else ALLOCATION_FAILED
        Arena.BAD_MEM -> if (message?.contains("heap corruption") == true) HEAP_CORRUPTION else INVALID_MEMORY_ACCESS
        Arena.BAD_FREE -> HEAP_CORRUPTION
        Vm.DIV_ZERO -> ARITHMETIC_FAULT
        Vm.STK_OVER, TOO_MANY -> RESOURCE_LIMIT_EXCEEDED
        BREAK -> STOPPED
        COMPILER -> COMPILE_ERROR
        else -> UNHANDLED_EXCEPTION
    }
}

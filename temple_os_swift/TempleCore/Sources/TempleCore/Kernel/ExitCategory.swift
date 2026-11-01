import Foundation

/**
 * Why a program ended, as one cross-engine category (port of ExitCategory.kt; docs/native-validation).
 * Pure Terry and the native engines word their messages differently; the category is what they must agree
 * on. A program whose static image does not fit the configured program memory (INSUFFICIENT_PROGRAM_MEMORY,
 * raised while its source is compiled or its translated data segment is loaded) is kept apart from a
 * run-time allocation that failed (ALLOCATION_FAILED), an access outside the program's memory
 * (INVALID_MEMORY_ACCESS) and corrupted allocator metadata (HEAP_CORRUPTION).
 */
public enum ExitCategory {
    public static let NORMAL = "NORMAL"
    public static let STOPPED = "STOPPED"
    public static let COMPILE_ERROR = "COMPILE_ERROR"
    public static let INSUFFICIENT_PROGRAM_MEMORY = "INSUFFICIENT_PROGRAM_MEMORY"
    public static let ALLOCATION_FAILED = "ALLOCATION_FAILED"
    public static let INVALID_MEMORY_ACCESS = "INVALID_MEMORY_ACCESS"
    public static let HEAP_CORRUPTION = "HEAP_CORRUPTION"
    public static let ARITHMETIC_FAULT = "ARITHMETIC_FAULT"
    public static let RESOURCE_LIMIT_EXCEEDED = "RESOURCE_LIMIT_EXCEEDED"
    public static let UNHANDLED_EXCEPTION = "UNHANDLED_EXCEPTION"
    public static let INTERNAL_RUNTIME_ERROR = "INTERNAL_RUNTIME_ERROR"

    private static let TOO_MANY = chCode("TooMany")
    private static let BREAK = chCode("Break")
    private static let COMPILER = chCode("Compiler")

    /** The category of an exception [code] that ended a task; [loading]: raised while the program was compiled or loaded. */
    public static func of(_ code: Int64, _ message: String?, loading: Bool) -> String {
        switch code {
        case Arena.OUT_MEM: return loading ? INSUFFICIENT_PROGRAM_MEMORY : ALLOCATION_FAILED
        case Arena.BAD_MEM: return (message?.contains("heap corruption") ?? false) ? HEAP_CORRUPTION : INVALID_MEMORY_ACCESS
        case Arena.BAD_FREE: return HEAP_CORRUPTION
        case Vm.DIV_ZERO: return ARITHMETIC_FAULT
        case Vm.STK_OVER, TOO_MANY: return RESOURCE_LIMIT_EXCEEDED
        case BREAK: return STOPPED
        case COMPILER: return COMPILE_ERROR
        default: return UNHANDLED_EXCEPTION
        }
    }
}

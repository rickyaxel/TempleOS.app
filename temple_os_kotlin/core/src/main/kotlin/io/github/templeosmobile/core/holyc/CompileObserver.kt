package io.github.templeosmobile.core.holyc

/**
 * Build-time observer of compilation, used only by the source-to-native translator
 * (temple_os_kotlin/translator): it sees every function's typed AST as the code
 * generator receives it and every arena allocation or write the compiler makes (the
 * program's data segment), in order. Null in the apps; it never changes what is
 * compiled. JVM-only build tooling, so the Swift port has no counterpart.
 */
interface CompileObserver {
    /** A compilation unit or chunk starts ([Program.compile], [Program.Session.next]). */
    fun unitStart(name: String) {}
    /** A compilation unit or chunk ended; [init] runs its top-level statements. */
    fun unitEnd(init: FuncSym?) {}
    /** [f] was compiled from [body] ([CodeGen.fallOffValue] already applied). */
    fun function(f: FuncSym, body: Stmt) {}
    /** Storage for a global, static local or top-level temporary ([Program.allocGlobal]). */
    fun global(addr: Int, size: Int) {}
    /** A string literal was interned ([Program.stringAddr]); called for every use, new or not. */
    fun string(bytes: ByteArray, addr: Int) {}
    /** A binary literal (DolDoc sprite data) was placed in the arena ([Program.binAddr]). */
    fun bin(bytes: ByteArray, addr: Int) {}
    /** The code generator placed binary literal [e] at [addr] (one allocation per occurrence, even of the same sprite). */
    fun binLit(e: Expr, addr: Int) {}
    /** A constant initializer wrote [width] bytes of [value] at [addr]; [isString] when the value is a string literal's address. */
    fun constWrite(addr: Int, width: Int, value: Long, isString: Boolean) {}
}

package io.github.templeosmobile.core

import io.github.templeosmobile.core.holyc.*
import io.github.templeosmobile.core.kernel.*
import org.junit.Test

class DebugTest {
    @Test
    fun syms() {
        if (System.getProperty("templeos.debug") != "true") return
        val k = Kernel(TestEnv(), "dbg"); k.boot()
        for (n in listOf("GrLine", "GrPlot", "Line", "Sprite3", "DistSqrI64", "GrBlot3", "TextPrint")) {
            val s = k.prog.globals[n]
            println("$n -> ${s?.javaClass?.simpleName} defined=${(s as? FuncSym)?.defined} entry=${(s as? FuncSym)?.entry}")
        }
        println("funcs=${k.prog.funcs.size} globals=${k.prog.globals.size}")
    }
}

class DebugLex {
    @Test
    fun lex() {
        if (System.getProperty("templeos.debug") != "true") return
        val f = java.io.File(SHARED, "runtime/GrLib.HC")
        val toks = Lexer(null).tokenize(SourceFile.parse("GrLib.HC", f.readBytes()), "C:/")
        println("tokens=${toks.size} lastLine=${toks.last().line} fileLines=${f.readText(Charsets.ISO_8859_1).lines().size}")
        val idx = toks.indexOfFirst { it.text == "DistSqrI64" && it.line > 200 }
        println("body DistSqrI64 at token $idx")
        println(toks.takeLast(5).joinToString { "${it.line}:${it}" })
    }
}

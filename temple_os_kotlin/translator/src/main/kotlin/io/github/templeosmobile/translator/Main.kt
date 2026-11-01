package io.github.templeosmobile.translator

import java.io.File

fun main(args: Array<String>) {
    val repo = Repo.locate()
    when (args.firstOrNull()) {
        "probe" -> {
            val fs=Capture.fs(repo)
            for(path in args.drop(1)) {val cap=Capture.program(repo,fs,path);println("$path: ${cap.error ?: "compiled"}");cap.kernel.terminate("probe")}
        }
        "extract-menu" -> extractMenu(repo)
        "stats" -> stats(repo, args.getOrNull(1)?.let { File(it) })
        "translate" -> {
            val only = args.drop(1).filter { !it.startsWith("--") }.toSet().ifEmpty { null }
            translate(repo, only, emitSwift = "--no-swift" !in args, force = "--force" in args)
        }
        else -> {
            System.err.println("usage: translator stats [out.txt] | translate [C:/path.HC ...] [--force] [--no-swift]")
            kotlin.system.exitProcess(2)
        }
    }
}

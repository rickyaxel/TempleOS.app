package io.github.templeosmobile.core.kernel

/** The standard TempleOS 16-color palette (ARGB). */
object Palette {
    val STD = intArrayOf(
        0xFF000000.toInt(), 0xFF0000AA.toInt(), 0xFF00AA00.toInt(), 0xFF00AAAA.toInt(),
        0xFFAA0000.toInt(), 0xFFAA00AA.toInt(), 0xFFAA5500.toInt(), 0xFFAAAAAA.toInt(),
        0xFF555555.toInt(), 0xFF5555FF.toInt(), 0xFF55FF55.toInt(), 0xFF55FFFF.toInt(),
        0xFFFF5555.toInt(), 0xFFFF55FF.toInt(), 0xFFFFFF55.toInt(), 0xFFFFFFFF.toInt(),
    )
    const val BLACK = 0; const val BLUE = 1; const val GREEN = 2; const val CYAN = 3
    const val RED = 4; const val PURPLE = 5; const val BROWN = 6; const val LTGRAY = 7
    const val DKGRAY = 8; const val LTBLUE = 9; const val LTGREEN = 10; const val LTCYAN = 11
    const val LTRED = 12; const val LTPURPLE = 13; const val YELLOW = 14; const val WHITE = 15
    const val TRANSPARENT = 0xFF
}

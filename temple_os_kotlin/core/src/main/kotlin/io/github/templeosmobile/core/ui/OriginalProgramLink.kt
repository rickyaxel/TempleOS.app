package io.github.templeosmobile.core.ui

import io.github.templeosmobile.core.kernel.Paths

/** A DolDoc include-only launch macro. Other macro languages retain their existing source workflow. */
class OriginalProgramLink(val label:String,val path:String) {
    companion object {
        fun parse(format:String,cwd:String):OriginalProgramLink? {
            fun quoted(at:Int):String? {
                if(at !in format.indices || format[at]!='"') return null
                val out=StringBuilder();var i=at+1
                while(i<format.length) {val c=format[i++];if(c=='"') return out.toString();if(c=='\\' && i<format.length) out.append(format[i++]) else out.append(c)}
                return null
            }
            val start=format.indexOf(",LM=");if(start<0) return null
            val macro=quoted(start+4) ?: return null
            val match=Regex("""\s*#include\s+"([^"]+)"\s*;?\s*""").matchEntire(macro) ?: return null
            var path=Paths.normalize(cwd,match.groupValues[1]) ?: return null
            if(!Paths.name(path).contains('.')) path+=".HC"
            if(path.endsWith(".Z",true)) path=path.dropLast(2)
            val tag=format.indexOf('"');val label=quoted(tag).orEmpty()
            return OriginalProgramLink(label,path)
        }
    }
}

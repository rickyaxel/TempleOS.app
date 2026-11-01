package io.github.templeosmobile.core

import io.github.templeosmobile.core.holyc.latin1
import org.junit.Assert.*
import org.junit.Test

/** A frame is only republished (and re-uploaded by the UI) when its pixels change. */
class FramePublishTest {
    @Test fun staticDrawItDoesNotRepublish() {
        val k = runHolyC(latin1("U0 DrawIt(CTask *,CDC *dc) { dc->color=RED; GrRect(dc,10,10,50,50); }\nFs->draw_it=&DrawIt;\nSleep(2000);\n"))
        println("static: frames=${k.frameCount} published=${k.publishedVersion}")
        assertTrue("frames ran: ${k.frameCount}", k.frameCount >= 40)
        assertTrue("identical frames are not republished: ${k.publishedVersion}", k.publishedVersion <= 3)
    }

    @Test fun movingDrawItRepublishes() {
        val k = runHolyC(latin1("I64 i;\nU0 DrawIt(CTask *,CDC *dc) { dc->color=RED; GrRect(dc,i,10,50,50); }\nFs->draw_it=&DrawIt;\nfor (i=0;i<60;i++) Sleep(40);\n"))
        println("moving: frames=${k.frameCount} published=${k.publishedVersion}")
        assertTrue("moving frames are published: ${k.publishedVersion}", k.publishedVersion >= 30)
    }
}

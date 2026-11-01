package io.github.templeosmobile.purekotlin

import io.github.templeosmobile.core.kernel.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import kotlin.math.abs
import kotlin.math.log2
import kotlin.math.pow
import kotlin.math.floor

/** Untouched sources, real event menus and chooser values; native executes zero bytecode. */
class DiscoveredMenuProgramTest {
    private fun expectedPitch(hz:Double):Double {
        val ona=(12*log2(32.0/440*hz)).toInt();val note=440.0/32*2.0.pow(ona/12.0)
        return 1193182/floor((18333*65536/1000).toDouble()/note)
    }
    private fun key(k:Kernel,ch:Int,down:Boolean=true) {val (_,sc)=Keys.forChar(ch);k.post(KInput.Key(ch,sc,down))}
    private fun tap(k:Kernel,ch:Int) {key(k,ch);key(k,ch,false)}
    private fun advance(k:Kernel,ms:Long) {advanceTo(k,ms);assertNull(k.console.plainText(),k.exitMessage)}
    private fun both(relative:String,answers:List<Long> = emptyList(),body:(Kernel,ParityEnv)->Unit) {
        val out=File("build/distribution-support").also {it.mkdirs()}
        for(engine in Engine.entries) {
            val env=ParityEnv(bundledFs());env.popupAnswers.addAll(answers)
            val (k,_)=bootProgram("C:/"+relative,engine,env=env)
            try {
                body(k,env);if(engine==Engine.NATIVE)assertEquals(0L,k.vm.instructionsExecuted)
                File(out,relative.replace('/','_')+"-$engine.txt").writeText("path=C:/$relative\nengine=$engine\ninstructions=${k.vm.instructionsExecuted}\nfinished=${k.finished}\nframes=${k.frameCount}\nsounds=${env.sound}\nremainingPopupAnswers=${env.popupAnswers}\n${k.console.plainText()}")
            } finally {k.terminate("test cleanup")}
        }
    }
    @Test fun dateTimeOutput() = both("Demo/DateTime.HC") {k,_->
        advance(k,100);assertTrue(k.finished)
        for(text in listOf("Hour:","Minute:","Second:","Day Name:","Month Name:"))assertTrue(k.console.plainText().contains(text))
        val stamp=Regex("[0-9]+/[0-9]+/[0-9]+ ([0-9]{2}):([0-9]{2}):([0-9]{2})").find(k.console.plainText())!!
        val fields=Regex("Hour:([0-9]{2}) Minute:([0-9]{2}) Second:([0-9]{2})").find(k.console.plainText())!!
        fun seconds(m:MatchResult)=(m.groupValues[1].toInt()*60+m.groupValues[2].toInt())*60+m.groupValues[3].toInt()
        assertTrue(abs(seconds(stamp)-seconds(fields))<=1)
    }
    @Test fun radixSortActuallySorts() = both("Demo/RadixSort.HC") {k,_->
        advance(k,100);assertTrue(k.finished)
        val values=Regex("(?m)^([0-9]+):([0-9]+)").findAll(k.console.plainText()).map {it.groupValues[2].toInt()}.toList()
        assertEquals(32,values.size);assertEquals(values.take(16).sorted(),values.takeLast(16))
    }
    @Test fun messageLoopInputAndExit() = both("Demo/MsgLoop.HC") {k,_->
        advance(k,100);assertFalse(k.finished);tap(k,97);advance(k,200)
        assertTrue(k.console.plainText(),k.console.plainText().contains("ARG1:00000061"))
        tap(k,Keys.CH_ESC);advance(k,400);assertTrue(k.finished)
    }
    @Test fun heldKeyAnimationAndRelease() = both("Demo/KeyBitMap.HC") {k,_->
        advance(k,100);assertFalse(k.finished);key(k,105);advance(k,200)
        val first=k.published.clone();advance(k,350);assertFalse(first.contentEquals(k.published));assertTrue(k.frameCount>5)
        key(k,105,false);advance(k,500);assertTrue(k.finished)
    }
    @Test fun pullDownEventsCheckedStateAudioAndMenuPop() = both("Demo/PullDownMenu.HC") {k,env->
        advance(k,100);assertEquals(listOf("File","Edit","Misc","Help"),k.menuSnapshot.filter {it.isDir}.map {it.label})
        fun send(path:String,ms:Long) {val m=k.menuSnapshot.first {it.path==path};k.post(KInput.Raw(m.msgCode.toInt(),m.a1,m.a2));advance(k,ms)}
        send("Misc/Opt1",200);assertTrue(k.menuSnapshot.first {it.path=="Misc/Opt1"}.checked)
        send("Misc/Opt2",300);assertTrue(k.console.plainText().contains("Option # 2"))
        send("Misc/Opt1",400);assertFalse(k.menuSnapshot.first {it.path=="Misc/Opt1"}.checked)
        send("Misc/Beep",1000);assertTrue(env.sound.any {it.second>0})
        send("File/Exit",1200);assertTrue(k.finished);assertTrue(k.menuSnapshot.isEmpty())
    }
    @Test fun buttonMenuNestedFrequencyPopupAndCancel() = both("Demo/DolDoc/MenuBttn.HC",listOf(0,2,1,400,3,-1)) {k,env->
        advance(k,1000);assertTrue(k.finished);assertTrue(env.popupAnswers.isEmpty())
        assertTrue(env.sound.any {abs(it.second-expectedPitch(100.0))<1e-9});assertTrue(env.sound.any {abs(it.second-expectedPitch(400.0))<1e-9});assertEquals(0.0,env.sound.last().second,0.0)
    }
    @Test fun spriteMenuValuesAndCancel() = both("Demo/DolDoc/MenuSprite.HC",listOf(50,100,200,-1)) {k,env->
        advance(k,1000);assertTrue(k.finished);assertTrue(env.popupAnswers.isEmpty())
        for(hz in listOf(50.0,100.0,200.0))assertTrue(env.sound.any {abs(it.second-expectedPitch(hz))<1e-9})
        assertEquals(0.0,env.sound.last().second,0.0)
    }
}

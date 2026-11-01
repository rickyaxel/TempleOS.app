package io.github.templeosmobile.purekotlin

import io.github.templeosmobile.core.kernel.*
import io.github.templeosmobile.core.ui.*
import io.github.templeosmobile.core.purenative.NativePrograms
import io.github.templeosmobile.purekotlin.gen.NativeCatalog
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.Collections

/** Real shell/custom-keyboard -> original or compiled program -> sound. No physical devices. */
class SoundKeyboardIntegrationTest {
    private class Env(dir:File):ShellEnv {
        override val fs=LayeredFs(DirBundle(File(SHARED,"bundled-fs"),File(SHARED,"bundled-fs.index")),dir)
        override val stateStore=object:StateStore {
            private var text:String?=null
            override fun load()=text
            override fun save(value:String) {text=value}
        }
        val sounds=Collections.synchronizedList(ArrayList<Double>())
        fun tones()=synchronized(sounds) {sounds.toList()}
        override fun runtimeFile(name:String)=File(SHARED,if(name=="catalog.json") "program-manifests/catalog.json" else "runtime/$name").takeIf {it.isFile}?.readBytes()
        override fun tone(freq:Double,atNs:Long) {sounds.add(freq)}
    }
    private fun wait(sh:Shell,ms:Long=10_000,condition:()->Boolean):Boolean {
        val end=System.nanoTime()+ms*1_000_000
        do {sh.tick();if(condition()) return true;Thread.sleep(10)} while(System.nanoTime()<end)
        return condition()
    }
    @Test fun originalInstrumentsUseTheCustomKeyboardInBothModes() {
        NativePrograms.catalog=NativeCatalog
        for(native in listOf(false,true)) for(id in listOf("sound.asciiorgan","sound.morsecode","app.psalmody","original.jukebox")) {
            val dir=kotlin.io.path.createTempDirectory("sound-keyboard").toFile()
            val env=Env(dir);val sh=Shell(env);sh.resize(402,874);sh.tick()
            sh.settings.engine=if(native) Settings.ENGINE_NATIVE else Settings.ENGINE_TERRY
            val info=sh.catalog.byId(id)!!;Launch.program(sh,info.path,info)
            val app=sh.focused!!.app as ProgramApp;val k=app.kernel
            try {
                assertEquals(native,app.native!=null)
                assertTrue(id,wait(sh) {sh.templeKeyboardShown && k.frameCount>4 && sh.accessibilityNodes().any {it.button && it.label=="a"}})
                assertNull(k.console.plainText(),k.exitMessage)
                fun key(label:String,down:Boolean) {
                    val r=sh.accessibilityNodes().last {it.button && it.label==label}.rect
                    sh.pointer(PointerEvent(if(down) Ptr.DOWN else Ptr.UP,r.x+r.w/2,r.y+r.h/2,id=73,timeMs=sh.env.nowMs()));sh.tick()
                }
                val label=if(id=="original.jukebox") "Space" else "a";val before=env.tones().count {it>0}
                key(label,true);assertTrue("$id $native: custom key produces sound",wait(sh) {env.tones().count {it>0}>before});key(label,false)
                if(id=="sound.morsecode" || id=="app.psalmody") assertTrue("key release silences $id",wait(sh) {env.tones().lastOrNull()==0.0})
                if(id=="app.psalmody") {
                    key("Symbols",true);key("Symbols",false)
                    for(note in listOf("left bracket","right bracket","apostrophe")) {
                        val count=env.tones().count {it>0}
                        key(note,true);assertTrue(note,wait(sh) {env.tones().count {it>0}>count})
                        key(note,false);assertTrue("$note release",wait(sh) {env.tones().lastOrNull()==0.0})
                    }
                    key("Letters",true);key("Letters",false)
                }
                if(id=="sound.asciiorgan") {
                    val lower=env.tones().lastOrNull();key("Shift",true);key("Shift",false)
                    val count=env.tones().count {it>0}
                    key("A",true);assertTrue(wait(sh) {env.tones().count {it>0}>count});key("A",false)
                    assertNotEquals("ASCII uppercase uses its original distinct pitch",lower,env.tones().lastOrNull())
                }
                sh.resize(874,402);sh.tick();assertTrue(sh.templeKeyboardShown)
                app.menu().first {it.label==tr("program.menu.hide_keyboard")}.action();sh.tick();assertFalse(sh.templeKeyboardShown)
                sh.resize(402,874);sh.tick();assertFalse("rotation respects Hide",sh.templeKeyboardShown)
                app.menu().first {it.label==tr("program.menu.show_keyboard")}.action();sh.tick();assertTrue(sh.templeKeyboardShown)
                if(native) assertEquals(0L,k.vm.instructionsExecuted)
                sh.close(sh.focused!!,force=true);assertTrue("closing silences $id",wait(sh,2000) {env.tones().lastOrNull()==0.0})
            } finally {sh.windows.toList().forEach {sh.close(it,force=true)};dir.deleteRecursively()}
        }
    }
}

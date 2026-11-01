package io.github.templeosmobile.core

import io.github.templeosmobile.core.holyc.latin1
import org.junit.Assert.*
import org.junit.Test

/**
 * Programs that try to corrupt host memory through the allocator, the operand
 * stack or graphics device-context fields must end with a HolyC exception and
 * leave the runtime intact (on Swift these were native memory-safety bugs).
 * Same cases as Swift MemorySafetyTests.
 */
class MemorySafetyTest {
    private fun expectFault(src: String, code: String) {
        val k = runHolyC(latin1(src + "\n\"survived\\n\";\n"))
        val out = k.console.plainText()
        assertTrue("program ended", k.finished)
        assertFalse("the bad operation must fault:\n$out", out.contains("survived"))
        assertTrue("expected $code:\n$out", out.contains(code))
        val k2 = runHolyC(latin1("I64 *a=MAlloc(64); a[7]=5; \"ok %d\\n\",a[7]; Free(a);"))
        assertTrue(k2.console.plainText().contains("ok 5"))
    }

    @Test fun forgedBlockSizeBeforeCAlloc() = expectFault("I64 *b=MAlloc(16); Free(b); b[-2]=0x10000000; CAlloc(16);", "BadMem")

    // the free-list link is in the block header (high half "FREE"): a forged link is detected
    @Test fun poisonedFreeList() = expectFault("I64 *a=MAlloc(16); Free(a); a[-1]=0x454552467FFF0000; MAlloc(16); MAlloc(16);", "BadMem")

    /** Kernel/Mem/MAllocFree.HC _MALLOC rounds requests up to 8 bytes (Talons' 240000 48-byte panels). */
    @Test fun heapBlocksAreRoundedTo8Bytes() {
        assertEquals("40 48 8 1024", runHolyC(latin1("\"%d %d %d %d\\n\",MSize(MAlloc(40)),MSize(MAlloc(41)),MSize(MAlloc(1)),MSize(MAlloc(1020));\n"))
            .console.plainText().trim().lines().last().trim())
    }

    /** Kernel/Mem/MAllocFree.HC: Free links the block through its header and leaves its bytes (Talons reads freed panels). */
    @Test fun freeLeavesTheBlocksBytes() {
        // read before printing: Print allocates (StrPrintJoin) and may reuse the block
        val k = runHolyC(latin1("I64 *a=MAlloc(16),*b,x,y,same; a[0]=0x1234; a[1]=5; Free(a); x=a[0]; y=a[1];" +
            "b=MAlloc(16); same=a==b; \"%X %d %d\\n\",x,y,same;\n"))
        assertTrue(k.console.plainText(), k.console.plainText().contains("1234 5 1"))
    }

    @Test fun forgedSizeClassOnFree() {
        expectFault("I64 *p=MAlloc(16); p[-2]=0; Free(p);", "BadFree")
        expectFault("I64 *p=MAlloc(16); p[-2]=1<<62; Free(p);", "BadFree")
        expectFault("I64 *p=MAlloc(16); p[-2]=24; Free(p);", "BadFree")
        expectFault("I64 *p=MAlloc(16); p[-2]=0x1000000; MSize(p);", "BadFree")
    }

    @Test fun hugeArgumentCount() = expectFault("""
        U8 *s=MAlloc(40000); I64 i;
        StrCpy(s,"Print(\"\""); for (i=0;i<9000;i++) StrCat(s,",0"); StrCat(s,");");
        ExePrint("%s",s);
        """.trimIndent(), "StkOver")

    @Test fun deepExpression() {
        // 9000 nested parentheses: a compile error, not a host stack overflow
        val k = runHolyC(latin1("""
            U8 *s=MAlloc(100000); I64 i;
            StrCpy(s,"I64 x="); for (i=0;i<9000;i++) StrCat(s,"1+("); StrCat(s,"1");
            for (i=0;i<9000;i++) StrCat(s,")"); StrCat(s,";");
            ExePrint("%s",s);
            "survived\n";
            """.trimIndent()))
        val out = k.console.plainText()
        assertTrue(out, out.contains("too deeply nested"))
        // as TempleOS's ExePutS (Compiler/CMain.HC): a compile error returns 0 and the caller continues
        assertTrue(out, out.contains("survived"))
    }

    @Test fun deepStatements() {
        val k = runHolyC(latin1("""
            U8 *s=MAlloc(100000); I64 i;
            StrCpy(s,""); for (i=0;i<9000;i++) StrCat(s,"{"); for (i=0;i<9000;i++) StrCat(s,"}");
            ExePrint("%s",s);
            "survived\n";
            """.trimIndent()))
        assertTrue(k.console.plainText().contains("too deeply nested"))
        assertTrue(k.console.plainText().contains("survived"))
    }

    @Test fun longOperatorChain() {
        // a left-deep chain of 20000 additions of a variable compiles or fails cleanly
        val k = runHolyC(latin1("""
            U8 *s=MAlloc(200000); I64 i;
            StrCpy(s,"I64 y=1,z=y"); for (i=0;i<20000;i++) StrCat(s,"+y"); StrCat(s,";\"z=%d\\n\",z;");
            ExePrint("%s",s);
            """.trimIndent()))
        val out = k.console.plainText()
        assertTrue(out, out.contains("z=20001") || out.contains("too deeply nested"))
    }

    @Test fun negativeRowStride() = expectFault("CDC *dc=DCNew(64,64); dc->width_internal=-0x100000; dc->color=RED; GrRect(dc,0,0,8,32);", "BadMem")

    @Test fun hugeRowStride() = expectFault("CDC *dc=DCNew(64,64); dc->width_internal=0x40000000; dc->color=RED; GrRect(dc,0,0,8,32);", "BadMem")

    @Test fun blotAndFloodWithForgedStride() {
        expectFault("CDC *dc=DCNew(64,64); CDC *img=DCNew(8,8); dc->width_internal=-0x100000; GrBlot(dc,0,10,img);", "BadMem")
        expectFault("CDC *dc=DCNew(64,64); dc->width_internal=-0x100000; dc->color=RED; GrFloodFill(dc,10,10);", "BadMem")
        expectFault("CDC *dc=DCNew(64,64); dc->width=0x7FFFFFFF; dc->height=0x7FFFFFFF; dc->color=RED; GrFloodFill(dc,10,10);", "BadMem")
    }

    // A negative count is a huge REP count on x86 (Kernel/KUtils.HC): it faults, never "does nothing".
    @Test fun negativeLengthCopies() {
        expectFault("U8 *a=MAlloc(64); MemSet(a,1,-5);", "BadMem")
        expectFault("U8 *a=MAlloc(64); MemCpy(a,a+8,-1);", "BadMem")
        expectFault("U8 *a=MAlloc(64); MemCpy(a,a+8,(1<<32)+20);", "BadMem")
        expectFault("I64 *a=MAlloc(64); MemSetI64(a,7,0x20000001);", "BadMem")
    }

    @Test fun freeOfALocalIsRejected() {
        expectFault("U0 F() { I64 x=1; Free(&x); } F;", "BadFree")
    }

    /** Ended tasks return their stacks (they leaked 256 KiB each: OutMem after ~110 Spawns). */
    @Test fun spawnedTasksReleaseTheirStacks() {
        val k = runHolyC(latin1("U0 Child(I64) {}\nI64 i,m0=MemUsed;\nfor (i=0;i<400;i++) { Spawn(&Child,NULL,\"child\"); Sleep(2); }\n\"grew %d KiB\\n\",(MemUsed-m0)/1024;\n"))
        val out = k.console.plainText()
        val grew = Regex("grew (\\d+) KiB").find(out)?.groupValues?.get(1)?.toInt()
        assertTrue(out, grew != null && grew < 400 * 8)
    }
}

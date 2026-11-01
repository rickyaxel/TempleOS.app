import XCTest
@testable import TempleCore

/**
 * Programs that try to corrupt host memory through the allocator, the operand
 * stack or graphics device-context fields must end with a HolyC exception and
 * leave the process intact. Run under AddressSanitizer too:
 * swift test --sanitize=address --filter MemorySafetyTests. Port of MemorySafetyTest.kt.
 */
final class MemorySafetyTests: XCTestCase {
    private func expectFault(_ src: String, _ code: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let k = try runHolyC(latin1(src + "\n\"survived\\n\";\n"))
        let out = k.console.plainText()
        XCTAssertTrue(k.finished, "program ended", file: file, line: line)
        XCTAssertFalse(out.contains("survived"), "the bad operation must fault:\n\(out)", file: file, line: line)
        XCTAssertTrue(out.contains(code), "expected \(code):\n\(out)", file: file, line: line)
        // the kernel still works afterwards: a fresh program runs normally
        let k2 = try runHolyC(latin1("I64 *a=MAlloc(64); a[7]=5; \"ok %d\\n\",a[7]; Free(a);"))
        XCTAssertTrue(k2.console.plainText().contains("ok 5"), file: file, line: line)
    }

    func testForgedBlockSizeBeforeCAlloc() throws {
        try expectFault("I64 *b=MAlloc(16); Free(b); b[-2]=0x10000000; CAlloc(16);", "BadMem")
    }

    // the free-list link is in the block header (high half "FREE"): a forged link is detected
    func testPoisonedFreeList() throws {
        try expectFault("I64 *a=MAlloc(16); Free(a); a[-1]=0x454552467FFF0000; MAlloc(16); MAlloc(16);", "BadMem")
    }

    /** Kernel/Mem/MAllocFree.HC _MALLOC rounds requests up to 8 bytes (Talons' 240000 48-byte panels). */
    func testHeapBlocksAreRoundedTo8Bytes() throws {
        let k = try runHolyC(latin1("\"%d %d %d %d\\n\",MSize(MAlloc(40)),MSize(MAlloc(41)),MSize(MAlloc(1)),MSize(MAlloc(1020));\n"))
        XCTAssertEqual(k.console.plainText().trimmed().components(separatedBy: "\n").last?.trimmingCharacters(in: .whitespaces), "40 48 8 1024")
    }

    /** Kernel/Mem/MAllocFree.HC: Free links the block through its header and leaves its bytes (Talons reads freed panels). */
    func testFreeLeavesTheBlocksBytes() throws {
        // read before printing: Print allocates (StrPrintJoin) and may reuse the block
        let k = try runHolyC(latin1("I64 *a=MAlloc(16),*b,x,y,same; a[0]=0x1234; a[1]=5; Free(a); x=a[0]; y=a[1];" +
            "b=MAlloc(16); same=a==b; \"%X %d %d\\n\",x,y,same;\n"))
        XCTAssertTrue(k.console.plainText().contains("1234 5 1"), k.console.plainText())
    }

    func testForgedSizeClassOnFree() throws {
        try expectFault("I64 *p=MAlloc(16); p[-2]=0; Free(p);", "BadFree")
        try expectFault("I64 *p=MAlloc(16); p[-2]=1<<62; Free(p);", "BadFree")
        try expectFault("I64 *p=MAlloc(16); p[-2]=24; Free(p);", "BadFree")
        try expectFault("I64 *p=MAlloc(16); p[-2]=0x1000000; MSize(p);", "BadFree")
    }

    func testHugeArgumentCount() throws {
        try expectFault("""
        U8 *s=MAlloc(40000); I64 i;
        StrCpy(s,"Print(\\"\\""); for (i=0;i<9000;i++) StrCat(s,",0"); StrCat(s,");");
        ExePrint("%s",s);
        """, "StkOver")
    }

    func testDeepExpression() throws {
        // 9000 nested parentheses: a compile error, not a host stack overflow
        let k = try runHolyC(latin1("""
        U8 *s=MAlloc(100000); I64 i;
        StrCpy(s,"I64 x="); for (i=0;i<9000;i++) StrCat(s,"1+("); StrCat(s,"1");
        for (i=0;i<9000;i++) StrCat(s,")"); StrCat(s,";");
        ExePrint("%s",s);
        "survived\n";
        """))
        let out = k.console.plainText()
        XCTAssertTrue(out.contains("too deeply nested"), out)
        // as TempleOS's ExePutS (Compiler/CMain.HC): a compile error returns 0 and the caller continues
        XCTAssertTrue(out.contains("survived"), out)
    }

    func testDeepStatements() throws {
        let k = try runHolyC(latin1("""
        U8 *s=MAlloc(100000); I64 i;
        StrCpy(s,""); for (i=0;i<9000;i++) StrCat(s,"{"); for (i=0;i<9000;i++) StrCat(s,"}");
        ExePrint("%s",s);
        "survived\n";
        """))
        XCTAssertTrue(k.console.plainText().contains("too deeply nested"))
        XCTAssertTrue(k.console.plainText().contains("survived"))
    }

    func testLongOperatorChain() throws {
        // a left-deep chain of 20000 additions of a variable compiles or fails cleanly
        let k = try runHolyC(latin1("""
        U8 *s=MAlloc(200000); I64 i;
        StrCpy(s,"I64 y=1,z=y"); for (i=0;i<20000;i++) StrCat(s,"+y"); StrCat(s,";\\"z=%d\\\\n\\",z;");
        ExePrint("%s",s);
        """))
        let out = k.console.plainText()
        XCTAssertTrue(out.contains("z=20001") || out.contains("too deeply nested"), out)
    }

    func testNegativeRowStride() throws {
        try expectFault("CDC *dc=DCNew(64,64); dc->width_internal=-0x100000; dc->color=RED; GrRect(dc,0,0,8,32);", "BadMem")
    }

    func testHugeRowStride() throws {
        try expectFault("CDC *dc=DCNew(64,64); dc->width_internal=0x40000000; dc->color=RED; GrRect(dc,0,0,8,32);", "BadMem")
    }

    func testBlotAndFloodWithForgedStride() throws {
        try expectFault("CDC *dc=DCNew(64,64); CDC *img=DCNew(8,8); dc->width_internal=-0x100000; GrBlot(dc,0,10,img);", "BadMem")
        try expectFault("CDC *dc=DCNew(64,64); dc->width_internal=-0x100000; dc->color=RED; GrFloodFill(dc,10,10);", "BadMem")
        try expectFault("CDC *dc=DCNew(64,64); dc->width=0x7FFFFFFF; dc->height=0x7FFFFFFF; dc->color=RED; GrFloodFill(dc,10,10);", "BadMem")
    }

    // A negative count is a huge REP count on x86 (Kernel/KUtils.HC): it faults, never "does nothing".
    func testNegativeLengthCopies() throws {
        try expectFault("U8 *a=MAlloc(64); MemSet(a,1,-5);", "BadMem")
        try expectFault("U8 *a=MAlloc(64); MemCpy(a,a+8,-1);", "BadMem")
        try expectFault("U8 *a=MAlloc(64); MemCpy(a,a+8,(1<<32)+20);", "BadMem")
        try expectFault("I64 *a=MAlloc(64); MemSetI64(a,7,0x20000001);", "BadMem")
    }

    func testFreeOfALocalIsRejected() throws {
        try expectFault("U0 F() { I64 x=1; Free(&x); } F;", "BadFree")
    }

    /** Ended tasks return their stacks (they leaked 256 KiB each: OutMem after ~110 Spawns). */
    func testSpawnedTasksReleaseTheirStacks() throws {
        let k = try runHolyC(latin1("U0 Child(I64) {}\nI64 i,m0=MemUsed;\nfor (i=0;i<400;i++) { Spawn(&Child,NULL,\"child\"); Sleep(2); }\n\"grew %d KiB\\n\",(MemUsed-m0)/1024;\n"))
        let out = k.console.plainText()
        guard let r = out.range(of: #"grew (\d+) KiB"#, options: .regularExpression),
              let grew = Int(out[r].dropFirst(5).dropLast(4)) else { return XCTFail(out) }
        XCTAssertLessThan(grew, 400 * 8, out)
    }
}

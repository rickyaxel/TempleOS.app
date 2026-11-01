import Foundation
import XCTest
@testable import TempleCore

/** Port of LayeredFsTest.kt. */
final class LayeredFsTests: XCTestCase {
    private let bundle = DirBundle(SHARED.appendingPathComponent("bundled-fs"), SHARED.appendingPathComponent("bundled-fs.index"))

    private func tmp() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("tosfs-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func testPathNormalization() {
        XCTAssertEqual("C:/Home/A.HC", Paths.normalize("C:/Home", "A.HC"))
        XCTAssertEqual("C:/Demo", Paths.normalize("C:/Home", "::/Demo"))
        XCTAssertEqual("C:/", Paths.normalize("C:/Home", "../../../.."))
        XCTAssertEqual("C:/etc/passwd", Paths.normalize("C:/Home", "../../etc/passwd"))
        XCTAssertNil(Paths.normalize("C:/Home", "D:/x"))
        XCTAssertNil(Paths.normalize("C:/Home", "a:b"))
        XCTAssertNil(Paths.normalize("C:/Home", "bad\u{0}name"))
        XCTAssertEqual("C:/Home/x", Paths.normalize("C:/", "~/x"))
    }

    func testBundledFilesCarryTheIsoDate() throws {
        // V-04: RedSea CDate of Doc/Welcome.DD on the V5.03 ISO = 2017-10-19 04:06:39 (wall clock)
        let fs = LayeredFs(bundle, tmp())
        let e = fs.stat("C:/Doc/Welcome.DD")!
        XCTAssertEqual(1508385999999, e.modified)
        XCTAssertEqual("10/19 04:06", FsCommands.dirDate(e))
        XCTAssertEqual(e.modified, fs.list("C:/Doc")!.first { $0.name == "Welcome.DD" }!.modified)
        XCTAssertGreaterThan(fs.stat("C:/Doc")!.modified, 0, "directories are dated too")
        XCTAssertEqual("--/-- --:--", FsCommands.dirDate(fs.stat("C:/Home/Examples/Hello.HC")!))
        try fs.writeFile("C:/Home/New.HC", Array("1;".utf8))
        XCTAssertLessThan(abs(fs.stat("C:/Home/New.HC")!.modified - Int64(Date().timeIntervalSince1970 * 1000)), 60_000)
    }

    func testBundledReadOnlyLayerAndOverlay() throws {
        let dir = tmp()
        let fs = LayeredFs(bundle, dir)
        XCTAssertTrue(fs.isDir("C:/Demo/Games"))
        let maze = fs.readFile("C:/Demo/Games/Maze.HC")!
        XCTAssertTrue(latin1(maze).contains("SolveMaze"))
        XCTAssertNotNil(fs.readFile("c:/demo/games/maze.hc"), "case-insensitive lookup")
        try fs.writeFile("C:/Demo/Games/Maze.HC", latin1("changed"))
        XCTAssertEqual("changed", latin1(fs.readFile("C:/Demo/Games/Maze.HC")!))
        XCTAssertFalse(fs.isOriginal("C:/Demo/Games/Maze.HC"))
        try fs.restoreOriginal("C:/Demo/Games/Maze.HC")
        XCTAssertEqual(maze, fs.readFile("C:/Demo/Games/Maze.HC"))
        try fs.delete("C:/Demo/Games/Maze.HC")
        XCTAssertNil(fs.readFile("C:/Demo/Games/Maze.HC"))
        XCTAssertTrue(fs.list("C:/Demo/Games")!.allSatisfy { $0.name != "Maze.HC" })
        let fs2 = LayeredFs(bundle, dir)
        XCTAssertNil(fs2.readFile("C:/Demo/Games/Maze.HC"))
        try fs2.writeFile("C:/Demo/Games/Maze.HC", maze)
        XCTAssertNotNil(LayeredFs(bundle, dir).readFile("C:/Demo/Games/Maze.HC"))
    }

    /** Storage full / I/O error while recording a deleted original: an FsError, and nothing is deleted. */
    func testFailedWhiteoutWriteIsAnFsErrorAndKeepsTheFile() throws {
        let dir = tmp()
        let fs = LayeredFs(bundle, dir)
        let blocker = dir.appendingPathComponent("deleted.txt.tmp")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true) // the list's temp file cannot be written
        XCTAssertThrowsError(try fs.delete("C:/Demo/Games/Maze.HC")) { e in
            XCTAssertEqual((e as? FsError)?.key, "fs.error.could_not_delete")
        }
        XCTAssertNotNil(fs.readFile("C:/Demo/Games/Maze.HC"), "the original is still there")
        XCTAssertNotNil(LayeredFs(bundle, dir).readFile("C:/Demo/Games/Maze.HC"), "and after a relaunch")
        try? FileManager.default.removeItem(at: blocker) // the failed save's cleanup may already have removed the empty blocker
        try fs.delete("C:/Demo/Games/Maze.HC") // works once there is room again
        XCTAssertNil(LayeredFs(bundle, dir).readFile("C:/Demo/Games/Maze.HC"))
    }

    func testUserFilesDirsMoveDelete() throws {
        let dir = tmp()
        let fs = LayeredFs(bundle, dir)
        try fs.mkdir("C:/Home/Proj")
        try fs.writeFile("C:/Home/Proj/A.HC", latin1("\"hi\\n\";"))
        XCTAssertTrue(fs.list("C:/Home/Proj")!.contains { $0.name == "A.HC" && !$0.readOnly })
        XCTAssertThrowsError(try fs.writeFile("C:/Home/Missing/B.HC", [1]))
        XCTAssertThrowsError(try fs.delete("C:/Home/Proj"), "non-empty dir")
        try fs.move("C:/Home/Proj/A.HC", "C:/Home/Proj/B.HC")
        XCTAssertNil(fs.readFile("C:/Home/Proj/A.HC"))
        XCTAssertNotNil(fs.readFile("C:/Home/Proj/B.HC"))
        XCTAssertThrowsError(try fs.move("C:/Home/Proj", "C:/Home/Proj/Sub"))
        try fs.delete("C:/Home/Proj", recursive: true)
        XCTAssertFalse(fs.exists("C:/Home/Proj"))
        XCTAssertEqual(0, fs.usedBytes())
        let leftovers = FileManager.default.enumerator(atPath: dir.path)?.compactMap { $0 as? String }.filter { ($0 as NSString).lastPathComponent.hasPrefix(".tmp-") } ?? []
        XCTAssertTrue(leftovers.isEmpty, "no temp files left")
    }

    func testTraversalCannotEscapeSandbox() throws {
        let dir = tmp()
        let fs = LayeredFs(bundle, dir)
        try fs.writeFile("C:/../../../outside.txt", latin1("x"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("files/outside.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().appendingPathComponent("outside.txt").path))
        XCTAssertNil(fs.readFile("C:/../../etc/passwd"))
    }

    func testQuotaEnforced() throws {
        let fs = LayeredFs(bundle, tmp(), quotaBytes: 1000)
        try fs.writeFile("C:/Home/a.bin", [UInt8](repeating: 0, count: 800))
        XCTAssertThrowsError(try fs.writeFile("C:/Home/b.bin", [UInt8](repeating: 0, count: 300)), "quota")
        try fs.writeFile("C:/Home/a.bin", [UInt8](repeating: 0, count: 900))
        XCTAssertEqual(900, fs.usedBytes())
    }

    func testExamplesRunFromVirtualFs() throws {
        let fs = LayeredFs(bundle, tmp())
        let env = TestEnv(fs)
        let hello = try runHolyC(fs.readFile("C:/Home/Examples/Hello.HC")!, "C:/Home/Examples/Hello.HC", env: env)
        XCTAssertEqual("Hello World!\nIn HolyC, strings can use DolDoc colors.\n*", hello.console.plainText().trimmingCharacters(in: .whitespacesAndNewlines))
        let fn = try runHolyC(fs.readFile("C:/Home/Examples/Functions.HC")!, "C:/Home/Examples/Functions.HC", env: env)
        XCTAssertTrue(fn.console.plainText().contains("Area(,4) = 40"))
        XCTAssertTrue(fn.console.plainText().contains("Fib(20) = 6765"))
        let loops = try runHolyC(fs.readFile("C:/Home/Examples/Loops.HC")!, "C:/Home/Examples/Loops.HC", env: env)
        XCTAssertTrue(loops.console.plainText().contains("Sum of 1..10 is 55"))
        XCTAssertTrue(loops.console.plainText().contains("zero small small small big big"))
        let inc = try runHolyC(latin1("#include \"::/Home/Examples/Arithmetic.HC\"\n"), "C:/Home/Inc.HC", env: env)
        XCTAssertTrue(inc.console.plainText().contains("1<<4+1 = 17"), inc.console.plainText())
        let io = try runHolyC(latin1("FileWrite(\"~/T.TXT\",\"abc\",3); U8 *b=FileRead(\"~/T.TXT\"); \"%s %d\\n\",b,FileFind(\"~/T.TXT\");"), "C:/Home/Io.HC", env: env)
        XCTAssertEqual("abc 1", io.console.plainText().trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

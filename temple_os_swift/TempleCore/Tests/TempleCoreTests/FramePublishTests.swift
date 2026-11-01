import XCTest
@testable import TempleCore

/** A frame is only republished (and re-uploaded by the UI) when its pixels change. Port of FramePublishTest.kt. */
final class FramePublishTests: XCTestCase {
    func testStaticDrawItDoesNotRepublish() throws {
        let k = try runHolyC(latin1("U0 DrawIt(CTask *,CDC *dc) { dc->color=RED; GrRect(dc,10,10,50,50); }\nFs->draw_it=&DrawIt;\nSleep(2000);\n"))
        XCTAssertGreaterThanOrEqual(k.frameCount, 40, "frames ran")
        XCTAssertLessThanOrEqual(k.publishedVersion, 3, "identical frames are not republished")
    }

    func testMovingDrawItRepublishes() throws {
        let k = try runHolyC(latin1("I64 i;\nU0 DrawIt(CTask *,CDC *dc) { dc->color=RED; GrRect(dc,i,10,50,50); }\nFs->draw_it=&DrawIt;\nfor (i=0;i<60;i++) Sleep(40);\n"))
        XCTAssertGreaterThanOrEqual(k.publishedVersion, 30, "moving frames are published")
    }
}

import Foundation
import TempleCore
import PureSwift
import XCTest

/**
 * A finished or closed program releases its kernel and arena (docs/native-validation): on iOS each arena reserves
 * its whole program-memory limit, so kernels kept alive by reference cycles exhaust the address space after about
 * a hundred program launches ("arena reservation failed" on the iPhone during the catalog run).
 */
final class KernelReleaseTests: XCTestCase {
    private func released(_ path: String, _ engine: Engine) throws -> Bool {
        weak var weakKernel: Kernel?
        weak var weakArena: Arena?
        try autoreleasepool {
            let (k, _) = try runScript(path, engine, sweepScript(500), 500, light: true)
            k.terminate("done")
            weakKernel = k
            weakArena = k.mem
        }
        // task threads of a native kernel finish asynchronously after terminate
        for _ in 0..<100 where weakKernel != nil || weakArena != nil { Thread.sleep(forTimeInterval: 0.02) }
        return weakKernel == nil && weakArena == nil
    }

    func testTerminatedKernelsAreReleased() throws {
        for engine in [Engine.terry, .native] {
            for path in ["C:/Demo/Games/BomberGolf.HC", "C:/Demo/Graphics/MouseDemo.HC", "C:/Demo/Graphics/Cartesian.HC"] {
                XCTAssertTrue(try released(path, engine), "\(path) on \(engine): the kernel or its arena is still alive after terminate")
            }
        }
    }
}

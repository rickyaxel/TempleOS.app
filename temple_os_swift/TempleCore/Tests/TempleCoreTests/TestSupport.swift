import CoreGraphics
import Foundation
import ImageIO
@testable import TempleCore

/** Repository paths, resolved from this source file (temple_os_swift/TempleCore/Tests/TempleCoreTests). */
let REPO: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let SHARED: URL = REPO.appendingPathComponent("shared")
let REFERENCE: URL = REPO.appendingPathComponent("reference")

func readFileBytes(_ url: URL) -> [UInt8]? { (try? Data(contentsOf: url)).map { [UInt8]($0) } }

/** Kernel environment for unit tests: runtime files from shared/, optional fs (port of TestEnv.kt). */
final class TestEnv: KernelEnv {
    let fs: VirtualFs?
    var sounds: [Double] = []
    /** (kernel time in ms, frequency) of every tone change, for timing checks. */
    var soundLog: [(Int64, Double)] = []
    /** Memory limit in MiB instead of the default (TEMPLEOS_MEMMB or 32). */
    var memMB: Int?
    /** A test-controlled clock instead of the monotonic one. */
    var fakeClock: Int64?
    init(_ fs: VirtualFs? = nil) { self.fs = fs }
    func nanoTime() -> Int64 { fakeClock ?? monoNanos() }
    func runtimeFile(_ name: String) -> [UInt8]? { readFileBytes(SHARED.appendingPathComponent("runtime/\(name)")) }
    /** The atNs of every tone change (KernelEnv.sound), in order. */
    var soundStamps: [Int64] = []
    /** Kernel time (Kernel.now, ns; virtual in virtual-time tests) of every tone change. */
    var soundNowNs: [Int64] = []
    func sound(_ kernel: Kernel, _ freq: Double, _ atNs: Int64) { sounds.append(freq); soundLog.append((kernel.now() / 1_000_000, freq)); soundStamps.append(atNs); soundNowNs.append(kernel.now()) }
    func entropy() -> Int64 { 12345 }
    var memoryLimit: Int { (memMB ?? Int(ProcessInfo.processInfo.environment["TEMPLEOS_MEMMB"] ?? "") ?? 32) << 20 }
    /** Headless popups pick the first (non-cancel) item. */
    func popupRequested(_ kernel: Kernel, _ req: PopupRequest) { req.result = req.items.first(where: { $0.value != -1 })?.value ?? -1 }
}

/** Read-only view of a host directory as the C: drive (port of HostDirFs in CensusTest.kt). */
final class HostDirFs: VirtualFs {
    private let root: URL
    init(_ root: URL) { self.root = root }
    private func f(_ p: String) -> URL {
        var r = p
        if r.hasPrefix("C:/") { r = String(r.dropFirst(3)) } else if r.hasPrefix("C:") { r = String(r.dropFirst(2)) }
        return root.appendingPathComponent(r)
    }
    private func isDirURL(_ u: URL) -> Bool { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: u.path, isDirectory: &d) && d.boolValue }
    func readFile(_ path: String) -> [UInt8]? { let u = f(path); return isDirURL(u) ? nil : readFileBytes(u) }
    func writeFile(_ path: String, _ data: [UInt8]) throws { throw FsError("read-only") }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: f(path).path) }
    func isDir(_ path: String) -> Bool { isDirURL(f(path)) }
    func list(_ dir: String) -> [FsEntry]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: f(dir).path) else { return nil }
        return names.map { n in
            let u = f(dir).appendingPathComponent(n)
            let a = try? FileManager.default.attributesOfItem(atPath: u.path)
            return FsEntry(n, "\(dir)/\(n)".replacingOccurrences(of: "//", with: "/"), isDirURL(u), (a?[.size] as? NSNumber)?.int64Value ?? 0, 0, true)
        }
    }
    func stat(_ path: String) -> FsEntry? {
        let u = f(path)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        let a = try? FileManager.default.attributesOfItem(atPath: u.path)
        return FsEntry(u.lastPathComponent, path, isDirURL(u), (a?[.size] as? NSNumber)?.int64Value ?? 0, 0, true)
    }
    func mkdir(_ path: String) throws { throw FsError("read-only") }
    func delete(_ path: String, recursive: Bool) throws { throw FsError("read-only") }
    func move(_ from: String, _ to: String) throws { throw FsError("read-only") }
    func isReadOnly(_ path: String) -> Bool { true }
}

/** Boots a kernel, runs [src] to completion in virtual time, returns the kernel (port of runHolyC). */
func runHolyC(_ src: [UInt8], _ name: String = "C:/Home/Test.HC", env: TestEnv = TestEnv(), maxSteps: Int = 100000, setup: (Kernel) throws -> Void = { _ in }) throws -> Kernel {
    let k = Kernel(env, "test")
    k.virtualTime = true
    try k.boot()
    try setup(k)
    try k.runProgram(name, src)
    var steps = 0
    let deadline = monoNanos() + 20_000_000_000
    while steps < maxSteps && monoNanos() < deadline {
        steps += 1
        let r = try k.step(50_000_000)
        if r < 0 { break }
    }
    if !k.finished { print("runHolyC: not finished after \(steps) steps; vtime=\(k.now() / 1_000_000)ms") }
    return k
}

/** Writes an indexed 640x480-style buffer as PNG (CoreGraphics + ImageIO, macOS). */
func writePNG(_ idx: UnsafePointer<UInt8>, _ w: Int, _ h: Int, _ palette: [Int32], to url: URL) {
    var rgba = [UInt8](repeating: 255, count: w * h * 4)
    for i in 0..<(w * h) {
        let c = UInt32(bitPattern: palette[Int(idx[i] & 15)])
        rgba[i * 4] = UInt8((c >> 16) & 0xFF); rgba[i * 4 + 1] = UInt8((c >> 8) & 0xFF); rgba[i * 4 + 2] = UInt8(c & 0xFF)
    }
    let data = Data(rgba) as CFData
    guard let provider = CGDataProvider(data: data),
          let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
                            shouldInterpolate: false, intent: .defaultIntent),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

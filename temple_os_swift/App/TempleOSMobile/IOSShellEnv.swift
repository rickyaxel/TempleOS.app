import AVFoundation
import Foundation
import os
import TempleCore
import UIKit

/** The bundled C: drive, read from the app bundle ("bundled-fs/..."). */
final class BundleFolder: BundleSource {
    private let root: URL
    private let indexURL: URL
    init(root: URL, index: URL) { self.root = root; self.indexURL = index }
    func index() -> String { (try? String(contentsOf: indexURL, encoding: .utf8)) ?? "" }
    func open(_ rel: String) -> [UInt8]? {
        let url = root.appendingPathComponent(rel)
        // never read outside the bundled drive
        guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { return nil }
        return (try? Data(contentsOf: url)).map { [UInt8]($0) }
    }
}

/** Session state in Application Support, written atomically. */
final class FileStateStore: StateStore {
    private let url: URL
    init(url: URL) { self.url = url }
    func load() -> String? { try? String(contentsOf: url, encoding: .utf8) }
    func save(_ text: String) { try? text.write(to: url, atomically: true, encoding: .utf8) }
}

/**
 * The device side of TempleOS's PC speaker on iOS: an AVAudioSourceNode pulling samples from [PcSpeaker]
 * (TempleCore), which turns the kernel's time-stamped speaker settings into PCM
 * (docs/audio/TEMPLEOS_SOUND.md). The engine only runs while a program sounds: the first tone starts it and
 * [IDLE_STOP_S] of silence stops it. Session and engine work happens on a private serial queue, never on
 * the main thread. [tone] runs on kernel threads for every speaker change (Noise and Sweep make about a
 * thousand a second): it queues the setting and, when the engine is off, asks the queue to start it once.
 *
 * Session policy (owner decision, 2026-10-18): `.playback` with `.mixWithOthers`. TempleOS sound plays with
 * the Ring/Silent switch on silent, at the user's volume, through the current route, mixed with other
 * apps' audio (nothing is interrupted or ducked). There is no background audio mode: in the background iOS
 * suspends the app, and [suspend] has already stopped the engine.
 *
 * Debug builds, `-soundcapture`: the main mixer's output (what goes to the hardware) is written to
 * Documents/sound-capture.wav, with Documents/sound-capture.json (start latency, buffer, latency, route)
 * for tools/audio/analyze_capture.py.
 */
final class ToneGenerator {
    /** The rate the speaker renders at (the mixer converts if the route runs at another rate). */
    static let RATE = 48000
    /** Silence after which the engine stops (the next tone starts it again). */
    static let IDLE_STOP_S = 2.0
    /** Kernel wake-up jitter covered by the latency, on top of one I/O buffer. */
    static let JITTER_NS: Int64 = 10_000_000

    let speaker = PcSpeaker(ToneGenerator.RATE, 40_000_000)
    private let queue = DispatchQueue(label: "io.github.templeosmobile.speaker", qos: .userInitiated)
    /** on: the engine runs; queued: a start is on the queue (kernel threads read both on every tone). */
    private let state = OSAllocatedUnfairLock(initialState: (on: false, queued: false))
    // queue only
    private var engine: AVAudioEngine?
    private var running = false
    private var idleTimer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var engineObserver: NSObjectProtocol?
    /** When a start last failed (an active phone call refuses it): no retry for a second. */
    private var failedAt: Int64 = Int64.min / 2
    private let captureURL: URL?
    private let captureLock = NSLock()
    private var captureFile: AVAudioFile? // captureLock
    private var captureInfo: [String: Any] = [:]

    init(capture: Bool = false) {
        captureURL = capture ? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first : nil
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] n in
            let began = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
            self?.queue.async { self?.outputChanged(rebuild: false, restart: !began) }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.outputChanged(rebuild: true, restart: true) }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if let o = engineObserver { NotificationCenter.default.removeObserver(o) }
    }

    func tone(_ f: Double, at atNs: Int64) {
        speaker.post(atNs, f)
        guard f > 0 else { return }
        let start = state.withLock { s -> Bool in
            if s.on || s.queued { return false }
            s.queued = true; return true
        }
        if start { queue.async { self.start() } }
    }

    /** The app is going to the background: stop at once (no idle wait). */
    func suspend() { queue.async { self.stop(deactivate: true) } }

    func release() { queue.sync { self.stop(deactivate: true) } }

    private func start() {
        state.withLock { $0.queued = false }
        let t0 = monoNanos()
        if running || t0 - failedAt < 1_000_000_000 { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
        } catch {
            NSLog("TempleOS speaker: audio session: %@", "\(error)")
        }
        let e = engine ?? makeEngine()
        // one I/O buffer is rendered ahead of time; the jitter margin covers late kernel wake-ups
        speaker.latencyNs = Int64(session.ioBufferDuration * 1e9) + ToneGenerator.JITTER_NS
        if captureURL != nil { startCapture(e) }
        do { try e.start() } catch {
            NSLog("TempleOS speaker: engine start: %@", "\(error)")
            failedAt = monoNanos()
            return
        }
        running = true
        state.withLock { $0.on = true }
        if captureURL != nil {
            captureInfo = ["start_ms": Double(monoNanos() - t0) / 1e6, "io_buffer_ms": session.ioBufferDuration * 1000,
                           "hw_rate": session.sampleRate, "latency_ms": Double(speaker.latencyNs) / 1e6,
                           "route": session.currentRoute.outputs.map { $0.portType.rawValue }, "category": session.category.rawValue,
                           "output_volume": session.outputVolume]
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            if self.speaker.idle(after: Int64(ToneGenerator.IDLE_STOP_S * Double(ToneGenerator.RATE))) { self.stop(deactivate: true) }
        }
        idleTimer?.cancel(); idleTimer = timer
        timer.resume()
    }

    private func makeEngine() -> AVAudioEngine {
        let e = AVAudioEngine()
        let sp = speaker // the render block holds the speaker only (no cycle through the engine)
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(ToneGenerator.RATE), channels: 1)!
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, abl -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            guard let out = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            sp.render(out, Int(frameCount), nowNs: monoNanos())
            return noErr
        }
        e.attach(node)
        e.connect(node, to: e.mainMixerNode, format: format)
        if let o = engineObserver { NotificationCenter.default.removeObserver(o) }
        engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: e, queue: nil) { [weak self] _ in
            // route or format change: the engine stopped itself
            self?.queue.async { self?.outputChanged(rebuild: false, restart: true) }
        }
        engine = e
        return e
    }

    /** The system stopped or replaced the output: a new timeline, and the tone back if one is set. */
    private func outputChanged(rebuild: Bool, restart: Bool) {
        let wanted = running && speaker.currentHz > 0
        idleTimer?.cancel(); idleTimer = nil
        if rebuild { engine = nil } else { engine?.stop() }
        running = false
        state.withLock { $0.on = false }
        speaker.restart()
        if restart && (wanted || speaker.pendingSound) { start() }
    }

    private func stop(deactivate: Bool) {
        idleTimer?.cancel(); idleTimer = nil
        guard running else { return }
        engine?.stop()
        running = false
        state.withLock { $0.on = false }
        speaker.restart()
        if captureURL != nil { finishCapture() }
        if deactivate { try? AVAudioSession.sharedInstance().setActive(false) }
    }

    private func startCapture(_ e: AVAudioEngine) {
        guard let url = captureURL?.appendingPathComponent("sound-capture.wav") else { return }
        captureLock.lock(); captureFile = nil; captureLock.unlock()
        e.mainMixerNode.removeTap(onBus: 0)
        // the mixer's format is only settled once the engine runs: the file takes the first buffer's
        e.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buf, _ in
            guard let self = self else { return }
            self.captureLock.lock()
            if self.captureFile == nil {
                self.captureFile = try? AVAudioFile(forWriting: url, settings: buf.format.settings,
                                                    commonFormat: buf.format.commonFormat, interleaved: buf.format.isInterleaved)
            }
            try? self.captureFile?.write(from: buf)
            self.captureLock.unlock()
        }
    }

    private func finishCapture() {
        engine?.mainMixerNode.removeTap(onBus: 0)
        captureLock.lock(); captureFile = nil; captureLock.unlock() // closes the file
        guard let dir = captureURL, let data = try? JSONSerialization.data(withJSONObject: captureInfo, options: [.prettyPrinted]) else { return }
        try? data.write(to: dir.appendingPathComponent("sound-capture.json"))
    }
}

/**
 * The platform text engine for UI text the TempleOS font cannot show (Surface.TextRun): the
 * system font with full fallback (CJK, Arabic, Indic, Ethiopic...), 10 logical px high. The
 * same attributes measure (IOSShellEnv.measureText) and draw (TempleView's text-run layer).
 */
enum TextRunFont {
    static func attributes(size: CGFloat, color: UIColor = .white) -> [NSAttributedString.Key: Any] {
        [.font: UIFont.boldSystemFont(ofSize: size), .foregroundColor: color]
    }

    /**
     * A run laid out by Core Text (shaping, bidi, font fallback as UIKit text) at its fitted size: the line, its
     * width and ascent/descent, and its glyph ink, all in points from the baseline (downwards positive).
     */
    final class Fit {
        let line: CTLine, size: CGFloat, width: CGFloat, ascent: CGFloat, descent: CGFloat, inkTop: CGFloat, inkBottom: CGFloat
        init(_ text: String, _ size: CGFloat, _ color: UIColor) {
            var a = attributes(size: size, color: color)
            a[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = color.cgColor
            line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: a))
            var asc: CGFloat = 0, desc: CGFloat = 0, lead: CGFloat = 0
            width = CGFloat(CTLineGetTypographicBounds(line, &asc, &desc, &lead))
            let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds) // y up from the baseline
            self.size = size; ascent = asc; descent = desc; inkTop = -ink.maxY; inkBottom = -ink.minY
        }
    }

    private static var fits: [String: Fit] = [:]

    /**
     * [text] at [size], or, when the script's marks reach further than [maxInk] points (Burmese, Thai, stacked
     * Vietnamese, Devanagari), just small enough that its ink fits. Cached by text, sizes and colour (layer drawing
     * runs on the main thread only).
     */
    static func fit(_ text: String, size: CGFloat, maxInk: CGFloat, color: UIColor) -> Fit {
        let key = "\(size)|\(maxInk)|\(color.hash)|\(text)"
        if let f = fits[key] { return f }
        var f = Fit(text, size, color)
        let h = f.inkBottom - f.inkTop
        if h > maxInk && h > 0 { f = Fit(text, size * maxInk / h, color) }
        if fits.count >= 512 { fits.removeAll() }
        fits[key] = f
        return f
    }
}

final class IOSShellEnv: ShellEnv {
    let fs: LayeredFs
    let stateStore: StateStore
    let sound: ToneGenerator
    var renderHandler: () -> Void = {}
    private var runtimeCache: [String: [UInt8]] = [:]
    private let cacheLock = NSLock()
    private let resources: URL

    init() {
        resources = Bundle.main.resourceURL!
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TempleOSMobile", isDirectory: true)
        #if DEBUG
        // UI tests start from a fresh install state (debug builds only).
        if ProcessInfo.processInfo.arguments.contains("-uitest-reset") { try? FileManager.default.removeItem(at: support) }
        #endif
        #if DEBUG
        // sound checks: -soundcapture records the speaker (tools/audio/analyze_capture.py)
        sound = ToneGenerator(capture: ProcessInfo.processInfo.arguments.contains("-soundcapture"))
        #else
        sound = ToneGenerator()
        #endif
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        // Application Support is backed up by default; the user's drive stays on this device only.
        var noBackup = URLResourceValues(); noBackup.isExcludedFromBackup = true
        var supportURL = support; try? supportURL.setResourceValues(noBackup)
        fs = LayeredFs(BundleFolder(root: resources.appendingPathComponent("bundled-fs"), index: resources.appendingPathComponent("bundled-fs.index")),
                       support.appendingPathComponent("drive", isDirectory: true))
        stateStore = FileStateStore(url: support.appendingPathComponent("session.txt"))
    }

    func runtimeFile(_ name: String) -> [UInt8]? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let c = runtimeCache[name] { return c }
        let url = name == "catalog.json" ? resources.appendingPathComponent(name) : resources.appendingPathComponent("runtime").appendingPathComponent(name)
        guard let d = try? Data(contentsOf: url) else { return nil }
        let b = [UInt8](d)
        // language catalogs are parsed once by L10n; keeping their bytes would hold every language visited
        if !name.hasPrefix("l10n/") { runtimeCache[name] = b }
        return b
    }

    /** The app's languages, most preferred first: includes the per-app language from iOS Settings. */
    func preferredLanguages() -> [String] { Locale.preferredLanguages }

    func deviceRegion() -> String? {
        if #available(iOS 16, *) { return Locale.current.region?.identifier }
        return Locale.current.regionCode
    }

    func measureText(_ s: String) -> Int {
        Int((s as NSString).size(withAttributes: TextRunFont.attributes(size: 10)).width.rounded(.up))
    }

    func tone(_ freq: Double, at atNs: Int64) { sound.tone(freq, at: atNs) }
    /** Apple's minimum touch target (Human Interface Guidelines): 44 pt. */
    var touchTargetDp: Double { 44.0 }
    /** UITouch.timestamp uses system uptime; keyboard/gesture timers must use the same clock. */
    func nowMs() -> Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1000) }

    func clipboardGet() -> String? { UIPasteboard.general.string }
    func clipboardSet(_ s: String) { UIPasteboard.general.string = s }
    func openPrivacyPolicy() {
        guard let url = URL(string: Brand.privacyURL) else { return }
        UIApplication.shared.open(url)
    }
    func requestRender() { renderHandler() }
    /**
     * Each program gets its own HolyC heap; larger on devices with more memory (TempleOS has no
     * per-program limit: Talons keeps about 65 MB, so it needs the 96 MiB class).
     */
    /**
     * Program memory per program (AndroidShellEnv.memoryLimitBytes): Talons needs 65-67 MiB (docs/native-validation).
     * physicalMemory reports less than the marketed size (a 4 GB iPhone about 3.7 GiB), hence the margins.
     */
    var memoryLimitBytes: Int {
        let mb = ProcessInfo.processInfo.physicalMemory >> 20
        return mb >= 3500 ? 96 << 20 : mb >= 2600 ? 72 << 20 : 32 << 20
    }
}

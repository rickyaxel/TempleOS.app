import TempleCore
import PureSwift
import UIKit

/**
 * TempleOS Mobile Classic for iOS. One window hosting one Shell (the TempleOS
 * Mobile desktop). Fully offline: no network code, no accounts, no analytics,
 * and no way to import programs from outside the app.
 */
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let c = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        c.delegateClass = SceneDelegate.self
        return c
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var controller: TempleViewController?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: ws)
        w.backgroundColor = .black // the launch screen's color until the first frame (then SystemChrome)
        #if TEMPLEOS_BENCH
        // device validation (bench builds only): headless deterministic benchmark, no shell, no saved state
        if let spec = BenchMode.spec() {
            w.rootViewController = BenchViewController(spec: spec)
            w.makeKeyAndVisible()
            window = w
            return
        }
        #endif
        let vc = TempleViewController()
        w.rootViewController = vc
        w.makeKeyAndVisible()
        window = w
        controller = vc
    }

    func sceneWillEnterForeground(_ scene: UIScene) { controller?.enterForeground() }
    func sceneWillResignActive(_ scene: UIScene) { controller?.releaseInput() }
    func sceneDidBecomeActive(_ scene: UIScene) { controller?.enterForeground() }
    func sceneDidEnterBackground(_ scene: UIScene) { controller?.enterBackground() }
    func sceneDidDisconnect(_ scene: UIScene) { controller?.shutdown() }
}

final class TempleViewController: UIViewController {
    private let env = IOSShellEnv()
    // awaitingRestore until onFirstLayout has read the saved session (Shell.awaitingRestore)
    private lazy var shell: Shell = { let s = Shell(env); s.awaitingRestore = true; return s }()
    private var templeView: TempleView!

    override func loadView() {
        // Pure Swift mode: the bundled programs' ahead-of-time Swift translations (Settings > Engine)
        NativePrograms.catalog = NativeCatalog.source
        // benchmarks: launch with -perflog (one perf line per second; UI tests read it from the view)
        if ProcessInfo.processInfo.arguments.contains("-perflog") { Shell.perfLog = true }
        let v = TempleView(shell: shell)
        templeView = v
        env.renderHandler = { [weak v] in v?.kick() }
        v.onFirstLayout = { [unowned self] in
            shell.restoreSession()
            // benchmarks: launch with -engine native|terry to select the engine (Settings > Engine) for automated runs
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-engine"), i + 1 < args.count {
                shell.settings.engine = args[i + 1] == "native" ? Settings.ENGINE_NATIVE : Settings.ENGINE_TERRY
            }
            // An empty session shows the exact four-line intro until MENU is used.
            templeView.relayout() // settings (display scale) may have changed
        }
        view = v
        v.onStep = { [weak self] in
            guard let self else { return }
            self.immersive = self.shell.systemChrome.defersEdgeGestures
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(localeChanged(_:)), name: NSLocale.currentLocaleDidChangeNotification, object: nil)
    }

    /** Device language or region changed while running: re-resolve, keep every window. */
    @objc private func localeChanged(_ n: Notification) {
        DispatchQueue.main.async { self.shell.applyLanguage(); self.templeView.kick() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        templeView.resume()
    }

    override var prefersStatusBarHidden: Bool { false }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    // Only while the focused app asks for it (SystemChrome.defersEdgeGestures: a program window,
    // whose on-screen controls sit near the bottom edge). The desktop, editor and terminal leave the
    // home gesture and indicator alone. The region under the indicator is painted by the shell in the
    // color of the surface that owns the bottom edge; iOS adapts the indicator's own color to it.
    private var immersive = false {
        didSet {
            if immersive == oldValue { return }
            setNeedsUpdateOfHomeIndicatorAutoHidden()
            setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        }
    }
    override var prefersHomeIndicatorAutoHidden: Bool { immersive }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { immersive ? .bottom : [] }
    override var canBecomeFirstResponder: Bool { true }

    // Hardware keys while the soft keyboard is not active (the view is not first responder).
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !templeView.handlePresses(presses, down: true) { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !templeView.handlePresses(presses, down: false) { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !templeView.handlePresses(presses, down: false) { super.pressesCancelled(presses, with: event) }
    }

    func releaseInput() { templeView?.releasePhysicalKeys(); shell.suspendInput() }
    func enterForeground() { shell.onForeground(); templeView.resume() }
    func enterBackground() { templeView.releasePhysicalKeys(); shell.onBackground(); templeView.pause(); env.sound.suspend() }

    func shutdown() {
        shell.onBackground()
        // Stop every HolyC program thread; the session was just saved.
        for w in shell.windows { w.app.close() }
        env.sound.release()
    }
}

import OSLog
import TempleCore
import UIKit

/**
 * No text-input adapter exists: TempleView is a plain UIView, not a UIKit text-entry client.
 * These observers diagnose violations, including transient presentations. They never dismiss a
 * keyboard or use its frame to lay out the app, and never capture typed text.
 */
final class NativeKeyboardDiagnostics {
    private var tokens: [NSObjectProtocol] = []
    private(set) var violations = 0
    var context: () -> String = { "unbound" }
    var changed: (() -> Void)?

    init() {
        for name in [UIResponder.keyboardWillShowNotification, UIResponder.keyboardDidShowNotification,
                     UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, UIApplication.shared.applicationState != .background else { return }
                if let local = note.userInfo?[UIResponder.keyboardIsLocalUserInfoKey] as? Bool, !local { return }
                // Offscreen/zero-height frames are dismissal or hardware accessory updates, not software input.
                if name == UIResponder.keyboardWillChangeFrameNotification || name == UIResponder.keyboardDidChangeFrameNotification {
                    guard let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
                          frame.height > 1,
                          UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                            .flatMap(\.windows).contains(where: { !$0.isHidden && $0.convert($0.bounds, to: nil).intersects(frame) }) else { return }
                }
                self.violations += 1
                inputLog.fault("Native software keyboard invariant violated: event=\(name.rawValue, privacy: .public) state=\(UIApplication.shared.applicationState.rawValue) \(self.context(), privacy: .public)")
                self.changed?()
            })
        }
    }

    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}

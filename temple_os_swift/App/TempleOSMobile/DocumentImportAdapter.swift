import TempleCore
import UIKit
import UniformTypeIdentifiers

/**
 * Start menu > Import... on iOS: the system document picker (Files: On My iPhone/iPad, iCloud Drive and other
 * providers). It runs with asCopy: the system downloads a cloud document if needed and copies each chosen document
 * into this app's temporary folder, so the import never reads or keeps the provider's original, needs no
 * permission, entitlement or document type, and no security-scoped access outlives the call. Any data file can be
 * chosen (UTType.data): .HC and .HC.Z have no system type, and TempleCore's FileImport decides by name and checks
 * the contents itself. The copies are handed to the shell's ImportFlow off the main thread; FileImport deletes them.
 */
final class DocumentImportAdapter: NSObject, UIDocumentPickerDelegate {
    private weak var presenter: UIViewController?
    private let deliver: ([PickedFile]) -> Void
    private let dismissed: () -> Void
    private var open = false

    /** [deliver] receives the copies (none when cancelled), from a background queue; [dismissed] runs on the main thread. */
    init(presenter: UIViewController, deliver: @escaping ([PickedFile]) -> Void, dismissed: @escaping () -> Void) {
        self.presenter = presenter; self.deliver = deliver; self.dismissed = dismissed
    }

    /** Presents the picker (main thread). False when it cannot be shown now (one is already open). */
    func present() -> Bool {
        guard !open, let vc = presenter, vc.presentedViewController == nil else { return false }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        picker.delegate = self
        open = true
        vc.present(picker, animated: true)
        return true
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        open = false
        dismissed()
        let deliver = self.deliver
        DispatchQueue.global(qos: .userInitiated).async { deliver(urls.map(DocumentImportAdapter.adopt)) }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        open = false
        dismissed()
        deliver([])
    }

    /** One copy from the picker, by the name the provider shows (FileImport normalizes it to NFC). */
    private static func adopt(_ url: URL) -> PickedFile {
        // a copy in this app's container needs no scope; asking is harmless and covers providers that hand one out
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        guard (try? url.checkResourceIsReachable()) == true else {
            return PickedFile(name: name, hostPath: nil, problem: ImportError("import.error.read"))
        }
        return PickedFile(name: name, hostPath: url.path)
    }
}

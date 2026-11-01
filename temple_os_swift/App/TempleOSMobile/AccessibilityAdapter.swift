import TempleCore
import UIKit

/**
 * Platform adapter: the shell's accessibility nodes ([A11yNode]) as VoiceOver elements of the
 * single TempleView. Activating an element taps its center, so VoiceOver users drive exactly
 * the same UI as touch users. Changes in iOS accessibility APIs belong in this file.
 */
final class AccessibilityAdapter {
    /** One shell node as a VoiceOver element. */
    private final class NodeElement: UIAccessibilityElement {
        let node: A11yNode
        weak var owner: TempleView?
        init(_ node: A11yNode, owner: TempleView) { self.node = node; self.owner = owner; super.init(accessibilityContainer: owner) }
        override func accessibilityActivate() -> Bool {
            guard let o = owner, node.button else { return false }
            o.shell.accessibilityActivate(node); o.kick()
            return true
        }
    }

    private unowned let view: TempleView
    private var nodeElements: [NodeElement] = []
    private var version: Int64 = -1

    init(_ view: TempleView) { self.view = view }

    var elements: [Any] { nodeElements }

    private func same(_ a: [A11yNode]) -> Bool {
        a.count == nodeElements.count && zip(a, nodeElements).allSatisfy { x, e in
            let y = e.node
            return x.label == y.label && x.selected == y.selected && x.rect.x == y.rect.x && x.rect.y == y.rect.y && x.rect.w == y.rect.w && x.rect.h == y.rect.h
        }
    }

    /** Rebuilds the elements when what is on screen changed; tells VoiceOver about real changes only. */
    func sync() {
        let shell = view.shell
        if shell.a11yVersion == version { return }
        version = shell.a11yVersion
        let nodes = shell.accessibilityNodes()
        if same(nodes) { return }
        let k = view.pointsPerLogical
        nodeElements = nodes.map { n in
            let e = NodeElement(n, owner: view)
            e.accessibilityLabel = n.label
            // VoiceOver speaks the UI language even when it differs from the system's
            e.accessibilityLanguage = L10n.locale?.id
            var traits: UIAccessibilityTraits = n.button ? .button : .staticText
            if n.selected { traits.insert(.selected) }
            e.accessibilityTraits = traits
            e.accessibilityFrameInContainerSpace = CGRect(x: CGFloat(n.rect.x) * k, y: CGFloat(n.rect.y) * k, width: CGFloat(n.rect.w) * k, height: CGFloat(n.rect.h) * k)
            return e
        }
        if UIAccessibility.isVoiceOverRunning { UIAccessibility.post(notification: .layoutChanged, argument: nil) }
    }
}

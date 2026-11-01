import TempleCore
import UIKit

/**
 * Platform adapter: measures the screen area of one view (TempleView) as the shell's DisplayGeometry,
 * in logical px (docs/foldable/IPHONE_DUO_ADAPTATION.md). Everything comes from the view itself — its
 * bounds, its trait collection's display scale, its safe area, its reserved regions — never from the
 * device or the main screen, so a window in split view, an unfolded or folded display and a rotation
 * all describe the space the app really has. Changes in iOS geometry APIs belong in this file.
 */
enum DisplayContextAdapter {
    /** The view's geometry at [scale] device px per logical px, with the device keyboard [keyboardPt] high. */
    @MainActor
    static func measure(_ v: UIView, scale: Int, displayScale px: CGFloat, keyboardPt: CGFloat) -> DisplayGeometry {
        let k = px / CGFloat(scale) // logical px per point
        func up(_ p: CGFloat) -> Int { Int((p * k).rounded(.up)) }
        let ins = v.safeAreaInsets
        var g = DisplayGeometry(width: Int(v.bounds.width * px) / scale, height: Int(v.bounds.height * px) / scale,
                                top: up(ins.top), bottom: up(ins.bottom), left: up(ins.left), right: up(ins.right),
                                keyboard: 0, dpPerPx: Double(scale) / Double(px))
        // The top bar sits right under the safe area's top. Where no status bar runs across the top (a
        // foldable's status-bar column at a side), that is the screen's very top edge, inside its rounded
        // corners: then its ends follow the safe area adapted to the corners, as iOS reports it.
        if #available(iOS 26.0, *) {
            let vertical = v.edgeInsets(for: .safeArea(cornerAdaptation: .vertical))
            if vertical.top > ins.top + 0.5 {
                let horizontal = v.edgeInsets(for: .safeArea(cornerAdaptation: .horizontal))
                g.barLeft = up(max(ins.left, horizontal.left)); g.barRight = up(max(ins.right, horizontal.right))
            }
        }
        // Reserved regions (iOS 27.1): a partly folded hinge divides the view; a camera housing or a
        // status-bar block occludes part of it. Only active regions shape the layout.
        if #available(iOS 27.1, *) {
            func logical(_ r: CGRect) -> Rect? {
                let c = r.intersection(v.bounds)
                if c.isNull || c.isEmpty { return nil }
                let x0 = Int((c.minX * k).rounded(.down)), y0 = Int((c.minY * k).rounded(.down))
                let x1 = Int((c.maxX * k).rounded(.up)), y1 = Int((c.maxY * k).rounded(.up))
                return Rect(x0, y0, x1 - x0, y1 - y0)
            }
            g.divisions = v.reservedRegions(kind: .division).filter(\.isActive).compactMap { logical($0.frame) }
            g.occlusions = v.reservedRegions(kind: .occlusion).filter(\.isActive).compactMap { logical($0.frame) }
        }
        return g
    }

    /**
     * Asks [v] to lay out again whenever the hinge changes state (iOS 27.1): the division regions follow the
     * fold, and the layout is rebuilt from them (the hinge angle itself drives nothing).
     */
    @MainActor
    static func observeHinge(_ v: UIView) {
        if #available(iOS 27.1, *) {
            v.addInteraction(UIHingeInteraction { [weak v] _, _ in v?.setNeedsLayout() })
        }
    }

    /** "x,y,w,h|..." for the UI tests (TempleView's accessibility value). */
    static func list(_ rects: [Rect]) -> String { rects.map { "\($0.x),\($0.y),\($0.w),\($0.h)" }.joined(separator: "|") }
}

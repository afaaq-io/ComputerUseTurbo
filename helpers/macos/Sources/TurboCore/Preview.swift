import CoreGraphics
import Foundation

// Live preview panel: a small floating picture-in-picture of the
// window the agent is working on, hanging inside the top-right corner of the window of the
// app the agent runs in (its host, detected at runtime). Pure parts: settings, geometry (anchoring, clamping, the user's
// drag offset), the pointer's position inside the image, status texts. All rectangles
// are global top-left points (AX / CGWindowList space) unless noted.

/// `settings.json` `"preview": {"enabled": true, "offsetX": 0, "offsetY": 0, "collapsed": false}`.
public struct PreviewSettings: Equatable, Sendable {
    /// Show the panel automatically when a session starts acting.
    public var enabled: Bool
    /// The user's drag offset from the default anchor (points; +x right, +y down).
    public var offsetX: Double
    public var offsetY: Double
    /// Shrunk to the small pill (app name only, no capture).
    public var collapsed: Bool

    public init(enabled: Bool = true, offsetX: Double = 0, offsetY: Double = 0, collapsed: Bool = false) {
        self.enabled = enabled
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.collapsed = collapsed
    }

    public static let defaults = PreviewSettings()
    /// Offsets are clamped to this many points either way.
    public static let maxOffset: Double = 4000

    public static func parse(_ data: Data?) -> PreviewSettings {
        var s = defaults
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let o = root["preview"] as? [String: Any]
        else { return s }
        if let b = o["enabled"] as? Bool { s.enabled = b }
        if let b = o["collapsed"] as? Bool { s.collapsed = b }
        func num(_ k: String) -> Double? {
            guard let n = o[k] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
            return min(maxOffset, max(-maxOffset, n.doubleValue))
        }
        if let x = num("offsetX") { s.offsetX = x }
        if let y = num("offsetY") { s.offsetY = y }
        return s
    }

    public static func load(_ url: URL) -> PreviewSettings { parse(try? Data(contentsOf: url)) }

    /// `settings.json` contents with this object's `preview` values merged in; every
    /// other key (pointer, hover, typing, …) is kept as it was. Malformed / missing input
    /// starts from an empty object.
    public func merged(into data: Data?) -> Data {
        var root: [String: Any] = [:]
        if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { root = obj }
        var p = root["preview"] as? [String: Any] ?? [:]
        p["enabled"] = enabled
        p["offsetX"] = (offsetX * 10).rounded() / 10
        p["offsetY"] = (offsetY * 10).rounded() / 10
        p["collapsed"] = collapsed
        root["preview"] = p
        return (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    }
}

public enum PreviewGeometry {
    /// Inset from the anchor window's right edge.
    public static let rightMargin: CGFloat = 16
    /// Below the anchor window's top edge (clears its title bar / toolbar).
    public static let topMargin: CGFloat = 56
    /// Inset from the screen edges when there is no anchor window.
    public static let screenMargin: CGFloat = 16
    public static let defaultWidth: CGFloat = 320
    public static let maxWidth: CGFloat = 360
    /// No header: the panel is the live image only (the user asked for no status / Stop).
    public static let headerHeight: CGFloat = 0
    /// Frames per second while visible and expanded (the pointer is animated separately,
    /// at display refresh).
    public static let framesPerSecond: Double = 5
    public static let minImageHeight: CGFloat = 120
    public static let maxImageHeight: CGFloat = 240
    /// The collapsed pill.
    public static let collapsedSize = CGSize(width: 190, height: 32)
    public static let cornerRadius: CGFloat = 12

    /// Panel size for a target window of `aspect` (width / height; nil = unknown, 16:10):
    /// 320 pt wide (never more than 360), image height from the aspect ratio clamped to
    /// 120…240 pt (a very tall window is letterboxed), plus the header.
    public static func panelSize(aspect: Double?, collapsed: Bool) -> CGSize {
        if collapsed { return collapsedSize }
        let width = min(maxWidth, defaultWidth)
        let a = (aspect.flatMap { $0.isFinite && $0 > 0.05 ? $0 : nil }) ?? 1.6
        let imageHeight = min(maxImageHeight, max(minImageHeight, (width / CGFloat(a)).rounded()))
        return CGSize(width: width, height: imageHeight + headerHeight)
    }

    /// Default top-left corner (before the user's offset): inside `anchor`'s top-right
    /// corner, or the top-right of `screen` (its visible frame) when there is no anchor.
    public static func defaultOrigin(size: CGSize, anchor: CGRect?, screen: CGRect) -> CGPoint {
        if let a = anchor {
            return CGPoint(x: a.maxX - rightMargin - size.width, y: a.minY + topMargin)
        }
        return CGPoint(x: screen.maxX - screenMargin - size.width, y: screen.minY + screenMargin)
    }

    /// The panel frame: default origin + offset, then kept fully on `screen` (the visible
    /// frame of the display it is on).
    public static func frame(size: CGSize, anchor: CGRect?, screen: CGRect, offset: CGPoint) -> CGRect {
        let o = defaultOrigin(size: size, anchor: anchor, screen: screen)
        return clamp(CGRect(x: o.x + offset.x, y: o.y + offset.y, width: size.width, height: size.height), to: screen)
    }

    /// `rect` moved (not resized) so it lies inside `screen` (top-left wins if too big).
    public static func clamp(_ rect: CGRect, to screen: CGRect) -> CGRect {
        guard screen.width > 0, screen.height > 0 else { return rect }
        var x = rect.minX
        var y = rect.minY
        if x + rect.width > screen.maxX { x = screen.maxX - rect.width }
        if x < screen.minX { x = screen.minX }
        if y + rect.height > screen.maxY { y = screen.maxY - rect.height }
        if y < screen.minY { y = screen.minY }
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    /// The offset to remember after the user dragged the panel to `frame`.
    public static func offset(afterDragTo frame: CGRect, anchor: CGRect?, screen: CGRect) -> CGPoint {
        let o = defaultOrigin(size: frame.size, anchor: anchor, screen: screen)
        let clampValue = { (v: CGFloat) in min(CGFloat(PreviewSettings.maxOffset), max(-CGFloat(PreviewSettings.maxOffset), v)) }
        return CGPoint(x: clampValue(frame.minX - o.x), y: clampValue(frame.minY - o.y))
    }

    /// Where an image of `size` is drawn inside `box` (aspect fit, centred).
    public static func fit(imageSize: CGSize, in box: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, box.width > 0, box.height > 0 else { return box }
        let scale = min(box.width / imageSize.width, box.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: box.minX + (box.width - w) / 2, y: box.minY + (box.height - h) / 2, width: w, height: h)
    }

    /// A global (top-left) screen point mapped into `rect`, the image of `window` drawn in a
    /// y-UP layer space (Core Animation's default on macOS): x scales left→right, y is
    /// flipped. Affine, so a quadratic Bézier maps to the Bézier of the mapped points (the
    /// preview arrow replays the on-screen glide exactly). Points outside the window map
    /// outside `rect` (the arrow is clipped there).
    public static func map(_ p: CGPoint, window: CGRect, into rect: CGRect) -> CGPoint {
        guard window.width > 0, window.height > 0 else { return CGPoint(x: rect.midX, y: rect.midY) }
        let fx = (p.x - window.minX) / window.width
        let fy = (p.y - window.minY) / window.height
        return CGPoint(x: rect.minX + fx * rect.width, y: rect.maxY - fy * rect.height)
    }

    /// Scale from screen points to preview points (for the press ring's size).
    public static func scale(window: CGRect, into rect: CGRect) -> CGFloat {
        guard window.width > 0 else { return 1 }
        return rect.width / window.width
    }

}

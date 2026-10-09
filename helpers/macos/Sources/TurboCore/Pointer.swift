import CoreGraphics
import Foundation

// Pure logic behind the agent's own on-screen pointer ("Soft arrow"):
// motion (quadratic Bézier + ease-in-out cubic), durations, the coordinate pipeline from
// the global top-left space used by AX / CGEvent to the pointer's y-up layers, the arrow
// outline and hotspot, pill labels, and the optional settings file. No AppKit here.

/// `<support>/settings.json` (optional): `{"pointer":{"enabled":true,"speed":1.0}}`.
public struct PointerSettings: Equatable, Sendable {
    /// Draw and animate the pointer. false skips it entirely (actions do not wait).
    public var enabled: Bool
    /// Movement speed multiplier (durations are divided by it), clamped to 0.25…4.
    public var speed: Double
    /// Debug only (`"debugCapturable": true`): let the pointer windows appear in screen
    /// captures (`screencapture`, recordings), for demo recordings. Off by default: the
    /// pointer is invisible to every capture (`sharingType = .none`).
    public var debugCapturable: Bool

    public static let defaults = PointerSettings(enabled: true, speed: 1.0, debugCapturable: false)
    public static let speedRange: ClosedRange<Double> = 0.25...4

    public init(enabled: Bool, speed: Double, debugCapturable: Bool = false) {
        self.enabled = enabled
        self.speed = speed
        self.debugCapturable = debugCapturable
    }

    /// Parse the settings file; anything missing, malformed or out of range falls back to
    /// the defaults (a broken file never disables safety features or crashes).
    public static func parse(_ data: Data?) -> PointerSettings {
        var s = defaults
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let pointer = root["pointer"] as? [String: Any]
        else { return s }
        if let enabled = pointer["enabled"] as? Bool { s.enabled = enabled }
        if let speed = (pointer["speed"] as? NSNumber)?.doubleValue, speed.isFinite, speed > 0 {
            s.speed = min(speedRange.upperBound, max(speedRange.lowerBound, speed))
        }
        if let capture = pointer["debugCapturable"] as? Bool { s.debugCapturable = capture }
        return s
    }

    public static func load(_ url: URL) -> PointerSettings {
        parse(try? Data(contentsOf: url))
    }
}

/// Look and timing constants of the "Soft arrow" pointer design.
public enum PointerStyle {
    /// Accent clay #D97757.
    public static let clay: (r: Double, g: Double, b: Double) = (0xD9 / 255.0, 0x77 / 255.0, 0x57 / 255.0)
    /// The arrow's box (y down, like the SVG it comes from).
    public static let arrowSize = CGSize(width: 22, height: 24)
    /// The tip, in the arrow's y-down box: the point that lands on the target.
    public static let arrowHotspot = CGPoint(x: 3.2, y: 2.6)
    public static let arrowStrokeWidth: CGFloat = 1.6
    /// The action pill's top-left corner relative to the tip (x right, y down).
    public static let pillOffset = CGPoint(x: 18, y: 20)
    public static let pillHeight: CGFloat = 20
    public static let pillPadding: CGFloat = 9
    public static let pillFontSize: CGFloat = 11
    public static let pillMaxLabel = 28
    public static let pillDuration: TimeInterval = 0.3

    public static let fadeInDuration: TimeInterval = 0.2
    public static let pressDuration: TimeInterval = 0.12
    public static let pressScale: CGFloat = 0.86
    public static let ringDuration: TimeInterval = 0.45
    public static let ringStartDiameter: CGFloat = 4
    public static let ringEndDiameter: CGFloat = 40
    public static let ringStartOpacity: Double = 0.8
    public static let idleDelay: TimeInterval = 2
    public static let idleOpacity: Double = 0.4
    /// Pill easing, CSS cubic-bezier(.2,.8,.2,1).
    public static let pillEasing: (Double, Double, Double, Double) = (0.2, 0.8, 0.2, 1)
    /// Ease-in-out cubic as a cubic Bézier timing function (for Core Animation).
    public static let glideEasing: (Double, Double, Double, Double) = (0.65, 0, 0.35, 1)
}

/// The "Soft arrow" outline, from the SVG path
/// `M3.2 2.6c0-1 1.1-1.5 1.9-.9l13.6 10.6c.8.6.4 1.9-.6 2l-5.6.6-3.1 5.8c-.5.9-1.8.7-2-.3z`
/// in a 22×24 y-down box, as absolute segments.
public enum SoftArrow {
    public enum Segment: Equatable, Sendable {
        case move(CGPoint)
        case line(CGPoint)
        case curve(CGPoint, CGPoint, CGPoint)  // control 1, control 2, end
        case close
    }

    public static let segments: [Segment] = [
        .move(CGPoint(x: 3.2, y: 2.6)),
        .curve(CGPoint(x: 3.2, y: 1.6), CGPoint(x: 4.3, y: 1.1), CGPoint(x: 5.1, y: 1.7)),
        .line(CGPoint(x: 18.7, y: 12.3)),
        .curve(CGPoint(x: 19.5, y: 12.9), CGPoint(x: 19.1, y: 14.2), CGPoint(x: 18.1, y: 14.3)),
        .line(CGPoint(x: 12.5, y: 14.9)),
        .line(CGPoint(x: 9.4, y: 20.7)),
        .curve(CGPoint(x: 8.9, y: 21.6), CGPoint(x: 7.6, y: 21.4), CGPoint(x: 7.4, y: 20.4)),
        .close,
    ]

    /// The segments in a y-UP box of the same size (Core Animation's default geometry
    /// on macOS): y' = height − y.
    public static func yUpSegments(height: CGFloat = PointerStyle.arrowSize.height) -> [Segment] {
        func f(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: height - p.y) }
        return segments.map {
            switch $0 {
            case .move(let p): return .move(f(p))
            case .line(let p): return .line(f(p))
            case .curve(let a, let b, let c): return .curve(f(a), f(b), f(c))
            case .close: return .close
            }
        }
    }
}

/// The coordinate pipeline from an action's global point to the pointer's layers
///. There is NO flipped geometry anywhere: AppKit owns the root layer
/// of a view and resets `geometryFlipped`, which once drew the pointer mirrored
/// (screenHeight − y). Everything is converted explicitly here, in y-up Cocoa terms.
public enum PointerGeometry {
    /// Position, in the y-up layer space of a panel that covers the screen whose Cocoa
    /// frame is `screen`, of the global top-left point `p` (AX / CGEvent coordinates).
    /// `primaryHeight` is the height of `NSScreen.screens[0]` (never `NSScreen.main`, never
    /// a visibleFrame).
    public static func layerPoint(global p: CGPoint, screen: CGRect, primaryHeight: CGFloat) -> CGPoint {
        let cocoa = ScreenGeometry.cocoaPoint(fromGlobal: p, primaryHeight: primaryHeight)
        return CGPoint(x: cocoa.x - screen.minX, y: cocoa.y - screen.minY)
    }

    /// Inverse of `layerPoint`.
    public static func globalPoint(layer p: CGPoint, screen: CGRect, primaryHeight: CGFloat) -> CGPoint {
        ScreenGeometry.globalPoint(
            fromCocoa: CGPoint(x: p.x + screen.minX, y: p.y + screen.minY), primaryHeight: primaryHeight)
    }

    /// `CALayer.anchorPoint` (unit coordinates, y up) that puts the arrow's tip on the
    /// layer's `position`.
    public static func arrowAnchor(
        hotspot: CGPoint = PointerStyle.arrowHotspot, size: CGSize = PointerStyle.arrowSize
    ) -> CGPoint {
        CGPoint(x: hotspot.x / size.width, y: (size.height - hotspot.y) / size.height)
    }

    /// The pill's anchor (its top-left corner) relative to the tip, in y-up layer terms.
    public static var pillTopLeftFromTip: CGPoint {
        CGPoint(x: PointerStyle.pillOffset.x, y: -PointerStyle.pillOffset.y)
    }
}

/// The text in the action pill.
public enum PointerLabel {
    /// At most `max` characters, with an ellipsis when cut; newlines become spaces.
    public static func truncate(_ s: String, max: Int = PointerStyle.pillMaxLabel) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard flat.count > max, max > 1 else { return flat }
        return String(flat.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    public static func moving(to target: String) -> String { truncate("Moving to \(target)") }
    public static func clicking(_ target: String) -> String { truncate("Clicking \(target)") }
    /// Shown while the real-pointer assist briefly uses the user's own mouse.
    public static let borrowingMouse = "Using your mouse briefly"
    public static func pressing(_ key: String) -> String { truncate("Pressing \(key)") }
    public static let typing = "Typing"
    public static let scrolling = "Scrolling"
    public static let dragging = "Dragging"
    public static let settingValue = "Setting value"
    public static let selecting = "Selecting text"
}

public enum PointerMotion {
    public static let baseDuration: TimeInterval = 0.38
    public static let perPointDuration: TimeInterval = 0.0015
    public static let maxDuration: TimeInterval = 1.1
    /// Largest perpendicular offset of the control point, as a fraction of the distance.
    public static let maxCurveFactor: CGFloat = 0.225

    /// Glide duration for a move of `distance` points: 380 ms + 1.5 ms/pt, divided by
    /// `speed`, capped at 1.1 s. A move shorter than half a point takes no time.
    public static func duration(distance: CGFloat, speed: Double = 1) -> TimeInterval {
        guard distance.isFinite, distance >= 0.5 else { return 0 }
        let s = speed.isFinite && speed > 0 ? speed : 1
        return min(maxDuration, (baseDuration + perPointDuration * Double(distance)) / s)
    }

    /// Ease-in-out cubic on 0…1 (clamped).
    public static func easeInOutCubic(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    /// Quadratic Bézier point B(t) = (1-t)²·p0 + 2(1-t)t·c + t²·p1.
    public static func quadratic(_ p0: CGPoint, _ c: CGPoint, _ p1: CGPoint, t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(
            x: u * u * p0.x + 2 * u * t * c.x + t * t * p1.x,
            y: u * u * p0.y + 2 * u * t * c.y + t * t * p1.y)
    }

    /// Control point: the midpoint pushed perpendicular to the path by
    /// `factor × distance` (`factor` is clamped to ±`maxCurveFactor`).
    public static func controlPoint(from a: CGPoint, to b: CGPoint, factor: CGFloat) -> CGPoint {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let d = hypot(dx, dy)
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        guard d.isFinite, d > 0 else { return mid }
        let f = min(maxCurveFactor, max(-maxCurveFactor, factor))
        // Unit normal (-dy, dx) / d, scaled by f·d → (-dy·f, dx·f).
        return CGPoint(x: mid.x - dy * f, y: mid.y + dx * f)
    }

    /// Position after `fraction` (0…1) of the glide's time: the Bézier evaluated at the
    /// eased parameter.
    public static func position(from a: CGPoint, control c: CGPoint, to b: CGPoint, timeFraction: Double) -> CGPoint {
        quadratic(a, c, b, t: CGFloat(easeInOutCubic(timeFraction)))
    }
}

/// Conversions between the global top-left coordinate space (AX, CGEvent, CGWindowList:
/// origin at the primary display's top-left, y down) and Cocoa's screen space (origin at
/// the primary display's bottom-left, y up). `primaryHeight` is the height of the primary
/// screen (`NSScreen.screens[0]`, the one at Cocoa origin (0,0)).
public enum ScreenGeometry {
    public static func cocoaPoint(fromGlobal p: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    public static func globalPoint(fromCocoa p: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    /// A rect in one space to the other (the two flips are the same operation).
    public static func cocoaRect(fromGlobal r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    public static func globalRect(fromCocoa r: CGRect, primaryHeight: CGFloat) -> CGRect {
        cocoaRect(fromGlobal: r, primaryHeight: primaryHeight)
    }

    /// A global point in the flipped (top-left origin) local coordinates of a screen
    /// whose Cocoa frame is `screenFrame`.
    public static func local(_ p: CGPoint, inScreen screenFrame: CGRect, primaryHeight: CGFloat) -> CGPoint {
        let g = globalRect(fromCocoa: screenFrame, primaryHeight: primaryHeight)
        return CGPoint(x: p.x - g.minX, y: p.y - g.minY)
    }

}

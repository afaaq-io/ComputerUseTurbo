import CoreGraphics
import Foundation

/// Geometry reported by target apps (AXPosition / AXSize) is untrusted: a buggy or
/// custom accessibility implementation can report NaN, ±∞ or absurd values, and
/// `Int(_:)` traps on those. Everything the helper reads goes through here.
public enum GeometryGuard {
    /// Largest coordinate magnitude accepted from an app, in points. Real desktops are
    /// orders of magnitude smaller.
    public static let maxMagnitude: CGFloat = 10_000_000

    public static func isSane(_ v: CGFloat) -> Bool { v.isFinite && abs(v) < maxMagnitude }

    public static func sanePoint(_ p: CGPoint) -> CGPoint? {
        isSane(p.x) && isSane(p.y) ? p : nil
    }

    public static func saneSize(_ s: CGSize) -> CGSize? {
        isSane(s.width) && isSane(s.height) && s.width >= 0 && s.height >= 0 ? s : nil
    }

    public static func isSane(_ r: CGRect) -> Bool {
        sanePoint(r.origin) != nil && saneSize(r.size) != nil
    }

    /// NaN/∞-safe, saturating conversion for messages and JSON (never traps).
    public static func displayInt(_ v: CGFloat) -> Int {
        guard v.isFinite else { return 0 }
        return Int(max(-1_000_000_000, min(1_000_000_000, v.rounded())))
    }

    public static func displayInt(_ v: Double) -> Int { displayInt(CGFloat(v)) }
}

/// One interpolated `mouseDragged` event.
public struct DragStep: Equatable, Sendable {
    public let point: CGPoint
    /// Integer movement since the previous event (`kCGMouseEventDeltaX/Y`). Events posted
    /// with `postToPid` are delivered as built: unlike HID events nobody fills these in,
    /// and views that track a drag through `NSEvent.deltaX/Y` would see no movement.
    public let dx: Int
    public let dy: Int

    public init(point: CGPoint, dx: Int, dy: Int) {
        self.point = point
        self.dx = dx
        self.dy = dy
    }
}

/// The drag path of `dragItem` (mouseDown at `from`, ≥ 10 interpolated drags, mouseUp
/// at `to`).
public enum DragPlan {
    public static func stepCount(from: CGPoint, to: CGPoint) -> Int {
        let distance = hypot(to.x - from.x, to.y - from.y)
        guard distance.isFinite else { return 10 }
        return max(10, min(60, Int(distance / 8)))
    }

    /// Interpolated positions from `from` (exclusive) to `to` (inclusive). Deltas come
    /// from cumulative rounding, so they add up to exactly `round(to - from)`.
    public static func steps(from: CGPoint, to: CGPoint) -> [DragStep] {
        let n = stepCount(from: from, to: to)
        let total = CGPoint(x: to.x - from.x, y: to.y - from.y)
        var out: [DragStep] = []
        out.reserveCapacity(n)
        var prevX = 0
        var prevY = 0
        for i in 1...n {
            let f = CGFloat(i) / CGFloat(n)
            let p = CGPoint(x: from.x + total.x * f, y: from.y + total.y * f)
            let cumX = GeometryGuard.displayInt(total.x * f)
            let cumY = GeometryGuard.displayInt(total.y * f)
            out.append(DragStep(point: p, dx: cumX - prevX, dy: cumY - prevY))
            prevX = cumX
            prevY = cumY
        }
        return out
    }

    /// The final move of an interrupted drag: back to where it started, so the button is
    /// released over the origin (a no-op drop) instead of completing the drop the user
    /// stopped.
    public static func returnStep(from last: CGPoint, to origin: CGPoint) -> DragStep {
        DragStep(
            point: origin, dx: GeometryGuard.displayInt(origin.x - last.x),
            dy: GeometryGuard.displayInt(origin.y - last.y))
    }
}

/// Where an element can actually be clicked.
public enum VisibleRegion {
    /// `element` clipped to its nearest enclosing scroll area and to its window (either
    /// may be nil = no clipping). nil when nothing of it is visible: an element scrolled
    /// out of view must not be clicked at its unclipped centre, which lies over some
    /// other control.
    public static func clip(_ element: CGRect, scrollArea: CGRect?, window: CGRect?) -> CGRect? {
        guard GeometryGuard.isSane(element), element.width > 0, element.height > 0 else { return nil }
        var rect = element
        for bound in [scrollArea, window].compactMap({ $0 }) {
            guard GeometryGuard.isSane(bound) else { continue }
            let clipped = rect.intersection(bound)
            if clipped.isNull || clipped.width <= 0 || clipped.height <= 0 { return nil }
            rect = clipped
        }
        return rect
    }

    public static func center(of r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }
}

/// Matching accessibility windows (AXPosition/AXSize) against window-server windows
/// (CGWindowList / ScreenCaptureKit), which report the same global top-left-origin
/// points for the same window.
public enum WindowMatcher {
    /// Largest |Δx| + |Δy| + |Δw| + |Δh| (points) for two frames to be the same window.
    public static let tolerance: CGFloat = 8

    public static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }

    /// The candidate whose frame is the same window as `target`: closest within
    /// `tolerance`, layer 0 preferred on ties. nil when none matches, so callers never
    /// substitute a different window (which would make screenshot coordinates map to the
    /// wrong place).
    public static func match<T>(
        _ target: CGRect, among candidates: [T], frame: (T) -> CGRect, layer: (T) -> Int,
        tolerance: CGFloat = tolerance
    ) -> T? {
        var best: (item: T, distance: CGFloat, layer: Int)?
        for c in candidates {
            let d = distance(frame(c), target)
            guard d.isFinite, d <= tolerance else { continue }
            let l = layer(c)
            if let b = best {
                if d < b.distance || (d == b.distance && l == 0 && b.layer != 0) { best = (c, d, l) }
            } else {
                best = (c, d, l)
            }
        }
        return best?.item
    }

    /// Index of the first frame (candidates in priority order) that is on screen, i.e.
    /// matches one of `onScreen` within `tolerance`.
    public static func firstOnScreen(_ frames: [CGRect], onScreen: [CGRect], tolerance: CGFloat = tolerance) -> Int? {
        frames.firstIndex { f in onScreen.contains { distance($0, f) <= tolerance } }
    }

    /// Index of the frame closest to any of `onScreen` (fallback for apps whose AX
    /// frames are slightly off), or nil when either list is empty.
    public static func nearest(_ frames: [CGRect], onScreen: [CGRect]) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (i, f) in frames.enumerated() {
            for s in onScreen {
                let d = distance(f, s)
                guard d.isFinite else { continue }
                if best == nil || d < best!.distance { best = (i, d) }
            }
        }
        return best?.index
    }
}

/// Small polling helper with an injectable clock.
public enum Polling {
    /// Re-read a value until `changed(initial, value)` holds, for at most `timeout`.
    /// Returns the first changed value, or nil if it never changed (failed reads count
    /// as "unchanged").
    public static func waitForChange<T>(
        from initial: T, timeout: TimeInterval, interval: TimeInterval,
        changed: (T, T) -> Bool,
        now: () -> Date = Date.init,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        read: () -> T?
    ) -> T? {
        let until = now().addingTimeInterval(timeout)
        repeat {
            sleep(interval)
            if let v = read(), changed(initial, v) { return v }
        } while now() < until
        return nil
    }
}

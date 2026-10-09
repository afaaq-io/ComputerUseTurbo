import CoreGraphics
import Foundation

/// One `kCGEventMouseMoved` event posted before a mouse action ("Hover
/// before mouse input").
public struct HoverMove: Equatable, Sendable {
    /// Global top-left point the event is posted at.
    public let point: CGPoint
    /// When to post it, in seconds after the plan started (the pointer's arrival).
    public let at: TimeInterval
    /// Integer movement since the previous move (`kCGMouseEventDeltaX/Y`): events posted
    /// to a pid are delivered as built, nobody fills these in.
    public let dx: Int
    public let dy: Int

    public init(point: CGPoint, at: TimeInterval, dx: Int, dy: Int) {
        self.point = point
        self.at = at
        self.dx = dx
        self.dy = dy
    }
}

/// Mouse-moved events before every mouse action (click, scroll, drag start). Some apps
/// (Blender, games, other custom toolkits) take the click position and hover state from
/// the last mouse-MOVED event rather than from the mouseDown itself: a bare down/up
/// posted to the pid then hits whatever the app last saw the mouse over (or nothing).
///
/// Only the FINAL APPROACH is posted, after the agent pointer has arrived: a few moves
/// within `approachOffsets` points of the target, on the line from where the app last saw
/// the mouse, ending exactly at the target. The pointer may glide along a curve, but the
/// app never sees the mouse sweep across other controls on the way — in a cascading menu
/// (Blender's Add ▸ Mesh ▸ Monkey) a move over another item of the parent menu would
/// switch or close the submenu before the click lands.
public enum HoverPlan {
    /// Distances (points) from the target of the approach moves before the target itself.
    /// Small enough to stay inside any clickable control (a menu item is ≥ ~16 pt tall).
    public static let approachOffsets: [CGFloat] = [3, 1]
    /// Spacing of the moves.
    public static let stepInterval: TimeInterval = 0.010
    /// Extra moves exactly at the target after the first one.
    public static let finalRepeats = 1
    /// Pause after the last move, before mouseDown.
    public static let settle: TimeInterval = 0.04
    /// Direction to approach from when the app has not seen the mouse yet: from up-left.
    static let defaultDirection = CGVector(dx: 3, dy: 2)

    /// The final approach to `to`: `approachOffsets` points away from it towards `from`
    /// (where this app last saw the mouse; nil / the same point → from up-left), clamped
    /// to `bounds` (the target's window) so every move stays over the app, then the
    /// target `1 + finalRepeats` times. Deltas count from `from` when known (the app's
    /// previous mouse position), else from the first move.
    public static func finalApproach(to: CGPoint, from: CGPoint?, within bounds: CGRect? = nil) -> [HoverMove] {
        guard GeometryGuard.sanePoint(to) != nil else { return [] }
        var dir = defaultDirection
        var origin: CGPoint?
        if let from, GeometryGuard.sanePoint(from) != nil {
            origin = from
            let d = CGVector(dx: to.x - from.x, dy: to.y - from.y)
            if hypot(d.dx, d.dy) >= 1 { dir = d }
        }
        let len = hypot(dir.dx, dir.dy)
        let unit = CGVector(dx: dir.dx / len, dy: dir.dy / len)
        var points: [CGPoint] = approachOffsets.map { off in
            clamp(CGPoint(x: to.x - unit.dx * off, y: to.y - unit.dy * off), to: bounds)
        }
        points.append(contentsOf: Array(repeating: to, count: 1 + finalRepeats))
        let start = origin ?? points[0]
        var out: [HoverMove] = []
        out.reserveCapacity(points.count)
        var prevX = 0
        var prevY = 0
        for (i, p) in points.enumerated() {
            // Cumulative rounding, so the deltas add up to exactly round(to − start).
            let cumX = GeometryGuard.displayInt(p.x - start.x)
            let cumY = GeometryGuard.displayInt(p.y - start.y)
            out.append(HoverMove(point: p, at: stepInterval * Double(i), dx: cumX - prevX, dy: cumY - prevY))
            prevX = cumX
            prevY = cumY
        }
        return out
    }

    private static func clamp(_ p: CGPoint, to bounds: CGRect?) -> CGPoint {
        guard let b = bounds, GeometryGuard.isSane(b), b.width >= 1, b.height >= 1 else { return p }
        return CGPoint(x: min(max(p.x, b.minX), b.maxX - 1), y: min(max(p.y, b.minY), b.maxY - 1))
    }
}

/// `<support>/settings.json` → `"hover":{…}` (/// "Real-pointer assist"). Anything missing or malformed falls back to the defaults.
public struct HoverSettings: Equatable, Sendable {
    /// Post mouse-moved events before mouse actions at all (debug switch).
    public var enabled: Bool
    /// Address the moves to a window (window number fields + window-local location)
    /// (debug switch).
    public var routeMoves: Bool
    /// Pause after the last move before mouseDown (ms, 0…500).
    public var settleMs: Int
    /// Real-pointer assist for the apps in `realPointerApps` (false turns it off).
    public var realPointerAssist: Bool
    /// Bundle ids (case-insensitive) whose controls only take clicks while the user's real
    /// pointer is over their window.
    public var realPointerApps: [String]

    /// Manual overrides only (empty by default): learned per app instead (`FocusPolicy`).
    public static let defaultRealPointerApps: [String] = []
    public static let defaults = HoverSettings(
        enabled: true, routeMoves: true, settleMs: Int(HoverPlan.settle * 1000), realPointerAssist: true,
        realPointerApps: defaultRealPointerApps)

    public init(enabled: Bool, routeMoves: Bool, settleMs: Int, realPointerAssist: Bool, realPointerApps: [String]) {
        self.enabled = enabled
        self.routeMoves = routeMoves
        self.settleMs = settleMs
        self.realPointerAssist = realPointerAssist
        self.realPointerApps = realPointerApps
    }

    public static func parse(_ data: Data?) -> HoverSettings {
        var s = defaults
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let hover = root["hover"] as? [String: Any]
        else { return s }
        if let b = hover["enabled"] as? Bool { s.enabled = b }
        if let b = hover["routeMoves"] as? Bool { s.routeMoves = b }
        if let n = hover["settleMs"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite {
            s.settleMs = Int(min(500, max(0, n.doubleValue.rounded())))
        }
        if let b = hover["realPointerAssist"] as? Bool { s.realPointerAssist = b }
        if let apps = hover["realPointerApps"] as? [Any] {
            s.realPointerApps = apps.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return s
    }

    public static func load(_ url: URL) -> HoverSettings {
        parse(try? Data(contentsOf: url))
    }

    public func needsRealPointer(bundleId: String) -> Bool {
        guard realPointerAssist, !bundleId.isEmpty else { return false }
        return realPointerApps.contains { $0.caseInsensitiveCompare(bundleId) == .orderedSame }
    }
}

/// Real-pointer assist: some apps only take clicks on their controls
/// while the user's REAL pointer is over their window. Godot, for one, updates hover
/// (which its buttons require before they take a press) only after the window server
/// reported that the real cursor entered the window, and closes its popups on any
/// mouseDown whose real cursor position is outside them; no event posted to the pid can
/// stand in for that. For such apps the helper moves the real pointer onto the target for
/// the duration of the button events and puts it back — only when nobody is using the
/// mouse or keyboard and the target app ALREADY is in front (the helper never activates it
/// for this); otherwise the click fails with 4022 userActive and nothing is sent.
public enum RealPointerAssistPolicy {
    /// The user's last hardware mouse / keyboard input must be at least this long ago.
    public static let idleSeconds: TimeInterval = 1.0
    /// Wait after moving the real pointer, so the window server's mouse-entered reaches
    /// the app before our events do.
    public static let enterDelay: TimeInterval = 0.05
    /// Wait after the last button event before the pointer goes back, so the app handles
    /// the click while the real pointer is still over it.
    public static let holdAfter: TimeInterval = 0.15

    public enum Decision: Equatable, Sendable {
        case assist
        /// Not needed for this app (or turned off).
        case notNeeded
        /// Needed, but the app is not in front or the user is using the mouse / keyboard:
        /// the click would be ignored, so nothing is sent (4022 userActive). The helper
        /// never activates the app to make the assist possible.
        case refused(Reason)
    }

    public enum Reason: String, Equatable, Sendable {
        case notInFront
        case userActive
    }

    public static func decide(
        settings: HoverSettings, bundleId: String, targetFront: Bool,
        secondsSinceUserMouse: TimeInterval, secondsSinceKeyboard: TimeInterval
    ) -> Decision {
        guard settings.needsRealPointer(bundleId: bundleId) else { return .notNeeded }
        if !targetFront { return .refused(.notInFront) }
        if min(secondsSinceUserMouse, secondsSinceKeyboard) < idleSeconds { return .refused(.userActive) }
        return .assist
    }

    /// Put the pointer back only if it is still where the helper left it and the user has
    /// not touched the mouse since (else the user has taken over: leave it).
    public static func shouldRestore(current: CGPoint, placed: CGPoint, secondsSinceUserMouse: TimeInterval, heldFor: TimeInterval) -> Bool {
        guard secondsSinceUserMouse >= heldFor else { return false }
        return hypot(current.x - placed.x, current.y - placed.y) < 1
    }

    public static func note(app: String) -> String {
        "The real mouse pointer was moved over \(app) for this action and put back (\(app) only takes clicks while the pointer is over its window)."
    }

    /// 4022 userActive message when the assist is needed but not possible.
    public static func refusedMessage(app: String, reason: Reason) -> String {
        let why =
            reason == .notInFront
            ? "\(app) is not in front"
            : "the user is using the mouse or keyboard right now"
        return "\(app) only accepts clicks while it is in front and nobody is using the mouse (it needs the real mouse pointer over its window), and \(why). The helper never brings apps to the front or takes the mouse from the user, so nothing was sent. Ask the user to bring \(app) to the front and leave the mouse alone for a moment, or wait and retry; keyboard shortcuts may work in the meantime."
    }
}

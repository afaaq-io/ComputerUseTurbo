import Foundation

// Settle before observation: actions return right after their
// input; the NEXT observe_app of that app waits for the UI to settle first. The wait is
// driven by the app's accessibility notifications (value changed, layout changed,
// element created / destroyed, focus moved, window created, title changed, …): a base
// delay that ends early once the app has been quiet for a while, and that is extended
// (up to a ceiling) while notifications keep arriving. Pure; the helper feeds it times.

/// Settle timing knobs (`settings.json` `"settle": {…}`, all optional, milliseconds).
public struct SettleSettings: Equatable, Sendable {
    /// The usual wait after an action (also the whole wait when no notification observer
    /// could be registered for the app).
    public var baseMs: Int
    /// The app counts as settled once no notification arrived for this long …
    public var quietMs: Int
    /// … but never before this much time passed since the action.
    public var minMs: Int
    /// Ceiling while notifications keep arriving.
    public var maxMs: Int

    public init(baseMs: Int, quietMs: Int, minMs: Int, maxMs: Int) {
        self.baseMs = baseMs
        self.quietMs = quietMs
        self.minMs = minMs
        self.maxMs = maxMs
    }

    public static let defaults = SettleSettings(baseMs: 1000, quietMs: 300, minMs: 400, maxMs: 5000)

    public static func parse(_ data: Data?) -> SettleSettings {
        var s = defaults
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let o = root["settle"] as? [String: Any]
        else { return s }
        func ms(_ key: String, _ range: ClosedRange<Int>) -> Int? {
            guard let n = o[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            let d = n.doubleValue
            guard d.isFinite else { return nil }
            return min(range.upperBound, max(range.lowerBound, Int(d)))
        }
        if let v = ms("baseMs", 0...10_000) { s.baseMs = v }
        if let v = ms("quietMs", 50...5_000) { s.quietMs = v }
        if let v = ms("minMs", 0...10_000) { s.minMs = v }
        if let v = ms("maxMs", 0...30_000) { s.maxMs = v }
        s.minMs = min(s.minMs, s.baseMs)
        s.maxMs = max(s.maxMs, s.baseMs)
        return s
    }

    public static func load(_ url: URL) -> SettleSettings { parse(try? Data(contentsOf: url)) }
}

public enum SettleReason: String, Equatable, Sendable {
    /// No notification for `quietMs` (after at least `minMs`).
    case quiet
    /// `baseMs` passed (no observer for the app, or quiet at that moment).
    case base
    /// Notifications kept arriving until `maxMs`.
    case ceiling
}

public enum SettleStep: Equatable, Sendable {
    /// Sleep this long, then ask again.
    case wait(TimeInterval)
    case done(SettleReason)
}

public enum SettlePolicy {
    /// One decision. Times are monotonic seconds; `lastNotification` is the latest
    /// accessibility notification from the app (nil = none since the action);
    /// `observing` = notifications can arrive at all (an observer is registered).
    public static func next(
        now: TimeInterval, actionEnded: TimeInterval, lastNotification: TimeInterval?, observing: Bool,
        settings s: SettleSettings = .defaults
    ) -> SettleStep {
        let elapsed = now - actionEnded
        let base = Double(s.baseMs) / 1000
        let maxWait = Double(s.maxMs) / 1000
        if elapsed >= maxWait { return .done(.ceiling) }
        guard observing else {
            return elapsed >= base ? .done(.base) : .wait(base - elapsed)
        }
        let quiet = Double(s.quietMs) / 1000
        let minWait = Double(s.minMs) / 1000
        let lastActivity = max(actionEnded, lastNotification ?? actionEnded)
        let quietFor = now - lastActivity
        if quietFor >= quiet && elapsed >= minWait {
            return .done(elapsed >= base ? .base : .quiet)
        }
        // Wait for whichever comes first: the quiet period completing, or the minimum.
        let untilQuiet = quiet - quietFor
        let untilMin = minWait - elapsed
        let step = max(0.02, min(max(untilQuiet, untilMin), maxWait - elapsed))
        return .wait(min(step, 0.1))
    }
}

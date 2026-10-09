import Foundation

// User take-back: real (hardware) input aimed at the target app —
// a click or scroll in one of its windows while it is in front, or a key press while it
// is in front — means the user is using that app themselves. While they are at it,
// actions on the app fail with a retryable "wait N s and retry"; once they stopped, the
// next action fails until a fresh observe_app has looked at what they changed. Pure;
// the helper feeds it times (monotonic seconds).

public enum InterventionVerdict: Equatable, Sendable {
    /// Nothing the user did since the latest observation.
    case none
    /// The user is still using the app: retry after this many seconds.
    case stillInteracting(retryAfter: Int)
    /// The user used the app after the latest observation: observe again first.
    case changedSinceObservation
}

public enum InterventionPolicy {
    /// The user counts as still interacting for this long after their last input.
    public static let debounce: TimeInterval = 1.5

    /// `lastUserInput`: the user's latest hardware input aimed at the app (nil = none);
    /// `lastObservation`: when this session's latest observe_app of the app finished
    /// reading it (nil = never).
    public static func verdict(
        lastUserInput: TimeInterval?, lastObservation: TimeInterval?, now: TimeInterval, debounce: TimeInterval = debounce
    ) -> InterventionVerdict {
        guard let input = lastUserInput, let observed = lastObservation, input > observed else { return .none }
        let since = now - input
        if since < debounce {
            return .stillInteracting(retryAfter: max(1, Int((debounce - since).rounded(.up))))
        }
        return .changedSinceObservation
    }

    public static func stillInteractingMessage(app: String, retryAfter: Int) -> String {
        "The user is using \(app) right now, so nothing was sent. Wait \(retryAfter) s and retry; then call observe_app first, because the user may have changed the app."
    }

    public static func changedMessage(app: String) -> String {
        "The user used \(app) since your last observe_app, so nothing was sent: the app may have changed. Call observe_app for \(app) again before acting on it."
    }
}

/// Which hardware event counts as the user using the target app (pure decision; the
/// helper supplies the facts it observed for the event).
public enum UserInputAttribution {
    public enum Kind: Equatable, Sendable { case mouseDown, scroll, key }

    /// `frontPid`: frontmost app at the time; `windowOwnerAtPoint`: owner of the topmost
    /// on-screen window under a mouse event (nil for keys / unknown). A key counts when
    /// the target is in front; a click or scroll when it lands in one of the target's
    /// windows (the target need not be in front for a scroll).
    public static func isAimedAtTarget(
        kind: Kind, targetPid: Int32, frontPid: Int32?, windowOwnerAtPoint: Int32?
    ) -> Bool {
        switch kind {
        case .key:
            return frontPid == targetPid
        case .mouseDown:
            return windowOwnerAtPoint == targetPid
        case .scroll:
            return windowOwnerAtPoint == targetPid
        }
    }
}

/// `settings.json` `"backgroundKeys": {"enabled": true}`: post key
/// events to an app in the background (and press ⌘-shortcuts' menu items) instead of
/// failing with userActive.
public struct BackgroundKeySettings: Equatable, Sendable {
    public var enabled: Bool

    public static func parse(_ data: Data?) -> BackgroundKeySettings {
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let o = root["backgroundKeys"] as? [String: Any]
        else { return BackgroundKeySettings(enabled: true) }
        return BackgroundKeySettings(enabled: o["enabled"] as? Bool ?? true)
    }

    public static func load(_ url: URL) -> BackgroundKeySettings { parse(try? Data(contentsOf: url)) }
}

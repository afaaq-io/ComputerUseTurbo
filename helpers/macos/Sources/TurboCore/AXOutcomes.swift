import Foundation

/// The raw `AXError` values (ApplicationServices `AXError.h`) the decisions below need.
/// TurboCore stays free of the Accessibility framework, so it works on the raw codes.
public enum AXErrorCode {
    public static let success: Int32 = 0
    public static let invalidUIElement: Int32 = -25202
    public static let cannotComplete: Int32 = -25204
    public static let attributeUnsupported: Int32 = -25205
    public static let noValue: Int32 = -25212

    /// The attribute read produced a definite answer: a value, "no value", or "this
    /// element has no such attribute". Anything else (timeouts, failures, API disabled)
    /// means we do not know.
    public static func isDefiniteAnswer(_ raw: Int32) -> Bool {
        raw == success || raw == noValue || raw == attributeUnsupported
    }
}

/// What the result of `AXUIElementPerformAction` means for the caller.
public enum AXActionOutcome: Equatable, Sendable {
    /// `.success`.
    case performed
    /// `.cannotComplete`: the action message was delivered but the app did not reply
    /// within the messaging timeout (slow handler, a modal alert / sheet, menu
    /// tracking). The action has almost certainly run or is running, so it must not be
    /// repeated by a fallback mouse click or reported as a retryable failure.
    case probablyPerformed
    /// `.invalidUIElement`: the element is gone.
    case elementGone
    /// Anything else (`.actionUnsupported`, `.failure`, `.illegalArgument`, …): not performed.
    case failed

    public init(rawError: Int32) {
        switch rawError {
        case AXErrorCode.success: self = .performed
        // attributeUnsupported from a *perform* call: seen from AppKit when the action did
        // run (Finder / Open-panel rows answering AXOpen, TextEdit's AXPress) — repeating it
        // with a mouse click would do it twice, so it counts as delivered.
        case AXErrorCode.cannotComplete, AXErrorCode.attributeUnsupported: self = .probablyPerformed
        case AXErrorCode.invalidUIElement: self = .elementGone
        default: self = .failed
        }
    }
}

/// Whether an element is a secure (password) text field, as a three-valued answer.
/// "Unknown" (e.g. the 1 s messaging timeout hit) must be treated like "secure" by every
/// check that gates input: failing open would type into a password field the moment a
/// busy app catches up.
public enum SecureFieldCheck: Equatable, Sendable {
    case secure
    case notSecure
    case unknown

    /// Combine the role and subrole reads (raw AXError + string value).
    public static func evaluate(roleError: Int32, role: String?, subroleError: Int32, subrole: String?) -> SecureFieldCheck {
        if role == AXRoles.secureTextField || subrole == AXRoles.secureTextField { return .secure }
        if AXErrorCode.isDefiniteAnswer(roleError) && AXErrorCode.isDefiniteAnswer(subroleError) {
            return .notSecure
        }
        return .unknown
    }
}

/// The app's focused element, as a three-valued answer.
public enum FocusReadKind: Equatable, Sendable {
    case element
    /// Definitely nothing focused (`noValue` / `attributeUnsupported`).
    case nothingFocused
    /// The app did not answer (timeout or failure).
    case unknown

    public static func classify(rawError: Int32, gotElement: Bool) -> FocusReadKind {
        if rawError == AXErrorCode.success { return gotElement ? .element : .nothingFocused }
        return AXErrorCode.isDefiniteAnswer(rawError) ? .nothingFocused : .unknown
    }
}

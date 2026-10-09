import Foundation

// Focus model: the helper works in the background. It never brings an
// app or window to the front on its own — not before actions, not after launching an app,
// not after the user switched away — so the user can keep using their Mac while the agent
// works. Mouse input goes to the target's pid with window routing, text and ⌘-shortcuts
// through accessibility, other keys as per-pid key events. Only when the target already is
// the frontmost app (the user put it there) are key events delivered the ordinary way.
// Pure policy: the helper feeds it what it sees right before an action.

public enum FocusMode: String, Equatable, Sendable {
    /// The target already is the frontmost app (the user brought it forward): key events
    /// are delivered normally. The helper never makes this happen itself.
    case foreground
    /// The target is not in front: mouse via pid-routed events, text via accessibility,
    /// keys as per-pid key events / menu items; what cannot be delivered this way fails
    /// with 4022 userActive. The target is never activated.
    case background
}

public enum FocusTransition: Equatable, Sendable {
    case none
    /// First action on this target in the session with it not in front, or the target
    /// left the front since the previous action.
    case enteredBackground
    /// The target is in front (and was not at the previous action on it).
    case targetInFront
}

/// Per-session record of the mode each target had at its latest action (for notes only;
/// nothing here ever activates an app).
public struct FocusModeState: Equatable, Sendable {
    public private(set) var lastMode: [Int32: FocusMode] = [:]

    public init() {}

    /// Mode for an action on `targetPid` with `frontmostPid` in front.
    public static func mode(targetPid: Int32, frontmostPid: Int32?) -> FocusMode {
        frontmostPid == targetPid ? .foreground : .background
    }

    /// Record the mode for this action and report a change against the previous action on
    /// the same target.
    public mutating func evaluate(targetPid: Int32, frontmostPid: Int32?) -> (mode: FocusMode, transition: FocusTransition) {
        let mode = Self.mode(targetPid: targetPid, frontmostPid: frontmostPid)
        let previous = lastMode[targetPid]
        lastMode[targetPid] = mode
        guard previous != mode else { return (mode, .none) }
        switch mode {
        case .background: return (mode, .enteredBackground)
        case .foreground: return (mode, previous == nil ? .none : .targetInFront)
        }
    }
}

/// `settings.json` `"focus": {"activateTarget": false, "foregroundInputApps": […]}`
///.
///
/// `activateTarget` is opt-in only: with `true` the helper brings the target to the front
/// before an action — but only while the user has not typed or clicked for
/// `quietSeconds`. Default false: the helper never activates anything.
///
/// `foregroundInputApps` (bundle ids, case-insensitive): apps that ignore mouse buttons,
/// scroll wheel and keys posted to them while they are not the active app (Blender's
/// GHOST layer routes input only to its active window). For them such input in the
/// background fails with 4022 userActive instead of silently going nowhere; accessibility
/// actions are unaffected.
///
/// `forceFrontApps` (bundle ids): apps that only work properly while they are the app in
/// front (Blender ignores background input; Godot / Epic need the real pointer over their
/// window). The helper brings these to the front itself — on every observation and before
/// every action — so the user sees what the agent works on. It first waits (up to
/// `forceFrontMaxWait`) for a pause of `forceFrontQuietSeconds` in the user's typing, so
/// keystrokes meant for another app do not land in the target.
public struct FocusSettings: Equatable, Sendable {
    public var activateTarget: Bool
    public var foregroundInputApps: [String]
    public var forceFrontApps: [String]
    /// Borrowed front (`BorrowFrontPolicy`): on by default; false = such actions fail with
    /// 4022 userActive instead.
    public var borrowFront: Bool = true

    /// Manual overrides only (empty by default): which apps need the front is detected and
    /// learned (`FocusPolicy`, `AppFocusProfileStore`).
    public static let defaultForegroundInputApps: [String] = []
    public static let defaultForceFrontApps: [String] = []
    public static let defaults = FocusSettings(
        activateTarget: false, foregroundInputApps: defaultForegroundInputApps, forceFrontApps: defaultForceFrontApps)
    public static let forceFrontQuietSeconds: TimeInterval = 1.0
    public static let forceFrontMaxWait: TimeInterval = 2.0

    public init(activateTarget: Bool, foregroundInputApps: [String], forceFrontApps: [String] = defaultForceFrontApps) {
        self.activateTarget = activateTarget
        self.foregroundInputApps = foregroundInputApps
        self.forceFrontApps = forceFrontApps
    }
    /// The opt-in activation waits until the user has been idle this long.
    public static let quietSeconds: TimeInterval = 2.0

    public static func parse(_ data: Data?) -> FocusSettings {
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let o = root["focus"] as? [String: Any]
        else { return .defaults }
        let apps = (o["foregroundInputApps"] as? [Any])?.compactMap { $0 as? String } ?? defaultForegroundInputApps
        let force = (o["forceFrontApps"] as? [Any])?.compactMap { $0 as? String } ?? defaultForceFrontApps
        var out = FocusSettings(
            activateTarget: o["activateTarget"] as? Bool ?? false, foregroundInputApps: apps, forceFrontApps: force)
        out.borrowFront = o["borrowFront"] as? Bool ?? true
        return out
    }

    public static func load(_ url: URL) -> FocusSettings { parse(try? Data(contentsOf: url)) }

    /// Whether the opt-in activation may bring the target forward now.
    public func shouldActivate(targetFront: Bool, secondsSinceUserInput: TimeInterval) -> Bool {
        activateTarget && !targetFront && secondsSinceUserInput >= Self.quietSeconds
    }

    /// Whether the helper brings `bundleId` to the front itself (`forceFrontApps`).
    public func forcesFront(bundleId: String) -> Bool {
        let id = bundleId.lowercased()
        return !id.isEmpty && forceFrontApps.contains { $0.lowercased() == id }
    }

    /// Whether `bundleId` takes mouse / key input only while it is the active app.
    public func needsForegroundInput(bundleId: String) -> Bool {
        let id = bundleId.lowercased()
        return !id.isEmpty && foregroundInputApps.contains { $0.lowercased() == id }
    }
}

/// Return / Enter and Escape pressed without modifiers trigger a window's default and
/// cancel buttons through AppKit's key-equivalent pass, which runs only in the active app.
/// In the background the helper presses that button through accessibility instead.
public enum DialogKey: Equatable, Sendable {
    /// Return / keypad Enter → the window's `AXDefaultButton`.
    case defaultButton
    /// Escape → the window's `AXCancelButton`.
    case cancelButton

    public static func from(_ chord: KeyChord) -> DialogKey? {
        guard chord.modifiers.isSubset(of: [.numericPad]) else { return nil }
        switch chord.keyCode {
        case USKeyboard.returnKeyCode, 0x4C: return .defaultButton
        case USKeyboard.escapeKeyCode: return .cancelButton
        default: return nil
        }
    }

    /// AXAttribute of the window that holds the button.
    public var windowAttribute: String { self == .defaultButton ? "AXDefaultButton" : "AXCancelButton" }

    /// Return in a multi-line text element inserts a line break, never the default button.
    public func applies(focusedRole: String?) -> Bool {
        !(self == .defaultButton && focusedRole == "AXTextArea")
    }
}

/// User-facing texts for focus modes.
public enum FocusModeText {
    /// Once per target, when an action finds it not in front.
    public static func backgroundNote(app: String) -> String {
        "\(app) is not in front; working in the background (the user can keep using their computer meanwhile)."
    }
    /// Key input posted to an app in the background.
    public static func backgroundKeysNote(app: String) -> String {
        "Keys were sent to \(app) in the background (it was not brought to the front); call observe_app to check that they arrived."
    }
    public static func userBusyMessage(app: String, what: String) -> String {
        "\(what.prefix(1).uppercased() + what.dropFirst()) cannot be delivered while \(app) is in the background, and the helper never brings apps to the front (the user may be using another app). Nothing was sent. Keep going with clicks, fill_value and write_text (they work in the background), retry later, or ask the user to bring \(app) to the front."
    }
    /// An app listed in `focus.foregroundInputApps` while it is not in front.
    public static func foregroundInputMessage(app: String, what: String) -> String {
        "\(app) only takes \(what) while it is the app in front, and it is in the background now; the helper never brings apps to the front (the user may be using another app). Nothing was sent. Retry later, or ask the user to bring \(app) to the front."
    }
    /// Borrowed front, after the action.
    public static func borrowedNote(app: String, previous: String?) -> String {
        "\(app) was brought to the front for this action only (it cannot be done while the app is in the background; the user was idle)\(previous.map { " and the front was handed back to \($0)" } ?? "")."
    }
    /// Borrowed front kept because a menu of the app is open.
    public static func borrowKeptForMenuNote(app: String) -> String {
        "\(app) stays in front while its menu is open; the front goes back to the user's app after the next action that closes the menu (or at finish)."
    }
    /// Borrowed front refused: the user is busy.
    public static func borrowBusyMessage(app: String, what: String) -> String {
        "\(what.prefix(1).uppercased() + what.dropFirst()) needs \(app) in front for a moment, but the user is typing or using the mouse right now. Nothing was sent. Retry in a few seconds."
    }
}

// MARK: - write_text over accessibility

/// One step of `writeText`.
public enum WriteTextRun: Equatable, Sendable {
    /// A maximal run without newlines or tabs (inserted through accessibility when
    /// possible, else typed as key events in ≤ 20-unit chunks).
    case text(String)
    /// `\n`, `\r` or `\r\n`.
    case newline
    case tab

    public var characterCount: Int {
        switch self {
        case .text(let s): return s.count
        case .newline, .tab: return 1
        }
    }

    /// Return / Tab can move keyboard focus.
    public var movesFocus: Bool { !isText }

    public var isText: Bool {
        if case .text = self { return true }
        return false
    }
}

public enum WriteTextPlan {
    public static func runs(_ text: String) -> [WriteTextRun] {
        var out: [WriteTextRun] = []
        var current = ""
        func flush() {
            if !current.isEmpty { out.append(.text(current)) }
            current = ""
        }
        for ch in text {
            if ch == "\n" || ch == "\r" || ch == "\r\n" {
                flush()
                out.append(.newline)
            } else if ch == "\t" {
                flush()
                out.append(.tab)
            } else {
                current.append(ch)
            }
        }
        flush()
        return out
    }

    /// How a newline / tab is delivered without key events (background mode): a text area
    /// takes the character itself; a single-line field submits with AXConfirm (newline
    /// only); anything else needs a real key press.
    public enum KeylessDelivery: Equatable, Sendable {
        case insertCharacter
        case confirm
        case needsKey
    }

    public static func keyless(_ run: WriteTextRun, role: String?, actions: [String]) -> KeylessDelivery {
        guard !run.isText else { return .insertCharacter }
        if role == "AXTextArea" { return .insertCharacter }
        if run == .newline, actions.contains("AXConfirm") { return .confirm }
        return .needsKey
    }
}

/// Read-back check after inserting text by setting `kAXSelectedTextAttribute`.
public enum AXInsertion {
    public enum Verdict: Equatable, Sendable {
        /// The value now holds the inserted text.
        case took
        /// The value did not change: the insertion did not take (fall back to keys).
        case unchanged
    }

    /// `before` with `selection` (UTF-16) replaced by `inserted`; nil if the range does
    /// not fit `before`.
    public static func expected(before: String, selection: UTF16Range?, inserted: String) -> String? {
        let ns = before as NSString
        let range = selection ?? UTF16Range(location: ns.length, length: 0)
        guard range.location >= 0, range.length >= 0, range.location + range.length <= ns.length else { return nil }
        return ns.replacingCharacters(in: NSRange(location: range.location, length: range.length), with: inserted)
    }

    /// Any change counts as taken (an app may reformat or autocomplete what was inserted;
    /// typing it again as keys would duplicate it). Only an unchanged value falls back.
    public static func verdict(before: String, after: String?) -> Verdict {
        guard let after else { return .unchanged }
        return after == before ? .unchanged : .took
    }

    /// Whether the read-back is exactly the expected splice (for the log / note).
    public static func isExact(after: String?, expected: String?) -> Bool {
        guard let after, let expected else { return false }
        return normalize(after) == normalize(expected)
    }

    static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }
}

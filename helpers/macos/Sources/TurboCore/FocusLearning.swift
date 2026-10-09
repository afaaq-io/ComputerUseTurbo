import Foundation

// Which apps need to be in front, and which need the user's real pointer — detected and
// learned, never hard-coded.
//
// Detection: an app whose accessibility tree is "sparse" (it draws its own UI —
// `AccessibilitySparsity`) is treated as needing the front: such apps (Blender, Godot, game
// engines, launchers) usually ignore input while inactive. Everything else works in the
// background (AppKit / web content takes posted events).
//
// Self-drawn apps are brought to the front and clicked with the user's real pointer over the
// target (put back right after), always exactly once: no guessing, no retries. If the user is
// using the mouse, the helper waits (≤ 2 s) for a pause, else sends nothing (4022 userActive).
// Profiles persist in `<support>/app-profiles.json`; settings lists stay as manual overrides
// (empty by default).

public enum FocusNeed: String, Equatable, Sendable {
    /// Works in the background (posted events, accessibility).
    case background
    /// Must be the app in front to take input.
    case front
    /// In front AND the real pointer over its window (clicks).
    case frontWithRealPointer
}

public struct AppFocusProfile: Codable, Equatable, Sendable {
    /// Seen with a sparse (self-drawn) accessibility tree.
    public var selfDrawn: Bool?
    /// Learned: needs the front (true) / proven to work in the background (false).
    public var needsFront: Bool?
    /// Learned: clicks only work with the real pointer over the window.
    public var needsRealPointer: Bool?
    /// Learned: a drag in this app starts a system drag session (Finder files, …), which
    /// follows the real pointer, so drags need the front and the real mouse.
    public var systemDrags: Bool?
    /// Short human-readable reason for the latest learned value.
    public var evidence: String?
    public var updatedAt: String?

    public init(
        selfDrawn: Bool? = nil, needsFront: Bool? = nil, needsRealPointer: Bool? = nil, systemDrags: Bool? = nil,
        evidence: String? = nil, updatedAt: String? = nil
    ) {
        self.systemDrags = systemDrags
        self.selfDrawn = selfDrawn
        self.needsFront = needsFront
        self.needsRealPointer = needsRealPointer
        self.evidence = evidence
        self.updatedAt = updatedAt
    }
}

/// Borrowed front: an action that cannot work while the app is in the background (a
/// menu from its menu bar, a ⌘-shortcut whose menu item the app disables while inactive,
/// committing an in-place editor, a system drag) brings the app to the front for that one
/// action — only after the user has paused typing and mousing — and then hands the front
/// back to the app the user had there, unless the user has taken over meanwhile or a menu
/// of the target is still open (the next action closes it, or the end of the turn).
public enum BorrowFrontPolicy {
    /// The user must not have typed, clicked or moved the mouse for this long.
    public static let quietSeconds: TimeInterval = 1.0
    /// Longest wait for such a pause before 4022 userActive.
    public static let maxWait: TimeInterval = 2.0
    /// The app keeps the front this long after the action, so it handles the input as the
    /// active app before it is deactivated.
    public static let holdAfter: TimeInterval = 0.4

    public static func userIdle(secondsSinceKeyboard: TimeInterval, secondsSinceMouse: TimeInterval) -> Bool {
        secondsSinceKeyboard >= quietSeconds && secondsSinceMouse >= quietSeconds
    }

    public enum Restore: Equatable, Sendable {
        /// Give the front back now.
        case restore
        /// Keep it for now (a menu of the target is open; restoring would close it).
        case keep
        /// Forget it: the user switched apps or used the Mac since the borrow.
        case drop
    }

    public static func restore(
        targetStillFront: Bool, menuOpen: Bool, secondsSinceUserInput: TimeInterval, heldFor: TimeInterval,
        force: Bool = false
    ) -> Restore {
        guard targetStillFront else { return .drop }
        // The user typed or clicked after the borrow started: they are working, leave it.
        if secondsSinceUserInput < heldFor { return .drop }
        if menuOpen && !force { return .keep }
        return .restore
    }
}

public enum FocusPolicy {
    /// Manual overrides (settings) win, then what was learned, then detection.
    public static func decide(
        bundleId: String, profile: AppFocusProfile?, focus: FocusSettings, hover: HoverSettings
    ) -> FocusNeed {
        if hover.needsRealPointer(bundleId: bundleId) { return .frontWithRealPointer }
        if focus.forcesFront(bundleId: bundleId) || focus.needsForegroundInput(bundleId: bundleId) { return .front }
        // An app that draws its own UI needs the front, and its clicks go out with the user's
        // real pointer over the target: that works in every window of every such app (Godot,
        // for one, takes posted clicks in its main window but not in its dialogs), so a click
        // is never silently ignored and never has to be repeated.
        return profile?.selfDrawn == true ? .frontWithRealPointer : .background
    }

}

/// `<support>/app-profiles.json`: `{"version":1,"apps":{"<bundleId>":{…}}}`, written
/// atomically with mode 0600. Thread-safe.
public final class AppFocusProfileStore: @unchecked Sendable {
    private struct File: Codable {
        var version = 1
        var apps: [String: AppFocusProfile] = [:]
    }

    private let url: URL
    private let lock = NSLock()
    private var file: File

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: data) {
            file = f
        } else {
            file = File()
        }
    }

    public func profile(_ bundleId: String) -> AppFocusProfile? {
        lock.lock()
        defer { lock.unlock() }
        return file.apps[bundleId.lowercased()]
    }

    /// Apply `change`; persists only when something changed. Returns the new profile.
    @discardableResult
    public func update(_ bundleId: String, evidence: String? = nil, _ change: (inout AppFocusProfile) -> Void)
        -> AppFocusProfile
    {
        let key = bundleId.lowercased()
        lock.lock()
        defer { lock.unlock() }
        var p = file.apps[key] ?? AppFocusProfile()
        let before = p
        change(&p)
        guard p != before || (evidence != nil && p.evidence != evidence) else { return p }
        if let evidence { p.evidence = evidence }
        p.updatedAt = ISO8601DateFormatter().string(from: Date())
        file.apps[key] = p
        persist()
        return p
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(file) else { return }
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}

import AppKit
import ApplicationServices
import TurboCore
import Foundation

/// Turns on the full accessibility tree of apps that build it lazily
/// (Electron and Chromium apps): Chromium (and so Electron, CEF) exposes only empty
/// groups until an assistive client asks for more. Setting `AXManualAccessibility`
/// (Electron's documented switch) and `AXEnhancedUserInterface` (what VoiceOver sets)
/// on the application element makes it build the tree.
///
/// Both are set on the first observation of an app in a session, and again when its
/// tree looks empty (at most every `retryInterval`). Errors are ignored: most native
/// apps do not support `AXManualAccessibility`.
///
/// Both have side effects, so the helper remembers each one's previous value per pid and
/// puts it back when the last session that turned it on ends (`finishTurn`):
/// `AXEnhancedUserInterface` makes some apps animate window moves / resizes made through
/// accessibility, and either switch tells Chromium-based apps that an assistive technology
/// is running — VS Code then turns on its "Screen Reader Optimized" mode, which changes how
/// its editor behaves for the user.
final class AccessibilityEnabler {
    static let manualAttribute = "AXManualAccessibility"
    static let enhancedAttribute = "AXEnhancedUserInterface"
    /// Minimum time between two attempts for the same pid when its tree looks empty.
    static let retryInterval: TimeInterval = 5

    struct Outcome {
        /// Some attribute went from off/unset to on (the tree may now grow).
        let changed: Bool
        /// `AXManualAccessibility` went from off/unset to on: the app supports it, so it
        /// is a Chromium-based app whose tree is being built right now.
        let manualTurnedOn: Bool
    }

    private struct Record {
        /// `AXEnhancedUserInterface` before the helper first set it (nil = unset / unknown).
        var enhancedBefore: Bool?
        /// The helper changed `AXEnhancedUserInterface` (so it restores it).
        var enhancedChanged = false
        /// `AXManualAccessibility` before the helper first set it, and whether it changed it.
        var manualBefore: Bool?
        var manualChanged = false
        /// Sessions that observed this pid since it was enabled.
        var sessions: Set<String> = []
        var lastAttempt = Date.distantPast
        /// Neither attribute can be set (a native app): no retries when its tree looks
        /// empty (an OpenGL / custom-drawn app like Blender always looks empty).
        var unsupported = false
        var kind: AppKind = .native
    }

    private let lock = NSLock()
    private var records: [pid_t: Record] = [:]

    /// Whether this session should (re)enable the app now: its first observation in the
    /// session, or its tree looked empty and the last attempt is `retryInterval` old.
    func shouldEnable(pid: pid_t, session: String, treeLooksEmpty: Bool, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let r = records[pid] else { return true }
        if !r.sessions.contains(session) { return true }
        return treeLooksEmpty && !r.unsupported && now.timeIntervalSince(r.lastAttempt) >= Self.retryInterval
    }

    /// Set both attributes to true on the application element.
    /// `kind` (detected from the bundle): Electron / Chromium get both attributes on
    /// first contact; other apps only `AXManualAccessibility` (harmless), and
    /// `AXEnhancedUserInterface` too only once their tree looks empty (it can make native
    /// apps animate window moves).
    @discardableResult
    func enable(pid: pid_t, session: String, appName: String, kind: AppKind = .native, treeLooksEmpty: Bool = false) -> Outcome {
        let app = AX.application(pid)
        let manualBefore = AX.bool(app, Self.manualAttribute)
        let enhancedBefore = AX.bool(app, Self.enhancedAttribute)
        let manualErr = AX.set(app, Self.manualAttribute, kCFBooleanTrue)
        let wantsEnhanced = kind.buildsTreeLazily || treeLooksEmpty
        let enhancedErr: AXError = wantsEnhanced ? AX.set(app, Self.enhancedAttribute, kCFBooleanTrue) : .attributeUnsupported
        let manualOn = manualErr == .success && manualBefore != true
        let enhancedOn = enhancedErr == .success && enhancedBefore != true
        lock.lock()
        var r = records[pid] ?? Record()
        if records[pid] == nil {
            r.enhancedBefore = enhancedBefore
            r.manualBefore = manualBefore
        }
        if enhancedOn { r.enhancedChanged = true }
        if manualOn { r.manualChanged = true }
        r.sessions.insert(session)
        r.lastAttempt = Date()
        r.unsupported = manualErr != .success && enhancedErr != .success && wantsEnhanced
        r.kind = kind
        records[pid] = r
        lock.unlock()
        Log.info(
            "accessibility: \(LogText.peer(appName)) pid \(pid) (\(kind.label)): AXManualAccessibility \(Self.describe(manualBefore)) → \(manualErr == .success ? "true" : "unsupported (\(manualErr.rawValue))"), AXEnhancedUserInterface \(Self.describe(enhancedBefore)) → \(!wantsEnhanced ? "not set (native app)" : enhancedErr == .success ? "true" : "unsupported (\(enhancedErr.rawValue))")"
        )
        return Outcome(changed: manualOn || enhancedOn, manualTurnedOn: manualOn)
    }

    /// Whether the helper turned the app's accessibility on (for the log).
    func isEnabled(pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return records[pid] != nil
    }

    /// `finishTurn` of `session`: put `AXEnhancedUserInterface` back for apps no other
    /// session still uses. Dead pids are forgotten.
    func sessionEnded(_ session: String) {
        lock.lock()
        var restore: [(pid_t, Bool)] = []
        var restoreManual: [(pid_t, Bool)] = []
        for (pid, var r) in records {
            if kill(pid, 0) != 0 && errno == ESRCH {
                records.removeValue(forKey: pid)
                continue
            }
            guard r.sessions.remove(session) != nil else { continue }
            if r.sessions.isEmpty {
                if r.enhancedChanged { restore.append((pid, r.enhancedBefore ?? false)) }
                if r.manualChanged { restoreManual.append((pid, r.manualBefore ?? false)) }
                // Forget it: the next session enables (and records) it afresh.
                records.removeValue(forKey: pid)
            } else {
                records[pid] = r
            }
        }
        lock.unlock()
        for (pid, value) in restoreManual {
            let err = AX.set(AX.application(pid), Self.manualAttribute, value ? kCFBooleanTrue : kCFBooleanFalse)
            Log.info("accessibility: pid \(pid): AXManualAccessibility restored to \(value) (AXError \(err.rawValue))")
        }
        // VoiceOver needs AXEnhancedUserInterface: never turn it off while it runs.
        if NSWorkspace.shared.isVoiceOverEnabled, !restore.isEmpty {
            Log.info("accessibility: VoiceOver is on; AXEnhancedUserInterface left on for \(restore.count) app(s)")
            return
        }
        for (pid, value) in restore {
            let err = AX.set(AX.application(pid), Self.enhancedAttribute, value ? kCFBooleanTrue : kCFBooleanFalse)
            Log.info("accessibility: pid \(pid): AXEnhancedUserInterface restored to \(value) (AXError \(err.rawValue))")
        }
    }

    private static func describe(_ b: Bool?) -> String { b.map { String($0) } ?? "unset" }
}

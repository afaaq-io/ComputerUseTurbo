import ApplicationServices
import TurboCore
import Foundation

/// Per-(session, app) state. Only touched while holding the service's work lock.
final class AppSessionState {
    let key: String
    var pid: pid_t
    let indexer: IdentityIndexer
    /// index → live element, from the latest read of this app.
    var elements: [Int: AXUIElement] = [:]
    /// Indices that were secure (password) fields when last read. fill_value /
    /// pick_text / write_text refuse them even if a live role re-check cannot be answered.
    var secureIndices: Set<Int> = []
    /// The window observed last (origin for screenshot coordinates). Only `observeApp`
    /// changes it: coordinates refer to the screenshot of the latest observation.
    var window: AXUIElement?
    var windowFrame: CGRect?
    /// Pixel space of x/y arguments from the latest observation (screenshot size and
    /// scale); nil = no window.
    var screenshotGeometry: ScreenshotGeometry?
    /// Where the helper last posted a mouse event for this app (global points): the
    /// start of the next hover approach when the pointer does not glide.
    var lastMousePoint: CGPoint?
    /// Thumbnail of the latest screenshot of this app (`ScreenshotChange`).
    var lastThumbnail: [UInt8]?
    /// Diff baseline (index → line) from the latest observation.
    var baseline: [Int: String]?
    /// `observeApp` has been done for this app in this session.
    var observed = false
    /// Some observation of this app in this session showed web content: actions wait
    /// for page loads.
    var webContentSeen = false
    /// Loading fingerprint (`PageLoadSignals.loadingFingerprint`) at which the latest
    /// page-load wait or observation ended with the page still loading; a later wait
    /// that sees exactly that load, unchanged, ends early (a page that never finishes).
    var stalledLoad: String?
    /// An action ran since the latest observation: the next `observeApp` settles first
    ///.
    var needsSettle = false
    /// Monotonic time the latest action returned.
    var lastActionEnd: TimeInterval = 0
    /// Monotonic time the latest observation started reading the app (user take-back:
    /// input after it means the observation may be stale).
    var lastObservedAt: TimeInterval?
    /// Key events posted to the app while it is in the background arrive (true), do not
    /// (false, verified on a text element), or not known yet (nil).
    var backgroundKeysWork: Bool?
    /// Indices of the menu bar as last listed (not "removed" when it is left out).
    var menuBarIndices: Set<Int> = []
    /// The app's process changed (relaunch, or a new instance such as Godot's editor
    /// replacing its project manager): the next observation lists the menu bar again.
    var menuBarNeeded = false
    /// The app's windows and sheets at the latest observation (`waitFor newWindow` counts
    /// what opened since then, also during the action before the wait).
    var windowsAtObservation: [AXUIElement]?

    init(key: String, pid: pid_t, counter: IndexCounter) {
        self.key = key
        self.pid = pid
        self.indexer = IdentityIndexer(counter: counter)
    }
}

/// Everything the helper remembers about one MCP session (`session.sessionId`).
final class SessionState {
    let id: String
    let counter: IndexCounter
    var apps: [String: AppSessionState] = [:]
    /// Password managers the user confirmed "For this task" (app keys).
    var approvals = Set<String>()
    var stopped = false
    var screenshots: [URL] = []
    var lastGatedRequest: Date?
    /// Foreground / background focus mode. Work lock only.
    var focus = FocusModeState()
    /// Last request of any kind (idle-session expiry).
    var lastRequest = Date()

    init(id: String, counter: IndexCounter = IndexCounter()) {
        self.id = id
        self.counter = counter
    }
}

/// Thread-safe registry of sessions.
final class SessionManager {
    private let lock = NSLock()
    private var sessions: [String: SessionState] = [:]
    /// Next index of sessions that expired while idle (`expireIdle`), so a session that
    /// comes back never gets an index it was handed before.
    private var retiredCounters: [String: Int] = [:]

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// The session (created on first use).
    func session(_ id: String) -> SessionState {
        locked { session(unlockedId: id) }
    }

    private func session(unlockedId id: String) -> SessionState {
        if let s = sessions[id] { return s }
        let start = retiredCounters.removeValue(forKey: id) ?? 0
        let s = SessionState(id: id, counter: IndexCounter(startingAt: start))
        sessions[id] = s
        return s
    }

    func appState(session: SessionState, key: String, pid: pid_t) -> AppSessionState {
        locked {
            if let a = session.apps[key] {
                if a.pid != pid {
                    // The app relaunched: element references are dead, but path keys
                    // (and therefore indices) stay valid for the session; every old live
                    // element is known to be gone, so the replacements inherit the indices
                    // without liveness checks.
                    a.pid = pid
                    a.indexer.forgetLiveElements()
                    a.elements = [:]
                    a.secureIndices = []
                    a.window = nil
                    a.screenshotGeometry = nil
                    a.lastMousePoint = nil
                    a.lastThumbnail = nil
                    a.backgroundKeysWork = nil
                    a.needsSettle = false
                    a.menuBarNeeded = true
                }
                return a
            }
            let a = AppSessionState(key: key, pid: pid, counter: session.counter)
            session.apps[key] = a
            return a
        }
    }

    func existingAppState(session: SessionState, key: String) -> AppSessionState? {
        locked { session.apps[key] }
    }

    func isStopped(_ id: String) -> Bool {
        locked { sessions[id]?.stopped ?? false }
    }

    /// Overlay Stop / Esc: every known session is stopped until it ends (finishTurn /
    /// reset). The agent is told to stop and ask the user; a new session starts fresh.
    func stopAll() {
        locked { for s in sessions.values { s.stopped = true } }
    }

    func hasApproval(_ id: String, key: String) -> Bool {
        locked { sessions[id]?.approvals.contains(key) ?? false }
    }

    func grantSessionApproval(_ id: String, key: String) {
        _ = locked { session(unlockedId: id).approvals.insert(key) }
    }

    func noteGatedRequest(_ id: String, at date: Date = Date()) {
        locked { session(unlockedId: id).lastGatedRequest = date }
    }

    /// Any request arrived for this session (only updates existing sessions).
    func touch(_ id: String, at date: Date = Date()) {
        locked { sessions[id]?.lastRequest = date }
    }

    func addScreenshot(_ id: String, url: URL) {
        locked { session(unlockedId: id).screenshots.append(url) }
    }

    /// Any session made a gated request within `seconds`.
    func anyActive(within seconds: TimeInterval, now: Date = Date()) -> Bool {
        locked {
            let cutoff = now.addingTimeInterval(-seconds)
            return sessions.values.contains { ($0.lastGatedRequest ?? .distantPast) > cutoff }
        }
    }

    var count: Int { locked { sessions.count } }

    /// `finishTurn` (keepApprovals false) / `reset` (true): drop element maps, baselines,
    /// observed flags, index numbering and the stop flag; returns screenshots to delete.
    func endTurn(_ id: String, keepApprovals: Bool) -> [URL] {
        locked {
            retiredCounters.removeValue(forKey: id)  // numbering restarts at 0
            guard let old = sessions.removeValue(forKey: id) else { return [] }
            if keepApprovals && !old.approvals.isEmpty {
                let fresh = SessionState(id: id)
                fresh.approvals = old.approvals
                sessions[id] = fresh
            }
            return old.screenshots
        }
    }

    /// Forget sessions with no request for `seconds` (their MCP server most likely died
    /// without sending finishTurn): frees their element maps and identity tables and
    /// returns their screenshots for deletion. A returning session must observe again
    /// (`observeFirst`), and its numbering continues where it stopped, so an old index
    /// can never name a different element.
    func expireIdle(olderThan seconds: TimeInterval, now: Date = Date()) -> (sessions: Int, screenshots: [URL]) {
        locked {
            let cutoff = now.addingTimeInterval(-seconds)
            let idle = sessions.values.filter { $0.lastRequest < cutoff }
            var files: [URL] = []
            for s in idle {
                sessions.removeValue(forKey: s.id)
                retiredCounters[s.id] = s.counter.next
                files.append(contentsOf: s.screenshots)
            }
            return (idle.count, files)
        }
    }
}

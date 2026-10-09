import ApplicationServices
import TurboCore
import Foundation

/// Accessibility notifications per target app: one
/// `AXObserver` per pid, registered on the application element (which delivers the
/// notifications of all its elements), its run-loop source on the main run loop. Keeps the
/// time of the latest notification (settle, `waitFor` wake-ups) and a short log of the
/// telling ones, described only when read ("since your last look").
final class ActivityObserver {
    static let notifications: [String] = [
        kAXValueChangedNotification, kAXUIElementDestroyedNotification, kAXCreatedNotification,
        kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification,
        kAXTitleChangedNotification, kAXSelectedChildrenChangedNotification, kAXSelectedTextChangedNotification,
        kAXMenuOpenedNotification, kAXMenuClosedNotification, kAXRowCountChangedNotification,
        kAXLayoutChangedNotification, "AXElementBusyChanged", "AXLoadComplete", kAXSheetCreatedNotification,
        "AXAnnouncementRequested",
    ]

    /// Notifications worth telling the agent about (the rest only wake waits).
    static let logged: Set<String> = [
        kAXValueChangedNotification, kAXFocusedUIElementChangedNotification, kAXWindowCreatedNotification,
        kAXTitleChangedNotification, kAXSelectedChildrenChangedNotification, kAXMenuOpenedNotification,
        kAXMenuClosedNotification, "AXLoadComplete", kAXSheetCreatedNotification, "AXAnnouncementRequested",
    ]
    static let maxLogged = 400

    /// One logged notification, described when read.
    private struct Raw {
        var at: TimeInterval
        let name: String
        let element: AXUIElement
        let announcement: String?
    }

    private final class Entry {
        let observer: AXObserver
        let app: AXUIElement
        let registered: Int
        init(observer: AXObserver, app: AXUIElement, registered: Int) {
            self.observer = observer
            self.app = app
            self.registered = registered
        }
    }

    private let lock = NSLock()
    private var entries: [pid_t: Entry] = [:]
    private var last: [pid_t: TimeInterval] = [:]
    /// Pids whose observer could not be created (no retry for 30 s).
    private var failed: [pid_t: TimeInterval] = [:]

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Make sure notifications of `pid` are being observed. Returns whether they are.
    @discardableResult
    func ensure(pid: pid_t) -> Bool {
        lock.lock()
        if entries[pid] != nil {
            lock.unlock()
            return true
        }
        if let f = failed[pid], Self.now() - f < 30 {
            lock.unlock()
            return false
        }
        lock.unlock()
        pruneDead()

        var observer: AXObserver?
        let callback: AXObserverCallbackWithInfo = { _, element, name, info, refcon in
            guard let refcon else { return }
            let box = Unmanaged<PidBox>.fromOpaque(refcon).takeUnretainedValue()
            let n = name as String
            var announcement: String?
            if n == "AXAnnouncementRequested", let dict = info as? [String: Any] {
                announcement = dict["AXAnnouncementKey"] as? String
            }
            box.owner?.noteNotification(pid: box.pid, name: n, element: element, announcement: announcement)
        }
        guard AXObserverCreateWithInfoCallback(pid, callback, &observer) == .success, let observer else {
            lock.lock()
            failed[pid] = Self.now()
            lock.unlock()
            return false
        }
        let app = AX.application(pid)
        let box = PidBox(pid: pid, owner: self)
        let refcon = Unmanaged.passRetained(box).toOpaque()
        var registered = 0
        for n in Self.notifications where AXObserverAddNotification(observer, app, n as CFString, refcon) == .success {
            registered += 1
        }
        guard registered > 0 else {
            Unmanaged<PidBox>.fromOpaque(refcon).release()
            lock.lock()
            failed[pid] = Self.now()
            lock.unlock()
            Log.info("settle: no accessibility notifications available for pid \(pid)")
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        lock.lock()
        entries[pid] = Entry(observer: observer, app: app, registered: registered)
        boxes[pid] = refcon
        lock.unlock()
        Log.info("settle: observing \(registered) accessibility notification type(s) of pid \(pid)")
        return true
    }

    private var boxes: [pid_t: UnsafeMutableRawPointer] = [:]

    private final class PidBox {
        let pid: pid_t
        weak var owner: ActivityObserver?
        init(pid: pid_t, owner: ActivityObserver) {
            self.pid = pid
            self.owner = owner
        }
    }

    private var logs: [pid_t: [Raw]] = [:]
    private let wake = NSCondition()

    fileprivate func noteNotification(pid: pid_t, name: String, element: AXUIElement, announcement: String?) {
        let now = Self.now()
        lock.lock()
        last[pid] = now
        if Self.logged.contains(name) {
            var log = logs[pid] ?? []
            // A value / title that keeps changing (typing, a progress bar) is one entry.
            if name == kAXValueChangedNotification || name == kAXTitleChangedNotification || name == kAXFocusedUIElementChangedNotification,
                let i = log.lastIndex(where: { $0.name == name && (name == kAXFocusedUIElementChangedNotification || CFEqual($0.element, element)) })
            {
                log.remove(at: i)
            }
            log.append(Raw(at: now, name: name, element: element, announcement: announcement))
            if log.count > Self.maxLogged { log.removeFirst(log.count - Self.maxLogged) }
            logs[pid] = log
        }
        lock.unlock()
        wake.lock()
        wake.broadcast()
        wake.unlock()
    }

    /// Wait (≤ `timeout`) for a notification from `pid` newer than `after`. Returns whether one came.
    func waitForNotification(pid: pid_t, after: TimeInterval, timeout: TimeInterval) -> Bool {
        let until = Date().addingTimeInterval(max(0, timeout))
        wake.lock()
        defer { wake.unlock() }
        while true {
            if let t = lastNotification(pid: pid), t > after { return true }
            if !wake.wait(until: until) { return lastNotification(pid: pid).map { $0 > after } ?? false }
        }
    }

    /// The logged events of `pid` since `since` (monotonic), described now. Password field
    /// values are never read.
    func events(pid: pid_t, since: TimeInterval) -> [UIEventRecord] {
        lock.lock()
        let raws = (logs[pid] ?? []).filter { $0.at > since }
        lock.unlock()
        return raws.suffix(60).compactMap(Self.describe)
    }

    private static func describe(_ raw: Raw) -> UIEventRecord? {
        let el = raw.element
        AXUIElementSetMessagingTimeout(el, 0.25)
        let (_, v) = AX.multiple(el, [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute])
        let role = AX.stringValue(v[kAXRoleAttribute])
        let subrole = AX.stringValue(v[kAXSubroleAttribute])
        let secure = role == AXRoles.secureTextField || subrole == AXRoles.secureTextField
        let label = (AX.stringValue(v[kAXTitleAttribute])).flatMap { $0.isEmpty ? nil : $0 } ?? AX.stringValue(v[kAXDescriptionAttribute])
        func what() -> String? {
            guard let role else { return label.map { "\"\(TreeFormat.clean($0, limit: 60))\"" } }
            let r = TreeFormat.roleText(role: role, subrole: subrole)
            guard let label, !label.isEmpty else { return r }
            return "\(r) \"\(TreeFormat.clean(label, limit: 60))\""
        }
        let value = secure ? nil : AX.nodeValue(v[kAXValueAttribute]).map(\.text)
        switch raw.name {
        case kAXWindowCreatedNotification:
            if let size = AX.size(el), WindowSize.isIncidental(width: Double(size.width), height: Double(size.height)) { return nil }
            let dialog = subrole == "AXDialog" || subrole == "AXSystemDialog" || role == "AXSheet"
            return UIEventRecord(at: raw.at, kind: dialog ? .dialogOpened : .windowOpened, what: label.map { "\"\(TreeFormat.clean($0, limit: 60))\"" })
        case kAXSheetCreatedNotification:
            return UIEventRecord(at: raw.at, kind: .dialogOpened, what: label.map { "sheet \"\(TreeFormat.clean($0, limit: 60))\"" } ?? "sheet")
        case kAXFocusedUIElementChangedNotification:
            guard role != nil else { return nil }
            return UIEventRecord(at: raw.at, kind: .focusMoved, what: what())
        case kAXValueChangedNotification:
            guard role != nil, !secure else { return nil }
            return UIEventRecord(at: raw.at, kind: .valueChanged, what: what(), detail: value)
        case kAXTitleChangedNotification:
            guard let role else { return nil }
            return UIEventRecord(at: raw.at, kind: .titleChanged, what: TreeFormat.roleText(role: role, subrole: subrole), detail: label)
        case kAXSelectedChildrenChangedNotification:
            guard role != nil else { return nil }
            return UIEventRecord(at: raw.at, kind: .selectionChanged, what: what())
        case kAXMenuOpenedNotification:
            return UIEventRecord(at: raw.at, kind: .menuOpened, what: label.map { "\"\(TreeFormat.clean($0, limit: 60))\"" })
        case kAXMenuClosedNotification:
            return UIEventRecord(at: raw.at, kind: .menuClosed)
        case "AXLoadComplete":
            return UIEventRecord(at: raw.at, kind: .pageLoaded, what: label.map { "\"\(TreeFormat.clean($0, limit: 60))\"" })
        case "AXAnnouncementRequested":
            guard let text = raw.announcement, !text.isEmpty else { return nil }
            return UIEventRecord(at: raw.at, kind: .announcement, detail: text)
        default:
            return nil
        }
    }

    /// Monotonic time of the latest notification from `pid` (nil = none yet).
    func lastNotification(pid: pid_t) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return last[pid]
    }

    /// Forget observers of processes that exited.
    func pruneDead() {
        lock.lock()
        let dead = entries.keys.filter { kill($0, 0) != 0 && errno == ESRCH }
        var removed: [(Entry, UnsafeMutableRawPointer?)] = []
        for pid in dead {
            if let e = entries.removeValue(forKey: pid) { removed.append((e, boxes.removeValue(forKey: pid))) }
            last.removeValue(forKey: pid)
            logs.removeValue(forKey: pid)
        }
        lock.unlock()
        for (e, box) in removed {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(e.observer), .commonModes)
            if let box { Unmanaged<PidBox>.fromOpaque(box).release() }
        }
    }
}

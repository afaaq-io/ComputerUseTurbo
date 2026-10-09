import AppKit
import ImageIO
import ApplicationServices
import TurboCore
import Foundation

// Waiting for a change and settling after actions.
extension HelperService {
    /// State of one `waitFor` across its checks.
    final class WaitProbe {
        let condition: WaitCondition
        var pid: pid_t = 0
        var started: TimeInterval = 0
        var lastCheck: TimeInterval = 0
        var baselineWindows: [AXUIElement]?
        var baselineElement: String?
        var baselineTexts: String?
        /// The window's picture (live feed thumbnail) when the wait began.
        var baselinePicture: [UInt8]?
        var matched = false
        var detail = ""
        init(_ condition: WaitCondition) { self.condition = condition }
    }

    /// How long menu items keep the state they had in front after the front was handed back.
    static let staleMenuStateSeconds: TimeInterval = 1.5

    /// `waitFor {app, until, text?, elementNumber?, timeoutMs?}`: check the condition, then
    /// again after each burst of the app's accessibility notifications (at least every
    /// 0.5 s) until it holds or the time is up. Each check runs the full safety pipeline
    /// (Stop ends the wait); the work lock is not held between checks.
    func waitFor(_ env: RequestEnvelope) throws -> JSONValue {
        let probe = WaitProbe(try WaitCondition.parse(env.payload))
        let timeout = Double(try WaitCondition.timeoutMs(env.payload)) / 1000
        let deadline = RequestDeadline(unixMillis: env.deadlineUnixMillis)
        let begin = ProcessInfo.processInfo.systemUptime
        let until = begin + min(timeout, max(0.2, Self.secondsLeft(deadline) - 2))
        while true {
            _ = try gated(env, probe: probe)
            let now = ProcessInfo.processInfo.systemUptime
            if probe.matched || now >= until { break }
            let pause = probe.condition == .settled ? 0.2 : 0.5
            _ = activity.waitForNotification(pid: probe.pid, after: probe.lastCheck, timeout: min(pause, until - now))
            if probe.condition != .settled { usleep(120_000) }  // let a burst of changes finish
        }
        let waited = ProcessInfo.processInfo.systemUptime - begin
        let events = UIEventSummary.lines(activity.events(pid: probe.pid, since: probe.started), limit: 15)
        Log.info("waitFor \(probe.condition): \(probe.matched ? "matched" : "timed out") after \(Int(waited * 1000)) ms")
        return [
            "matched": .bool(probe.matched), "waitedMs": .int(Int(waited * 1000)), "detail": .string(probe.detail),
            "events": .array(events.map { .string($0) }),
        ]
    }

    /// One check of a `waitFor` (under the work lock, after the safety pipeline).
    func check(_ probe: WaitProbe, session: SessionState, resolved: ResolvedApp, policy: PolicyEvaluation) throws
        -> JSONValue
    {
        guard let pid = resolved.pid else { throw TurboError(.observeFirst, "\(resolved.name) is not running; call observe_app.") }
        let app = sessions.appState(session: session, key: resolved.key, pid: pid)
        let now = ProcessInfo.processInfo.systemUptime
        let first = probe.started == 0
        if first {
            probe.pid = pid
            probe.started = now
            activity.ensure(pid: pid)
        }
        defer { probe.lastCheck = now }
        let hideForeign = foreignOwnerFilter(hostRisk: policy.risk)
        func texts() -> [String] {
            WaitCondition.texts(reader.snapshot(pid: pid, hideForeign: hideForeign, scope: ObservationScope(keyWindowOnly: false, includeMenuBar: false)).roots)
        }
        func elementState(_ index: Int) throws -> String? {
            guard let el = try? element(index, app: app, pid: pid, policy: policy) else { return nil }
            let (_, v) = AX.multiple(el, [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXEnabledAttribute, kAXSelectedAttribute])
            let value = AX.isSecure(el) ? "" : (AX.nodeValue(v[kAXValueAttribute])?.text ?? "")
            return [AX.stringValue(v[kAXTitleAttribute]) ?? "", AX.stringValue(v[kAXDescriptionAttribute]) ?? "", value,
                "\(AX.boolValue(v[kAXEnabledAttribute]) ?? true)", "\(AX.boolValue(v[kAXSelectedAttribute]) ?? false)"].joined(separator: "|")
        }
        switch probe.condition {
        case .textAppears(let t):
            if texts().contains(where: { WaitCondition.contains($0, t) }) {
                probe.matched = true
                probe.detail = "\"\(TreeFormat.clean(t, limit: 80))\" is shown in \(resolved.name)."
            }
        case .textGone(let t):
            if !texts().contains(where: { WaitCondition.contains($0, t) }) {
                probe.matched = true
                probe.detail = "\"\(TreeFormat.clean(t, limit: 80))\" is no longer shown in \(resolved.name)."
            }
        case .elementChanges(let index):
            let state = try elementState(index)
            if first {
                guard state != nil else { throw TurboError.elementInvalid(index) }
                probe.baselineElement = state
            } else if state != probe.baselineElement {
                probe.matched = true
                probe.detail = state == nil ? "#\(index) is gone." : "#\(index) changed."
            }
        case .newWindow:
            let windows = Self.windowsAndSheets(pid: pid)
            // Since the latest observation: a window the previous action opened counts.
            let since = app.lastObservedAt ?? probe.started
            if first, probe.baselineWindows == nil {
                probe.baselineWindows = app.windowsAtObservation ?? windows
            }
            if let fresh = windows.first(where: { w in !(probe.baselineWindows ?? []).contains(where: { CFEqual($0, w) }) }) {
                probe.matched = true
                let title = AX.string(fresh, kAXTitleAttribute).flatMap { $0.isEmpty ? nil : $0 }
                probe.detail = "A new window opened in \(resolved.name)\(title.map { ": \"\(TreeFormat.clean($0, limit: 80))\"" } ?? "")."
            } else if activity.events(pid: pid, since: since).contains(where: { $0.kind == .dialogOpened || $0.kind == .windowOpened }) {
                probe.matched = true
                probe.detail = "A window or dialog opened in \(resolved.name)."
            }
        case .settled:
            let quietFor = now - max(activity.lastNotification(pid: pid) ?? 0, app.lastActionEnd)
            let loading = PageLoadProbe.scan(windows: Self.loadWindows(pid: pid, observed: app.window)).isLoading
            if !first, quietFor >= 1.0, !loading {
                probe.matched = true
                probe.detail = "\(resolved.name) has been quiet for \(String(format: "%.1f", quietFor)) s."
            }
        case .anyChange:
            let joined = texts().joined(separator: "\u{1F}")
            // Apps that draw their own UI change only in pixels: compare the window's
            // picture too (the live feed's newest frame; nothing when no feed runs).
            let picture = WindowFeeds.shared.latest(pid: pid).flatMap { Screenshotter.thumbnail($0.0) }
            if first {
                probe.baselineTexts = joined
                probe.baselinePicture = picture
            } else if let before = probe.baselinePicture, let picture,
                let changed = ScreenshotChange.fraction(previous: before, current: picture), changed >= 0.02
            {
                probe.matched = true
                probe.detail = "The window of \(resolved.name) changed (≈\(max(1, Int((changed * 100).rounded())))% of the picture)."
            } else if joined != probe.baselineTexts {
                probe.matched = true
                probe.detail = "The content of \(resolved.name) changed."
            } else if let e = activity.events(pid: pid, since: probe.started).first(where: { $0.kind != .focusMoved }) {
                probe.matched = true
                probe.detail = "Something changed in \(resolved.name): \(e.line)."
            }
        }
        return ["matched": .bool(probe.matched)]
    }

    /// Chromium / Electron apps: commands and shortcuts act on their active window, which
    /// they have only while in front.
    static func actsOnActiveWindow(pid: pid_t) -> Bool {
        guard let path = NSRunningApplication(processIdentifier: pid)?.bundleURL?.path else { return false }
        return AppKindCache.kind(path: path).buildsTreeLazily
    }

    /// "A new window opened: "Welcome"…" when the command opened one (said so the agent
    /// notices a command that acted on a new window instead of the one it meant).
    static func newWindowNote(before: [AXUIElement], pid: pid_t, app: String) -> String? {
        usleep(300_000)
        let fresh = windowsAndSheets(pid: pid).filter { w in !before.contains(where: { CFEqual($0, w) }) }
        guard let w = fresh.first else { return nil }
        let title = AX.string(w, kAXTitleAttribute).flatMap { $0.isEmpty ? nil : "\"\(TreeFormat.clean($0, limit: 60))\"" } ?? "(untitled)"
        return "A new window or sheet opened: \(title). If the command was meant for a window that was already open, observe_app and check where it acted."
    }

    /// The app's windows and the sheets attached to them (a sheet is not in AXWindows),
    /// leaving out small helper windows (floating icons and badges such as the Writing Tools
    /// button), which are not windows the user works in.
    static func windowsAndSheets(pid: pid_t) -> [AXUIElement] {
        let windows = (AX.elements(AX.application(pid), kAXWindowsAttribute) ?? []).filter { !isIncidentalWindow($0) }
        var out = windows
        for w in windows {
            for child in AX.elements(w, kAXChildrenAttribute) ?? [] where AX.string(child, kAXRoleAttribute) == "AXSheet" {
                out.append(child)
            }
        }
        return out
    }

    static func isIncidentalWindow(_ w: AXUIElement) -> Bool {
        guard let size = AX.size(w) else { return false }
        return WindowSize.isIncidental(width: Double(size.width), height: Double(size.height))
    }

    /// Frame of the sheet attached to the app's focused window, if one is open (it has the
    /// keyboard and the mouse of that window).
    static func sheetFrame(pid: pid_t) -> CGRect? {
        guard let window = AX.element(AX.application(pid), kAXFocusedWindowAttribute) else { return nil }
        for child in AX.elements(window, kAXChildrenAttribute) ?? [] where AX.string(child, kAXRoleAttribute) == "AXSheet" {
            if let f = AX.frame(child), f.width > 0, f.height > 0 { return f }
        }
        return nil
    }

    /// Frame of the dialog surface that has the app's keyboard (`DialogSurface`): a sheet, or
    /// a window without title-bar buttons.
    static func dialogSurfaceFrame(pid: pid_t) -> CGRect? {
        let app = AX.application(pid)
        func isDialogWindow(_ w: AXUIElement) -> Bool {
            guard AX.string(w, kAXRoleAttribute) == AXRoles.window, !isIncidentalWindow(w) else { return false }
            let (_, v) = AX.multiple(w, [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute])
            return DialogSurface.isDialogWindow(
                hasClose: v[kAXCloseButtonAttribute] != nil, hasMinimize: v[kAXMinimizeButtonAttribute] != nil,
                hasZoom: v[kAXZoomButtonAttribute] != nil)
        }
        func surface(in window: AXUIElement) -> CGRect? {
            for child in AX.elements(window, kAXChildrenAttribute) ?? [] where AX.string(child, kAXRoleAttribute) == "AXSheet" {
                return AX.frame(child)
            }
            return isDialogWindow(window) ? AX.frame(window) : nil
        }
        // 1. The keyboard focus is inside a sheet or a dialog window (also a sheet of one,
        // such as a file panel's "Go to Folder" box).
        if var el = AX.focusedElement(pid: pid) {
            for _ in 0..<40 {
                let role = AX.string(el, kAXRoleAttribute)
                if role == "AXSheet" { return AX.frame(el) }
                if role == AXRoles.window { return isDialogWindow(el) ? AX.frame(el) : nil }
                guard let parent = AX.element(el, kAXParentAttribute) else { break }
                el = parent
            }
        }
        // 2. The focused window. 3. While the app is in the background the focus may not be
        // reported: its main window decides.
        for key in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let window = AX.element(app, key) { return surface(in: window) }
        }
        return nil
    }

    /// A click in a dialog or sheet that an accessibility action cannot do: its content may be
    /// drawn by another process that events posted to the app never reach, so this
    /// is a real click — the app in front (borrowed while the user is idle), the real pointer
    /// moved there and put back right after.
    /// A click with the real mouse, the app in front (input posted to the app does not reach
    /// it): in a system dialog / sheet of the app, or on a canvas that takes only real clicks.
    func clickInDialog(
        at point: CGPoint, label: String, button: MouseButton, count: Int, _ c: ActionContext, canvas: Bool = false
    ) throws -> String {
        let place = canvas ? "on the canvas of \(c.name)" : "in the dialog or sheet of \(c.name)"
        try borrowFront(c, what: "clicking \(place) (input posted to the app does not reach it)")
        guard BorrowFrontPolicy.userIdle(secondsSinceKeyboard: UserInput.keyboard, secondsSinceMouse: UserInput.mouse) else {
            throw TurboError(.userActive, FocusModeText.borrowBusyMessage(app: c.name, what: "clicking \(place) with the real mouse"))
        }
        try travel(c, to: point, moving: PointerLabel.moving(to: label), arrived: PointerLabel.clicking(label))
        let saved = CGEvent(source: nil)?.location
        input.routeThroughSystem = true
        defer {
            input.routeThroughSystem = false
            if let saved {
                CGWarpMouseCursorPosition(saved)
                CGAssociateMouseAndMouseCursorPosition(1)
            }
        }
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
        usleep(60_000)
        try input.click(at: point, button: button, count: count, pid: c.pid, window: nil)
        usleep(80_000)
        c.app.lastMousePoint = point
        pointer?.press()
        let what = count == 1 ? "click" : "\(count)-click"
        return "Clicked (\(what)) \(place) with the real mouse at screen point (\(GeometryGuard.displayInt(point.x)), \(GeometryGuard.displayInt(point.y))), \(c.name) in front; your pointer was put back."
    }

    // MARK: - Settle

    /// Before an observation that follows an action: wait until the app's accessibility
    /// notifications have been quiet (`SettlePolicy`), bounded by the request deadline and
    /// ended early by the user's Stop / a screen lock.
    func settleBeforeObservation(
        pid: pid_t, app: AppSessionState, observing: Bool, deadline: RequestDeadline, interrupted: () -> Bool
    ) {
        let settings = SettleSettings.load(paths.settings)
        let started = ProcessInfo.processInfo.systemUptime
        let limit = started + max(0, Self.secondsLeft(deadline) - 3)
        var reason = SettleReason.base
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            if interrupted() || now >= limit { break }
            switch SettlePolicy.next(
                now: now, actionEnded: app.lastActionEnd, lastNotification: activity.lastNotification(pid: pid),
                observing: observing, settings: settings)
            {
            case .done(let r):
                reason = r
            case .wait(let t):
                usleep(useconds_t(max(0.01, min(t, limit - now)) * 1_000_000))
                continue
            }
            break
        }
        app.needsSettle = false
        let waited = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
        let since = Int((ProcessInfo.processInfo.systemUptime - app.lastActionEnd) * 1000)
        Log.info("settle: pid \(pid) waited \(waited) ms (\(since) ms after the action; \(observing ? reason.rawValue : "no notifications, base"))")
    }
}

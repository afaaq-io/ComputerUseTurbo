import AppKit
import ImageIO
import ApplicationServices
import TurboCore
import Foundation

// Observing an app: the tree, the screenshot and what changed since the last look.
extension HelperService {
    func observeApp(
        env: RequestEnvelope, session: SessionState, resolved: inout ResolvedApp, policy: PolicyEvaluation,
        deadline: RequestDeadline
    ) throws -> JSONValue {
        let fullTree = env.payload["fullTree"]?.boolValue ?? false
        let includeScreenshot = env.payload["includeScreenshot"]?.boolValue ?? true

        var launchedNow = false
        if resolved.runningApplication == nil {
            resolved = try launch(resolved)
            launchedNow = true
        }
        guard let pid = resolved.pid else { throw TurboError(.helperFault, "Launched app has no pid.") }
        try deadline.check("after launching the app")

        let appState = sessions.appState(session: session, key: resolved.key, pid: pid)
        // Apps that only work in front are shown there while the agent looks at them.
        forceFrontIfNeeded(pid: pid, app: appState, name: resolved.name)
        let sessionId = env.sessionId
        let interrupted: () -> Bool = { [sessions] in
            sessions.isStopped(sessionId) || SystemState.isScreenLocked || deadline.isExpired()
        }
        let hideForeign = foreignOwnerFilter(hostRisk: policy.risk)
        // Accessibility notifications of the app drive the settle wait.
        let observing = activity.ensure(pid: pid)
        if appState.needsSettle {
            settleBeforeObservation(pid: pid, app: appState, observing: observing, deadline: deadline, interrupted: interrupted)
        }
        // Observation scope: the key window and what is attached to it; the menu bar
        // on the first observation of the app in the session (and whenever a menu is open).
        var scope = ObservationScope(keyWindowOnly: true, includeMenuBar: !appState.observed || appState.menuBarNeeded)
        scope.listSurfaces = fullTree
        appState.menuBarNeeded = false
        let kind = AppKindCache.kind(path: resolved.path)
        // Electron / Chromium build their accessibility tree only when asked: turn
        // it on at the first observation of the app in this session.
        var enabled: AccessibilityEnabler.Outcome?
        if axEnabler.shouldEnable(pid: pid, session: sessionId, treeLooksEmpty: false) {
            enabled = axEnabler.enable(pid: pid, session: sessionId, appName: resolved.name, kind: kind)
        }
        let readStarted = ProcessInfo.processInfo.systemUptime
        // A page that is still loading would show the previous page or half of the new
        // one: wait (bounded) for web content to finish before taking the snapshot.
        var loadWait: TimeInterval = 0
        // A load that an earlier wait already gave up on, unchanged since then, is not
        // waited for again in full (a page that never finishes loading).
        var stalledFor: TimeInterval?
        let loadBudget = min(PageLoadPolicy.observationBudget, Self.secondsLeft(deadline) - 3)
        if loadBudget > 0, PageLoadPolicy.shouldProbe(webContentSeen: appState.webContentSeen, isWebBrowser: AppKindCache.isWebBrowser(path: resolved.path)) {
            let observed = appState.window
            let r = PageLoadProbe.waitUntilLoaded(
                windows: { Self.loadWindows(pid: pid, observed: observed) }, budget: loadBudget,
                baseline: appState.stalledLoad, interrupted: interrupted)
            loadWait = r.waited
            if case .stalled(let unchanged) = r.verdict { stalledFor = unchanged }
        }
        var snapshot = reader.snapshot(pid: pid, hideForeign: hideForeign, scope: scope)
        if snapshot.pageLoad.isLoading, stalledFor == nil, loadBudget - loadWait >= PageLoadPolicy.pollInterval {
            // Not probed before (an app not yet known to show web content), or the page
            // started loading meanwhile.
            let windows = [snapshot.window, snapshot.focusedWindow].compactMap { $0 }
            let r = PageLoadProbe.waitUntilLoaded(
                windows: { windows }, budget: loadBudget - loadWait, baseline: appState.stalledLoad,
                interrupted: interrupted)
            loadWait += r.waited
            if case .stalled(let unchanged) = r.verdict { stalledFor = unchanged }
            snapshot = reader.snapshot(pid: pid, hideForeign: hideForeign, scope: scope)
        }
        let starting =
            launchedNow || Self.isStarting(resolved.runningApplication ?? NSRunningApplication(processIdentifier: pid))
        snapshot = fillAccessibilityTree(
            snapshot, pid: pid, sessionId: sessionId, appName: resolved.name, enabled: enabled, kind: kind,
            budget: starting || kind.buildsTreeLazily ? Self.readinessWait : Self.treeFillWait, hideForeign: hideForeign, scope: scope,
            interrupted: interrupted)

        // Screenshot, waiting (≤ 3 s) for an app that is still starting to show a
        // capturable, non-blank window.
        var notes: [String] = []
        let wantShot = includeScreenshot && Permissions.screenRecording
        let related = Screenshotter.relatedPids(of: pid, appPath: resolved.path)
        var shot: Screenshot?
        var shotGeometry: ScreenshotGeometry?
        func captureNow() {
            if let old = shot { try? FileManager.default.removeItem(at: old.url) }
            shot = nil
            guard let frame = snapshot.windowFrame else { return }
            let g = ScreenshotScale.fit(width: Double(frame.width), height: Double(frame.height))
            shotGeometry = g
            if wantShot { shot = screenshotter.capture(pid: pid, frame: frame, geometry: g, relatedPids: related) }
        }
        captureNow()
        func ready() -> Bool {
            snapshot.windowFrame != nil && (!wantShot || (shot.map { !$0.possiblyBlank } ?? false))
        }
        var stillStarting = false
        if !ready(), starting {
            let started = Date()
            let until = started.addingTimeInterval(min(Self.readinessWait, max(0, Self.secondsLeft(deadline) - 3)))
            while !ready(), Date() < until, !interrupted() {
                usleep(250_000)
                if snapshot.windowFrame == nil {
                    snapshot = reader.snapshot(pid: pid, hideForeign: hideForeign, scope: scope)
                } else if let w = snapshot.window, let f = AX.frame(w), f.width > 0, f.height > 0 {
                    snapshot.windowFrame = f
                }
                captureNow()
            }
            stillStarting = !ready()
            Log.info(
                "observeApp \(resolved.bundleId): waited \(Int(Date().timeIntervalSince(started) * 1000)) ms for the starting app's window (\(stillStarting ? "not ready" : "ready"))")
        }
        appState.stalledLoad = snapshot.pageLoad.loadingFingerprint
        if snapshot.pageLoad.hasWebContent || snapshot.roots.contains(where: Self.containsWebArea) {
            appState.webContentSeen = true
        }
        let tree = serialize(snapshot, app: appState)
        applyElementMap(tree, snapshot, to: appState)
        // The observed window is the origin of screenshot coordinates; it changes
        // only here, on a new observation, together with the pixel space of x/y.
        appState.window = snapshot.window
        appState.windowFrame = snapshot.windowFrame
        appState.screenshotGeometry = snapshot.windowFrame == nil ? nil : shotGeometry

        if let stalledFor, snapshot.pageLoad.isLoading {
            notes.append(PageLoadPolicy.stalledObservationNote(unchangedFor: stalledFor))
        }
        var window: WindowSummary?
        if let frame = snapshot.windowFrame {
            window = WindowSummary(
                title: snapshot.windowTitle, x: GeometryGuard.displayInt(frame.minX),
                y: GeometryGuard.displayInt(frame.minY), width: GeometryGuard.displayInt(frame.width),
                height: GeometryGuard.displayInt(frame.height))
            if includeScreenshot {
                if !Permissions.screenRecording {
                    notes.append(
                        "Note: Screen Recording permission is not granted, so no screenshot was captured; element-index and coordinate actions still work."
                    )
                } else if let s = shot {
                    sessions.addScreenshot(env.sessionId, url: s.url)
                    if s.possiblyBlank {
                        notes.append(
                            stillStarting
                                ? "Note: \(resolved.name) is still starting; the screenshot may be blank (app still rendering?). Observe again."
                                : "Note: the screenshot may be blank (app still rendering?); observe again, or rely on the accessibility tree.")
                    }
                } else if stillStarting {
                    notes.append("Note: \(resolved.name) is still starting (its window could not be captured yet); observe again.")
                } else {
                    notes.append("Note: the window could not be captured (it may be off-screen or on another Space).")
                }
            }
        } else if stillStarting {
            notes.append("Note: \(resolved.name) is still starting (no window yet); observe again.")
        } else {
            // Windows that exist but are not on screen (hidden, minimized, closed to the menu
            // bar / Dock): name them and say how to bring one back.
            let hidden = snapshot.roots.filter { $0.role == AXRoles.window }
            let background = resolved.runningApplication.map { $0.activationPolicy != .regular } ?? false
            if background, snapshot.roots.contains(where: { $0.role == AXRoles.menuBar && $0.title == "status items" }) {
                notes.append(
                    "Note: \(resolved.name) runs in the background; what it shows is its status items in the menu bar (listed below). Click one to open its menu or panel, then observe the app that owns the panel (find_apps lists it).")
            } else if hidden.isEmpty {
                notes.append("Note: \(resolved.name) has no on-screen window, so there is no screenshot.")
            } else {
                let names = hidden.prefix(3).map { "\"\(TreeFormat.clean($0.title ?? "untitled", limit: 50))\"" }.joined(separator: ", ")
                notes.append(
                    "Note: \(resolved.name) has no window on screen; it has \(hidden.count) hidden or minimized window(s) (\(names)), which show nothing until brought back. Try invoke_action \"Raise\" on one, or a command from its Window menu (find_command \"window\"), then observe again.")
            }
        }

        var trailers: [String] = []
        if snapshot.cutShort {
            trailers.append("… accessibility read stopped early (very large or unresponsive app); act on visible elements or scroll")
        }

        // Cheap "did the picture change" signal for the diff: this screenshot vs the
        // previous one of this app in this session.
        var screenshotChange: Double?
        if let thumb = shot?.thumbnail, let page = BlankPageArea.pageFrame(snapshot.roots), let wf = snapshot.windowFrame,
            wf.width > 0, wf.height > 0,
            BlankPageArea.isBlank(
                thumbnail: thumb, side: ScreenshotChange.side,
                region: (
                    (page.x - wf.minX) / wf.width, (page.y - wf.minY) / wf.height, (page.x + page.width - wf.minX) / wf.width,
                    (page.y + page.height - wf.minY) / wf.height
                ))
        {
            notes.append(BlankPageArea.note)
        }
        if let thumb = shot?.thumbnail {
            if appState.observed, let previous = appState.lastThumbnail {
                screenshotChange = ScreenshotChange.fraction(previous: previous, current: thumb)
            }
            appState.lastThumbnail = thumb
        }
        // The menu bar left the scope: its indices are not "removed".
        let menuBar = TreeDiff.menuBarIndices(tree.elements)
        var ignoredRemovals = Set<Int>()
        if menuBar.isEmpty { ignoredRemovals = appState.menuBarIndices } else { appState.menuBarIndices = menuBar }
        // What happened in the app since the previous observation.
        if appState.observed, let since = appState.lastObservedAt {
            notes += UIEventSummary.sinceLastLook(activity.events(pid: pid, since: since))
        }
        var observationInput = (
            ObservationInput(
                appName: resolved.name, bundleId: resolved.bundleId, pid: Int(pid), appKind: kind == .native ? nil : kind.label,
                window: window, notes: notes,
                tree: tree, focusedHandle: snapshot.focusedHandle, selectedText: snapshot.selectedText,
                trailers: trailers,
                previousBaseline: appState.observed ? appState.baseline : nil, fullTree: fullTree,
                pageLoad: snapshot.pageLoad.summary, screenshot: appState.screenshotGeometry,
                screenshotCaptured: shot != nil, screenshotChange: screenshotChange))
        observationInput.ignoredRemovals = ignoredRemovals
        let output = ObservationRenderer.render(observationInput)
        // Detection for focus needs: an app that draws its own UI needs the front.
        // Chromium / Electron apps are never "self-drawn": their tree is built on demand and
        // can look empty while it is being built.
        if !resolved.bundleId.isEmpty, window != nil {
            let selfDrawn = !kind.buildsTreeLazily
                && AccessibilitySparsity.isSparse(tree, window: window, hasWebContent: snapshot.pageLoad.summary != nil)
            if focusProfiles.profile(resolved.bundleId)?.selfDrawn != selfDrawn {
                focusProfiles.update(resolved.bundleId) { $0.selfDrawn = selfDrawn }
                Log.info("focus: \(resolved.bundleId) \(selfDrawn ? "draws its own UI -> needs the front" : "exposes its UI to accessibility -> background")")
            }
        }
        appState.baseline = output.baseline
        appState.windowsAtObservation = Self.windowsAndSheets(pid: pid)
        appState.observed = true
        // Cleared by this observation: user input before the read is seen in it.
        appState.lastObservedAt = readStarted

        Log.info(
            "observeApp \(resolved.bundleId) pid \(pid): \(tree.elements.count) elements (raw \(snapshot.elements.count)), diff=\(output.isDiff), screenshot=\(shot.map { "\($0.width)x\($0.height) scale \(ScreenshotScale.format($0.scale)) via \($0.path)\($0.possiblyBlank ? " (possibly blank)" : "")" } ?? "none"), liveness checks \(appState.indexer.lastLivenessChecks)\(snapshot.pageLoad.hasWebContent ? ", page \(snapshot.pageLoad.isLoading ? "loading" : "loaded") after \(Int(loadWait * 1000)) ms wait" : "")"
        )
        let windowJSON: JSONValue =
            window.map {
                ["x": .int($0.x), "y": .int($0.y), "width": .int($0.width), "height": .int($0.height)]
            } ?? .null
        return [
            "resolved": resolved.json,
            "text": .string(output.text),
            "screenshot": shot?.json ?? .null,
            "window": windowJSON,
            "isDiff": .bool(output.isDiff),
        ]
    }

    /// Longest wait for a just-launched app's window to become capturable.
    static let readinessWait: TimeInterval = 3
    /// Longest wait for an Electron / Chromium tree to fill in after enabling it;
    /// `readinessWait` for an app that is still starting (its page may not be loaded yet).
    static let treeFillWait: TimeInterval = 1.5

    /// An app that has not finished launching, or launched in the last 20 s.
    static func isStarting(_ app: NSRunningApplication?) -> Bool {
        guard let app else { return false }
        if !app.isFinishedLaunching { return true }
        if let launched = app.launchDate, Date().timeIntervalSince(launched) < 20 { return true }
        return false
    }

    /// When the tree looks empty, (re)enable the app's accessibility and, if that
    /// changed anything — or Chromium's own switch was just turned on — re-read the tree
    /// until it grows (≤ `budget`).
    func fillAccessibilityTree(
        _ snapshot: AXSnapshot, pid: pid_t, sessionId: String, appName: String, enabled: AccessibilityEnabler.Outcome?,
        kind: AppKind, budget: TimeInterval, hideForeign: @escaping AXReader.ForeignOwnerFilter, scope: ObservationScope,
        interrupted: () -> Bool
    ) -> AXSnapshot {
        var snap = snapshot
        let empty = TreeHeuristics.looksEmpty(roots: snap.roots)
        var outcome = enabled
        if empty, outcome == nil, axEnabler.shouldEnable(pid: pid, session: sessionId, treeLooksEmpty: true) {
            outcome = axEnabler.enable(pid: pid, session: sessionId, appName: appName, kind: kind, treeLooksEmpty: true)
        }
        // Electron / Chromium just turned on: wait for the web area it fills in,
        // not just for "the tree grew".
        let wantsWebArea = kind.buildsTreeLazily && !snap.roots.contains(where: Self.containsWebArea)
        guard let outcome, outcome.changed, empty || outcome.manualTurnedOn || wantsWebArea else { return snap }
        let startCount = TreeHeuristics.count(snap.roots)
        let started = Date()
        let until = started.addingTimeInterval(budget)
        var grew = false
        while Date() < until, !interrupted() {
            usleep(150_000)
            let next = reader.snapshot(pid: pid, hideForeign: hideForeign, scope: scope)
            snap = next
            let filled = TreeHeuristics.count(next.roots) > startCount && !TreeHeuristics.looksEmpty(roots: next.roots)
            if filled && (!wantsWebArea || next.roots.contains(where: Self.containsWebArea)) {
                grew = true
                break
            }
        }
        Log.info(
            "accessibility: \(LogText.peer(appName)) tree \(grew ? "grew" : "did not grow") from \(startCount) to \(TreeHeuristics.count(snap.roots)) node(s) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        return snap
    }

    /// Index the snapshot: the same live element
    /// keeps its index; a vanished element's index can pass to its replacement.
    func serialize(_ snapshot: AXSnapshot, app: AppSessionState) -> SerializedTree {
        TreeSerializer.serialize(
            roots: snapshot.roots, indexer: app.indexer, liveKeys: snapshot.liveKeys,
            isAlive: { key in key.axElement.map(Self.isAlive) ?? false })
    }

    /// Whether a previously read element still exists. The owner process being gone is
    /// answered locally (no IPC); otherwise one attribute read (`kAXErrorInvalidUIElement`
    /// = gone).
    static func isAlive(_ el: AXUIElement) -> Bool {
        if let owner = AX.pid(el), owner > 0, kill(owner, 0) != 0, errno == ESRCH { return false }
        return AX.isValid(el)
    }

    static func containsWebArea(_ node: AXNode) -> Bool {
        node.role == AXReader.webAreaRole || node.children.contains(where: containsWebArea)
    }

    /// Windows whose page loads an action / observation waits for: the focused window
    /// (a navigation may have opened it) and the observed one.
    static func loadWindows(pid: pid_t, observed: AXUIElement?) -> [AXUIElement] {
        var out: [AXUIElement] = []
        if let focused = AX.element(AX.application(pid), kAXFocusedWindowAttribute) { out.append(focused) }
        if let observed, !out.contains(where: { CFEqual($0, observed) }) { out.append(observed) }
        return out
    }

    /// Seconds until `deadline` (negative once expired).
    static func secondsLeft(_ deadline: RequestDeadline) -> TimeInterval {
        let (diff, overflow) = deadline.unixMillis.subtractingReportingOverflow(currentUnixMillis())
        if overflow { return deadline.unixMillis > 0 ? .greatestFiniteMagnitude : -.greatestFiniteMagnitude }
        return Double(diff) / 1000
    }

    /// index → live element, plus the indices that are secure fields (kept across
    /// re-reads: the role is part of an index's identity, so a secure index stays
    /// secure). An observation replaces the map; the re-read behind a stale index
    /// (`merge`) only adds to it, so other indices of that observation keep working.
    func applyElementMap(_ tree: SerializedTree, _ snapshot: AXSnapshot, to app: AppSessionState, merge: Bool = false) {
        var map: [Int: AXUIElement] = merge ? app.elements : [:]
        for e in tree.elements where e.handle >= 0 && e.handle < snapshot.elements.count {
            map[e.index] = snapshot.elements[e.handle]
            if e.isSecure { app.secureIndices.insert(e.index) }
        }
        app.elements = map
    }

    /// AXReader filter for UI hosted inside the app by another process: hidden when that
    /// process's own policy would not allow it under the host's approval (protected, or
    /// sensitive inside a normal app). Unlisted system services (web content, the
    /// Open/Save panel service) stay visible.
    func foreignOwnerFilter(hostRisk: PolicyRisk) -> AXReader.ForeignOwnerFilter {
        let policy = currentPolicy()
        var cache: [pid_t: String?] = [:]
        return { [owners] ownerPid in
            if let hit = cache[ownerPid] { return hit }
            let owner = owners.owner(of: ownerPid)
            var note: String?
            if policy.evaluateForeignOwner(ownerBundleIds: owner.bundleIds, hostRisk: hostRisk) != nil {
                note = "Content from \(owner.name) is hidden: that app cannot be controlled through this one"
            }
            cache[ownerPid] = note
            return note
        }
    }

    final class LaunchBox: @unchecked Sendable {
        var app: NSRunningApplication?
        var error: Error?
    }

    /// Launch without activating and wait ≤ 8 s for a window.
    func launch(_ r: ResolvedApp) throws -> ResolvedApp {
        guard !r.path.isEmpty else { throw TurboError(.appMissing, "\(r.name) has no bundle path to launch.") }
        Log.info("launching \(r.path)")
        let frontBefore = NSWorkspace.shared.frontmostApplication
        let launchStarted = ProcessInfo.processInfo.systemUptime
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        let box = LaunchBox()
        let done = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: r.path), configuration: config) { app, error in
            box.app = app
            box.error = error
            done.signal()
        }
        if done.wait(timeout: .now() + 15) == .timedOut {
            throw TurboError(.actionError, "Timed out launching \(r.name).")
        }
        guard let app = box.app else {
            throw TurboError(.actionError, "Could not launch \(r.name): \(box.error.map { "\($0.localizedDescription)" } ?? "unknown error").")
        }
        let pid = app.processIdentifier
        func hasWindow() -> Bool {
            // An AX window that is also on screen (the window server lists it).
            guard let windows = AX.elements(AX.application(pid), kAXWindowsAttribute), !windows.isEmpty else { return false }
            return WindowList.hasWindow(pid: pid)
        }
        var until = Date().addingTimeInterval(3)
        while Date() < until, !hasWindow() { usleep(150_000) }
        if !hasWindow() {
            // Launched without activation, many document apps open no window (they open their
            // first one when they are activated). Opening the running app again sends it the
            // "reopen" event the Dock sends, still without activating it.
            Log.info("launch: \(LogText.peer(r.name)) has no window yet; sending reopen")
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: r.path), configuration: config) { _, _ in }
            until = Date().addingTimeInterval(5)
            while Date() < until, !hasWindow() { usleep(150_000) }
        }
        restoreFrontAfterLaunch(launched: pid, previous: frontBefore, since: launchStarted)
        var out = AppResolver.resolved(from: app)
        if out.name.isEmpty { out.name = r.name }
        return out
    }

    /// The app is launched without activation, but many apps activate themselves
    /// when they start. If the launched app took the front from the app the user was
    /// using and the user has not clicked or typed since, give the front back to that
    /// app (AXFrontmost works from a background process). The target never stays in front
    /// because of the helper.
    func restoreFrontAfterLaunch(launched pid: pid_t, previous: NSRunningApplication?, since start: TimeInterval) {
        guard let previous, previous.processIdentifier != pid, previous.processIdentifier != getpid(),
            !previous.isTerminated
        else { return }
        // Self-activation can come a moment after the first window.
        let until = Date().addingTimeInterval(0.6)
        while Date() < until, frontmostPid() != pid { usleep(100_000) }
        guard frontmostPid() == pid else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        guard min(UserInput.keyboard, UserInput.clickOrScroll) > elapsed else {
            Log.info("launch: pid \(pid) is in front and the user used the Mac meanwhile; leaving it")
            return
        }
        let err = AX.set(AX.application(previous.processIdentifier), kAXFrontmostAttribute, kCFBooleanTrue)
        if err != .success { previous.activate(options: []) }
        Log.info("launch: pid \(pid) activated itself; handed the front back to \(previous.bundleIdentifier ?? "?")")
    }
}

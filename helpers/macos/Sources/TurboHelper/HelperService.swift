import AppKit
import ImageIO
import ApplicationServices
import TurboCore
import Foundation

/// Implements every request type and the safety checks that run before gated work.
///
/// Gated work (observeApp / action) is serialized across all connections by
/// `workLock`: there is one keyboard, one mouse and one confirmation card.
final class HelperService {
    let paths: TurboPaths
    let sessions = SessionManager()
    let resolver = AppResolver()
    let reader = AXReader()
    let screenshotter: Screenshotter
    /// Learned per-app focus needs; accessed under the work lock.
    lazy var focusProfiles = AppFocusProfileStore(url: paths.supportDir.appendingPathComponent("app-profiles.json"))
    let input = InputSynthesizer()
    let prompter = ApprovalPrompter()
    let overlay: OverlayController
    let owners = OwnerResolver()
    /// Turns on Chromium / Electron accessibility trees.
    let axEnabler = AccessibilityEnabler()
    /// The agent's own on-screen pointer.
    let pointer: PointerDriver?
    /// The live preview panel (main thread).
    let preview: LivePreviewController?
    /// The user's own input aimed at apps (take-back).
    let userInput: UserInputMonitor
    /// Accessibility notifications per app.
    let activity = ActivityObserver()
    /// Display kept awake while a gated request runs.
    let displayAwake = DisplayAwake()
    /// Apps brought to the front for one action, to hand back.
    let borrows = FrontBorrows()
    /// When a borrowed front was last handed back, per pid (under the work lock): menu items
    /// keep the enabled state they had in front for a moment afterwards.
    var handedBackAt: [pid_t: TimeInterval] = [:]
    /// Menu commands found to work only with the app in front, per app (under the work lock).
    var frontOnlyCommands: [String: Set<String>] = [:]
    let workLock = NSLock()
    /// Helper-wide time an approval dialog has been on screen: requests queued behind
    /// another request's dialog are credited with it.
    let dialogClock = DialogClock()

    init(
        paths: TurboPaths, overlay: OverlayController, pointer: PointerDriver? = nil, preview: LivePreviewController? = nil,
        userInput: UserInputMonitor = UserInputMonitor()
    ) {
        self.paths = paths
        self.overlay = overlay
        self.pointer = pointer
        self.preview = preview
        self.userInput = userInput
        self.screenshotter = Screenshotter(shotsDir: paths.shotsDir)
    }

    /// Current safety policy (re-reads `allow-protected.txt` so edits apply immediately). The
    /// app hosting the agent is protected: the agent must never act on itself.
    func currentPolicy() -> SafetyPolicy {
        var hosts = Set<String>()
        if let pid = AgentRegistry.shared.current.hostPid, let app = NSRunningApplication(processIdentifier: pid),
            let id = app.bundleIdentifier
        {
            hosts.insert(id)
        }
        return SafetyPolicy.load(overridesFile: paths.allowProtected, hostBundleIds: hosts)
    }

    /// Overlay Stop / Esc: stops every session and latches "ask the user before
    /// resuming" (cleared only by the user approving a new dialog).
    func userPressedStop() {
        sessions.stopAll()
        WindowFeeds.shared.closeAll("the user pressed Stop")
    }

    // MARK: - Dispatch

    func handle(_ env: RequestEnvelope) throws -> JSONValue {
        sessions.touch(env.sessionId)
        if let agent = env.agent { AgentRegistry.shared.update(agent) }
        switch env.requestType {
        case .accessStatus:
            return Permissions.json
        case .requestAccess:
            return Permissions.request()
        case .findApps:
            return resolver.findApps()
        case .checkPolicy:
            return try checkPolicy(env)
        case .finishTurn:
            return endTurn(env, keepApprovals: false)
        case .reset:
            return endTurn(env, keepApprovals: true)
        case .observeApp, .act, .appCommands:
            return try gated(env)
        case .waitFor:
            return try waitFor(env)
        case .previewPanel:
            return previewPanel(env)
        }
    }

    /// `previewPanel {show}`: show / hide the preview panel on request.
    func previewPanel(_ env: RequestEnvelope) -> JSONValue {
        let show = env.payload["show"]?.boolValue ?? true
        let enabled = PreviewSettings.load(paths.settings).enabled
        let active = sessions.anyActive(within: TurboProtocol.overlayIdleSeconds)
        var shown = false
        if let preview {
            let box = BoolBox()
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                box.value = preview.toggle(show: show)
                done.signal()
            }
            if done.wait(timeout: .now() + 2) == .success { shown = box.value }
        }
        Log.info("previewPanel: show=\(show) → \(shown ? "shown" : "hidden")\(active ? "" : " (no active session)")")
        return ["visible": .bool(shown), "enabled": .bool(enabled), "sessionActive": .bool(active)]
    }

    final class BoolBox: @unchecked Sendable { var value = false }

    // MARK: - Ungated

    func appQuery(_ env: RequestEnvelope) throws -> String {
        guard let app = env.payload["app"]?.stringValue,
            !app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw TurboError.invalid("payload.app must be an app name, bundle id or absolute .app path")
        }
        return app
    }

    func checkPolicy(_ env: RequestEnvelope) throws -> JSONValue {
        let resolved = try resolver.resolve(try appQuery(env))
        let policy = evaluate(resolved)
        return [
            "resolved": resolved.json,
            "decision": .string(policy.decision.rawValue),
            "risk": .string(policy.risk.rawValue),
            "reason": .optional(policy.reason),
        ]
    }

    func evaluate(_ r: ResolvedApp) -> PolicyEvaluation {
        let policy = currentPolicy()
        if r.pid == getpid() {
            return policy.evaluate(bundleId: policy.helperBundleId)
        }
        if let pid = r.pid, pid == AgentRegistry.shared.current.hostPid {
            return PolicyEvaluation(
                decision: .protected, risk: .normal,
                reason: "This is the app the agent itself runs in; an agent may not control its own host.")
        }
        return policy.evaluate(bundleId: r.bundleId)
    }

    func endTurn(_ env: RequestEnvelope, keepApprovals: Bool) -> JSONValue {
        let files = sessions.endTurn(env.sessionId, keepApprovals: keepApprovals)
        // A front borrowed for an open menu goes back now.
        for pid in borrows.pids() { _ = restoreBorrowedFront(pid: pid, force: true) }
        for f in files { try? FileManager.default.removeItem(at: f) }
        // AXEnhancedUserInterface back to what it was for apps no other session uses.
        axEnabler.sessionEnded(env.sessionId)
        // Hide the overlay only when no other session is still working: another
        // session's Stop button and Esc must keep working. The check runs on the main
        // queue, after any noteActivity another session's request has already queued; the
        // overlay's own idle timer hides it 60 s after the last gated request otherwise.
        DispatchQueue.main.async { [overlay, sessions, preview] in
            if !sessions.anyActive(within: TurboProtocol.overlayIdleSeconds) { overlay.hide() }
            // The job is finished: close the live preview unless another session is still working.
            if !sessions.anyActive(within: TurboProtocol.previewSessionSeconds) {
                preview?.sessionsEnded()
                WindowFeeds.shared.closeAll("the job finished")
            }
        }
        Log.info(
            "\(keepApprovals ? "reset" : "finishTurn"): session \(LogText.peer(String(env.sessionId.prefix(8)), limit: 8)) — deleted \(files.count) screenshot(s)"
        )
        return ["ok": true]
    }

    // MARK: - Gated pipeline

    func gated(_ env: RequestEnvelope, probe: WaitProbe? = nil) throws -> JSONValue {
        var deadline = RequestDeadline(unixMillis: env.deadlineUnixMillis)
        try deadline.check("before start")
        let dialogTimeBefore = dialogClock.reading()
        workLock.lock()
        defer { workLock.unlock() }
        // No display sleep while the helper works.
        displayAwake.begin()
        defer { displayAwake.end() }
        // Time spent queued behind another request's approval dialog was the user's time,
        // not ours; the total credit is capped (RequestDeadline.maxCreditSeconds).
        deadline.credit(seconds: dialogClock.reading() - dialogTimeBefore)
        try deadline.check("while waiting for another request to finish")

        // 1. Stop flag. 2. Screen locked.
        try refuseIfStoppedOrLocked(env.sessionId)
        // 3. Accessibility permission (Screen Recording is optional, see observeApp).
        guard Permissions.accessibility else {
            throw TurboError(.accessMissing, Permissions.notGrantedMessage)
        }

        // Validate the payload before anything can prompt the user.
        let query = try appQuery(env)
        let action: TurboAction? = env.requestType == .act ? try TurboAction.parse(env.payload["step"]) : nil
        if case .sendKeys(let key)? = action {
            // An invalid chord is 4017 without ever showing the approval dialog.
            _ = try KeyChordParser.parse(key, characterMap: KeyboardLayout.characterMap)
        }
        var resolved = try resolver.resolve(query)

        // 4. Protected list. 5. Sensitive risk (folded into the evaluation).
        let policy = evaluate(resolved)
        if policy.decision == .protected {
            throw TurboError(
                .appProtected,
                "\(resolved.name) (\(resolved.bundleId.isEmpty ? resolved.path : resolved.bundleId)) cannot be controlled: \(TurboError.sentence(policy.reason ?? "it is on the safety deny list")) Do not retry."
            )
        }

        let session = sessions.session(env.sessionId)
        if probe != nil {
            guard let st = sessions.existingAppState(session: session, key: resolved.key), st.observed else {
                throw TurboError(
                    .observeFirst,
                    "No active session for \(resolved.name): call observe_app first, then wait on what it shows.")
            }
            guard resolved.runningApplication != nil else {
                throw TurboError(.observeFirst, "\(resolved.name) is no longer running; call observe_app to relaunch it.")
            }
        }
        if action != nil {
            guard let st = sessions.existingAppState(session: session, key: resolved.key), st.observed else {
                throw TurboError(
                    .observeFirst,
                    "No active session for \(resolved.name): call observe_app first, then act on the indices it returns.")
            }
            // The app quit since it was observed: fail now, not after an approval dialog
            // for a request that cannot succeed.
            guard resolved.runningApplication != nil else {
                throw TurboError(.observeFirst, "\(resolved.name) is no longer running; call observe_app to relaunch it.")
            }
            // User take-back: the user is using the app, or used it since the
            // latest observation.
            if let pid = resolved.pid {
                switch InterventionPolicy.verdict(
                    lastUserInput: userInput.lastInput(pid: pid), lastObservation: st.lastObservedAt,
                    now: ProcessInfo.processInfo.systemUptime)
                {
                case .none:
                    break
                case .stillInteracting(let wait):
                    Log.info("take-back: the user is using \(LogText.peer(resolved.name)); action refused (retry in \(wait) s)")
                    throw TurboError(.userTookOver, InterventionPolicy.stillInteractingMessage(app: resolved.name, retryAfter: wait))
                case .changedSinceObservation:
                    Log.info("take-back: the user used \(LogText.peer(resolved.name)) since the last observation; action refused")
                    throw TurboError(.userTookOver, InterventionPolicy.changedMessage(app: resolved.name))
                }
            }
        }

        // 6. Password managers: the user confirms once per session.
        // (The card activates the helper; afterwards it hands the front back to the app
        // the user had in front — never to the target.)
        if try confirmSensitiveApp(env: env, resolved: resolved, policy: policy, deadline: &deadline) {
            // The card may have been up for a while: re-check Stop and the screen lock.
            try refuseIfStoppedOrLocked(env.sessionId)
        }

        // 7. Overlay.
        sessions.noteGatedRequest(env.sessionId)
        let sessionId = env.sessionId
        let appName = resolved.name
        let appPath = resolved.path
        let capturable = PointerSettings.load(paths.settings).debugCapturable
        func previewTarget() -> PreviewTarget? {
            guard let pid = resolved.pid else { return nil }
            let frame = sessions.existingAppState(session: session, key: resolved.key)?.windowFrame
            return PreviewTarget(pid: pid, appName: resolved.name, appPath: resolved.path, windowFrame: frame)
        }
        let startTarget = previewTarget()
        DispatchQueue.main.async { [overlay, sessions, preview, userInput] in
            // Stop / Esc also run on the main thread, so this cannot race with them: a
            // session the user has just stopped never brings back "<agent> is working in …".
            guard !sessions.isStopped(sessionId) else { return }
            overlay.noteActivity(appName: appName, appPath: appPath, capturable: capturable)
            userInput.installIfNeeded()
            if let preview, let startTarget {
                preview.noteActivity(target: startTarget, capturable: capturable)
            }
        }
        defer {
            // The observed window may have changed (a new observation): the preview
            // follows it.
            let endTarget = previewTarget()
            DispatchQueue.main.async { [sessions, preview] in
                guard let preview, !sessions.isStopped(sessionId), let endTarget, endTarget != startTarget else { return }
                preview.noteActivity(target: endTarget, capturable: capturable)
            }
        }

        try deadline.check("after approval")
        if let action {
            return try perform(action, env: env, session: session, resolved: resolved, policy: policy, deadline: deadline)
        }
        if let probe {
            return try check(probe, session: session, resolved: resolved, policy: policy)
        }
        if env.requestType == .appCommands {
            return try appCommands(env: env, resolved: &resolved)
        }
        return try observeApp(env: env, session: session, resolved: &resolved, policy: policy, deadline: deadline)
    }

    /// The first two safety checks: the user pressed Stop, or the screen is locked.
    func refuseIfStoppedOrLocked(_ sessionId: String) throws {
        if sessions.isStopped(sessionId) { throw TurboError.haltedByUser() }
        if SystemState.isScreenLocked {
            throw TurboError(.displayLocked, "The screen is locked. Wait for the user to unlock it, then try again.")
        }
    }

    /// A password manager (sensitive app) needs the user's confirmation in the helper's own
    /// card, once per session; nothing else ever asks. Returns whether the card was shown.
    func confirmSensitiveApp(
        env: RequestEnvelope, resolved: ResolvedApp, policy: PolicyEvaluation, deadline: inout RequestDeadline
    ) throws -> Bool {
        guard policy.risk == .sensitive, !sessions.hasApproval(env.sessionId, key: resolved.key) else { return false }
        let started = Date()
        dialogClock.dialogOpened(at: started)
        let choice = prompter.ask(
            appName: resolved.name, bundleId: resolved.bundleId, appPath: resolved.path, timeout: TurboProtocol.approvalTimeoutSeconds)
        let ended = Date()
        dialogClock.dialogClosed(at: ended)
        // Time spent on the card does not count against the request deadline.
        deadline.credit(seconds: ended.timeIntervalSince(started))
        switch choice {
        case .once:
            return true
        case .session:
            sessions.grantSessionApproval(env.sessionId, key: resolved.key)
            return true
        case .deny:
            throw TurboError(.userDeclined, "The user declined access to \(resolved.name). Do not retry.")
        }
    }
}

import AppKit
import ImageIO
import ApplicationServices
import TurboCore
import Foundation

// Running one action step: the checks every action passes, then its handler.
extension HelperService {
    func perform(
        _ action: TurboAction, env: RequestEnvelope, session: SessionState, resolved: ResolvedApp,
        policy: PolicyEvaluation, deadline: RequestDeadline
    ) throws -> JSONValue {
        guard let pid = resolved.runningApplication?.processIdentifier else {
            throw TurboError(.observeFirst, "\(resolved.name) is no longer running; call observe_app to relaunch it.")
        }
        let app = sessions.appState(session: session, key: resolved.key, pid: pid)
        let started = Date()
        let sessionId = env.sessionId
        // The next observation settles first, also after a failed action
        // that may have sent part of its input.
        defer {
            app.needsSettle = true
            app.lastActionEnd = ProcessInfo.processInfo.systemUptime
        }
        // Ends long input early: the user's Stop, a screen lock or the deadline.
        let interrupted: () -> Bool = { [sessions] in
            sessions.isStopped(sessionId) || SystemState.isScreenLocked || deadline.isExpired()
        }
        // What was already loading before the action: a load that is still exactly that
        // afterwards (no progress) was not started by the action and is not waited for
        // in full.
        let probeLoads = PageLoadPolicy.shouldProbe(webContentSeen: app.webContentSeen, isWebBrowser: AppKindCache.isWebBrowser(path: resolved.path))
        let loadBaseline =
            probeLoads ? PageLoadProbe.scan(windows: Self.loadWindows(pid: pid, observed: app.window)).loadingFingerprint : nil
        // Focus: never bring the app forward (unless the user opted in); note
        // whether it is in front, which decides how keys are delivered.
        let focus = prepareFocus(session: session, pid: pid, app: app, name: resolved.name)
        let ctx = ActionContext(
            session: session, sessionId: sessionId, app: app, pid: pid, name: resolved.name, policy: policy,
            deadline: deadline, focus: focus, interrupted: interrupted)
        let note: String?
        /// Runs after the UI has settled (fill_value read-back).
        var afterSettle: (() -> String?)?
        // The real pointer goes back also when the action throws; so does a borrowed front.
        defer {
            input.routeThroughSystem = false
            ctx.extras.finishAssist()
            _ = restoreBorrowedFront(pid: pid)
        }
        switch action {
        case .click(.point(let x, let y), _, _), .drag(let x, let y, _, _):
            try refuseIfScreenChanged(ctx, at: (x, y))
        default:
            break
        }
        switch action {
        case .click(let target, let button, let count):
            note = try click(target: target, button: button, count: count, ctx)
        case .scroll(let target, let direction, let pages):
            note = try scroll(target: target, direction: direction, pages: pages, ctx)
        case .drag(let fx, let fy, let tx, let ty):
            let frame = try windowFrame(app, name: resolved.name)
            let from = try globalPoint(x: fx, y: fy, frame: frame, app: app)
            let to = try globalPoint(x: tx, y: ty, frame: frame, app: app)
            let pointer = self.pointer
            // Apps whose drags start a system drag session (learned): the session
            // follows the real pointer, so borrow the front and drag with the real mouse.
            let systemDrags = focusProfiles.profile(app.key)?.systemDrags == true
            let completed: Bool
            if systemDrags {
                try borrowFront(ctx, what: "dragging (\(resolved.name) starts system drags, which follow the real mouse)")
                guard BorrowFrontPolicy.userIdle(secondsSinceKeyboard: UserInput.keyboard, secondsSinceMouse: UserInput.mouse) else {
                    throw TurboError(.userActive, FocusModeText.borrowBusyMessage(app: resolved.name, what: "dragging with the real mouse"))
                }
                try travel(ctx, to: from, moving: PointerLabel.moving(to: resolved.name), arrived: PointerLabel.dragging)
                completed = try input.dragWithRealPointer(
                    from: from, to: to, shouldStop: interrupted,
                    onStep: { point, seconds in pointer?.follow(to: point, duration: seconds) })
                ctx.extras.addNote("The drag used the real mouse with \(resolved.name) in front (its drags are system drag sessions); the pointer was put back.")
            } else {
                // Mouse-moved events to the start point first, then down, drags, up.
                try travel(
                    ctx, to: from, moving: PointerLabel.moving(to: resolved.name), arrived: PointerLabel.dragging, hover: true,
                    assist: true)
                let dragCount = DispatchQueue.main.sync { NSPasteboard(name: .drag).changeCount }
                if ctx.extras.assist != nil, isFrontmost(pid) {
                    // An app that takes input only under the real pointer (the assist placed it
                    // there): the whole drag goes with the real mouse, like a finger swipe.
                    completed = try input.dragWithRealPointer(
                        from: from, to: to, shouldStop: interrupted,
                        onStep: { point, seconds in pointer?.follow(to: point, duration: seconds) })
                } else {
                    completed = try input.drag(
                        from: from, to: to, pid: pid, window: Self.window(pid: pid, containing: from), shouldStop: interrupted,
                        onStep: { point, seconds in pointer?.follow(to: point, duration: seconds) })
                }
                let started = DispatchQueue.main.sync { NSPasteboard(name: .drag).changeCount } != dragCount
                if started, !isFrontmost(pid) {
                    focusProfiles.update(app.key, evidence: "a background drag started a system drag session") { $0.systemDrags = true }
                    Log.info("drag: \(LogText.peer(resolved.name)) started a system drag session in the background -> real-mouse drags from now on")
                    ctx.extras.addNote(
                        "\(resolved.name) started a system drag session, which follows the real mouse pointer, so the drop probably did not land at the target. Check with observe_app; if nothing moved, drag again: from now on drags in \(resolved.name) briefly bring it to the front and use the real mouse (put back afterwards).")
                }
            }
            app.lastMousePoint = completed ? to : from
            if !completed {
                throw interruptionError(
                    sessionId, deadline: deadline,
                    detail: "The drag was cancelled: the mouse button was released where the drag started.")
            }
            note =
                "Dragged from (\(GeometryGuard.displayInt(fx)), \(GeometryGuard.displayInt(fy))) to (\(GeometryGuard.displayInt(tx)), \(GeometryGuard.displayInt(ty)))."
        case .writeText(let text, let index):
            note = try writeText(text, index: index, ctx)
        case .sendKeys(let key):
            note = try sendKeys(key, ctx)
        case .paste(let text, let format):
            note = try paste(text, format: format, ctx)
        case .fillValue(let index, let value):
            let verify = try fillValue(index: index, value: value, ctx)
            afterSettle = verify
            note = nil
        case .pickText(let index, let text, let prefix, let suffix, let selection):
            note = try pickText(
                index: index, text: text, prefix: prefix, suffix: suffix, mode: selection, ctx)
        case .invokeAction(let index, let name):
            note = try invokeAction(index: index, name: name, ctx)
        case .runCommand(let path):
            note = try runCommand(path, ctx)
        }
        ctx.extras.finishAssist()
        var notes = [note].compactMap { $0 } + ctx.extras.notes + focus.notes
        if let restored = restoreBorrowedFront(pid: pid) { notes.append(restored) }
        if let afterSettle {
            // fill_value read-back: give the app a moment to revert / reformat the value.
            usleep(150_000)
            if let extra = afterSettle() { notes.append(extra) }
        }
        var loadInfo = ""
        // Web content: wait (bounded) until a page load the action started has finished,
        // so the next observe_app sees the new page.
        let loadBudget = min(PageLoadPolicy.budget(for: action), Self.secondsLeft(deadline) - 3)
        if loadBudget > 0, probeLoads {
            let observed = app.window
            let r = PageLoadProbe.waitUntilLoaded(
                windows: { Self.loadWindows(pid: pid, observed: observed) }, budget: loadBudget, baseline: loadBaseline,
                interrupted: interrupted)
            if r.signals.hasWebContent {
                app.webContentSeen = true
                let state = r.stalled ? "stalled (loading, no progress)" : r.stillLoading ? "still loading" : "loaded"
                loadInfo = ", page \(state) after \(Int(r.waited * 1000)) ms"
            } else if r.signals.incomplete {
                loadInfo = ", page load state unknown after \(Int(r.waited * 1000)) ms (scan cut short)"
            }
            app.stalledLoad = r.stillLoading ? r.signals.loadingFingerprint : nil
            let stopped = sessions.isStopped(sessionId)
            // The action closed the app (Quit) or its last window: there is no page to report on.
            let appGone = (NSRunningApplication(processIdentifier: pid)?.isTerminated ?? true)
                || (AX.elements(AX.application(pid), kAXWindowsAttribute) ?? []).isEmpty
            if appGone {
                // nothing to say about page loads
            } else if r.interrupted && (stopped || SystemState.isScreenLocked) {
                // The user's Stop or a screen lock ended the wait: never advise carrying on.
                notes.append(PageLoadPolicy.interruptedNote(stopped: stopped))
            } else if case .stalled(let unchanged) = r.verdict, let summary = r.signals.summary {
                notes.append(PageLoadPolicy.stalledNote(summary, unchangedFor: unchanged))
            } else if r.stillLoading, let summary = r.signals.summary {
                notes.append(PageLoadPolicy.stillLoadingNote(summary, waited: r.waited))
            } else if !r.signals.hasWebContent, r.signals.incomplete {
                notes.append(PageLoadPolicy.unknownNote)
            }
        }
        Log.info(
            "action \(action.typeName) on \(resolved.bundleId) done in \(Int(Date().timeIntervalSince(started) * 1000)) ms\(loadInfo)")
        return ["ok": true, "note": .optional(notes.isEmpty ? nil : notes.joined(separator: " "))]
    }

    /// Error for input that `interrupted` cut short: the user's Stop, a screen lock, or the
    /// deadline (in that order of precedence).
    func interruptionError(_ sessionId: String, deadline: RequestDeadline, detail: String) -> TurboError {
        let suffix = detail.isEmpty ? "" : " " + detail
        if sessions.isStopped(sessionId) { return TurboError(.haltedByUser, TurboError.userStoppedMessage + suffix) }
        if SystemState.isScreenLocked {
            return TurboError(
                .displayLocked,
                "The screen was locked, so input stopped.\(suffix) Wait for the user to unlock it, then call observe_app before retrying."
            )
        }
        if deadline.isExpired() {
            return TurboError(
                .timedOut,
                "The request deadline passed, so input stopped.\(suffix) Call observe_app to check the app before retrying.")
        }
        return TurboError(.haltedByUser, TurboError.userStoppedMessage + suffix)
    }

    static func isBareDeadKey(_ chord: KeyChord) -> Bool {
        guard chord.modifiers.isDisjoint(with: [.command, .control, .option, .function]),
            chord.keyName.count == 1, let ch = chord.keyName.first
        else { return false }
        return KeyboardLayout.deadKeyCharacters.contains(ch)
    }
}

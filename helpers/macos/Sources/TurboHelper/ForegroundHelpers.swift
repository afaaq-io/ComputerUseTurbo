import AppKit
import ImageIO
import ApplicationServices
import TurboCore
import Foundation

/// Posts the mouse-moved events of one hover: the final
/// approach to the target (`HoverPlan.finalApproach`) at its times, then the settle pause
/// before mouseDown. Each move is routed to the app's window under it (else the target's
/// window), like a click.
final class HoverPoster {
    private let input: InputSynthesizer
    private let pid: pid_t
    private let windows: [WindowList.Info]
    private let targetWindow: WindowList.Info?
    private let plan: [HoverMove]
    private let settings: HoverSettings
    private(set) var posted = 0

    init(
        input: InputSynthesizer, pid: pid_t, target: CGPoint, from: CGPoint?, windowFrame: CGRect?,
        settings: HoverSettings = .defaults
    ) {
        self.input = input
        self.pid = pid
        self.settings = settings
        windows = WindowList.onScreenWindows()
        targetWindow = WindowList.window(pid: pid, containing: target, in: windows)
        plan = HoverPlan.finalApproach(to: target, from: from, within: targetWindow?.bounds ?? windowFrame)
    }

    /// Post the moves, then pause. false = interrupted (no click must follow).
    func post(interrupted: () -> Bool) -> Bool {
        let origin = Date()
        for m in plan {
            if interrupted() { return false }
            let wait = m.at - Date().timeIntervalSince(origin)
            if wait > 0 { usleep(useconds_t(min(wait, 0.25) * 1_000_000)) }
            input.moveMouse(
                m, pid: pid,
                window: settings.routeMoves
                    ? (WindowList.window(pid: pid, containing: m.point, in: windows) ?? targetWindow) : nil)
            posted += 1
        }
        usleep(useconds_t(settings.settleMs * 1000))
        return !interrupted()
    }

    var detailIfStopped: String {
        posted > 0 ? "Only mouse movement was sent; nothing was clicked, scrolled or dragged." : "Nothing was sent."
    }
}

/// Real-pointer assist: moves the user's real pointer onto the target
/// of one button action (`place`) and back afterwards (`finish`) — unless the user took
/// the mouse meanwhile.
final class RealPointerAssist {
    let appName: String
    private var original: CGPoint?
    private var placed: CGPoint?
    private var placedAt = Date()

    init(appName: String) {
        self.appName = appName
    }

    private static func cursor() -> CGPoint? { CGEvent(source: nil)?.location }

    func place(at point: CGPoint) {
        if original == nil { original = Self.cursor() }
        guard original != nil else { return }
        CGWarpMouseCursorPosition(point)
        placed = point
        placedAt = Date()
        Log.info("real-pointer assist: pointer moved over \(LogText.peer(appName)) for the action")
        usleep(useconds_t(RealPointerAssistPolicy.enterDelay * 1_000_000))
    }

    func finish() {
        guard let original, let placed else { return }
        self.original = nil
        self.placed = nil
        usleep(useconds_t(RealPointerAssistPolicy.holdAfter * 1_000_000))
        let held = Date().timeIntervalSince(placedAt)
        let current = Self.cursor() ?? placed
        if RealPointerAssistPolicy.shouldRestore(
            current: current, placed: placed, secondsSinceUserMouse: HelperService.UserInput.mouse, heldFor: held)
        {
            CGWarpMouseCursorPosition(original)
            Log.info("real-pointer assist: pointer put back")
        } else {
            Log.info("real-pointer assist: the user moved the mouse meanwhile; pointer left where it is")
        }
    }
}

/// Apps brought to the front for one action: target pid → the app
/// that was in front before. Thread-safe.
final class FrontBorrows: @unchecked Sendable {
    struct Borrow {
        let previousPid: pid_t
        let at: TimeInterval
    }

    private let lock = NSLock()
    private var byPid: [pid_t: Borrow] = [:]

    func record(pid: pid_t, previous: NSRunningApplication) {
        lock.lock()
        defer { lock.unlock() }
        // Keep the oldest record: a second borrow while the first is pending (a menu was
        // left open) must still hand the front back to the user's app.
        if byPid[pid] == nil {
            byPid[pid] = Borrow(previousPid: previous.processIdentifier, at: ProcessInfo.processInfo.systemUptime)
        }
    }

    func pending(pid: pid_t) -> Borrow? {
        lock.lock()
        defer { lock.unlock() }
        return byPid[pid]
    }

    func clear(pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        byPid[pid] = nil
    }

    func pids() -> [pid_t] {
        lock.lock()
        defer { lock.unlock() }
        return Array(byPid.keys)
    }
}

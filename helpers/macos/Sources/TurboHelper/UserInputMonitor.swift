import AppKit
import TurboCore
import Foundation

/// Detects the user's own (hardware) input aimed at an app (user
/// take-back): global `NSEvent` monitors for mouse-down, scroll-wheel and key-down
/// events. Global monitors only see events delivered to OTHER apps through the window
/// server; events the helper posts to a pid never pass through them (and carry the
/// helper's tag, which is checked as well). A key counts for the frontmost app; a click
/// or scroll for the owner of the topmost window under the pointer (the helper's own
/// panels skipped). Only the time of the latest input per pid is kept.
final class UserInputMonitor {
    private var monitors: [Any] = []
    private let lock = NSLock()
    private var lastInput: [pid_t: TimeInterval] = [:]
    private var lastScrollCheck: TimeInterval = 0
    private let myPid = getpid()

    /// Install (main thread). Needs the Accessibility grant for key events; retried by
    /// `installIfNeeded` until it is there.
    func installIfNeeded() {
        guard monitors.isEmpty, AXIsProcessTrusted() else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handle(e) }) {
            monitors.append(m)
            Log.info("take-back: user input monitor installed")
        }
    }

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func handle(_ event: NSEvent) {
        if let cg = event.cgEvent, cg.getIntegerValueField(.eventSourceUserData) == InputSynthesizer.eventTag { return }
        let kind: UserInputAttribution.Kind
        switch event.type {
        case .keyDown: kind = .key
        case .scrollWheel: kind = .scroll
        default: kind = .mouseDown
        }
        let now = Self.now()
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var owner: pid_t?
        if kind != .key {
            if kind == .scroll {
                // Trackpads send scroll events at a high rate: one hit test per 100 ms.
                if now - lastScrollCheck < 0.1 { return }
                lastScrollCheck = now
            }
            let point = CGEvent(source: nil)?.location ?? .zero
            owner = Self.windowOwner(at: point, excluding: myPid)
        }
        let target: pid_t? = kind == .key ? front : owner
        guard let pid = target,
            UserInputAttribution.isAimedAtTarget(kind: kind, targetPid: pid, frontPid: front, windowOwnerAtPoint: owner)
        else { return }
        record(pid: pid, at: now)
    }

    /// Owner of the topmost on-screen window under `point` (global top-left), ignoring
    /// `excluding`'s windows (the helper's pointer / preview / overlay panels) and
    /// transparent windows.
    static func windowOwner(at point: CGPoint, excluding: pid_t) -> pid_t? {
        WindowList.onScreenWindows().first { $0.pid != excluding && $0.alpha > 0.05 && $0.bounds.contains(point) }?.pid
    }

    func record(pid: pid_t, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        lastInput[pid] = time
        if lastInput.count > 256 {
            let cutoff = time - 3600
            lastInput = lastInput.filter { $0.value > cutoff }
        }
        lock.unlock()
    }

    /// The user's latest input aimed at `pid` (monotonic), nil = none seen.
    func lastInput(pid: pid_t) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return lastInput[pid]
    }
}

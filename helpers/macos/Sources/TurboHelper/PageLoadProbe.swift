import ApplicationServices
import TurboCore
import Foundation

/// Cheap, bounded reads of page-load state (for the observation header).
///
/// Scans the given windows without ever entering a web area (≈ 30 elements and a few
/// milliseconds for a Safari window), reading role, identifier and children of each
/// element and `AXLoaded` / `AXLoadingProgress` / `AXURL` of web areas, all in one round
/// trip per element.
enum PageLoadProbe {
    /// Per window (a second window gets its own budget, so a big focused window cannot
    /// hide the observed one's page).
    static let maxElements = 400
    static let maxDepth = 25
    static let timeBudget: TimeInterval = 0.15

    private static let attributes = [
        kAXRoleAttribute, kAXIdentifierAttribute, kAXChildrenAttribute, "AXLoaded", "AXLoadingProgress", "AXURL",
    ]

    /// Signals of `windows` (duplicates ignored). `incomplete` is set when a window's
    /// walk hit its element or time cap with elements left, or an element did not answer
    /// (messaging timeout): the scan then cannot say "no web content".
    static func scan(windows: [AXUIElement]) -> PageLoadSignals {
        var signals = PageLoadSignals()
        var seen: [AXUIElement] = []
        for w in windows where !seen.contains(where: { CFEqual($0, w) }) {
            seen.append(w)
            let deadline = Date().addingTimeInterval(timeBudget)
            var visited = 0
            var stack: [(AXUIElement, Int)] = [(w, 0)]
            while let (el, depth) = stack.popLast() {
                if visited >= maxElements || Date() > deadline {
                    signals.incomplete = true
                    break
                }
                visited += 1
                let (err, v) = AX.multiple(el, attributes)
                if err == .cannotComplete { signals.incomplete = true }
                guard err == .success else { continue }
                let role = AX.stringValue(v[kAXRoleAttribute])
                if role == AXReader.webAreaRole {
                    var progress: Double?
                    if let p = v["AXLoadingProgress"], CFGetTypeID(p) == CFNumberGetTypeID() {
                        progress = (p as! NSNumber).doubleValue
                    }
                    signals.webAreas.append(
                        WebAreaLoad(loaded: AX.boolValue(v["AXLoaded"]), progress: progress, url: AX.urlString(v["AXURL"])))
                    continue  // never inside a web area
                }
                if let id = AX.stringValue(v[kAXIdentifierAttribute]), PageLoadSignals.isPageGroupIdentifier(id) {
                    signals.pageGroupIdentifiers.append(id)
                }
                guard depth + 1 < maxDepth, let kids = v[kAXChildrenAttribute].flatMap({ AX.elementArray($0) }) else {
                    continue
                }
                // Reverse so the walk is in document order.
                for kid in kids.reversed() { stack.append((kid, depth + 1)) }
            }
        }
        return signals
    }

    struct WaitResult {
        var signals: PageLoadSignals
        var waited: TimeInterval
        var verdict: PageLoadWait.Verdict
        /// Stop, a screen lock or the deadline ended the wait.
        var interrupted: Bool
        /// Still loading when the wait ended (budget used up, interrupted or stalled).
        var stillLoading: Bool { signals.hasWebContent && signals.isLoading }
        var stalled: Bool {
            if case .stalled = verdict { return true }
            return false
        }
    }

    /// Poll until the pages in `windows()` (re-evaluated every poll: a navigation can
    /// replace the focused window) have loaded, `budget` is used up or `interrupted`.
    /// Returns at once when there is no web content. `baseline` is the loading
    /// fingerprint from before the action: a load still matching it that makes no
    /// progress for `PageLoadPolicy.stallAfter` ends the wait early (see `PageLoadWait`).
    static func waitUntilLoaded(
        windows: () -> [AXUIElement], budget: TimeInterval, baseline: String? = nil, interrupted: () -> Bool
    ) -> WaitResult {
        let start = Date()
        var wait = PageLoadWait(baseline: baseline)
        var signals = scan(windows: windows())
        var verdict = wait.evaluate(signals, at: 0)
        var wasInterrupted = false
        while verdict == .keepWaiting {
            let elapsed = Date().timeIntervalSince(start)
            if elapsed + PageLoadPolicy.pollInterval > budget { break }
            if interrupted() {
                wasInterrupted = true
                break
            }
            usleep(useconds_t(PageLoadPolicy.pollInterval * 1_000_000))
            signals = scan(windows: windows())
            verdict = wait.evaluate(signals, at: Date().timeIntervalSince(start))
        }
        return WaitResult(
            signals: signals, waited: Date().timeIntervalSince(start), verdict: verdict, interrupted: wasInterrupted)
    }
}

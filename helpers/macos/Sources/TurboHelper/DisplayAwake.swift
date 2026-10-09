import Foundation
import IOKit.pwr_mgt

/// Keeps the display awake while the helper handles a gated request: a "prevent user-idle display sleep" power assertion, reference
/// counted, released when the last request finishes.
final class DisplayAwake {
    private let lock = NSLock()
    private var count = 0
    private var assertion: IOPMAssertionID = 0

    func begin() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        guard count == 1 else { return }
        let r = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Computer Use Turbo is working" as CFString, &assertion)
        if r != kIOReturnSuccess {
            assertion = 0
            Log.warn("display-awake assertion failed (\(r))")
        }
    }

    func end() {
        lock.lock()
        defer { lock.unlock() }
        guard count > 0 else { return }
        count -= 1
        if count == 0, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }
}

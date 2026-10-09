import Foundation

/// A request deadline that is credited with time the user spends in
/// an approval dialog: the request's own dialog, or another request's dialog that this
/// request was queued behind (gated work is serialized, so one slow answer delays every
/// queued request).
///
/// The total credit is capped at `maxCreditSeconds` so the helper never acts after the
/// MCP server's local safety timer (deadline + 5 s grace + 120 s approval allowance) has
/// already given up on the request.
public struct RequestDeadline: Equatable, Sendable {
    /// Largest total extension, in seconds (= the approval dialog timeout).
    public static let maxCreditSeconds: TimeInterval = TurboProtocol.approvalTimeoutSeconds

    public private(set) var unixMillis: Int64
    /// Seconds credited so far (≤ `maxCreditSeconds`).
    public private(set) var creditedSeconds: TimeInterval = 0

    public init(unixMillis: Int64) {
        self.unixMillis = unixMillis
    }

    public func isExpired(nowMillis: Int64 = currentUnixMillis()) -> Bool {
        nowMillis > unixMillis
    }

    /// Throw `4012 timedOut` if the deadline has passed; `stage` says where.
    public func check(_ stage: String, nowMillis: Int64 = currentUnixMillis()) throws {
        if isExpired(nowMillis: nowMillis) {
            throw TurboError(.timedOut, "The request deadline passed (\(stage)).")
        }
    }

    /// Extend by `seconds` of user wait time. Saturating (never traps), ignores
    /// negative / non-finite input, and stops at `maxCreditSeconds` in total.
    public mutating func credit(seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0 else { return }
        let allowed = min(seconds, max(0, Self.maxCreditSeconds - creditedSeconds))
        guard allowed > 0 else { return }
        creditedSeconds += allowed
        let millis = Int64((allowed * 1000).rounded())
        let (sum, overflow) = unixMillis.addingReportingOverflow(millis)
        unixMillis = overflow ? Int64.max : sum
    }
}

/// Accumulates the time an approval dialog has been on screen, helper-wide.
///
/// A request samples `reading()` before it starts waiting for the work lock and again
/// once it holds it; the difference is the dialog time it spent queued, which
///.2 says must not count against its deadline.
public final class DialogClock: @unchecked Sendable {
    private let lock = NSLock()
    private var accumulated: TimeInterval = 0
    private var openedAt: Date?

    public init() {}

    public func dialogOpened(at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        if openedAt == nil { openedAt = date }
    }

    public func dialogClosed(at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard let start = openedAt else { return }
        accumulated += max(0, date.timeIntervalSince(start))
        openedAt = nil
    }

    /// Total dialog time so far, including a dialog that is still open.
    public func reading(at date: Date = Date()) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return accumulated + (openedAt.map { max(0, date.timeIntervalSince($0)) } ?? 0)
    }
}

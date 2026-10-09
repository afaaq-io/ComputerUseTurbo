import Foundation

/// Protocol-level constants.
public enum TurboProtocol {
    /// API version exchanged in `hello`. A mismatch is fatal (4011).
    public static let apiVersion = "turbo-1"
    /// Version reported as `helperVersion` and in Info.plist.
    public static let helperVersion = "0.1.0"
    /// Bundle identifier of the helper app (always on the protected list).
    public static let helperBundleId = "dev.cuturbo.helper"

    /// Default request deadline when the client omits `deadlineUnixMillis`.
    public static let defaultDeadlineMillis: Int64 = 120_000

    /// Hard frame cap, both directions: 8 MiB.
    public static let maxFrameLength = 8 * 1024 * 1024

    /// Tree limits.
    public static let maxTreeDepth = 40
    public static let maxEmittedElements = 1500
    public static let maxStringLength = 160
    public static let diffLineBudget = 400

    /// Approval dialog timeout.
    public static let approvalTimeoutSeconds: TimeInterval = 120
    /// Overlay stays visible this long after the last gated request.
    public static let overlayIdleSeconds: TimeInterval = 60
    /// The live preview stays up for the whole job: it closes on finishTurn / Stop, and only
    /// as a safety net after this long without any request.
    public static let previewSessionSeconds: TimeInterval = 1800
}

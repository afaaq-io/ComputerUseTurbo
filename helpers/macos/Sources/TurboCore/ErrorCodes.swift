import Foundation

/// Domain error codes. Raw values are the wire codes.
public enum TurboErrorCode: Int, CaseIterable, Sendable {
    case callerRejected = 4001
    case appBlockedByPolicy = 4002
    case appProtected = 4003
    case accessMissing = 4004
    case accessWaiting = 4005
    case appNameUnclear = 4006
    case staleElement = 4007
    case haltedByUser = 4008
    case userTookOver = 4009
    case displayLocked = 4010
    case protocolMismatch = 4011
    case timedOut = 4012
    case appMissing = 4013
    case noWindow = 4014
    case observeFirst = 4015
    case passwordGuard = 4016
    case badArguments = 4017
    case actionError = 4018
    case notSupported = 4019
    case helperFault = 4020
    case userDeclined = 4021
    case userActive = 4022

    /// The `data.name` string sent on the wire.
    public var name: String {
        switch self {
        case .callerRejected: return "callerRejected"
        case .appBlockedByPolicy: return "appBlockedByPolicy"
        case .appProtected: return "appProtected"
        case .accessMissing: return "accessMissing"
        case .accessWaiting: return "accessWaiting"
        case .appNameUnclear: return "appNameUnclear"
        case .staleElement: return "staleElement"
        case .haltedByUser: return "haltedByUser"
        case .userTookOver: return "userTookOver"
        case .displayLocked: return "displayLocked"
        case .protocolMismatch: return "protocolMismatch"
        case .timedOut: return "timedOut"
        case .appMissing: return "appMissing"
        case .noWindow: return "noWindow"
        case .observeFirst: return "observeFirst"
        case .passwordGuard: return "passwordGuard"
        case .badArguments: return "badArguments"
        case .actionError: return "actionError"
        case .notSupported: return "notSupported"
        case .helperFault: return "helperFault"
        case .userDeclined: return "userDeclined"
        case .userActive: return "userActive"
        }
    }

    /// The `data.retryable` flag sent on the wire.
    public var retryable: Bool {
        switch self {
        case .accessWaiting, .staleElement, .displayLocked, .timedOut,
            .noWindow, .observeFirst, .actionError, .helperFault, .userActive, .userTookOver:
            return true
        default:
            return false
        }
    }
}

/// A domain error raised anywhere in the helper; converted to a JSON-RPC error at the edge.
public struct TurboError: Error, Equatable, CustomStringConvertible, Sendable {
    public let code: TurboErrorCode
    public let message: String

    public init(_ code: TurboErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "\(code.name) (\(code.rawValue)): \(message)" }

    // Canonical messages used in several places.
    public static let userStoppedMessage =
        "The user stopped Computer Use. Do not retry; ask the user how to proceed."

    public static func haltedByUser() -> TurboError { TurboError(.haltedByUser, userStoppedMessage) }

    public static func invalid(_ message: String) -> TurboError { TurboError(.badArguments, message) }

    public static func elementInvalid(_ index: Int) -> TurboError {
        TurboError(
            .staleElement,
            "Element #\(index) is no longer available; re-run observe_app and use a current index.")
    }
}

/// JSON-RPC 2.0 level error codes.
public enum JSONRPCErrorCode: Int, Sendable {
    case parseError = -32700
    case invalidRequest = -32600
    case methodNotFound = -32601
    case invalidParams = -32602

    public var name: String {
        switch self {
        case .parseError: return "parseError"
        case .invalidRequest: return "invalidRequest"
        case .methodNotFound: return "methodNotFound"
        case .invalidParams: return "invalidParams"
        }
    }
}

extension TurboError {
    /// `text` as one sentence: exactly one closing period ("…controlled." never "…controlled..").
    public static func sentence(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let last = t.last else { return t }
        return ".!?…".contains(last) ? t : t + "."
    }
}

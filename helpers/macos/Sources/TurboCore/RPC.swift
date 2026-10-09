import Foundation

/// A JSON-RPC error object: `{code, message, data: {name, retryable}}`.
public struct RPCError: Error, Equatable, Sendable {
    public let code: Int
    public let message: String
    public let name: String
    public let retryable: Bool

    public init(code: Int, message: String, name: String, retryable: Bool) {
        self.code = code
        self.message = message
        self.name = name
        self.retryable = retryable
    }

    public init(_ error: TurboError) {
        self.init(
            code: error.code.rawValue, message: error.message, name: error.code.name,
            retryable: error.code.retryable)
    }

    public init(_ code: JSONRPCErrorCode, _ message: String) {
        self.init(code: code.rawValue, message: message, name: code.name, retryable: false)
    }

    public var json: JSONValue {
        return [
            "code": .int(code),
            "message": .string(message),
            "data": ["name": .string(name), "retryable": .bool(retryable)],
        ]
    }
}

/// A validated JSON-RPC request with an integer id.
public struct RPCRequest: Equatable, Sendable {
    public let id: Int
    public let method: String
    public let params: JSONValue?

    public init(id: Int, method: String, params: JSONValue?) {
        self.id = id
        self.method = method
        self.params = params
    }
}

/// Outcome of parsing one frame.
public enum RPCParseResult: Equatable {
    /// A well-formed request.
    case request(RPCRequest)
    /// A notification (no `id`). v1 does not use notifications; the helper ignores them.
    case notification(method: String)
    /// Respond with this error; `id` is the request id when known, else `.null`.
    case failure(id: JSONValue, error: RPCError)
}

public enum RPCMessage {
    /// Parse and validate one frame body.
    public static func parse(_ data: Data) -> RPCParseResult {
        let value: JSONValue
        do {
            value = try JSONValue.decode(data)
        } catch {
            return .failure(id: .null, error: RPCError(.parseError, "Invalid JSON"))
        }
        guard case .object(let obj) = value else {
            return .failure(
                id: .null,
                error: RPCError(.invalidRequest, "Request must be a JSON object (batches are not supported)"))
        }
        let rawId = obj["id"]
        // Echo back whatever id we can (string/int) so the client can correlate the error.
        let echoId: JSONValue
        switch rawId {
        case .some(.int), .some(.string): echoId = rawId!
        default: echoId = .null
        }
        guard obj["jsonrpc"]?.stringValue == "2.0" else {
            return .failure(id: echoId, error: RPCError(.invalidRequest, "jsonrpc must be \"2.0\""))
        }
        guard let method = obj["method"]?.stringValue, !method.isEmpty else {
            return .failure(id: echoId, error: RPCError(.invalidRequest, "method must be a non-empty string"))
        }
        if let params = obj["params"] {
            switch params {
            case .object, .array, .null: break
            default:
                return .failure(
                    id: echoId, error: RPCError(.invalidRequest, "params must be an object or array"))
            }
        }
        guard let rawId else {
            return .notification(method: method)
        }
        guard case .int(let id) = rawId else {
            return .failure(id: echoId, error: RPCError(.invalidRequest, "id must be an integer"))
        }
        return .request(RPCRequest(id: id, method: method, params: obj["params"]))
    }

    public static func success(id: JSONValue, result: JSONValue) -> JSONValue {
        return ["jsonrpc": "2.0", "id": id, "result": result]
    }

    public static func failure(id: JSONValue, error: RPCError) -> JSONValue {
        return ["jsonrpc": "2.0", "id": id, "error": error.json]
    }
}

// MARK: - `hello` and `request` params

/// The work request types.
public enum RequestType: String, CaseIterable, Sendable {
    case accessStatus
    case requestAccess
    case findApps
    case checkPolicy
    case finishTurn
    case reset
    case observeApp
    case act
    /// Show / hide the live preview panel. Ungated: it only shows
    /// what the session's current target already showed.
    case previewPanel
    /// The app's menu commands. Gated.
    case appCommands
    /// Wait until a condition holds in the app. Gated.
    case waitFor

}

/// Parsed `request` params.
public struct RequestEnvelope: Equatable, Sendable {
    public let requestType: RequestType
    public let payload: JSONValue
    public let deadlineUnixMillis: Int64
    public let sessionId: String
    public let turnId: String?
    /// `session.agent`: who is driving the helper; nil = not sent.
    public var agent: AgentIdentity? = nil

    /// Validate `params`. JSON-RPC-level problems raise `-32602`/`-32601`.
    public static func parse(_ params: JSONValue?, nowMillis: Int64) throws -> RequestEnvelope {
        guard let params, case .object(let obj) = params else {
            throw RPCError(.invalidParams, "params must be an object")
        }
        guard let typeString = obj["requestType"]?.stringValue else {
            throw RPCError(.invalidParams, "params.requestType must be a string")
        }
        guard let type = RequestType(rawValue: typeString) else {
            throw RPCError(.methodNotFound, "Unknown requestType '\(typeString)'")
        }
        let payload: JSONValue
        switch obj["payload"] {
        case .none, .some(.null): payload = .object([:])
        case .some(.object(let o)): payload = .object(o)
        default: throw RPCError(.invalidParams, "params.payload must be an object")
        }
        let deadline: Int64
        switch obj["deadlineUnixMillis"] {
        case .none, .some(.null):
            deadline = nowMillis + TurboProtocol.defaultDeadlineMillis
        case .some(.int(let i)):
            deadline = clampDeadline(Int64(i))
        case .some(let v):
            guard let d = v.doubleValue, d.isFinite else {
                throw RPCError(.invalidParams, "params.deadlineUnixMillis must be a number")
            }
            deadline = clampDeadline(d)
        }
        guard let session = obj["session"], case .object(let s) = session,
            let sessionId = s["sessionId"]?.stringValue, !sessionId.isEmpty
        else {
            throw RPCError(.invalidParams, "params.session.sessionId must be a non-empty string")
        }
        let turnId = s["turnId"]?.stringValue
        var envelope = RequestEnvelope(
            requestType: type, payload: payload, deadlineUnixMillis: deadline,
            sessionId: sessionId, turnId: turnId)
        envelope.agent = AgentIdentity.parse(s["agent"])
        return envelope
    }

    /// Largest accepted deadline: far in the future, with headroom so crediting dialog
    /// time (`RequestDeadline.credit`) can never overflow.
    public static let maxDeadlineMillis: Int64 = Int64.max / 4

    /// Clamp an integer deadline into `0...maxDeadlineMillis` (≤ 0 = already expired).
    public static func clampDeadline(_ millis: Int64) -> Int64 {
        min(max(millis, 0), maxDeadlineMillis)
    }

    /// Clamp a finite floating-point deadline without trapping: `Int64(d)` traps for
    /// values outside the Int64 range (1e20, Int64.max widened to 2^63, -1e300, …).
    public static func clampDeadline(_ millis: Double) -> Int64 {
        guard millis.isFinite, millis > 0 else { return 0 }
        if millis >= Double(maxDeadlineMillis) { return maxDeadlineMillis }
        return Int64(millis)
    }

    /// Label for the helper log: request type, session prefix, and the app / action type
    /// escaped onto one line and truncated. These strings come from the peer (the model
    /// chooses `app`), so they must never be able to forge extra log lines. Typed text
    /// and values are never included.
    public var logLabel: String {
        var label = "\(requestType.rawValue) [session \(TreeFormat.clean(String(sessionId.prefix(8)), limit: 8))]"
        if let app = payload["app"]?.stringValue { label += " app=\"\(TreeFormat.clean(app, limit: 120))\"" }
        if let type = payload["step"]?["type"]?.stringValue { label += " action=\(TreeFormat.clean(type, limit: 40))" }
        return label
    }
}

/// Helpers for text written to the helper log.
public enum LogText {
    /// Escape line breaks so one log call can never produce more than one log line.
    public static func singleLine(_ message: String) -> String {
        guard message.contains(where: { $0.isNewline }) else { return message }
        var out = ""
        out.reserveCapacity(message.utf8.count + 8)
        for scalar in message.unicodeScalars {
            switch scalar {
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}": out += "\\n"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// A peer-supplied string for a log line: one line, quotes escaped, truncated.
    public static func peer(_ value: String, limit: Int = 80) -> String {
        TreeFormat.clean(value, limit: limit)
    }
}

/// Wall clock in Unix milliseconds.
public func currentUnixMillis() -> Int64 {
    return Int64((Date().timeIntervalSince1970 * 1000).rounded())
}

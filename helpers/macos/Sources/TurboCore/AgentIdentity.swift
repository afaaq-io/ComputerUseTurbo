import Foundation

/// Who is driving the helper (`session.agent`): the agent's display name
/// and the app it runs in. Both come from the connecting server at runtime — the name from
/// the MCP client's own self-description (or the user's setting), the host from the server's
/// process ancestry. Nothing here knows any agent or host by name.
public struct AgentIdentity: Equatable, Sendable {
    /// Shown in the overlay and the approval card ("<name> is working in Safari").
    public var name: String
    /// Process id of the app the agent runs in (its window anchors the live preview, and
    /// it may never be controlled: the agent would act on itself).
    public var hostPid: Int32?
    /// That app's bundle / executable path, when known.
    public var hostAppPath: String?

    public init(name: String, hostPid: Int32? = nil, hostAppPath: String? = nil) {
        self.name = name
        self.hostPid = hostPid
        self.hostAppPath = hostAppPath
    }

    public static let fallbackName = "Your AI agent"
    public static let unknown = AgentIdentity(name: fallbackName)
    static let maxNameLength = 40

    /// A readable display name from a client-supplied string: control characters removed,
    /// trimmed, kebab / snake case turned into words ("my-agent_cli" → "My Agent Cli"),
    /// capped in length. Empty → `fallbackName`.
    public static func displayName(_ raw: String?) -> String {
        guard let raw else { return fallbackName }
        var s = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains(" "), s.contains(where: { $0 == "-" || $0 == "_" }) {
            s = s.split(whereSeparator: { $0 == "-" || $0 == "_" })
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        } else if let first = s.first, first.isLowercase {
            s = first.uppercased() + s.dropFirst()
        }
        if s.count > maxNameLength { s = String(s.prefix(maxNameLength - 1)) + "…" }
        return s.isEmpty ? fallbackName : s
    }

    /// `session.agent` = `{name?, hostPid?, hostAppPath?}`; nil when absent or not an object.
    public static func parse(_ value: JSONValue?) -> AgentIdentity? {
        guard let value, case .object(let o) = value else { return nil }
        var id = AgentIdentity(name: displayName(o["name"]?.stringValue))
        if let pid = o["hostPid"]?.intValue, pid > 0, pid <= Int(Int32.max) { id.hostPid = Int32(pid) }
        if let path = o["hostAppPath"]?.stringValue, path.hasPrefix("/") || path.contains(":\\") {
            id.hostAppPath = path
        }
        return id
    }
}

/// The identity of the most recent request (thread-safe). UI that is not tied to one
/// request — the overlay, the live preview — shows this one.
public final class AgentRegistry: @unchecked Sendable {
    public static let shared = AgentRegistry()
    private let lock = NSLock()
    private var value = AgentIdentity.unknown

    public init() {}

    public var current: AgentIdentity {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func update(_ identity: AgentIdentity) {
        lock.lock()
        value = identity
        lock.unlock()
    }
}

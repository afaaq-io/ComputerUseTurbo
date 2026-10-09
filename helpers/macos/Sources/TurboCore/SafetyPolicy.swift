import Foundation

/// The default safety lists, read from the shared policy file
/// (`shared/policy.json` in the source tree, `policy.json` in the app's resources): data,
/// not code, one section per platform. The helper's own id and the app hosting the agent are
/// added at runtime by `SafetyPolicy`.
public struct SafetyLists: Equatable, Sendable {
    public var protected: [String]
    public var sensitive: [String]

    public init(protected: [String], sensitive: [String]) {
        self.protected = protected
        self.sensitive = sensitive
    }

    public static let empty = SafetyLists(protected: [], sensitive: [])
    /// Section of the policy file this helper reads.
    public static let platform = "macos"

    /// Parse a policy file for `platform`; nil when it is not a valid policy file.
    public static func parse(_ data: Data, platform: String = platform) -> SafetyLists? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func list(_ key: String) -> [String] {
            ((root[key] as? [String: Any])?[platform] as? [Any])?.compactMap { $0 as? String } ?? []
        }
        guard root["protected"] != nil || root["sensitive"] != nil else { return nil }
        return SafetyLists(protected: list("protected"), sensitive: list("sensitive"))
    }

    /// Where the policy file is looked for: `$CUT_POLICY_FILE`, the app bundle's resources,
    /// then `shared/policy.json` above this source file (development builds).
    public static func candidateURLs(sourceFile: String = #filePath) -> [URL] {
        var out: [URL] = []
        if let env = ProcessInfo.processInfo.environment["CUT_POLICY_FILE"], !env.isEmpty {
            out.append(URL(fileURLWithPath: env))
        }
        out += TurboPaths.sharedFileCandidates("policy.json", sourceFile: sourceFile)
        return out
    }

    /// The first readable policy file, loaded once. With none at all the helper still works,
    /// but only the runtime protections (itself, the agent's host) apply.
    public static let standard: SafetyLists = {
        for url in candidateURLs() {
            if let data = try? Data(contentsOf: url), let lists = parse(data) { return lists }
        }
        return .empty
    }()
}

public enum PolicyDecision: String, Sendable { case allowed, protected }
public enum PolicyRisk: String, Sendable { case normal, sensitive }

/// Result of evaluating one bundle id.
public struct PolicyEvaluation: Equatable, Sendable {
    public let decision: PolicyDecision
    public let risk: PolicyRisk
    public let reason: String?

    public init(decision: PolicyDecision, risk: PolicyRisk, reason: String?) {
        self.decision = decision
        self.risk = risk
        self.reason = reason
    }
}

/// Evaluates bundle ids against the protected / sensitive lists, the runtime protections
/// (the helper itself, the app hosting the agent) and the user's overrides.
public struct SafetyPolicy: Sendable {
    public let helperBundleId: String
    /// Lower-cased ids of the app(s) the agent runs in: the agent must never act on itself.
    public let hostBundleIds: Set<String>
    /// Lower-cased bundle ids un-protected by `allow-protected.txt`.
    public let overrides: Set<String>
    private let protectedSet: Set<String>
    private let sensitiveSet: Set<String>

    public init(
        helperBundleId: String = TurboProtocol.helperBundleId, hostBundleIds: Set<String> = [],
        overrides: Set<String> = [], lists: SafetyLists = .standard
    ) {
        self.helperBundleId = helperBundleId
        self.hostBundleIds = Set(hostBundleIds.map { $0.lowercased() }.filter { !$0.isEmpty })
        self.overrides = Set(overrides.map { $0.lowercased() })
        protectedSet = Set(lists.protected.map { $0.lowercased() })
        sensitiveSet = Set(lists.sensitive.map { $0.lowercased() })
    }

    /// Parse `allow-protected.txt`: bundle ids separated by commas and/or newlines;
    /// whitespace trimmed; blank entries and `#` comments ignored.
    public static func parseOverrides(_ text: String) -> Set<String> {
        var out = Set<String>()
        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: { $0.isNewline }) {
            var line = String(rawLine)
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }
            for item in line.split(separator: ",") {
                let id = item.trimmingCharacters(in: .whitespaces)
                if !id.isEmpty { out.insert(id.lowercased()) }
            }
        }
        return out
    }

    /// Load overrides from a file (missing/unreadable → none).
    public static func load(
        overridesFile: URL, helperBundleId: String = TurboProtocol.helperBundleId, hostBundleIds: Set<String> = []
    ) -> SafetyPolicy {
        let text = (try? String(contentsOf: overridesFile, encoding: .utf8)) ?? ""
        return SafetyPolicy(helperBundleId: helperBundleId, hostBundleIds: hostBundleIds, overrides: parseOverrides(text))
    }

    public func isSensitive(_ bundleId: String) -> Bool {
        Self.listed(bundleId.lowercased(), in: sensitiveSet)
    }

    /// On the list itself, or a part of a listed app ("com.apple.passwords.menubarextra" is
    /// part of "com.apple.passwords"): a helper of an app gets the same treatment as the app.
    static func listed(_ id: String, in set: Set<String>) -> Bool {
        set.contains(id) || set.contains { id.hasPrefix($0 + ".") }
    }

    public func evaluate(bundleId: String) -> PolicyEvaluation {
        let id = bundleId.lowercased()
        let sensitive = isSensitive(id)
        let risk: PolicyRisk = sensitive ? .sensitive : .normal
        // Neither the helper nor the agent's own host can ever be un-protected: the agent
        // would approve or steer its own actions.
        if id == helperBundleId.lowercased() {
            return PolicyEvaluation(
                decision: .protected, risk: risk,
                reason: "Computer Use Turbo cannot operate its own helper app.")
        }
        if hostBundleIds.contains(id) {
            return PolicyEvaluation(
                decision: .protected, risk: risk,
                reason: "This is the app the agent itself runs in; an agent may not control its own host.")
        }
        if Self.listed(id, in: protectedSet) && !overrides.contains(id) {
            return PolicyEvaluation(
                decision: .protected, risk: risk,
                reason:
                    "This app is protected by the safety policy (system authentication, system settings) and cannot be controlled.")
        }
        if sensitive {
            return PolicyEvaluation(
                decision: .allowed, risk: .sensitive,
                reason:
                    "This app manages passwords or other credentials; approval is required every session and cannot be saved.")
        }
        return PolicyEvaluation(decision: .allowed, risk: .normal, reason: nil)
    }
}

// MARK: - UI hosted by other processes

/// Accessibility trees can contain elements owned by other processes: remote / ViewBridge
/// views (Open/Save panels of sandboxed apps), web content processes, app extensions
/// (share sheets, AutoFill credential providers). Approval and the deny lists are
/// checked for the app the user approved, so such elements need their own check.
extension SafetyPolicy {
    /// Policy verdict for UI owned by another process inside an approved host app, given
    /// that process's bundle ids (innermost bundle first, then every enclosing app, see
    /// `BundleOwnership`). Returns nil when the UI may be used under the host's approval:
    /// unlisted helpers such as WebKit content processes or the Open/Save panel service.
    /// Otherwise the evaluation that makes it off-limits: a protected owner, or an
    /// sensitive owner (password manager) inside a host whose approval did not carry
    /// the sensitive warning.
    public func evaluateForeignOwner(ownerBundleIds: [String], hostRisk: PolicyRisk) -> PolicyEvaluation? {
        let evaluations = ownerBundleIds.filter { !$0.isEmpty }.map { evaluate(bundleId: $0) }
        if let protected = evaluations.first(where: { $0.decision == .protected }) { return protected }
        if hostRisk != .sensitive, let sensitive = evaluations.first(where: { $0.risk == .sensitive }) { return sensitive }
        return nil
    }
}

/// Maps a process's executable to the bundles it belongs to.
public enum BundleOwnership {
    private static let bundleExtensions: Set<String> = ["app", "appex", "xpc"]

    /// `.app`, `.appex` and `.xpc` bundle directories on `path`, innermost first, e.g.
    /// `/Applications/1Password.app/Contents/PlugIns/Fill.appex/Contents/MacOS/Fill`
    /// → [`…/Fill.appex`, `/Applications/1Password.app`]. An extension therefore
    /// inherits the policy of the app that ships it. Frameworks are skipped.
    public static func enclosingBundlePaths(of path: String) -> [String] {
        guard path.hasPrefix("/") else { return [] }
        var out: [String] = []
        var current = ""
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            current += "/" + component
            let ext = (String(component) as NSString).pathExtension.lowercased()
            if bundleExtensions.contains(ext) { out.append(current) }
        }
        return out.reversed()
    }
}

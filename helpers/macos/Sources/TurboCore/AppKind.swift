import Foundation

// App kinds that need help to expose their accessibility tree (Electron,
// Chromium and Catalyst apps), detected up front from the bundle rather than
// guessed from an empty tree. Pure: the helper lists the bundle's frameworks and
// Info.plist keys.

public enum AppKind: String, Equatable, Sendable {
    case native
    /// Contents/Frameworks/Electron Framework.framework.
    case electron
    /// Built on the Chromium engine (a browser, CEF or another embedder): recognised by the
    /// engine's own data files in its frameworks, whatever the product is called.
    case chromium
    /// Mac Catalyst (an iPad app built for the Mac).
    case catalyst

    /// Chromium builds its tree only once asked (AXManualAccessibility /
    /// AXEnhancedUserInterface) and then fills a web area in.
    public var buildsTreeLazily: Bool { self == .electron || self == .chromium }

    public var label: String {
        switch self {
        case .native: return "native"
        case .electron: return "Electron"
        case .chromium: return "Chromium"
        case .catalyst: return "Mac Catalyst"
        }
    }

    /// Data files every Chromium engine ships (Unicode data, the V8 snapshot).
    public static func isChromiumEngineFile(_ name: String) -> Bool {
        name == "icudtl.dat" || (name.hasPrefix("v8_context_snapshot") && name.hasSuffix(".bin"))
    }

    /// `frameworks`: names of the entries in Contents/Frameworks; `infoKeys`: the
    /// Info.plist's top-level keys; `hasChromiumEngine`: the frameworks contain the engine's
    /// data files (`isChromiumEngineFile`).
    public static func detect(frameworks: [String], infoKeys: Set<String>, hasChromiumEngine: Bool = false) -> AppKind {
        let names = frameworks.map { $0.lowercased() }
        if names.contains("electron framework.framework") { return .electron }
        if hasChromiumEngine { return .chromium }
        if infoKeys.contains("UIDeviceFamily") || infoKeys.contains("UIApplicationSceneManifest")
            || infoKeys.contains("LSRequiresIPhoneOS")
        {
            return .catalyst
        }
        return .native
    }
}

// MARK: - find_apps

/// One `findApps` entry before it is turned into JSON.
public struct AppListEntry: Equatable, Sendable {
    public var name: String
    public var bundleId: String
    public var path: String
    public var isRunning: Bool
    /// Spotlight `kMDItemLastUsedDate` (nil = unknown).
    public var lastUsed: Date?
    /// Spotlight `kMDItemUseCount` (nil = unknown).
    public var useCount: Int?

    public init(name: String, bundleId: String, path: String, isRunning: Bool, lastUsed: Date? = nil, useCount: Int? = nil) {
        self.name = name
        self.bundleId = bundleId
        self.path = path
        self.isRunning = isRunning
        self.lastUsed = lastUsed
        self.useCount = useCount
    }
}

public enum AppUsageList {
    /// Apps not running are listed when used within this many days.
    public static let recentDays = 14

    /// Running apps first, then the rest; each group most recently used first (unknown
    /// last), then by name.
    public static func sorted(_ entries: [AppListEntry]) -> [AppListEntry] {
        entries.sorted { a, b in
            if a.isRunning != b.isRunning { return a.isRunning }
            switch (a.lastUsed, b.lastUsed) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }

    /// Whether a not-running app belongs in the list (used within `recentDays`).
    public static func isRecent(_ lastUsed: Date?, now: Date, days: Int = recentDays) -> Bool {
        guard let lastUsed else { return false }
        return now.timeIntervalSince(lastUsed) <= Double(days) * 86_400
    }

    /// ISO 8601 date-time (UTC) for the wire.
    public static func isoString(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }
}

import Foundation

/// Pure helpers for interpreting the `app` argument.
public enum AppMatching {
    /// Directories searched for installed apps, in resolution order.
    public static func installedAppDirectories(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        return [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
        ]
    }

    /// Trimmed, `.app`-suffix-free, lower-cased name used for case-insensitive comparison.
    public static func normalizedName(_ s: String) -> String {
        var name = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(".app") { name = String(name.dropLast(4)) }
        return name.lowercased()
    }

    /// Exact, case-insensitive name equality (ignoring a trailing `.app`).
    public static func namesMatch(_ a: String, _ b: String) -> Bool {
        let na = normalizedName(a)
        return !na.isEmpty && na == normalizedName(b)
    }

    /// An absolute path to an `.app` bundle.
    public static func isAbsoluteAppPath(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("/") else { return false }
        var p = t
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p.lowercased().hasSuffix(".app")
    }

    /// Plausible reverse-DNS bundle identifier (`com.apple.TextEdit`).
    public static func looksLikeBundleId(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.hasPrefix("/"), !t.lowercased().hasSuffix(".app") else { return false }
        guard t.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return t.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// `"/System/Applications/TextEdit.app"` → `"TextEdit"`.
    public static func appName(fromPath path: String) -> String {
        var last = (path as NSString).lastPathComponent
        if last.lowercased().hasSuffix(".app") { last = String(last.dropLast(4)) }
        return last
    }

    /// Bundle-id equality is case-insensitive in LaunchServices.
    public static func bundleIdsMatch(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b, !a.isEmpty else { return false }
        return a.caseInsensitiveCompare(b) == .orderedSame
    }

    /// Sort key for findApps: running first, then case-insensitive name.
    public static func listOrder(
        _ lhs: (name: String, isRunning: Bool), _ rhs: (name: String, isRunning: Bool)
    ) -> Bool {
        if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
        let c = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if c != .orderedSame { return c == .orderedAscending }
        return lhs.name < rhs.name
    }
}

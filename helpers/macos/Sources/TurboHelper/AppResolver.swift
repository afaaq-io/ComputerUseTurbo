import AppKit
import TurboCore
import Foundation

/// A resolved target app (`Resolved`).
struct ResolvedApp {
    var name: String
    var bundleId: String
    var path: String
    var pid: pid_t?

    /// Key for per-app session state and approvals: bundle id, else path.
    var key: String { bundleId.isEmpty ? path.lowercased() : bundleId.lowercased() }

    var json: JSONValue {
        [
            "name": .string(name), "bundleId": .string(bundleId), "path": .string(path),
            "pid": pid.map { .int(Int($0)) } ?? .null,
        ]
    }

    var runningApplication: NSRunningApplication? {
        guard let pid else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        return (app?.isTerminated ?? true) ? nil : app
    }
}

/// Resolves the `app` argument: exact bundle id → absolute path → running app by exact
/// (case-insensitive) localized name → installed app by name in the standard folders.
final class AppResolver {
    private let installDirs = AppMatching.installedAppDirectories()

    func resolve(_ rawQuery: String) throws -> ResolvedApp {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw TurboError.invalid("app must be a non-empty name, bundle id or path") }
        let running = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }

        // 1. Exact bundle id (running instance first, then LaunchServices).
        if !query.hasPrefix("/") {
            let byId = running.filter { AppMatching.bundleIdsMatch($0.bundleIdentifier, query) }
            if byId.count == 1 { return Self.resolved(from: byId[0]) }
            if byId.count > 1 { return Self.resolved(from: Self.bestInstance(byId)) }
            if AppMatching.looksLikeBundleId(query),
                let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: query)
            {
                return try resolved(installedAt: url, running: running)
            }
        }

        // 2. Absolute path to an .app bundle.
        if query.hasPrefix("/") {
            let url = URL(fileURLWithPath: query).standardizedFileURL.resolvingSymlinksInPath()
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
                AppMatching.isAbsoluteAppPath(url.path)
            else {
                throw TurboError(.appMissing, "No application bundle at \(query).")
            }
            return try resolved(installedAt: url, running: running, strictPathMatch: true)
        }

        // 3. Running app with that exact localized name. Prefer regular (Dock) apps.
        let byName = running.filter { app in
            guard let name = app.localizedName else { return false }
            return AppMatching.namesMatch(name, query)
        }
        let regular = byName.filter { $0.activationPolicy == .regular }
        let pool = regular.isEmpty ? byName : regular
        if pool.count == 1 { return Self.resolved(from: pool[0]) }
        if pool.count > 1 {
            // Several processes of one app (Godot's editor next to its project manager):
            // not ambiguous, pick the instance the user would mean.
            if Set(pool.map { $0.bundleIdentifier?.lowercased() ?? $0.bundleURL?.path ?? "" }).count == 1 {
                return Self.resolved(from: Self.bestInstance(pool))
            }
            throw ambiguity(query, pool)
        }

        // 4. Installed app with that name.
        if let url = findInstalled(named: query) {
            return try resolved(installedAt: url, running: running)
        }
        throw TurboError(
            .appMissing,
            "No app named \"\(query)\" is running or installed in /Applications, /System/Applications or ~/Applications. Use find_apps to see available apps."
        )
    }

    /// Several running processes of the same app (same bundle): the frontmost one, else
    /// one with a window on screen (the newest of those), else the newest. A process that
    /// is quitting (no window left) is never preferred over one that shows a window.
    static func bestInstance(_ apps: [NSRunningApplication]) -> NSRunningApplication {
        if let front = apps.first(where: { $0.isActive }) { return front }
        func newest(_ list: [NSRunningApplication]) -> NSRunningApplication? {
            list.max { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
        }
        let withWindow = apps.filter { WindowList.hasWindow(pid: $0.processIdentifier) }
        return newest(withWindow) ?? newest(apps) ?? apps[0]
    }

    private func ambiguity(_ query: String, _ apps: [NSRunningApplication]) -> TurboError {
        let list = apps.map { "\($0.localizedName ?? "?") (\($0.bundleIdentifier ?? "no bundle id")) pid \($0.processIdentifier)\($0.bundleURL.map { " at " + $0.path } ?? "")" }
            .joined(separator: "; ")
        return TurboError(
            .appNameUnclear,
            "Multiple running apps match \"\(query)\": \(list). Pass the bundle id or the absolute .app path instead.")
    }

    /// Installed app whose file name (or, failing that, bundle display name) matches.
    private func findInstalled(named query: String) -> URL? {
        let wanted = AppMatching.normalizedName(query)
        let fm = FileManager.default
        for dir in installDirs {
            let direct = dir.appendingPathComponent(AppMatching.appName(fromPath: query) + ".app")
            if fm.fileExists(atPath: direct.path) { return direct }
            guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            if let hit = items.first(where: {
                $0.lowercased().hasSuffix(".app") && AppMatching.normalizedName($0) == wanted
            }) {
                return dir.appendingPathComponent(hit)
            }
        }
        // Second pass: display names that differ from the file name ("Visual Studio Code" for Code.app, …)
        for app in installedApps() where AppMatching.namesMatch(app.name, query) {
            return URL(fileURLWithPath: app.path)
        }
        return nil
    }

    static func resolved(from app: NSRunningApplication) -> ResolvedApp {
        let path = app.bundleURL?.path ?? app.executableURL?.path ?? ""
        let name = app.localizedName ?? (path.isEmpty ? "pid \(app.processIdentifier)" : AppMatching.appName(fromPath: path))
        return ResolvedApp(name: name, bundleId: app.bundleIdentifier ?? "", path: path, pid: app.processIdentifier)
    }

    private func resolved(installedAt url: URL, running: [NSRunningApplication], strictPathMatch: Bool = false) throws
        -> ResolvedApp
    {
        let bundle = Bundle(url: url)
        let bundleId = bundle?.bundleIdentifier ?? ""
        let path = url.path
        // A running instance of exactly this bundle (by path), else (unless strict) by bundle id.
        let samePath = running.filter { $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == path }
        if samePath.count == 1 { return Self.resolved(from: samePath[0]) }
        if samePath.count > 1 { return Self.resolved(from: Self.bestInstance(samePath)) }
        if !strictPathMatch, !bundleId.isEmpty {
            let byId = running.filter { AppMatching.bundleIdsMatch($0.bundleIdentifier, bundleId) }
            if byId.count == 1 { return Self.resolved(from: byId[0]) }
            if byId.count > 1 { return Self.resolved(from: Self.bestInstance(byId)) }
        }
        return ResolvedApp(name: Self.displayName(for: url, bundle: bundle), bundleId: bundleId, path: path, pid: nil)
    }

    /// The name the system shows for a not-running app: the bundle's (localized)
    /// CFBundleDisplayName / CFBundleName — what `NSRunningApplication.localizedName`
    /// reports once it runs — else the Finder name without `.app`.
    static func displayName(for url: URL, bundle: Bundle?) -> String {
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let n = bundle?.object(forInfoDictionaryKey: key) as? String,
                !n.trimmingCharacters(in: .whitespaces).isEmpty
            {
                return n
            }
        }
        let fsName = AppMatching.appName(fromPath: FileManager.default.displayName(atPath: url.path))
        return fsName.isEmpty ? AppMatching.appName(fromPath: url.path) : fsName
    }

    // MARK: findApps

    struct InstalledApp {
        let name: String
        let bundleId: String
        let path: String
    }

    /// All `.app` bundles directly inside the standard folders (deduplicated by bundle id).
    func installedApps() -> [InstalledApp] {
        let fm = FileManager.default
        var seen = Set<String>()
        var out: [InstalledApp] = []
        for dir in installDirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for item in items.sorted() where item.lowercased().hasSuffix(".app") {
                let url = dir.appendingPathComponent(item)
                let bundle = Bundle(url: url)
                let bundleId = bundle?.bundleIdentifier ?? ""
                let key = bundleId.isEmpty ? url.path.lowercased() : bundleId.lowercased()
                if seen.contains(key) { continue }
                seen.insert(key)
                out.append(InstalledApp(name: Self.displayName(for: url, bundle: bundle), bundleId: bundleId, path: url.path))
            }
        }
        return out
    }

    /// `findApps` result: running regular apps plus the apps used in the
    /// last 14 days (Spotlight), each with its last-used date and use count when known;
    /// running first, then most recently used. Without Spotlight: ≤ 50 installed apps.
    func findApps() -> JSONValue {
        let withWindows = WindowList.pidsWithWindows()
        let myPid = getpid()
        let running = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.activationPolicy == .regular && $0.processIdentifier != myPid
        }
        var entries: [AppListEntry] = []
        var extra: [String: [(pid: pid_t, isActive: Bool, hasWindow: Bool)]] = [:]
        var runningKeys = Set<String>()
        for app in running {
            let r = Self.resolved(from: app)
            runningKeys.insert(r.bundleId.lowercased())
            runningKeys.insert(r.path.lowercased())
            let usage = r.path.isEmpty ? nil : AppUsageCatalog.usage(path: r.path)
            entries.append(
                AppListEntry(
                    name: r.name, bundleId: r.bundleId, path: r.path, isRunning: true, lastUsed: usage?.lastUsed,
                    useCount: usage?.useCount))
            extra[r.path, default: []].append(
                (app.processIdentifier, app.isActive, withWindows.contains(app.processIdentifier)))
        }
        func notRunning(_ bundleId: String, _ path: String) -> Bool {
            !runningKeys.contains(path.lowercased()) && (bundleId.isEmpty || !runningKeys.contains(bundleId.lowercased()))
        }
        let helperId = TurboProtocol.helperBundleId.lowercased()
        if let recent = AppUsageCatalog.recent(days: AppUsageList.recentDays) {
            var seen = Set<String>()
            let now = Date()
            for u in recent where notRunning(u.bundleId, u.path) && u.bundleId.lowercased() != helperId {
                guard AppUsageList.isRecent(u.lastUsed, now: now) else { continue }
                let key = u.bundleId.isEmpty ? u.path.lowercased() : u.bundleId.lowercased()
                if seen.contains(key) { continue }
                seen.insert(key)
                let name = u.name.isEmpty ? AppMatching.appName(fromPath: u.path) : u.name
                entries.append(
                    AppListEntry(name: name, bundleId: u.bundleId, path: u.path, isRunning: false, lastUsed: u.lastUsed, useCount: u.useCount))
            }
        } else {
            for app in installedApps().filter({ notRunning($0.bundleId, $0.path) })
                .sorted(by: { AppMatching.listOrder(($0.name, false), ($1.name, false)) }).prefix(50)
            {
                entries.append(AppListEntry(name: app.name, bundleId: app.bundleId, path: app.path, isRunning: false))
            }
        }
        var json: [JSONValue] = AppUsageList.sorted(entries).map { e in
            var o: [String: JSONValue] = [
                "name": .string(e.name), "bundleId": .string(e.bundleId), "path": .string(e.path), "isRunning": .bool(e.isRunning),
                "isActive": false, "hasWindow": false,
                "lastUsed": e.lastUsed.map { .string(AppUsageList.isoString($0)) } ?? .null,
                "useCount": e.useCount.map { .int($0) } ?? .null,
            ]
            if e.isRunning, let x = extra[e.path]?.first {
                extra[e.path]?.removeFirst()
                o["pid"] = .int(Int(x.pid))
                o["isActive"] = .bool(x.isActive)
                o["hasWindow"] = .bool(x.hasWindow)
            }
            return .object(o)
        }
        json += Self.systemSurfaces(excluding: myPid).map { app in
            let r = Self.resolved(from: app)
            return [
                "name": .string(r.name), "bundleId": .string(r.bundleId), "path": .string(r.path), "isRunning": true,
                "isActive": .bool(app.isActive), "hasWindow": false, "lastUsed": .null, "useCount": .null,
                "pid": .int(Int(app.processIdentifier)), "background": true,
            ]
        }
        return ["apps": .array(json)]
    }

    /// Background processes without a Dock icon that show something on screen: status
    /// items in the menu bar (the system's Control Center and clock, a sync app's icon) or
    /// panels such as a search field or a notification list. They are targets like any
    /// app; their observation lists their status items, which open their panels.
    static func systemSurfaces(excluding myPid: pid_t) -> [NSRunningApplication] {
        let shown = Set(WindowList.onScreenWindows().filter { $0.bounds.width > 1 && $0.bounds.height > 1 && $0.alpha > 0.05 }.map(\.pid))
        let candidates = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.activationPolicy != .regular && $0.processIdentifier != myPid
                && !($0.bundleIdentifier ?? "").isEmpty
        }
        // Status items are drawn by the window server on current systems, so only
        // accessibility tells whose they are: asked of every candidate at once, briefly.
        final class Hits: @unchecked Sendable {
            let lock = NSLock()
            var pids = Set<pid_t>()
        }
        let hits = Hits()
        DispatchQueue.concurrentPerform(iterations: candidates.count) { i in
            let pid = candidates[i].processIdentifier
            var show = shown.contains(pid)
            if !show {
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.25)
                var bar: CFTypeRef?
                if AXUIElementCopyAttributeValue(app, AXReader.extrasMenuBarAttribute as CFString, &bar) == .success, let bar,
                    CFGetTypeID(bar) == AXUIElementGetTypeID()
                {
                    var count: CFIndex = 0
                    show = AXUIElementGetAttributeValueCount(bar as! AXUIElement, kAXChildrenAttribute as CFString, &count) == .success && count > 0
                }
            }
            if show {
                hits.lock.lock()
                hits.pids.insert(pid)
                hits.lock.unlock()
            }
        }
        return candidates.filter { hits.pids.contains($0.processIdentifier) }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }
}

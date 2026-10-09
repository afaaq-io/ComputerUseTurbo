import AppKit
import CoreServices
import TurboCore
import Foundation

/// Bundle facts for app-kind detection, cached per bundle path.
enum AppKindCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: AppKind] = [:]

    static func kind(path: String) -> AppKind {
        guard !path.isEmpty else { return .native }
        lock.lock()
        if let k = cache[path] {
            lock.unlock()
            return k
        }
        lock.unlock()
        let url = URL(fileURLWithPath: path)
        let frameworks = (try? FileManager.default.contentsOfDirectory(
            atPath: url.appendingPathComponent("Contents/Frameworks").path)) ?? []
        let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
        let kind = AppKind.detect(
            frameworks: frameworks, infoKeys: Set(info.keys),
            hasChromiumEngine: Self.containsChromiumEngine(url.appendingPathComponent("Contents/Frameworks")))
        lock.lock()
        cache[path] = kind
        lock.unlock()
        return kind
    }

    /// The Chromium engine's data files somewhere in the bundle's frameworks (≤ 6 levels).
    static func containsChromiumEngine(_ frameworks: URL) -> Bool {
        guard let walker = FileManager.default.enumerator(
            at: frameworks, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return false }
        for case let file as URL in walker {
            if walker.level > 6 { walker.skipDescendants(); continue }
            if AppKind.isChromiumEngineFile(file.lastPathComponent) { return true }
        }
        return false
    }

    nonisolated(unsafe) private static var browsers: [String: Bool] = [:]

    /// Whether the bundle is a web browser (it registers http / https), cached per path.
    static func isWebBrowser(path: String) -> Bool {
        guard !path.isEmpty else { return false }
        lock.lock()
        if let b = browsers[path] {
            lock.unlock()
            return b
        }
        lock.unlock()
        let info = NSDictionary(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist"))
        let types = info?["CFBundleURLTypes"] as? [[String: Any]] ?? []
        let result = PageLoadPolicy.isWebBrowser(urlTypes: types)
        lock.lock()
        browsers[path] = result
        lock.unlock()
        return result
    }
}

/// Recently used apps from Spotlight (`kMDItemLastUsedDate`, `kMDItemUseCount`) for
/// `findApps`.
enum AppUsageCatalog {
    struct Usage {
        let path: String
        let bundleId: String
        let name: String
        let lastUsed: Date?
        let useCount: Int?
    }

    /// Apps used within `days` (application bundles only, nothing under /System/Library or
    /// /Library). nil when Spotlight did not answer within `timeout`.
    static func recent(days: Int, timeout: TimeInterval = 2) -> [Usage]? {
        final class Box: @unchecked Sendable { var result: [Usage]? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { done.signal() }
            let query = "kMDItemContentTypeTree == \"com.apple.application\" && kMDItemLastUsedDate >= $time.today(-\(days))"
            guard let q = MDQueryCreate(kCFAllocatorDefault, query as CFString, nil, nil) else { return }
            guard MDQueryExecute(q, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return }
            var out: [Usage] = []
            for i in 0..<MDQueryGetResultCount(q) {
                guard let raw = MDQueryGetResultAtIndex(q, i) else { continue }
                let item = unsafeBitCast(raw, to: MDItem.self)
                guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String, path.hasSuffix(".app") else { continue }
                if path.hasPrefix("/System/Library/") || path.hasPrefix("/Library/") || path.contains(".app/") { continue }
                out.append(usage(item, path: path))
            }
            box.result = out
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            Log.warn("findApps: Spotlight did not answer within \(timeout) s")
            return nil
        }
        return box.result
    }

    /// Spotlight usage of one bundle (running apps).
    static func usage(path: String) -> Usage? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return usage(item, path: path)
    }

    private static func usage(_ item: MDItem, path: String) -> Usage {
        let last = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
        let uses = (MDItemCopyAttribute(item, "kMDItemUseCount" as CFString) as? NSNumber)?.intValue
        let bid = MDItemCopyAttribute(item, kMDItemCFBundleIdentifier) as? String ?? ""
        let name = (MDItemCopyAttribute(item, kMDItemDisplayName) as? String).map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 } ?? ""
        return Usage(path: path, bundleId: bid, name: name, lastUsed: last, useCount: uses)
    }
}

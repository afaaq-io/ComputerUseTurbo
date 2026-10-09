import AppKit
import TurboCore
import Darwin
import Foundation

/// Identifies the process that owns an accessibility element, for UI hosted inside an
/// approved app by another process (remote views, web content, app extensions).
final class OwnerResolver {
    struct Owner {
        let pid: pid_t
        let name: String
        /// Innermost bundle first, then every enclosing app (an extension inherits the
        /// identity of the app that ships it).
        let bundleIds: [String]
    }

    private let lock = NSLock()
    private var cache: [pid_t: (owner: Owner, at: Date)] = [:]
    /// Pids are recycled; cached owners are re-resolved after this long.
    private let ttl: TimeInterval = 30

    func owner(of pid: pid_t) -> Owner {
        lock.lock()
        if let hit = cache[pid], Date().timeIntervalSince(hit.at) < ttl {
            lock.unlock()
            return hit.owner
        }
        lock.unlock()
        let owner = Self.resolve(pid)
        lock.lock()
        cache[pid] = (owner, Date())
        if cache.count > 256 { cache = cache.filter { Date().timeIntervalSince($0.value.at) < ttl } }
        lock.unlock()
        return owner
    }

    private static func resolve(_ pid: pid_t) -> Owner {
        let running = NSRunningApplication(processIdentifier: pid)
        var paths: [String] = []
        if let bundle = running?.bundleURL?.path { paths.append(bundle) }
        if let exe = running?.executableURL?.path ?? executablePath(pid) { paths.append(exe) }
        var ids: [String] = []
        for path in paths {
            for bundlePath in BundleOwnership.enclosingBundlePaths(of: path) {
                if let id = Bundle(path: bundlePath)?.bundleIdentifier, !ids.contains(id) { ids.append(id) }
            }
        }
        if let id = running?.bundleIdentifier, !ids.contains(id) { ids.insert(id, at: 0) }
        let name =
            running?.localizedName
            ?? paths.last.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? "pid \(pid)"
        return Owner(pid: pid, name: name, bundleIds: ids)
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(cString: buffer)
    }
}

import CryptoKit
import Foundation

/// Monotonic index source for one session. A new session (or `finishTurn`/`reset`)
/// starts again at 0.
///
/// One counter is shared by all apps observed in a session, so an index is unique
/// across the whole session (an index from one app can never alias an element of another).
public final class IndexCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var nextValue: Int

    /// `startingAt` > 0 continues the numbering of an earlier incarnation of the same
    /// session (see `SessionManager.expireIdle`), so its old indices are never handed out
    /// again.
    public init(startingAt start: Int = 0) {
        nextValue = max(0, start)
    }

    /// Hand out the next index (`maxIndexEverAssigned + 1`).
    public func allocate() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let v = nextValue
        nextValue += 1
        return v
    }

    /// The index `allocate()` would return next.
    public var next: Int {
        lock.lock()
        defer { lock.unlock() }
        return nextValue
    }
}

/// Opaque identity of a *live* accessibility element. The helper wraps an
/// `AXUIElement` (whose `Hashable` conformance is `CFHash` / `CFEqual`, so two reads of
/// the same UI element compare equal); any hashable stand-in works. TurboCore never
/// looks inside.
public struct LiveKey: Hashable, @unchecked Sendable {
    public let base: AnyHashable

    public init<T: Hashable>(_ value: T) {
        base = AnyHashable(value)
    }
}

/// Fixed-size digest of a path key (or of an element's content). The indexer keeps only
/// these 16 bytes per remembered index instead of the full multi-component path string
///. SHA-256 truncated to 128 bits: web pages
/// control labels, so a non-cryptographic hash could be steered into a collision.
public struct PathDigest: Hashable, Sendable, CustomStringConvertible {
    public let hi: UInt64
    public let lo: UInt64

    public init(_ text: String) {
        let d = SHA256.hash(data: Data(text.utf8))
        var hi: UInt64 = 0
        var lo: UInt64 = 0
        for (i, b) in d.prefix(16).enumerated() {
            if i < 8 { hi = hi << 8 | UInt64(b) } else { lo = lo << 8 | UInt64(b) }
        }
        self.hi = hi
        self.lo = lo
    }

    public var description: String { String(format: "%016llx%016llx", hi, lo) }
}

/// One element that needs an index in the current observation.
public struct IndexCandidate: Sendable {
    /// Path key without volatile parts (see `TreeSerializer.identityComponent`).
    public var stableKey: String
    /// The live element, when the reader has one.
    public var liveKey: LiveKey?
    public var role: String
    public var subrole: String?
    /// What the element shows (label and value, see `TreeSerializer.contentKey`). A
    /// path-only match (the old owner has no live element, e.g. after an app relaunch)
    /// also requires the same content, so a different document that took over the old
    /// one's path never inherits its indices.
    public var content: String?

    public init(stableKey: String, liveKey: LiveKey?, role: String, subrole: String?, content: String? = nil) {
        self.stableKey = stableKey
        self.liveKey = liveKey
        self.role = role
        self.subrole = subrole
        self.content = content
    }
}

/// Assigns element indices for one (session, app) pair ("Indices +
/// identity"). Per observation, in this order:
///
/// 1. **Same live element.** An element that is the same live accessibility element as
///    one indexed before (`LiveKey` equality) and still has the same role and subrole
///    keeps its index — whatever happened to its window title, its own label or value,
///    or its ancestors' labels.
/// 2. **Replacement of a vanished element.** Otherwise, an element whose path key
///    (`stableKey`) equals the key of an earlier element that is *gone* (its live element
///    is invalid, checked with `isAlive`) inherits that index. An index whose element is
///    still alive is never taken. Liveness checks are budgeted per observation (they are
///    IPC round trips, slow for dead elements); past the budget the old owner is assumed
///    alive and a fresh index is used.
/// 3. Otherwise a new index from the session counter.
///
/// An index whose live element was forgotten because the app relaunched (see
/// `forgetLiveElements`) is matched in step 2 only by an element with the same path key
/// **and** the same content (label and value): after a relaunch, window order (focus
/// order) can differ, so the path alone could hand one document's indices to another.
///
/// Each index is given to at most one element per observation.
///
/// Memory is bounded: once more than `capacity` indices are remembered, the ones seen
/// least recently are forgotten (down to 75 % of the capacity), never those of the
/// current observation. A forgotten element that reappears gets a **new** index (the
/// counter only moves forward), so an index never comes back to name a different element.
public final class IdentityIndexer: @unchecked Sendable {
    public static let defaultCapacity = 50_000
    /// Liveness checks per observation (step 2).
    public static let defaultLivenessChecks = 300
    /// Wall-clock budget for liveness checks per observation (step 2).
    public static let defaultLivenessSeconds: TimeInterval = 0.2

    public let counter: IndexCounter
    public let capacity: Int
    public let maxLivenessChecks: Int
    public let maxLivenessSeconds: TimeInterval

    private struct Record {
        var liveKey: LiveKey?
        /// Digest of the path key (the full string is never kept).
        var stableKey: PathDigest
        var role: String
        var subrole: String?
        var content: PathDigest?
        var lastSeen: Int
        /// Its live element was forgotten by `forgetLiveElements` (app relaunch).
        var detached = false
    }

    private let lock = NSLock()
    private var records: [Int: Record] = [:]
    private var byLive: [LiveKey: Int] = [:]
    private var byStable: [PathDigest: Int] = [:]
    private var generation = 0
    /// Liveness checks made by the latest `assign` (for the log).
    public private(set) var lastLivenessChecks = 0

    public init(
        counter: IndexCounter = IndexCounter(), capacity: Int = IdentityIndexer.defaultCapacity,
        maxLivenessChecks: Int = IdentityIndexer.defaultLivenessChecks,
        maxLivenessSeconds: TimeInterval = IdentityIndexer.defaultLivenessSeconds
    ) {
        self.counter = counter
        self.capacity = max(1, capacity)
        self.maxLivenessChecks = max(0, maxLivenessChecks)
        self.maxLivenessSeconds = max(0, maxLivenessSeconds)
    }

    /// Indices for `candidates` (one observation, in document order). `isAlive` answers
    /// whether a previously indexed live element still exists.
    public func assign(_ candidates: [IndexCandidate], isAlive: (LiveKey) -> Bool) -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        let stable = candidates.map { PathDigest($0.stableKey) }
        let content = candidates.map { $0.content.map(PathDigest.init) }
        var result = [Int?](repeating: nil, count: candidates.count)
        var taken = Set<Int>()

        // 1. Same live element, same role/subrole.
        for (i, c) in candidates.enumerated() {
            guard let key = c.liveKey, let idx = byLive[key], !taken.contains(idx), let rec = records[idx],
                rec.liveKey == key, rec.role == c.role, rec.subrole == c.subrole
            else { continue }
            result[i] = idx
            taken.insert(idx)
        }

        // 2. Replacement of a vanished element with the same path key; 3. new index.
        var checks = 0
        let started = Date()
        func ownerIsGone(_ rec: Record) -> Bool {
            // An index remembered without a live element (no reader handle) is matched by
            // path alone.
            guard let owner = rec.liveKey else { return true }
            guard checks < maxLivenessChecks, Date().timeIntervalSince(started) <= maxLivenessSeconds else {
                return false  // out of budget: assume alive, never steal
            }
            checks += 1
            return !isAlive(owner)
        }
        for i in candidates.indices where result[i] == nil {
            let c = candidates[i]
            if let idx = byStable[stable[i]], !taken.contains(idx), let rec = records[idx],
                rec.stableKey == stable[i], rec.role == c.role, rec.subrole == c.subrole,
                rec.liveKey == nil || rec.liveKey != c.liveKey,
                // Relaunch (no live owner to check): the content must agree too.
                !rec.detached || rec.content == content[i],
                ownerIsGone(rec)
            {
                result[i] = idx
                taken.insert(idx)
                continue
            }
            let idx = counter.allocate()
            result[i] = idx
            taken.insert(idx)
        }
        lastLivenessChecks = checks

        // Remember what each index names now.
        var out: [Int] = []
        out.reserveCapacity(candidates.count)
        for (i, c) in candidates.enumerated() {
            let idx = result[i]!
            out.append(idx)
            if let old = records[idx] {
                if let oldLive = old.liveKey, oldLive != c.liveKey, byLive[oldLive] == idx {
                    byLive.removeValue(forKey: oldLive)
                }
                if old.stableKey != stable[i], byStable[old.stableKey] == idx {
                    byStable.removeValue(forKey: old.stableKey)
                }
            }
            records[idx] = Record(
                liveKey: c.liveKey, stableKey: stable[i], role: c.role, subrole: c.subrole, content: content[i],
                lastSeen: generation)
            if let key = c.liveKey { byLive[key] = idx }
            byStable[stable[i]] = idx
        }
        return out
    }

    /// Every live element remembered so far is gone (the app relaunched): indices are
    /// then matched by path key and content (no liveness check) until new live elements
    /// are seen.
    public func forgetLiveElements() {
        lock.lock()
        defer { lock.unlock() }
        for idx in Array(records.keys) where records[idx]?.liveKey != nil {
            records[idx]?.liveKey = nil
            records[idx]?.detached = true
        }
        byLive.removeAll()
    }

    /// Digest of the path key of the element that owns `index`, if this indexer assigned
    /// it (and still remembers it).
    public func identity(for index: Int) -> PathDigest? {
        lock.lock()
        defer { lock.unlock() }
        return records[index]?.stableKey
    }

    /// Whether `index` is remembered without a live element (it was last seen before the
    /// app relaunched and has not been matched since).
    public func isDetached(_ index: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return records[index]?.detached ?? false
    }

    /// Number of indices remembered.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return records.count
    }

    /// Forget least-recently-seen indices once more than `capacity` are remembered.
    /// Returns how many were forgotten.
    @discardableResult
    public func pruneIfNeeded() -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard records.count > capacity else { return 0 }
        let target = max(1, capacity * 3 / 4)
        let removable = records.filter { $0.value.lastSeen < generation }
            .sorted { ($0.value.lastSeen, $0.key) < ($1.value.lastSeen, $1.key) }
        var removed = 0
        for (idx, rec) in removable {
            if records.count <= target { break }
            records.removeValue(forKey: idx)
            if let key = rec.liveKey, byLive[key] == idx { byLive.removeValue(forKey: key) }
            if byStable[rec.stableKey] == idx { byStable.removeValue(forKey: rec.stableKey) }
            removed += 1
        }
        return removed
    }
}

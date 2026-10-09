import Foundation

/// Index-keyed diff between two observations.
public enum TreeDiff {
    public enum Outcome: Equatable, Sendable {
        /// Nothing changed.
        case noChanges
        /// `~`/`+` lines in current-tree (document, i.e. depth-first pre-) order — a
        /// parent's change always precedes its descendants' — then the `- Removed
        /// element IDs:` line.
        case changes([String])
        /// The diff would exceed the line budget; emit the full tree instead.
        case tooLarge(lineCount: Int)
    }

    public static let header = "Changes since the last observe_app (M modified, A added, D deleted):"
    public static let noChangesLine = "No changes since the last observe_app."

    /// Compare `current` against `previous` (index → line, indentation ignored).
    /// `ignoringRemoved`: indices that are gone only because they left the observation
    /// scope (the menu bar after the first observation): not reported removed.
    public static func compute(
        previous: [Int: String], current: [SerializedElement],
        budget: Int = TurboProtocol.diffLineBudget, ignoringRemoved: Set<Int> = []
    ) -> Outcome {
        var lines: [String] = []
        var seen = Set<Int>()
        for element in current {
            seen.insert(element.index)
            if let old = previous[element.index] {
                if old != element.line { lines.append("M " + element.line) }
            } else {
                lines.append("A " + element.line)
            }
        }
        let removed = previous.keys.filter { !seen.contains($0) && !ignoringRemoved.contains($0) }.sorted()
        if !removed.isEmpty {
            lines.append("D gone: " + compressRanges(removed))
        }
        if lines.isEmpty { return .noChanges }
        if lines.count > budget { return .tooLarge(lineCount: lines.count) }
        return .changes(lines)
    }

    /// A diff is sent only if its text is at most this fraction of the full tree's
    /// (UTF-8 bytes, header line included); otherwise the full tree is sent.
    public static let maxDiffRatio = 0.6

    /// Whether `diffLines` (the `~`/`+`/`-` lines) save enough over `fullLines` (the
    /// indented full-tree lines) to be worth sending.
    public static func isWorthSending(diffLines: [String], fullLines: [String], maxRatio: Double = maxDiffRatio) -> Bool {
        let diffBytes = ([header] + diffLines).reduce(0) { $0 + $1.utf8.count + 1 }
        let fullBytes = fullLines.reduce(0) { $0 + $1.utf8.count + 1 }
        return Double(diffBytes) <= maxRatio * Double(fullBytes)
    }

    /// `[40,41,42,43,44,47]` → `"40-44, 47"`. Input need not be sorted; duplicates collapse.
    /// Indices of the menu bar subtree in `elements` (the `AXMenuBar` line and everything
    /// indented below it).
    public static func menuBarIndices(_ elements: [SerializedElement]) -> Set<Int> {
        var out = Set<Int>()
        var depth: Int?
        for e in elements {
            if let d = depth, e.depth > d {
                out.insert(e.index)
                continue
            }
            depth = nil
            if e.role == AXRoles.menuBar {
                depth = e.depth
                out.insert(e.index)
            }
        }
        return out
    }

    public static func compressRanges(_ ids: [Int]) -> String {
        let sorted = Array(Set(ids)).sorted()
        guard var start = sorted.first else { return "" }
        var parts: [String] = []
        var prev = start
        func flush() { parts.append(start == prev ? "#\(start)" : "#\(start)-#\(prev)") }
        for id in sorted.dropFirst() {
            if id == prev + 1 {
                prev = id
            } else {
                flush()
                start = id
                prev = id
            }
        }
        flush()
        return parts.joined(separator: ", ")
    }
}

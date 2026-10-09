import Foundation

/// `pickText.selection`.
public enum TextSelectionMode: String, Sendable {
    case text
    case cursorBefore = "cursor_before"
    case cursorAfter = "cursor_after"
}

/// A UTF-16 range as used by `kAXSelectedTextRangeAttribute` (`CFRange`).
public struct UTF16Range: Equatable, Sendable {
    public let location: Int
    public let length: Int
    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

public enum TextRangeFinder {
    /// Find the first occurrence of `text` in `haystack` whose preceding text ends with
    /// `prefix` and whose following text starts with `suffix` (both optional), and map it
    /// to the requested selection. Returns nil when nothing matches.
    public static func find(
        in haystack: String, text: String, prefix: String? = nil, suffix: String? = nil,
        mode: TextSelectionMode = .text
    ) -> UTF16Range? {
        guard !text.isEmpty else { return nil }
        let hay = haystack as NSString
        let needle = text as NSString
        let pre = (prefix ?? "") as NSString
        let suf = (suffix ?? "") as NSString
        var searchStart = 0
        while searchStart <= hay.length - needle.length {
            let found = hay.range(
                of: text, options: [.literal], range: NSRange(location: searchStart, length: hay.length - searchStart))
            if found.location == NSNotFound { return nil }
            let before = found.location
            let after = found.location + found.length
            let prefixOK =
                pre.length == 0
                || (before >= pre.length
                    && hay.substring(with: NSRange(location: before - pre.length, length: pre.length)) == pre as String)
            let suffixOK =
                suf.length == 0
                || (hay.length - after >= suf.length
                    && hay.substring(with: NSRange(location: after, length: suf.length)) == suf as String)
            if prefixOK && suffixOK {
                switch mode {
                case .text: return UTF16Range(location: found.location, length: found.length)
                case .cursorBefore: return UTF16Range(location: found.location, length: 0)
                case .cursorAfter: return UTF16Range(location: after, length: 0)
                }
            }
            searchStart = found.location + 1
        }
        return nil
    }
}

/// One step of `writeText` synthesis.
public enum TypingSegment: Equatable, Sendable {
    /// Up to `maxUTF16` code units delivered with `CGEventKeyboardSetUnicodeString`.
    case text(String)
    /// A Return key press (`\n`, `\r`, or `\r\n`).
    case returnKey
    /// A tab character, always delivered on its own: like Return it usually moves
    /// keyboard focus (to the next field), so the secure-field check must run again
    /// before anything typed after it.
    case tab

    /// Return and Tab can move keyboard focus (submit a form, go to the next field).
    public var movesFocus: Bool {
        switch self {
        case .returnKey, .tab: return true
        case .text: return false
        }
    }

    /// Characters (grapheme clusters) of the original text this segment delivers.
    public var characterCount: Int {
        switch self {
        case .text(let s): return s.count
        case .returnKey, .tab: return 1
        }
    }
}

public enum TextChunker {
    /// Split `text` into Unicode chunks of at most `maxUTF16` UTF-16 units (never splitting
    /// a grapheme cluster unless a single cluster is itself longer), Return presses and
    /// tabs (each tab is a segment of its own, see `TypingSegment.tab`).
    public static func segments(_ text: String, maxUTF16: Int = 20) -> [TypingSegment] {
        precondition(maxUTF16 > 0)
        var out: [TypingSegment] = []
        var current = ""
        var currentUnits = 0
        func flush() {
            if !current.isEmpty { out.append(.text(current)) }
            current = ""
            currentUnits = 0
        }
        for ch in text {
            // "\r\n" is a single Character in Swift.
            if ch == "\n" || ch == "\r" || ch == "\r\n" {
                flush()
                out.append(.returnKey)
                continue
            }
            if ch == "\t" {
                flush()
                out.append(.tab)
                continue
            }
            let units = String(ch).utf16.count
            if units > maxUTF16 {
                // Pathological cluster (e.g. long emoji ZWJ sequence): split on scalars.
                flush()
                var piece = ""
                var pieceUnits = 0
                for scalar in String(ch).unicodeScalars {
                    let u = String(scalar).utf16.count
                    if pieceUnits + u > maxUTF16 {
                        out.append(.text(piece))
                        piece = ""
                        pieceUnits = 0
                    }
                    piece.unicodeScalars.append(scalar)
                    pieceUnits += u
                }
                if !piece.isEmpty { out.append(.text(piece)) }
                continue
            }
            if currentUnits + units > maxUTF16 { flush() }
            current.append(ch)
            currentUnits += units
        }
        flush()
        return out
    }
}

/// Drives `writeText` segment by segment, keeping the safety checks in
/// one place:
///
/// * `interrupted()` is polled before every segment (user Stop, screen lock, deadline);
///   true ends typing early.
/// * after a segment that can move focus (Return / Tab) `settle()` gives the app time to
///   move it before the next check;
/// * `guardFocus(typedSoFar)` runs before **every** segment and throws to refuse (the
///   secure-field / secure-input check). Checking only once before the first segment
///   would let `"alice\nhunter2"` type the password into the field Return moved to.
public enum TypingDriver {
    public enum Outcome: Equatable, Sendable {
        /// Every segment was delivered; `typed` characters in total.
        case completed(typed: Int)
        /// `interrupted()` stopped typing after `typed` characters.
        case interrupted(typed: Int)
    }

    public static func run(
        _ segments: [TypingSegment],
        interrupted: () -> Bool,
        settle: () -> Void,
        guardFocus: (_ typedSoFar: Int) throws -> Void,
        deliver: (TypingSegment) throws -> Void
    ) throws -> Outcome {
        var typed = 0
        var previous: TypingSegment?
        for segment in segments {
            if interrupted() { return .interrupted(typed: typed) }
            if previous?.movesFocus == true {
                settle()
                if interrupted() { return .interrupted(typed: typed) }
            }
            try guardFocus(typed)
            try deliver(segment)
            typed += segment.characterCount
            previous = segment
        }
        return .completed(typed: typed)
    }
}

import Foundation

/// One key press of `writeText`'s key-event path: exactly ONE character per keyDown /
/// keyUp pair. Apps that read a single character per key event
/// (Blender's text fields read one character from each event) otherwise drop
/// everything after the first character of a multi-character event.
public struct TypedKey: Equatable, Sendable {
    /// The character, set as the event's Unicode string (one grapheme cluster).
    public let text: String
    /// The real virtual keycode when the character is on a key of the current layout
    /// (not a dead key); nil = a Unicode-only event on the carrier keycode.
    public let keyCode: UInt16?
    /// The layout needs shift for this character (sent as the event's shift flag).
    public let shift: Bool

    public init(text: String, keyCode: UInt16?, shift: Bool) {
        self.text = text
        self.keyCode = keyCode
        self.shift = shift
    }
}

public enum KeyTyping {
    /// One `TypedKey` per character of `text`. A character the layout produces on a key
    /// (`characterMap`, built with UCKeyTranslate) gets that key's virtual keycode and
    /// shift state, plus the character as the Unicode string; dead-key characters and
    /// characters with no key (accents, emoji, other scripts) are Unicode-only.
    /// Newlines and tabs are not expected here (`TextChunker` makes them key presses);
    /// should one arrive it is Unicode-only too.
    public static func plan(
        _ text: String, characterMap: [Character: KeyStroke], deadKeys: Set<Character> = []
    ) -> [TypedKey] {
        text.map { ch in
            let s = String(ch)
            if ch.unicodeScalars.count == 1, !deadKeys.contains(ch), let stroke = characterMap[ch],
                !ch.isNewline, ch != "\t"
            {
                return TypedKey(text: s, keyCode: stroke.keyCode, shift: stroke.needsShift)
            }
            return TypedKey(text: s, keyCode: nil, shift: false)
        }
    }
}

/// `<support>/settings.json` → `"typing":{"keyDelayMs":12}`: pause after each typed key
/// (keyDown → keyUp → pause). Anything missing or malformed falls back to the default.
public struct TypingSettings: Equatable, Sendable {
    public var keyDelayMs: Int

    public static let defaults = TypingSettings(keyDelayMs: 12)
    public static let keyDelayRange: ClosedRange<Int> = 0...200

    public init(keyDelayMs: Int) {
        self.keyDelayMs = keyDelayMs
    }

    public static func parse(_ data: Data?) -> TypingSettings {
        var s = defaults
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let typing = root["typing"] as? [String: Any]
        else { return s }
        if let n = typing["keyDelayMs"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            let d = n.doubleValue
            if d.isFinite {
                s.keyDelayMs = Int(min(Double(keyDelayRange.upperBound), max(Double(keyDelayRange.lowerBound), d.rounded())))
            }
        }
        return s
    }

    public static func load(_ url: URL) -> TypingSettings {
        parse(try? Data(contentsOf: url))
    }
}

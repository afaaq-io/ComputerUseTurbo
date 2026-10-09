import Foundation

// MARK: - App commands (`appCommands`, step `runCommand`)

extension MenuShortcut {
    /// The shortcut in `send_keys` syntax ("cmd+shift+e", "cmd+Return"), nil when the key
    /// cannot be named.
    public var comboText: String? {
        var key: String?
        if let ch = character, ch.count == 1, let c = ch.first, MenuShortcutMatcher.isPrintable(c) {
            key = c == " " ? "space" : String(c).lowercased()
        } else if let vk = virtualKey {
            key = Self.keyNames[UInt16(truncatingIfNeeded: vk)]
        } else if let ch = character, let scalar = ch.unicodeScalars.first {
            // Function-key glyphs in the private-use area (NSUpArrowFunctionKey…).
            key = Self.functionGlyphs[scalar.value]
        }
        guard let key else { return nil }
        let m = modifiers
        var parts: [String] = []
        if m.contains(.control) { parts.append("ctrl") }
        if m.contains(.option) { parts.append("alt") }
        if m.contains(.shift) { parts.append("shift") }
        if m.contains(.command) { parts.append("cmd") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    static let keyNames: [UInt16: String] = {
        var m: [UInt16: String] = [
            0x24: "Return", 0x30: "Tab", 0x31: "space", 0x35: "Escape", 0x33: "BackSpace", 0x75: "Delete",
            0x7E: "Up", 0x7D: "Down", 0x7B: "Left", 0x7C: "Right", 0x73: "Home", 0x77: "End", 0x74: "Page_Up",
            0x79: "Page_Down", 0x4C: "KP_Enter",
        ]
        let fkeys: [UInt16] = [
            0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,
        ]
        for (i, code) in fkeys.enumerated() { m[code] = "F\(i + 1)" }
        return m
    }()

    static let functionGlyphs: [UInt32: String] = {
        var m: [UInt32: String] = [
            0xF700: "Up", 0xF701: "Down", 0xF702: "Left", 0xF703: "Right", 0xF728: "Delete", 0xF729: "Home",
            0xF72B: "End", 0xF72C: "Page_Up", 0xF72D: "Page_Down", 0x0D: "Return", 0x09: "Tab", 0x1B: "Escape",
            0x08: "BackSpace", 0x7F: "BackSpace", 0x03: "KP_Enter",
        ]
        for i in 0..<20 { m[0xF704 + UInt32(i)] = "F\(i + 1)" }
        return m
    }()
}

/// Menu titles as the agent names them: case, surrounding space and a trailing "…" / "..."
/// do not matter ("Export As PDF" finds "Export As PDF…").
public enum MenuTitle {
    public static func normalize(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix("…") || t.hasSuffix("...") {
            t = String(t.dropLast(t.hasSuffix("…") ? 1 : 3)).trimmingCharacters(in: .whitespaces)
        }
        return t.lowercased()
    }

    public static func same(_ a: String, _ b: String) -> Bool { normalize(a) == normalize(b) }

    /// Validate a `runCommand` path: 1-8 non-empty titles of at most 300 characters.
    public static func validatePath(_ value: JSONValue?) throws -> [String] {
        guard let value, case .array(let items) = value else {
            throw TurboError.invalid("runCommand requires path: an array of menu titles, e.g. [\"File\", \"Export…\"]")
        }
        let titles = items.compactMap(\.stringValue).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard titles.count == items.count, (1...8).contains(titles.count), titles.allSatisfy({ !$0.isEmpty && $0.count <= 300 })
        else {
            throw TurboError.invalid("runCommand path must be 1-8 non-empty menu titles (strings)")
        }
        return titles
    }

    /// "File ▸ Export ▸ PDF…"
    public static func display(_ path: [String]) -> String {
        path.map { TreeFormat.clean($0, limit: 80) }.joined(separator: " ▸ ")
    }
}

/// Items an app adds to a menu by itself — recent documents, history, bookmarks, open windows
/// — are made from one template, so they share one identifier (their action), while every
/// real command has its own. Auto-generated identifiers (`_NS:123`) say nothing.
public enum AppFilledItems {
    public static func identifiers(_ ids: [String?]) -> Set<String> {
        var counts: [String: Int] = [:]
        for case let id? in ids where !id.isEmpty && TreeFormat.meaningfulIdentifier(id) != nil {
            counts[id, default: 0] += 1
        }
        return Set(counts.filter { $0.value >= 2 }.keys)
    }
}

/// Section headings inside a menu ("Halves", "Quarters" in Window ▸ Move & Resize) are
/// labels, not commands: an item without an identifier or shortcut that starts its group
/// (first item, or right after a separator) while the item after it has an identifier.
public enum MenuSection {
    public static func isHeading(at i: Int, titles: [String], identifiers: [String?], hasShortcut: [Bool]) -> Bool {
        guard i < titles.count, !titles[i].trimmingCharacters(in: .whitespaces).isEmpty, !hasShortcut[i],
            TreeFormat.meaningfulIdentifier(identifiers[i]) == nil, i + 1 < titles.count,
            TreeFormat.meaningfulIdentifier(identifiers[i + 1]) != nil
        else { return false }
        return i == 0 || titles[i - 1].trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// One command of an app's menus, as `appCommands` reports it.
public struct AppCommand: Equatable, Sendable {
    public var path: [String]
    public var shortcut: String?
    public var enabled: Bool?

    public init(path: [String], shortcut: String? = nil, enabled: Bool? = nil) {
        self.path = path
        self.shortcut = shortcut
        self.enabled = enabled
    }

    public var json: JSONValue {
        var o: [String: JSONValue] = ["path": .array(path.map { .string($0) })]
        if let shortcut { o["shortcut"] = .string(shortcut) }
        if let enabled { o["enabled"] = .bool(enabled) }
        return .object(o)
    }
}

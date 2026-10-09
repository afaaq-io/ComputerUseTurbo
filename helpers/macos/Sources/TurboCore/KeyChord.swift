import Foundation

/// Modifier flags with the same raw values as `CGEventFlags` masks, so the helper can
/// pass `rawValue` straight to CoreGraphics.
public struct ModifierFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let shift = ModifierFlags(rawValue: 0x0002_0000)  // kCGEventFlagMaskShift
    public static let control = ModifierFlags(rawValue: 0x0004_0000)  // kCGEventFlagMaskControl
    public static let option = ModifierFlags(rawValue: 0x0008_0000)  // kCGEventFlagMaskAlternate
    public static let command = ModifierFlags(rawValue: 0x0010_0000)  // kCGEventFlagMaskCommand
    public static let numericPad = ModifierFlags(rawValue: 0x0020_0000)  // kCGEventFlagMaskNumericPad
    public static let function = ModifierFlags(rawValue: 0x0080_0000)  // kCGEventFlagMaskSecondaryFn

    /// Virtual keycodes of the left-hand modifier keys, in the order they are pressed.
    public static let pressOrder: [(ModifierFlags, UInt16)] = [
        (.command, 0x37), (.control, 0x3B), (.option, 0x3A), (.shift, 0x38), (.function, 0x3F),
    ]
}

/// A character's position on a keyboard layout.
public struct KeyStroke: Equatable, Hashable, Sendable {
    public let keyCode: UInt16
    public let needsShift: Bool
    public init(keyCode: UInt16, needsShift: Bool = false) {
        self.keyCode = keyCode
        self.needsShift = needsShift
    }
}

/// A parsed `sendKeys` chord.
public struct KeyChord: Equatable, Sendable {
    public let keyCode: UInt16
    /// Modifiers explicitly requested plus any implied by the key (shift for `?`).
    public let modifiers: ModifierFlags
    /// Normalized key name (for logs; the character itself for character keys).
    public let keyName: String
    /// The key is itself a modifier key ("Shift_L", "ctrl" alone): it is pressed with
    /// flags-changed events, `modifierFlag` set while it is down.
    public let modifierFlag: ModifierFlags?

    public init(keyCode: UInt16, modifiers: ModifierFlags, keyName: String, modifierFlag: ModifierFlags? = nil) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyName = keyName
        self.modifierFlag = modifierFlag
    }

    /// The key types a character (letters, digits, punctuation), not a named key.
    public var isCharacterKey: Bool { modifierFlag == nil && keyName.count == 1 }

    /// Navigation / function keys that hardware reports with the fn (and, for arrows,
    /// numeric-pad) flag set; keypad keys carry the numeric-pad flag. Synthesized events
    /// mimic that.
    public var impliedHardwareFlags: ModifierFlags {
        switch keyCode {
        case 0x7B, 0x7C, 0x7D, 0x7E: return [.function, .numericPad]  // arrows
        case 0x73, 0x77, 0x74, 0x79, 0x75, 0x72: return [.function]  // home end pgup pgdn fwd-delete help
        case 0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F,
            0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A:
            return [.function]  // F1-F20
        case 0x41, 0x43, 0x45, 0x47, 0x4B, 0x4C, 0x4E, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C:
            return [.numericPad]  // keypad
        default: return []
        }
    }
}

/// Static US-ANSI tables (fallback when no layout-derived table is available).
public enum USKeyboard {
    /// Characters → key positions on a US keyboard.
    public static let characterMap: [Character: KeyStroke] = {
        var m: [Character: KeyStroke] = [:]
        let plain: [(Character, UInt16)] = [
            ("a", 0x00), ("s", 0x01), ("d", 0x02), ("f", 0x03), ("h", 0x04), ("g", 0x05), ("z", 0x06),
            ("x", 0x07), ("c", 0x08), ("v", 0x09), ("b", 0x0B), ("q", 0x0C), ("w", 0x0D), ("e", 0x0E),
            ("r", 0x0F), ("y", 0x10), ("t", 0x11), ("1", 0x12), ("2", 0x13), ("3", 0x14), ("4", 0x15),
            ("6", 0x16), ("5", 0x17), ("=", 0x18), ("9", 0x19), ("7", 0x1A), ("-", 0x1B), ("8", 0x1C),
            ("0", 0x1D), ("]", 0x1E), ("o", 0x1F), ("u", 0x20), ("[", 0x21), ("i", 0x22), ("p", 0x23),
            ("l", 0x25), ("j", 0x26), ("'", 0x27), ("k", 0x28), (";", 0x29), ("\\", 0x2A), (",", 0x2B),
            ("/", 0x2C), ("n", 0x2D), ("m", 0x2E), (".", 0x2F), ("`", 0x32), (" ", 0x31),
        ]
        for (c, k) in plain { m[c] = KeyStroke(keyCode: k) }
        let shifted: [(Character, Character)] = [
            ("!", "1"), ("@", "2"), ("#", "3"), ("$", "4"), ("%", "5"), ("^", "6"), ("&", "7"),
            ("*", "8"), ("(", "9"), (")", "0"), ("_", "-"), ("+", "="), ("{", "["), ("}", "]"),
            ("|", "\\"), (":", ";"), ("\"", "'"), ("<", ","), (">", "."), ("?", "/"), ("~", "`"),
        ]
        for (s, base) in shifted {
            if let k = m[base] { m[s] = KeyStroke(keyCode: k.keyCode, needsShift: true) }
        }
        return m
    }()

    /// Named, layout-independent keys. Looked up lower-cased, so the xdotool keysym
    /// names (`BackSpace`, `Page_Up`, `KP_Enter`, `Prior`, …) match too. The one
    /// case-sensitive exception is xdotool's `Delete` (forward delete), see
    /// `caseSensitiveNamedKeys`: lower-case `delete` stays Backspace, as before.
    public static let namedKeys: [String: UInt16] = {
        var m: [String: UInt16] = [
            "return": 0x24, "enter": 0x24, "linefeed": 0x24, "tab": 0x30, "space": 0x31,
            "escape": 0x35, "esc": 0x35,
            "backspace": 0x33, "delete": 0x33, "forward_delete": 0x75, "forwarddelete": 0x75, "del": 0x75,
            "up": 0x7E, "down": 0x7D, "left": 0x7B, "right": 0x7C,
            "home": 0x73, "end": 0x77, "begin": 0x73,
            "page_up": 0x74, "pageup": 0x74, "pgup": 0x74, "prior": 0x74,
            "page_down": 0x79, "pagedown": 0x79, "pgdn": 0x79, "next": 0x79,
            "insert": 0x72, "help": 0x72, "menu": 0x6E, "caps_lock": 0x39, "capslock": 0x39,
            "clear": 0x47, "num_lock": 0x47,
            // Keypad (xdotool KP_*).
            "kp_0": 0x52, "kp_1": 0x53, "kp_2": 0x54, "kp_3": 0x55, "kp_4": 0x56, "kp_5": 0x57, "kp_6": 0x58,
            "kp_7": 0x59, "kp_8": 0x5B, "kp_9": 0x5C, "kp_decimal": 0x41, "kp_separator": 0x41, "kp_multiply": 0x43,
            "kp_add": 0x45, "kp_divide": 0x4B, "kp_enter": 0x4C, "kp_subtract": 0x4E, "kp_equal": 0x51,
            "kp_delete": 0x75, "kp_insert": 0x72, "kp_home": 0x73, "kp_end": 0x77, "kp_begin": 0x73,
            "kp_prior": 0x74, "kp_page_up": 0x74, "kp_next": 0x79, "kp_page_down": 0x79,
            "kp_up": 0x7E, "kp_down": 0x7D, "kp_left": 0x7B, "kp_right": 0x7C,
            "kp_space": 0x31, "kp_tab": 0x30,
        ]
        let fkeys: [UInt16] = [
            0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F,  // F1-F12
            0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,  // F13-F20
        ]
        for (i, code) in fkeys.enumerated() { m["f\(i + 1)"] = code }
        return m
    }()

    /// Exact-case names that differ from the lower-cased table: xdotool's `Delete` is
    /// forward delete (its `BackSpace` is backspace).
    public static let caseSensitiveNamedKeys: [String: UInt16] = ["Delete": 0x75, "KP_Delete": 0x75]

    /// xdotool punctuation keysym names → the character they type.
    public static let punctuationNames: [String: Character] = [
        "exclam": "!", "quotedbl": "\"", "numbersign": "#", "dollar": "$", "percent": "%", "ampersand": "&",
        "apostrophe": "'", "quoteright": "'", "parenleft": "(", "parenright": ")", "asterisk": "*", "plus": "+",
        "comma": ",", "minus": "-", "period": ".", "slash": "/", "colon": ":", "semicolon": ";", "less": "<",
        "equal": "=", "greater": ">", "question": "?", "at": "@", "bracketleft": "[", "backslash": "\\",
        "bracketright": "]", "asciicircum": "^", "underscore": "_", "grave": "`", "quoteleft": "`",
        "braceleft": "{", "bar": "|", "braceright": "}", "asciitilde": "~",
    ]

    /// xdotool keysyms without a Mac key of their own, pressed as the chord that does the
    /// same thing in Mac apps.
    public static let chordAliases: [String: (key: String, modifiers: ModifierFlags)] = [
        "undo": ("z", [.command]), "redo": ("z", [.command, .shift]), "find": ("f", [.command]),
        "iso_left_tab": ("tab", [.shift]),
    ]

    /// Modifier names (case-insensitive) → flag.
    public static let modifierNames: [String: ModifierFlags] = [
        "cmd": .command, "command": .command, "super": .command, "meta": .command, "win": .command,
        "super_l": .command, "super_r": .command, "meta_l": .command, "meta_r": .command,
        "cmd_l": .command, "cmd_r": .command, "command_l": .command, "command_r": .command,
        "ctrl": .control, "control": .control, "control_l": .control, "control_r": .control,
        "ctrl_l": .control, "ctrl_r": .control,
        "alt": .option, "option": .option, "opt": .option, "alt_l": .option, "alt_r": .option,
        "option_l": .option, "option_r": .option,
        "shift": .shift, "shift_l": .shift, "shift_r": .shift,
        "fn": .function,
        "hyper": [.command, .control, .option, .shift], "hyper_l": [.command, .control, .option, .shift],
        "hyper_r": [.command, .control, .option, .shift],
    ]

    /// Virtual keycode of a modifier key pressed on its own ("Shift_R"); left-hand key
    /// unless the name ends in `_r`.
    public static func modifierKeyCode(name: String) -> (code: UInt16, flag: ModifierFlags)? {
        let n = name.lowercased()
        guard let flags = modifierNames[n] else { return nil }
        let right = n.hasSuffix("_r")
        if flags == [.command, .control, .option, .shift] { return (0x37, .command) }
        switch flags {
        case .command: return (right ? 0x36 : 0x37, .command)
        case .control: return (right ? 0x3E : 0x3B, .control)
        case .option: return (right ? 0x3D : 0x3A, .option)
        case .shift: return (right ? 0x3C : 0x38, .shift)
        case .function: return (0x3F, .function)
        default: return nil
        }
    }

    /// Keycode used as a carrier for Unicode-string key events (`kVK_ANSI_A`).
    public static let unicodeCarrierKeyCode: UInt16 = 0x00
    public static let returnKeyCode: UInt16 = 0x24
    public static let escapeKeyCode: UInt16 = 0x35
}

/// Parses `+`-separated, case-insensitive chords such as `cmd+shift+t`, `Return`,
/// `Control_L+a`, `cmd++`, `?`, and the xdotool `key` vocabulary (`KP_Enter`, `Prior`,
/// `BackSpace`, `Super_L+bracketleft`, `F15`, a lone modifier such as `Shift_L`).
public enum KeyChordParser {
    public static func parse(
        _ input: String, characterMap: [Character: KeyStroke] = USKeyboard.characterMap
    ) throws -> KeyChord {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw TurboError.invalid("key must be a non-empty chord such as \"cmd+s\"") }

        // Split on "+", treating a trailing "++" (or a lone "+") as the plus key itself.
        var parts: [String]
        if trimmed == "+" {
            parts = ["+"]
        } else if trimmed.hasSuffix("++") {
            parts = String(trimmed.dropLast(2)).split(separator: "+", omittingEmptySubsequences: false).map(String.init)
            parts.append("+")
        } else {
            parts = trimmed.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        }
        parts = parts.map { $0 == " " ? $0 : $0.trimmingCharacters(in: .whitespaces) }
        if parts.contains(where: { $0.isEmpty }) {
            throw TurboError.invalid("Invalid key chord \"\(input)\": empty component")
        }

        var modifiers: ModifierFlags = []
        var key: (code: UInt16, name: String, shift: Bool)?
        var lastModifier: String?
        for part in parts {
            let lower = part.lowercased()
            if let flag = USKeyboard.modifierNames[lower] {
                modifiers.insert(flag)
                lastModifier = part
                continue
            }
            guard key == nil else {
                throw TurboError.invalid("Invalid key chord \"\(input)\": more than one non-modifier key")
            }
            if let code = USKeyboard.caseSensitiveNamedKeys[part] {
                key = (code, lower == "delete" ? "forward_delete" : lower, false)
            } else if let code = USKeyboard.namedKeys[lower] {
                key = (code, lower, false)
            } else if let alias = USKeyboard.chordAliases[lower] {
                modifiers.formUnion(alias.modifiers)
                if let code = USKeyboard.namedKeys[alias.key] {
                    key = (code, alias.key, false)
                } else if let ch = alias.key.first, let stroke = characterMap[ch] ?? USKeyboard.characterMap[ch] {
                    key = (stroke.keyCode, alias.key, stroke.needsShift)
                }
            } else if let ch = (part.count == 1 ? lower.first : USKeyboard.punctuationNames[lower]) {
                if let stroke = characterMap[ch] ?? USKeyboard.characterMap[ch] {
                    // Letters are case-insensitive: "A" means the A key, not shift+a.
                    key = (stroke.keyCode, String(ch), stroke.needsShift)
                } else {
                    throw TurboError.invalid("Invalid key chord \"\(input)\": unsupported key \"\(part)\"")
                }
            } else {
                throw TurboError.invalid("Invalid key chord \"\(input)\": unknown key \"\(part)\"")
            }
        }
        guard let key else {
            // Only modifiers ("Shift_L", "ctrl+alt"): press the last one as the key.
            if let last = lastModifier, let m = USKeyboard.modifierKeyCode(name: last) {
                var others = modifiers
                // Its own flag is set by the key itself while it is down.
                if parts.filter({ USKeyboard.modifierNames[$0.lowercased()] == USKeyboard.modifierNames[last.lowercased()] }).count == 1 {
                    others.subtract(USKeyboard.modifierNames[last.lowercased()] ?? [])
                }
                return KeyChord(keyCode: m.code, modifiers: others, keyName: last.lowercased(), modifierFlag: m.flag)
            }
            throw TurboError.invalid("Invalid key chord \"\(input)\": it must contain a key")
        }
        if key.shift { modifiers.insert(.shift) }
        return KeyChord(keyCode: key.code, modifiers: modifiers, keyName: key.name)
    }
}

// MARK: - Menu key equivalents (background key equivalents)

/// A menu item's keyboard shortcut as accessibility reports it (`AXMenuItemCmdChar`,
/// `AXMenuItemCmdVirtualKey`, `AXMenuItemCmdModifiers`).
public struct MenuShortcut: Equatable, Sendable {
    public var character: String?
    public var virtualKey: Int?
    /// `AXMenuItemCmdModifiers`: bit 0 shift, bit 1 option, bit 2 control, bit 3 = NO command.
    public var axModifiers: Int

    public init(character: String?, virtualKey: Int?, axModifiers: Int) {
        self.character = character
        self.virtualKey = virtualKey
        self.axModifiers = axModifiers
    }

    public var modifiers: ModifierFlags {
        var m: ModifierFlags = []
        if axModifiers & 8 == 0 { m.insert(.command) }
        if axModifiers & 1 != 0 { m.insert(.shift) }
        if axModifiers & 2 != 0 { m.insert(.option) }
        if axModifiers & 4 != 0 { m.insert(.control) }
        return m
    }
}

/// Matches a `sendKeys` chord against menu shortcuts. Key equivalents (⌘-chords) reach
/// an app only while it is active; in the background the helper presses the menu item
/// that owns the shortcut through accessibility instead.
public enum MenuShortcutMatcher {
    /// Whether a chord is a key equivalent that only the active app handles (it has
    /// command or control; plain keys and shift/option combos are typed normally).
    public static func needsMenu(_ chord: KeyChord) -> Bool {
        chord.modifierFlag == nil && !chord.modifiers.isDisjoint(with: [.command])
    }

    public static func matches(_ chord: KeyChord, _ s: MenuShortcut) -> Bool {
        guard chord.modifierFlag == nil else { return false }
        let wanted = chord.modifiers.intersection([.command, .shift, .option, .control])
        var have = s.modifiers
        if let ch = s.character, ch.count == 1, let c = ch.first, isPrintable(c) {
            guard chord.isCharacterKey else { return false }
            guard ch.lowercased() == chord.keyName.lowercased() else { return false }
            // Accessibility reports letters upper-case whatever the shortcut ("A" for ⌘A;
            // ⌘⇧Z has the shift bit), so letters compare case-insensitively and only the
            // shift bit counts; a shifted symbol such as "?" implies shift by itself.
            if !c.isLetter, let stroke = USKeyboard.characterMap[c], stroke.needsShift { have.insert(.shift) }
            return have == wanted
        }
        if let vk = s.virtualKey {
            return UInt16(truncatingIfNeeded: vk) == chord.keyCode && have == wanted
        }
        return false
    }

    static func isPrintable(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return false }
        // Function-key glyphs live in the private-use area; control characters are not typed.
        if scalar.value < 0x20 || scalar.value == 0x7F { return false }
        if (0xE000...0xF8FF).contains(scalar.value) { return false }
        return true
    }
}

/// Standard text-editing shortcuts the helper can carry out through accessibility on the
/// focused text element when the app is in the background and its menu item is unavailable
/// (AppKit validates Edit-menu items against the key window, which an inactive app does not
/// have, so they read as disabled there) —.
public enum TextEditShortcut: String, Equatable, Sendable {
    case selectAll, copy, cut, paste

    public static func from(_ chord: KeyChord) -> TextEditShortcut? {
        guard chord.modifiers == [.command], chord.isCharacterKey else { return nil }
        switch chord.keyName.lowercased() {
        case "a": return .selectAll
        case "c": return .copy
        case "x": return .cut
        case "v": return .paste
        default: return nil
        }
    }
}

/// The shortcuts the system itself owns (Spotlight, Mission Control, screenshots, …), as macOS
/// reports them: a virtual keycode and Carbon modifier bits. Only these may be pressed
/// system-wide: any other chord would land in whatever app the user has in front.
public enum SystemShortcuts {
    public struct Registered: Equatable, Sendable {
        public let keyCode: Int
        public let carbonModifiers: Int

        public init(keyCode: Int, carbonModifiers: Int) {
            self.keyCode = keyCode
            self.carbonModifiers = carbonModifiers
        }
    }

    /// Carbon's modifier bits (cmdKey, shiftKey, optionKey, controlKey, and the Globe / fn key
    /// that system shortcuts such as Globe-C use) as ours.
    public static func modifiers(carbon: Int) -> ModifierFlags {
        var m: ModifierFlags = []
        if carbon & 0x0100 != 0 { m.insert(.command) }
        if carbon & 0x0200 != 0 { m.insert(.shift) }
        if carbon & 0x0800 != 0 { m.insert(.option) }
        if carbon & 0x1000 != 0 { m.insert(.control) }
        if carbon & 0x20000 != 0 { m.insert(.function) }
        return m
    }

    /// Whether `chord` is exactly one of the registered (enabled) system shortcuts.
    public static func contains(_ chord: KeyChord, in registered: [Registered]) -> Bool {
        // Arrows and F-keys carry the fn flag in hardware, so the system lists them with it.
        let mods = chord.modifiers.union(chord.impliedHardwareFlags).intersection([.command, .shift, .option, .control, .function])
        return registered.contains { Int(chord.keyCode) == $0.keyCode && modifiers(carbon: $0.carbonModifiers) == mods }
    }
}

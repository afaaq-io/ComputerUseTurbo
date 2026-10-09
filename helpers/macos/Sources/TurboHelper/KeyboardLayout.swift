import Carbon
import TurboCore
import Foundation

/// Character → key position table for the user's keyboard layout, built once at startup
/// with `UCKeyTranslate` (Text Input Sources must be queried on the main thread).
/// Characters the layout doesn't produce fall back to the static US table.
enum KeyboardLayout {
    nonisolated(unsafe) private(set) static var characterMap: [Character: KeyStroke] = USKeyboard.characterMap
    nonisolated(unsafe) private(set) static var sourceDescription = "static US table"
    /// Characters that the layout produces with a dead key (e.g. `^` and `` ` `` on German,
    /// French and US-International layouts). Pressing such a key on its own only starts a
    /// composition in the target app, so a bare press of one is typed as text instead.
    nonisolated(unsafe) private(set) static var deadKeyCharacters: Set<Character> = []

    /// `UCKeyTranslate` options: the NoDeadKeys **mask** (1 << bit). Passing the bit
    /// number itself (0) means "no options", so dead keys returned no character and fell
    /// back to the static US table — the wrong key on non-US layouts.
    static let translateOptions = OptionBits(kUCKeyTranslateNoDeadKeysMask)

    /// Call on the main thread during startup.
    static func buildOnMainThread() {
        precondition(Thread.isMainThread, "TIS APIs must run on the main thread")
        var map: [Character: KeyStroke] = [:]
        var dead: Set<Character> = []
        var described: [String] = []
        // Current layout first, then the ASCII-capable one (for non-Latin layouts),
        // so letters always resolve to the keys the system uses for shortcuts.
        let sources: [TISInputSource?] = [
            TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
        ]
        for source in sources.compactMap({ $0 }) {
            let added = addEntries(from: source, into: &map, deadKeys: &dead)
            if added > 0, let name = sourceName(source) { described.append("\(name) (\(added))") }
        }
        // Fill gaps from the static US table.
        for (ch, stroke) in USKeyboard.characterMap where map[ch] == nil { map[ch] = stroke }
        characterMap = map
        deadKeyCharacters = dead
        sourceDescription = described.isEmpty ? "static US table" : described.joined(separator: ", ") + " + US fallback"
    }

    private static func sourceName(_ source: TISInputSource) -> String? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    /// Keypad and named keys are excluded so digits map to the top row.
    private static let excludedKeyCodes: Set<UInt16> = {
        var s: Set<UInt16> = [0x24, 0x30, 0x33, 0x35, 0x4C, 0x47, 0x51, 0x4B, 0x43, 0x4E, 0x45, 0x41]
        for k in UInt16(0x52)...UInt16(0x5C) { s.insert(k) }  // keypad digits
        return s
    }()

    @discardableResult
    private static func addEntries(
        from source: TISInputSource, into map: inout [Character: KeyStroke], deadKeys: inout Set<Character>
    ) -> Int {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return 0 }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return 0 }
        var added = 0
        bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            let kbdType = UInt32(LMGetKbdType())
            // Unshifted first so plain characters win over shifted duplicates.
            for (shift, modifierState) in [(false, UInt32(0)), (true, UInt32((shiftKey >> 8) & 0xFF))] {
                for code in UInt16(0)..<UInt16(128) where !excludedKeyCodes.contains(code) {
                    var deadKeyState: UInt32 = 0
                    var length = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(
                        layout, code, UInt16(kUCKeyActionDisplay), modifierState, kbdType,
                        translateOptions, &deadKeyState, chars.count, &length, &chars)
                    guard status == noErr, length == 1 else { continue }
                    // Same key without the NoDeadKeys option: a dead key only sets state.
                    var probeState: UInt32 = 0
                    var probeLength = 0
                    var probeChars = [UniChar](repeating: 0, count: 4)
                    let probe = UCKeyTranslate(
                        layout, code, UInt16(kUCKeyActionDown), modifierState, kbdType,
                        0, &probeState, probeChars.count, &probeLength, &probeChars)
                    let isDeadKey = probe == noErr && probeState != 0
                    let scalarValue = chars[0]
                    guard scalarValue >= 0x20, scalarValue != 0x7F, let scalar = Unicode.Scalar(scalarValue) else {
                        continue
                    }
                    let ch = Character(scalar)
                    if map[ch] == nil {
                        map[ch] = KeyStroke(keyCode: code, needsShift: shift)
                        if isDeadKey { deadKeys.insert(ch) }
                        added += 1
                    }
                }
            }
        }
        return added
    }
}

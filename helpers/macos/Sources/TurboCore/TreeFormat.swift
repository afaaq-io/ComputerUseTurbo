import Foundation

/// The rendered label of an element.
public struct ElementLabel: Equatable, Sendable {
    public enum Kind: String, Sendable { case text, placeholder, identifier }
    public let kind: Kind
    /// The raw (unescaped, untruncated) label text.
    public let raw: String

    /// As printed on the line: `"Title"`, `placeholder="Name"`, or `id=nameField`.
    public var rendered: String {
        switch kind {
        case .text: return "\"\(TreeFormat.clean(raw))\""
        case .placeholder: return "placeholder=\"\(TreeFormat.clean(raw))\""
        case .identifier: return "id=\(TreeFormat.clean(raw))"
        }
    }
}

/// Line-level formatting rules.
public enum TreeFormat {
    /// `AXTextField` → `text field`, `AXMenuBarItem` → `menu bar item`, `AXURLField` → `url field`.
    public static func humanize(_ axName: String) -> String {
        var name = axName
        if name.hasPrefix("AX") && name.count > 2 { name = String(name.dropFirst(2)) }
        let chars = Array(name)
        var words: [String] = []
        var current = ""
        for (i, c) in chars.enumerated() {
            if c == "_" || c == " " || c == "-" {
                if !current.isEmpty { words.append(current); current = "" }
                continue
            }
            if c.isUppercase, !current.isEmpty {
                let prev = chars[i - 1]
                let nextIsLower = i + 1 < chars.count && chars[i + 1].isLowercase
                // Break on lower→Upper ("textField") and at the end of an acronym ("URLField").
                if prev.isLowercase || prev.isNumber || (prev.isUppercase && nextIsLower) {
                    words.append(current)
                    current = ""
                }
            }
            current.append(c)
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.lowercased() }.joined(separator: " ")
    }

    /// `role` or `role (subrole)` when the subrole is informative.
    public static func roleText(role: String, subrole: String?) -> String {
        let base = humanize(role)
        guard let subrole, !subrole.isEmpty, subrole != role, subrole != "AXUnknown" else { return base }
        let sub = humanize(subrole)
        guard !sub.isEmpty, sub != base else { return base }
        return "\(base) (\(sub))"
    }

    /// Auto-generated AppKit identifiers (`_NS:123`) carry no meaning and are not stable
    /// across launches; they are treated as absent.
    public static func meaningfulIdentifier(_ id: String?) -> String? {
        guard let id = nonEmpty(id), !id.hasPrefix("_NS:") else { return nil }
        return id
    }

    static func nonEmpty(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = withoutIconGlyphs(s)
        guard !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return t
    }

    /// Icon fonts draw their glyphs from the private-use areas of Unicode: such characters
    /// show nothing in text and are dropped (an icon-only label is no label).
    public static func withoutIconGlyphs(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: isIconGlyph) else { return s }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: s.unicodeScalars.filter { !isIconGlyph($0) })
        return String(out).trimmingCharacters(in: .whitespaces)
    }

    static func isIconGlyph(_ c: Unicode.Scalar) -> Bool {
        (0xE000...0xF8FF).contains(c.value) || c.value >= 0xF0000
    }

    /// Roles whose value is something to type or set: `editable` means it there (a settable
    /// AXValue on a group or a button — Electron reports that — is not something to edit).
    static let editableRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSlider", "AXIncrementor", "AXDateField",
        "AXTimeField", "AXSecureTextField", "AXColorWell", "AXStepper", "AXLevelIndicator", "AXValueIndicator",
        "AXScrollBar", "AXSplitter",
    ]

    /// First non-empty of AXTitle, AXDescription, AXLabelValue, AXPlaceholderValue, AXIdentifier.
    public static func label(for node: AXNode) -> ElementLabel? {
        if let t = nonEmpty(node.title) { return ElementLabel(kind: .text, raw: t) }
        if let d = nonEmpty(node.description) { return ElementLabel(kind: .text, raw: d) }
        if let l = nonEmpty(node.labelValue) { return ElementLabel(kind: .text, raw: l) }
        if let p = nonEmpty(node.placeholder) { return ElementLabel(kind: .placeholder, raw: p) }
        if let i = meaningfulIdentifier(node.identifier) { return ElementLabel(kind: .identifier, raw: i) }
        return nil
    }

    /// Truncate to `limit` characters (appending `…`) and escape `\`, `"`, newlines, tabs.
    public static func clean(_ s: String, limit: Int = TurboProtocol.maxStringLength) -> String {
        var text = s
        if text.count > limit {
            text = String(text.prefix(limit)) + "…"
        }
        var out = ""
        out.reserveCapacity(text.utf8.count + 8)
        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\r":
                // CRLF counts as a single line break.
                if i + 1 < scalars.count && scalars[i + 1] == "\n" { i += 1 }
                out += "\\n"
            case "\n", "\u{2028}", "\u{2029}": out += "\\n"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(scalar)
            }
            i += 1
        }
        return out
    }

    /// `value="…"` contents, or nil when omitted (empty, equal to label, or secure).
    public static func valueText(for node: AXNode, label: ElementLabel?) -> String? {
        if node.isSecure { return nil }
        guard let value = node.value else { return nil }
        guard let text = nonEmpty(value.text) else { return nil }
        if let label, label.raw == text { return nil }
        return text
    }

    /// Flags in canonical order: focused, selected, disabled, editable, expanded, checked, secure.
    public static func flags(for node: AXNode) -> [String] {
        var flags: [String] = []
        if node.isFocused { flags.append("focused") }
        if node.isSelected { flags.append("selected") }
        if node.isEnabled == false { flags.append("disabled") }
        // `editable` = AXValue settable, secure fields included (fill_value / write_text
        // still refuse them; only the value itself is never printed).
        if node.isValueSettable, node.isSecure || editableRoles.contains(node.role) || node.value.map({ if case .string(let v) = $0 { return nonEmpty(v) != nil } else { return false } }) == true {
            flags.append("editable")
        }
        if node.isExpanded { flags.append("expanded") }
        if node.role == AXRoles.checkBox || node.role == AXRoles.radioButton,
            let v = node.value, v.isOn
        {
            flags.append("checked")
        }
        if node.isSecure { flags.append("secure") }
        return flags
    }

    /// Plain-word names for the standard accessibility actions: what
    /// `actions=` and the secondary-actions footer show and what
    /// `invoke_action` accepts (case-insensitively; raw AX names too).
    public static let actionWords: [String: String] = [
        "AXPress": "Press", "AXShowMenu": "Show Menu", "AXScrollToVisible": "Scroll to Visible",
        "AXIncrement": "Increment", "AXDecrement": "Decrement", "AXConfirm": "Confirm", "AXCancel": "Cancel",
        "AXRaise": "Raise", "AXPick": "Pick", "AXShowAlternateUI": "Show Alternate UI",
        "AXShowDefaultUI": "Show Default UI", "AXScrollUpByPage": "Scroll Up", "AXScrollDownByPage": "Scroll Down",
        "AXScrollLeftByPage": "Scroll Left", "AXScrollRightByPage": "Scroll Right", "AXZoomWindow": "Zoom Window",
        "AXDelete": "Delete", "AXOpen": "Open", "AXExpand": "Expand", "AXCollapse": "Collapse",
    ]

    /// How one raw AX action name is printed: a plain-word name ("Scroll Down",
    /// "Show Menu"; unknown `AX…` names are split into words), a custom action
    /// (`Name:Archive\nTarget:0x…`) as its name, newlines → spaces and commas → `;`
    /// (`actions=` is a comma-separated list). `ActionNameMatcher` accepts this form back.
    public static func displayName(forAction raw: String) -> String {
        var name: String
        if let word = actionWords[raw] {
            name = word
        } else if let custom = ActionNameMatcher.customActionName(raw) {
            name = custom
        } else if raw.hasPrefix("AX") && raw.count > 2 && !raw.contains(where: { $0.isWhitespace }) {
            name = humanize(raw).split(separator: " ").map { w in
                w.count <= 2 ? w.uppercased() : w.prefix(1).uppercased() + w.dropFirst()
            }.joined(separator: " ")
        } else {
            name = raw
        }
        return name.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: ",", with: ";")
    }

    /// Action names for `actions=` / the secondary-actions footer: hidden ones removed,
    /// plain words, duplicates dropped.
    public static func displayActions(_ actions: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for a in actions where !AXRoles.hiddenActions.contains(a) {
            let name = displayName(forAction: a)
            if name.isEmpty || seen.contains(name.lowercased()) { continue }
            seen.insert(name.lowercased())
            out.append(name)
        }
        return out
    }

    /// Longest static text printed on one line (Markdown-ish text).
    public static let maxTextLength = 300

    /// Text for Markdown-ish lines: truncated, line breaks / tabs escaped (`\n`, `\t`),
    /// nothing else escaped (no quotes around it).
    public static func inlineText(_ s: String, limit: Int = maxTextLength) -> String {
        var text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > limit { text = String(text.prefix(limit)) + "…" }
        return text.replacingOccurrences(of: "\r\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\u{2028}", with: "\\n")
            .replacingOccurrences(of: "\u{2029}", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
    }

    /// Text a static text shows: its value, else title / description / label.
    public static func staticTextContent(_ node: AXNode) -> String? {
        if let v = node.value?.text, let shown = nonEmpty(v) { return shown }
        return nonEmpty(node.title) ?? nonEmpty(node.description) ?? nonEmpty(node.labelValue)
    }

    /// One element line without indentation:
    /// `[<index>] <role> <label> value="<value>" {flags} actions=<a,b>`; static text as
    /// `[<index>] text [id=<id>] [{flags}]: <text>` and links as
    /// `[<index>] link [<text>](<short url>) …` (Markdown-ish).
    public static func line(index: Int, node: AXNode) -> String {
        if node.role == AXRoles.staticText { return staticTextLine(index: index, node: node) }
        let label = label(for: node)
        var parts = ["#\(index)", roleText(role: node.role, subrole: node.subrole)]
        if node.role == AXRoles.link, let url = nonEmpty(node.url) {
            let text = label.map { $0.kind == .text ? $0.raw : "" } ?? ""
            let shown = inlineText(text, limit: TurboProtocol.maxStringLength).replacingOccurrences(of: "]", with: "\\]")
            parts.append("[\(shown)](\(URLShortener.shorten(url)))")
            if let label, label.kind != .text { parts.append(label.rendered) }
        } else if let label {
            parts.append(label.rendered)
        }
        if let v = valueText(for: node, label: label) { parts.append("value=\"\(clean(v))\"") }
        let f = flags(for: node)
        if !f.isEmpty { parts.append("{\(f.joined(separator: ", "))}") }
        if let rows = node.rowSubset { parts.append(rows.note) }
        if node.isSurface {
            parts.append("(its items are not listed; observe_app with full_tree: true lists them)")
        } else if node.isSummaryOnly {
            parts.append("(other window; contents not shown — perform Raise to switch to it)")
        }
        let actions = displayActions(node.actions)
        if !actions.isEmpty { parts.append("actions=\(actions.joined(separator: ","))") }
        return parts.joined(separator: " ")
    }

    static func staticTextLine(index: Int, node: AXNode) -> String {
        var head = "#\(index) text"
        if let id = meaningfulIdentifier(node.identifier) { head += " id=\(clean(id))" }
        let f = flags(for: node)
        if !f.isEmpty { head += " {\(f.joined(separator: ", "))}" }
        let actions = displayActions(node.actions)
        if !actions.isEmpty { head += " actions=\(actions.joined(separator: ","))" }
        guard let text = staticTextContent(node) else { return head }
        return head + ": " + inlineText(text)
    }
}

/// Shortens long URLs for the tree text: drops `https://` and `www.`,
/// keeps host and the start of the path, cuts the rest with `…`.
public enum URLShortener {
    public static let maxLength = 60

    public static func shorten(_ raw: String, maxLength: Int = maxLength) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://"] where s.lowercased().hasPrefix(prefix) {
            if prefix == "https://" { s = String(s.dropFirst(prefix.count)) }
            break
        }
        if s.lowercased().hasPrefix("www.") { s = String(s.dropFirst(4)) }
        if s.hasSuffix("/") && s.filter({ $0 == "/" }).count == 1 { s = String(s.dropLast()) }
        guard s.count > maxLength else { return s }
        // Drop the query / fragment first, then cut the path.
        if let cut = s.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            let base = String(s[..<cut])
            if base.count + 2 <= maxLength { return base + "?…" }
            s = base
        }
        guard s.count > maxLength else { return s }
        return String(s.prefix(maxLength - 1)) + "…"
    }
}

/// Resolves the action name a client asks for (`invoke_action`) to the raw AX
/// action name to perform. An observation promises that a name listed after `actions=`
/// or under "More actions on" can be performed by that name, so the printed form
/// (`TreeFormat.displayName`) must map back to the raw name.
public enum ActionNameMatcher {
    /// The raw name in `available` that `requested` refers to, or nil. Tried in order
    /// (case-insensitive): the raw name or `AX` + name; the printed form; the `Name:`
    /// value of a custom action (`Name:Archive\nTarget:…` ← "Archive").
    public static func match(_ requested: String, in available: [String]) -> String? {
        let wanted = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }
        if let raw = available.first(where: { same($0, wanted) || same($0, "AX" + wanted) }) { return raw }
        if let raw = available.first(where: { same(TreeFormat.displayName(forAction: $0), wanted) }) { return raw }
        if let raw = available.first(where: { customActionName($0).map { same($0, wanted) } ?? false }) { return raw }
        // Spacing / underscores / the AX prefix do not matter: "scroll down", "ScrollDown",
        // "scroll_down" and "AXScrollDownByPage" all name the same action.
        let key = squash(wanted)
        if let raw = available.first(where: { squash($0) == key || squash(TreeFormat.displayName(forAction: $0)) == key }) {
            return raw
        }
        return nil
    }

    static func squash(_ s: String) -> String {
        var t = s.lowercased().filter { !$0.isWhitespace && $0 != "_" && $0 != "-" }
        if t.hasPrefix("ax") && t.count > 2 { t = String(t.dropFirst(2)) }
        return t
    }

    /// `Name:Archive\nTarget:0x…\nSelector:(null)` → `Archive` (NSAccessibilityCustomAction).
    public static func customActionName(_ raw: String) -> String? {
        guard raw.hasPrefix("Name:") else { return nil }
        let rest = raw.dropFirst("Name:".count)
        let firstLine = rest.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }).first ?? ""
        let name = firstLine.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}

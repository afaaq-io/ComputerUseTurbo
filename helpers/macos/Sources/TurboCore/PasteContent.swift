import Foundation

// `paste`: what goes on the pasteboard for each format, and the
// decision whether the user's previous pasteboard can be put back. Pure.

public enum PasteFormat: String, Equatable, Sendable, CaseIterable {
    case text, markdown, html

    /// Accepts the documented names plus `md`.
    public static func parse(_ raw: String?) -> PasteFormat? {
        guard let raw else { return .text }
        switch raw.lowercased() {
        case "text", "plain", "txt": return .text
        case "markdown", "md": return .markdown
        case "html": return .html
        default: return nil
        }
    }
}

/// The pasteboard flavors for one paste: plain text always; HTML for markdown / html
/// (the helper adds RTF converted from the HTML).
public struct PastePayload: Equatable, Sendable {
    public var plain: String
    public var html: String?

    public init(plain: String, html: String?) {
        self.plain = plain
        self.html = html
    }

    public static func make(text: String, format: PasteFormat) -> PastePayload {
        switch format {
        case .text: return PastePayload(plain: text, html: nil)
        case .markdown: return PastePayload(plain: text, html: MarkdownHTML.render(text))
        case .html: return PastePayload(plain: HTMLText.plainText(text), html: text)
        }
    }
}

public enum PasteRestore {
    public enum Decision: Equatable, Sendable {
        /// Put the user's previous contents back.
        case restore
        /// Someone else wrote the pasteboard after the helper did (the user copied
        /// something): leave it alone.
        case leaveChanged
    }

    /// `ourChangeCount`: the pasteboard change count right after the helper wrote it;
    /// `currentChangeCount`: now.
    public static func decide(ourChangeCount: Int, currentChangeCount: Int) -> Decision {
        currentChangeCount == ourChangeCount ? .restore : .leaveChanged
    }

    /// How long the helper waits for the app to read the pasteboard after ⌘V.
    public static let readTimeout: TimeInterval = 1.0
    /// After the first read, more flavors may follow: wait this long without a new read.
    public static let readQuiet: TimeInterval = 0.15
}

/// A small Markdown → HTML converter for `paste` (headings, paragraphs, line breaks,
/// bullet / numbered lists, block quotes, fenced code, inline code, bold, italic,
/// links). Everything else is escaped text.
public enum MarkdownHTML {
    public static func render(_ md: String) -> String {
        let lines = md.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var out: [String] = []
        var paragraph: [String] = []
        var list: (ordered: Bool, items: [String])?
        var quote: [String] = []
        var code: [String]?

        func flushParagraph() {
            if !paragraph.isEmpty { out.append("<p>" + paragraph.map(inline).joined(separator: "<br>") + "</p>") }
            paragraph = []
        }
        func flushList() {
            if let l = list {
                let tag = l.ordered ? "ol" : "ul"
                out.append("<\(tag)>" + l.items.map { "<li>\(inline($0))</li>" }.joined() + "</\(tag)>")
            }
            list = nil
        }
        func flushQuote() {
            if !quote.isEmpty { out.append("<blockquote>" + render(quote.joined(separator: "\n")) + "</blockquote>") }
            quote = []
        }
        func flushAll() {
            flushParagraph()
            flushList()
            flushQuote()
        }

        for line in lines {
            if var c = code {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    out.append("<pre><code>" + escape(c.joined(separator: "\n")) + "</code></pre>")
                    code = nil
                } else {
                    c.append(line)
                    code = c
                }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flushAll()
                code = []
                continue
            }
            if trimmed.isEmpty {
                flushAll()
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                flushList()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            flushQuote()
            if let (level, text) = heading(trimmed) {
                flushParagraph()
                flushList()
                out.append("<h\(level)>\(inline(text))</h\(level)>")
                continue
            }
            if let item = bullet(trimmed) {
                flushParagraph()
                if list?.ordered == true { flushList() }
                list = (false, (list?.items ?? []) + [item])
                continue
            }
            if let item = numbered(trimmed) {
                flushParagraph()
                if list?.ordered == false { flushList() }
                list = (true, (list?.items ?? []) + [item])
                continue
            }
            flushList()
            paragraph.append(trimmed)
        }
        if let c = code { out.append("<pre><code>" + escape(c.joined(separator: "\n")) + "</code></pre>") }
        flushAll()
        return out.joined(separator: "\n")
    }

    static func heading(_ s: String) -> (Int, String)? {
        var level = 0
        for ch in s {
            if ch == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let rest = s.dropFirst(level)
        guard rest.first == " " else { return nil }
        return (level, rest.trimmingCharacters(in: .whitespaces))
    }

    static func bullet(_ s: String) -> String? {
        for marker in ["- ", "* ", "+ "] where s.hasPrefix(marker) {
            return String(s.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func numbered(_ s: String) -> String? {
        let digits = s.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let rest = s.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }

    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Inline markup: `code`, **bold** / __bold__, *italic* / _italic_, [text](url).
    static func inline(_ text: String) -> String {
        let s = Array(text)
        var out = ""
        var i = 0
        func find(_ marker: [Character], from: Int) -> Int? {
            var j = from
            while j + marker.count <= s.count {
                if Array(s[j..<j + marker.count]) == marker { return j }
                j += 1
            }
            return nil
        }
        while i < s.count {
            let c = s[i]
            if c == "\\", i + 1 < s.count {
                out += escape(String(s[i + 1]))
                i += 2
                continue
            }
            if c == "`", let close = find(["`"], from: i + 1) {
                out += "<code>" + escape(String(s[(i + 1)..<close])) + "</code>"
                i = close + 1
                continue
            }
            if (c == "*" || c == "_"), i + 1 < s.count, s[i + 1] == c,
                let close = find([c, c], from: i + 2), close > i + 2
            {
                out += "<strong>" + inline(String(s[(i + 2)..<close])) + "</strong>"
                i = close + 2
                continue
            }
            if (c == "*" || c == "_"), i + 1 < s.count, s[i + 1] != " ",
                let close = find([c], from: i + 1), close > i + 1
            {
                out += "<em>" + inline(String(s[(i + 1)..<close])) + "</em>"
                i = close + 1
                continue
            }
            if c == "[", let closeText = find(["]"], from: i + 1), closeText + 1 < s.count, s[closeText + 1] == "(",
                let closeURL = find([")"], from: closeText + 2)
            {
                let label = String(s[(i + 1)..<closeText])
                let url = String(s[(closeText + 2)..<closeURL])
                out += "<a href=\"\(escape(url))\">\(inline(label))</a>"
                i = closeURL + 1
                continue
            }
            out += escape(String(c))
            i += 1
        }
        return out
    }
}

/// Plain text of an HTML fragment (tags dropped, block ends as line breaks, the common
/// entities decoded) — the plain-text flavor of an HTML paste.
public enum HTMLText {
    public static func plainText(_ html: String) -> String {
        var s = html
        for tag in ["<br>", "<br/>", "<br />", "</p>", "</div>", "</li>", "</h1>", "</h2>", "</h3>", "</h4>", "</h5>", "</h6>", "</tr>"] {
            s = s.replacingOccurrences(of: tag, with: tag + "\n", options: .caseInsensitive)
        }
        var out = ""
        var inTag = false
        for ch in s {
            if ch == "<" { inTag = true; continue }
            if ch == ">" && inTag { inTag = false; continue }
            if !inTag { out.append(ch) }
        }
        let entities = ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&amp;": "&"]
        for (k, v) in entities { out = out.replacingOccurrences(of: k, with: v) }
        let lines = out.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var collapsed: [String] = []
        for l in lines where !(l.isEmpty && (collapsed.last?.isEmpty ?? true)) { collapsed.append(l) }
        return collapsed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

import Foundation

// MARK: - UI events ("since your last look", `waitFor`)

/// What happened in an app, in words every platform can produce.
public enum UIEventKind: String, Sendable, CaseIterable {
    case windowOpened, dialogOpened, windowClosed, menuOpened, menuClosed, focusMoved, valueChanged, titleChanged,
        selectionChanged, pageLoaded, announcement, busyChanged

    /// Higher = listed first when there are more events than room.
    public var weight: Int {
        switch self {
        case .announcement, .dialogOpened: return 5
        case .windowOpened, .windowClosed, .pageLoaded: return 4
        case .valueChanged, .titleChanged: return 3
        case .menuOpened, .menuClosed, .selectionChanged, .busyChanged: return 2
        case .focusMoved: return 1
        }
    }

    var verb: String {
        switch self {
        case .windowOpened: return "window opened"
        case .dialogOpened: return "dialog opened"
        case .windowClosed: return "window closed"
        case .menuOpened: return "menu opened"
        case .menuClosed: return "menu closed"
        case .focusMoved: return "focus moved to"
        case .valueChanged: return "value changed"
        case .titleChanged: return "title changed"
        case .selectionChanged: return "selection changed in"
        case .pageLoaded: return "page finished loading"
        case .announcement: return "announced"
        case .busyChanged: return "busy state changed"
        }
    }
}

/// One described event: `what` is the element ("text field \"Name\""), `detail` its new
/// value or the announced text (never the value of a password field).
public struct UIEventRecord: Equatable, Sendable {
    public var at: TimeInterval
    public var kind: UIEventKind
    public var what: String?
    public var detail: String?

    public init(at: TimeInterval, kind: UIEventKind, what: String? = nil, detail: String? = nil) {
        self.at = at
        self.kind = kind
        self.what = what
        self.detail = detail
    }

    public var line: String {
        var s = kind.verb
        if let what, !what.isEmpty { s += " \(what)" }
        if let detail, !detail.isEmpty {
            s += kind == .announcement ? " \"\(TreeFormat.clean(detail, limit: 160))\"" : " → \"\(TreeFormat.clean(detail, limit: 80))\""
        }
        return s
    }
}

public enum UIEventSummary {
    /// Lines for at most `limit` events: duplicates folded (latest wins), the most telling
    /// kinds kept when there are too many, then in the order they happened.
    public static func lines(_ records: [UIEventRecord], limit: Int = 12) -> [String] {
        var latest: [String: UIEventRecord] = [:]
        var order: [String] = []
        for r in records {
            // A value / title / focus change counts once per element; other kinds once per line.
            let key: String
            switch r.kind {
            case .valueChanged, .titleChanged, .selectionChanged: key = "\(r.kind.rawValue)|\(r.what ?? "")"
            case .focusMoved, .busyChanged: key = r.kind.rawValue
            default: key = "\(r.kind.rawValue)|\(r.what ?? "")|\(r.detail ?? "")"
            }
            if latest[key] == nil { order.append(key) } else { order.removeAll { $0 == key }; order.append(key) }
            latest[key] = r
        }
        var kept = order.compactMap { latest[$0] }
        let dropped = max(0, kept.count - limit)
        if dropped > 0 {
            let cut = kept.enumerated().sorted { a, b in
                a.element.kind.weight != b.element.kind.weight ? a.element.kind.weight > b.element.kind.weight : a.offset > b.offset
            }.prefix(limit).map(\.offset)
            let keep = Set(cut)
            kept = kept.enumerated().filter { keep.contains($0.offset) }.map(\.element)
        }
        var out = kept.map { "- \($0.line)" }
        if dropped > 0 { out.append("- … and \(dropped) more change(s)") }
        return out
    }

    /// The "since your last look" block for an observation (empty when nothing happened).
    public static func sinceLastLook(_ records: [UIEventRecord], limit: Int = 12) -> [String] {
        let body = lines(records, limit: limit)
        guard !body.isEmpty else { return [] }
        return ["Since your last look:"] + body
    }
}

/// Small helper windows — floating buttons and badges an app or the system shows next to a
/// window (the Writing Tools button, input-method badges) — are not windows the user works in:
/// they are not reported as opened windows or dialogs.
public enum WindowSize {
    public static func isIncidental(width: Double, height: Double) -> Bool {
        width < 200 || height < 100
    }
}

/// Dialog surfaces — sheets, and windows without title-bar buttons (open / save panels,
/// alerts, other dialogs): their content may be drawn by another process (the system's file
/// panels are), which input posted to the app never reaches. While one has the keyboard,
/// keys and clicks that accessibility cannot do go as real input with the app in front.
/// Recognised by structure, never by name.
public enum DialogSurface {
    /// A window is dialog-like when it has none of the title-bar buttons app windows have.
    public static func isDialogWindow(hasClose: Bool, hasMinimize: Bool, hasZoom: Bool) -> Bool {
        !hasClose && !hasMinimize && !hasZoom
    }
}

/// A page that has content in the accessibility tree but shows as one flat colour in the
/// screenshot: Chromium-based apps stop drawing web content they consider covered or in
/// the background, so the capture shows a stale or empty area.
public enum BlankPageArea {
    /// `thumbnail`: `side`² grayscale cells of the screenshot (top row first); `region`:
    /// the page area as fractions of the window (x0, y0, x1, y1). Uniform = every cell
    /// within 6 grey levels.
    public static func isBlank(thumbnail: [UInt8], side: Int, region: (Double, Double, Double, Double)) -> Bool {
        let (x0, y0, x1, y1) = region
        let c0 = max(0, Int((x0 * Double(side)).rounded(.up))), c1 = min(side, Int((x1 * Double(side)).rounded(.down)))
        let r0 = max(0, Int((y0 * Double(side)).rounded(.up))), r1 = min(side, Int((y1 * Double(side)).rounded(.down)))
        guard c1 - c0 >= 4, r1 - r0 >= 4, thumbnail.count >= side * side else { return false }
        var lo = UInt8.max, hi = UInt8.min
        for r in r0..<r1 {
            for c in c0..<c1 {
                let v = thumbnail[r * side + c]
                lo = min(lo, v)
                hi = max(hi, v)
            }
        }
        return Int(hi) - Int(lo) <= 6
    }

    /// The first web area with listed content: its frame.
    public static func pageFrame(_ roots: [AXNode]) -> NodeFrame? {
        for n in roots {
            if n.role == "AXWebArea", let f = n.frame, f.hasArea, VisibleArea.hasContent(n) { return f }
            if let f = pageFrame(n.children) { return f }
        }
        return nil
    }

    public static let note =
        "Note: the page area of the screenshot looks blank although the page has content (the app may not draw web content while it is covered or in the background): rely on the text above, or observe again."
}

// MARK: - waitFor conditions

public enum WaitCondition: Equatable, Sendable {
    case textAppears(String)
    case textGone(String)
    case elementChanges(Int)
    case newWindow
    case settled
    case anyChange

    public static let maxTimeoutMs = 60_000
    public static let defaultTimeoutMs = 10_000

    /// Parse `{until, text?, elementNumber?}`.
    public static func parse(_ payload: JSONValue) throws -> WaitCondition {
        guard let until = payload["until"]?.stringValue else {
            throw TurboError.invalid("waitFor requires until: textAppears, textGone, elementChanges, newWindow, settled or anyChange")
        }
        func text() throws -> String {
            guard let t = payload["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, t.count <= 500
            else { throw TurboError.invalid("\(until) requires a non-empty text (at most 500 characters)") }
            return t
        }
        switch until {
        case "textAppears": return .textAppears(try text())
        case "textGone": return .textGone(try text())
        case "elementChanges":
            guard let i = payload["elementNumber"]?.intValue, i >= 0 else {
                throw TurboError.invalid("elementChanges requires elementNumber from the latest observation")
            }
            return .elementChanges(i)
        case "newWindow": return .newWindow
        case "settled": return .settled
        case "anyChange": return .anyChange
        default:
            throw TurboError.invalid("Unknown until \"\(TreeFormat.clean(until, limit: 40))\": use textAppears, textGone, elementChanges, newWindow, settled or anyChange")
        }
    }

    public static func timeoutMs(_ payload: JSONValue) throws -> Int {
        guard let v = payload["timeoutMs"], !v.isNull else { return defaultTimeoutMs }
        guard let ms = v.intValue, (100...maxTimeoutMs).contains(ms) else {
            throw TurboError.invalid("timeoutMs must be 100-\(maxTimeoutMs)")
        }
        return ms
    }

    /// Case- and space-insensitive containment, for text conditions.
    public static func contains(_ haystack: String, _ needle: String) -> Bool {
        squash(haystack).contains(squash(needle))
    }

    static func squash(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Every user-visible string of a tree (labels, values, text), one per node; password
    /// field values are never read into `AXNode` in the first place.
    public static func texts(_ roots: [AXNode]) -> [String] {
        var out: [String] = []
        func walk(_ n: AXNode) {
            for s in [n.title, n.description, n.labelValue, n.placeholder] {
                if let s, !s.isEmpty { out.append(s) }
            }
            if !n.isSecure, let v = n.value, case .string(let s) = v, !s.isEmpty { out.append(s) }
            n.children.forEach(walk)
        }
        roots.forEach(walk)
        return out
    }
}

import Foundation

/// Loading state of one top-level web area (`AXWebArea`, not nested in another one).
public struct WebAreaLoad: Equatable, Sendable {
    /// `AXLoaded`; nil when the browser does not expose it.
    public var loaded: Bool?
    /// `AXLoadingProgress` (0…1); nil when not exposed.
    public var progress: Double?
    /// `AXURL`, for the log.
    public var url: String?

    public init(loaded: Bool?, progress: Double?, url: String? = nil) {
        self.loaded = loaded
        self.progress = progress
        self.url = url
    }

    /// This web area says it is still loading.
    public var isLoading: Bool {
        if loaded == false { return true }
        if let p = progress, p.isFinite, p < PageLoadSignals.completeProgress { return true }
        return false
    }
}

/// What the helper read about page loads in the observed window(s), used to settle. Pure data; the helper fills it from AX.
///
/// Signals, all observed live in Safari (WebKit) and documented for Chromium:
/// * `AXLoaded` / `AXLoadingProgress` on each web area: accurate once the new page has
///   started arriving.
/// * Safari's page group identifier `BrowserView?IsPageLoaded=false&…`: covers the first
///   phase of a navigation, before the new page's web area exists (the old page's and a
///   placeholder web area both still say loaded=true then).
public struct PageLoadSignals: Equatable, Sendable {
    /// Progress at or above this counts as complete.
    public static let completeProgress = 0.999
    /// Identifier marker of a Safari page group that has not started showing its page.
    public static let pendingMarker = "IsPageLoaded=false"
    public static let pageGroupMarker = "IsPageLoaded="

    public var webAreas: [WebAreaLoad]
    /// Identifiers seen in the window that carry `IsPageLoaded=` (others are not kept).
    public var pageGroupIdentifiers: [String]
    /// The read stopped before it covered every window (element or time cap, or an
    /// element that did not answer): "no web content" is then unknown, not a fact.
    public var incomplete: Bool

    public init(webAreas: [WebAreaLoad] = [], pageGroupIdentifiers: [String] = [], incomplete: Bool = false) {
        self.webAreas = webAreas
        self.pageGroupIdentifiers = pageGroupIdentifiers
        self.incomplete = incomplete
    }

    /// Whether `identifier` is worth keeping in `pageGroupIdentifiers`.
    public static func isPageGroupIdentifier(_ identifier: String?) -> Bool {
        identifier?.contains(pageGroupMarker) ?? false
    }

    public var hasWebContent: Bool { !webAreas.isEmpty || !pageGroupIdentifiers.isEmpty }

    public var isLoading: Bool {
        webAreas.contains(where: \.isLoading) || pageGroupIdentifiers.contains { $0.contains(Self.pendingMarker) }
    }

    /// Lowest progress among the web areas that are still loading (nil if unknown, e.g.
    /// in the first phase where only the page group says so).
    public var progress: Double? {
        webAreas.filter(\.isLoading).compactMap { $0.progress.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil } }.min()
    }

    public mutating func merge(_ other: PageLoadSignals) {
        webAreas.append(contentsOf: other.webAreas)
        pageGroupIdentifiers.append(contentsOf: other.pageGroupIdentifiers)
        incomplete = incomplete || other.incomplete
    }

    /// What is loading right now (loading web areas' URL and progress, pending page
    /// groups), nil when nothing is. Two equal fingerprints a while apart mean the load
    /// made no progress (see `PageLoadWait`).
    public var loadingFingerprint: String? {
        guard isLoading else { return nil }
        let areas = webAreas.filter(\.isLoading).map { area -> String in
            let p = area.progress.map { $0.isFinite ? String(format: "%.3f", $0) : "?" } ?? "-"
            return "\(area.url ?? "")@\(p)/\(area.loaded.map { $0 ? "1" : "0" } ?? "-")"
        }
        let pending = pageGroupIdentifiers.filter { $0.contains(Self.pendingMarker) }
        return (areas.sorted() + pending.sorted()).joined(separator: "\n")
    }

    /// The header summary, or nil when there is no web content.
    public var summary: PageLoadSummary? {
        hasWebContent ? PageLoadSummary(isLoading: isLoading, progress: isLoading ? progress : nil) : nil
    }
}

/// The `Page loading:` header line of an observation.
public struct PageLoadSummary: Equatable, Sendable {
    public var isLoading: Bool
    public var progress: Double?

    public init(isLoading: Bool, progress: Double? = nil) {
        self.isLoading = isLoading
        self.progress = progress
    }

    /// `63%`, or nil when unknown.
    public var percentText: String? {
        guard let p = progress, p.isFinite else { return nil }
        return "\(Int((min(max(p, 0), 1) * 100).rounded(.down)))%"
    }

    /// `Page loading: yes (63%)`, `Page loading: yes`, `Page loading: no`.
    public var headerLine: String {
        guard isLoading else { return "Page loading: no" }
        if let pct = percentText { return "Page loading: yes (\(pct))" }
        return "Page loading: yes"
    }
}

/// When and how long the helper waits for web content to finish loading.
public enum PageLoadPolicy {
    /// Long wait: actions that typically start a navigation.
    public static let navigationBudget: TimeInterval = 10
    /// Short wait: other actions, and before a observe_app snapshot.
    public static let defaultBudget: TimeInterval = 3
    public static let observationBudget: TimeInterval = 3
    /// Poll interval while waiting.
    public static let pollInterval: TimeInterval = 0.15

    /// Whether to probe for page loads after an action / before a snapshot: apps that
    /// showed web content in this session, and web browsers (detected from the bundle: it
    /// registers the http / https URL schemes) even before that. Other apps pay nothing.
    public static func shouldProbe(webContentSeen: Bool, isWebBrowser: Bool) -> Bool {
        webContentSeen || isWebBrowser
    }

    /// A bundle that registers `http` or `https` (`CFBundleURLTypes`) is a web browser.
    public static func isWebBrowser(urlTypes: [[String: Any]]) -> Bool {
        urlTypes.contains { entry in
            ((entry["CFBundleURLSchemes"] as? [Any]) ?? []).contains {
                guard let scheme = ($0 as? String)?.lowercased() else { return false }
                return scheme == "http" || scheme == "https"
            }
        }
    }

    /// Maximum page-load wait after `action`.
    public static func budget(for action: TurboAction) -> TimeInterval {
        switch action {
        case .writeText(let text, _):
            return text.contains("\n") || text.contains("\r") ? navigationBudget : defaultBudget
        case .sendKeys(let key):
            return isNavigationChord(key) ? navigationBudget : defaultBudget
        case .click, .invokeAction, .runCommand:
            return navigationBudget
        case .scroll, .drag, .fillValue, .pickText, .paste:
            return defaultBudget
        }
    }

    /// Return/Enter (any modifiers), cmd+r (reload), cmd+[ / cmd+] (back / forward).
    public static func isNavigationChord(_ chord: String) -> Bool {
        let parts = chord.lowercased().split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // "cmd++" style chords end in an empty part; the key is then "+".
        guard let last = parts.last else { return false }
        let key = last.isEmpty && parts.count > 1 ? "+" : last
        let mods = Set(parts.dropLast())
        if key == "return" || key == "enter" || key == "kp_enter" { return true }
        let cmd = !mods.isDisjoint(with: ["cmd", "command", "super", "meta"])
        return cmd && ["r", "[", "]"].contains(key)
    }

    /// A load that was already under way before the action and has not changed (same
    /// URL, same progress) for this long is treated as stuck: the wait ends early.
    public static let stallAfter: TimeInterval = 1.0
    /// Scans cut short before reaching any web content are retried for this long, then
    /// the load state is reported as unknown.
    public static let unknownLimit: TimeInterval = 1.0

    static func seconds(_ t: TimeInterval) -> String {
        let secs = max(0, t)
        return secs >= 9.95 ? String(Int(secs.rounded())) : String(format: "%.1f", secs)
    }

    /// Note appended to an action result when the page was still loading at the end of
    /// the wait.
    public static func stillLoadingNote(_ summary: PageLoadSummary, waited: TimeInterval) -> String {
        let pct = summary.percentText.map { " (\($0))" } ?? ""
        return
            "The page is still loading\(pct) after \(seconds(waited)) s; call observe_app to see what has loaded so far before reading or clicking page content (it may be incomplete)."
    }

    /// Note when the page was already loading before the action and made no progress.
    public static func stalledNote(_ summary: PageLoadSummary, unchangedFor: TimeInterval) -> String {
        let pct = summary.percentText.map { " (\($0))" } ?? ""
        return
            "The page was already loading\(pct) before this action and made no progress for \(seconds(unchangedFor)) s, so the helper did not wait for it; it may never finish. Its content may be usable as it is: check it with observe_app."
    }

    /// Observation note for a page that keeps loading without progress.
    public static func stalledObservationNote(unchangedFor: TimeInterval) -> String {
        "Note: the page has been loading without progress for at least \(seconds(unchangedFor)) s and may never finish; its content below may be usable as it is."
    }

    /// Note when the scans could not tell whether the page finished loading.
    public static let unknownNote =
        "The helper could not tell whether the page finished loading (the window did not answer in time); call observe_app before reading or clicking page content."

    /// Note when the user's Stop or a screen lock ended the wait: the action itself was
    /// performed, and the model must not carry on.
    public static func interruptedNote(stopped: Bool) -> String {
        stopped
            ? "The action was performed, but the user pressed Stop while the helper waited for the page to load. Do not continue; ask the user how to proceed."
            : "The action was performed, but the screen locked while the helper waited for the page to load. Wait for the user to unlock it, then call observe_app."
    }
}

/// The decision logic of one bounded page-load wait, fed
/// with one scan per poll. Pure: no AX calls.
public struct PageLoadWait: Sendable {
    public enum Verdict: Equatable, Sendable {
        /// Poll again.
        case keepWaiting
        /// No web content (complete scan): nothing to wait for.
        case noWebContent
        case loaded
        /// Already loading before the action, unchanged for `stallAfter`.
        case stalled(unchangedFor: TimeInterval)
        /// Scans kept being cut short before reaching web content.
        case unknown
    }

    /// `loadingFingerprint` before the action (or where an earlier wait ended still
    /// loading); nil when nothing was loading. Only a load that still matches it can be
    /// treated as stuck: a load the action started always gets the full budget.
    public private(set) var baseline: String?
    private var unchangedSince: TimeInterval?
    private var firstIncomplete: TimeInterval?

    public init(baseline: String?) {
        self.baseline = baseline
    }

    /// Decide after a scan taken `t` seconds into the wait.
    public mutating func evaluate(_ s: PageLoadSignals, at t: TimeInterval) -> Verdict {
        guard s.hasWebContent else {
            guard s.incomplete else { return .noWebContent }
            // A cut-short scan that found nothing is not "no web content": retry briefly.
            if firstIncomplete == nil { firstIncomplete = t }
            return t - (firstIncomplete ?? t) >= PageLoadPolicy.unknownLimit ? .unknown : .keepWaiting
        }
        firstIncomplete = nil
        guard s.isLoading else { return .loaded }
        let fp = s.loadingFingerprint
        guard let base = baseline, fp == base else {
            // Something changed (the action started a load, or the load moved on): wait
            // for it, and never treat this wait as stuck again.
            baseline = nil
            unchangedSince = nil
            return .keepWaiting
        }
        if unchangedSince == nil { unchangedSince = t }
        let unchanged = t - (unchangedSince ?? t)
        return unchanged >= PageLoadPolicy.stallAfter ? .stalled(unchangedFor: unchanged) : .keepWaiting
    }
}

/// fill_value helpers.
public enum FillValuePolicy {
    /// Roles whose value only "sticks" in some apps when the field is being edited
    /// (Safari's address field ignores a value set while it is not focused).
    public static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// Focus the element before setting its value: text-like, focusable and not focused.
    public static func shouldFocusFirst(role: String?, isFocused: Bool?, focusSettable: Bool) -> Bool {
        guard let role, textRoles.contains(role) else { return false }
        return isFocused != true && focusSettable
    }

    public enum ReadBack: Equatable, Sendable {
        case kept
        /// The element did not take the value: it reads empty or what it held before
        /// (rendered text form).
        case notKept(actual: String)
        /// The element holds something else that is neither the request nor the old
        /// value: the app reformatted it (input mask, number formatting, autocomplete).
        case reformatted(actual: String)
        /// The value could not be read back.
        case unknown
    }

    /// Words accepted for an element whose value is a true/false (`CFBoolean`).
    public static let trueWords: Set<String> = ["1", "true", "yes", "on", "checked", "selected"]
    public static let falseWords: Set<String> = ["0", "false", "no", "off", "unchecked", "unselected"]
    public static let booleanWordsText = "true/false, 1/0, yes/no, on/off, checked/unchecked"

    /// The boolean a fill_value word means, nil when it is not an explicit true/false word.
    public static func booleanValue(_ word: String) -> Bool? {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trueWords.contains(w) { return true }
        if falseWords.contains(w) { return false }
        return nil
    }

    /// Compare what was requested with what the element holds after settling.
    /// `previous` is what it held before the set (nil = unknown).
    public static func compare(requested: String, readBack: AXNodeValue?, previous: AXNodeValue? = nil) -> ReadBack {
        guard let readBack else { return .unknown }
        switch readBack {
        case .string(let s):
            if s == requested { return .kept }
            // Line endings (NSTextView turns \r\n into \n), non-breaking spaces (WebKit
            // keeps runs of spaces as U+00A0) and surrounding whitespace (trimmed by many
            // web inputs) are not a different value.
            if normalized(s) == normalized(requested) { return .kept }
            let reverted =
                s.isEmpty || previous.map { normalized($0.text) == normalized(s) && normalized($0.text) != normalized(requested) }
                ?? false
            return reverted || previous == nil ? .notKept(actual: s) : .reformatted(actual: s)
        case .number(let d):
            if let want = Double(requested.trimmingCharacters(in: .whitespaces)), abs(want - d) <= max(1e-9, abs(want) * 1e-9) {
                return .kept
            }
            return .notKept(actual: readBack.text)
        case .bool(let b):
            guard let want = booleanValue(requested) else { return .notKept(actual: readBack.text) }
            return want == b ? .kept : .notKept(actual: readBack.text)
        }
    }

    /// Text compared for "the same value": line endings unified, NBSP → space, runs of
    /// spaces/tabs collapsed, surrounding whitespace trimmed.
    static func normalized(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        t = t.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
        var out = ""
        var lastWasSpace = false
        for ch in t {
            let space = ch == " " || ch == "\t"
            if space && lastWasSpace { continue }
            out.append(space ? " " : ch)
            lastWasSpace = space
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Note for a value the app reformatted (kept, but not character for character).
    public static func reformattedNote(index: Int, requested: String, actual: String) -> String {
        "The value was set; #\(index) now reads \"\(TreeFormat.clean(actual, limit: 80))\" (the app may have reformatted \"\(TreeFormat.clean(requested, limit: 80))\"). Check it with observe_app if the exact text matters; do not type it again."
    }

    /// Note for a value the app did not keep.
    public static func notKeptNote(index: Int, requested: String, actual: String) -> String {
        let shownActual = actual.isEmpty ? "empty" : "\"\(TreeFormat.clean(actual, limit: 80))\""
        return
            "The value was set, but #\(index) did not keep it: it reads \(shownActual) instead of \"\(TreeFormat.clean(requested, limit: 80))\" (the app reverted or ignored the change). Try clicking the field and typing with write_text instead; for a browser address bar use send_keys \"cmd+l\" then write_text \"<url>\\n\"."
    }
}

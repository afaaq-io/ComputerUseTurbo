import Foundation

/// The observed window, in global points (top-left origin).
public struct WindowSummary: Equatable, Sendable {
    public var title: String
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(title: String, x: Int, y: Int, width: Int, height: Int) {
        self.title = title
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Everything needed to render the `text` of a `observeApp` result.
public struct ObservationInput: Sendable {
    public var appName: String
    public var bundleId: String
    public var pid: Int
    /// "Electron" / "Chromium" / "Mac Catalyst" (nil = a native app): shown in the header.
    public var appKind: String?
    public var window: WindowSummary?
    /// One-line notes printed right after the header (e.g. missing Screen Recording).
    public var notes: [String]
    public var tree: SerializedTree
    /// Handle of the app's `AXFocusedUIElement`, if known.
    public var focusedHandle: Int?
    public var selectedText: String?
    /// Lines printed after the tree/diff body (e.g. "read was cut short").
    public var trailers: [String]
    /// Baseline from the previous observation of this app in this session.
    public var previousBaseline: [Int: String]?
    public var fullTree: Bool
    /// Indices that left the observation scope (not reported as removed).
    public var ignoredRemovals: Set<Int> = []
    /// Page-load state of the observed window; nil when it shows no web content (then
    /// there is no `Page loading:` header line).
    public var pageLoad: PageLoadSummary?
    /// Pixel space of x/y arguments (the screenshot's size and scale); nil = no window.
    public var screenshot: ScreenshotGeometry?
    /// A screenshot image accompanies this observation.
    public var screenshotCaptured: Bool
    /// Fraction of the screenshot that changed since the previous observation of this app
    /// in this session (`ScreenshotChange`); nil = unknown (no screenshot either time).
    public var screenshotChange: Double?

    public init(
        appName: String, bundleId: String, pid: Int, appKind: String? = nil, window: WindowSummary?, notes: [String] = [],
        tree: SerializedTree, focusedHandle: Int? = nil, selectedText: String? = nil,
        trailers: [String] = [],
        previousBaseline: [Int: String]? = nil, fullTree: Bool = false, pageLoad: PageLoadSummary? = nil,
        screenshot: ScreenshotGeometry? = nil, screenshotCaptured: Bool = false, screenshotChange: Double? = nil
    ) {
        self.appName = appName
        self.bundleId = bundleId
        self.pid = pid
        self.appKind = appKind
        self.window = window
        self.notes = notes
        self.tree = tree
        self.focusedHandle = focusedHandle
        self.selectedText = selectedText
        self.trailers = trailers
        self.previousBaseline = previousBaseline
        self.fullTree = fullTree
        self.pageLoad = pageLoad
        self.screenshot = screenshot
        self.screenshotCaptured = screenshotCaptured
        self.screenshotChange = screenshotChange
    }
}

public struct ObservationOutput: Equatable, Sendable {
    public var text: String
    public var isDiff: Bool
    /// The new diff baseline (always the full new tree).
    public var baseline: [Int: String]
}

/// Assembles header, tree or diff, and footer.
public enum ObservationRenderer {
    public static func headerLines(
        appName: String, bundleId: String, pid: Int, window: WindowSummary?, pageLoad: PageLoadSummary? = nil,
        screenshot: ScreenshotGeometry? = nil, screenshotCaptured: Bool = false, appKind: String? = nil
    ) -> [String] {
        var lines = ["App: \(appName) (\(bundleId)) pid \(pid)" + (appKind.map { " — \($0) app" } ?? "")]
        if let w = window {
            lines.append("Window: \"\(TreeFormat.clean(w.title))\" \(w.width)x\(w.height) at (\(w.x),\(w.y))")
            if let g = screenshot { lines.append(screenshotLine(g, captured: screenshotCaptured)) }
        } else {
            lines.append("Window: none")
        }
        if let pageLoad { lines.append(pageLoad.headerLine) }
        return lines
    }

    /// `Screenshot: 1493x770 px, scale 0.5834 (…)`: the pixel space of every x/y argument
    ///.
    public static func screenshotLine(_ g: ScreenshotGeometry, captured: Bool) -> String {
        let size = "\(g.pixelWidth)x\(g.pixelHeight) px"
        if !captured {
            return g.isDownscaled
                ? "Screenshot: none; x/y arguments are pixels of a \(size) image of the window, scale \(g.scaleText) (screen point = window origin + pixel / scale)"
                : "Screenshot: none; x/y arguments are window points (scale 1)"
        }
        return g.isDownscaled
            ? "Screenshot: \(size), scale \(g.scaleText) (downscaled; x/y arguments are pixels in this screenshot, screen point = window origin + pixel / scale)"
            : "Screenshot: \(size), scale 1 (x/y arguments are pixels in this screenshot = window points)"
    }

    /// The focused element used for the footer: the element whose handle is the app's
    /// focused UI element, else the deepest-last focused non-window element.
    public static func focusedElement(in tree: SerializedTree, focusedHandle: Int?) -> SerializedElement? {
        if let h = focusedHandle, h >= 0, let e = tree.element(forHandle: h) { return e }
        return tree.elements.last { $0.isFocused && $0.role != AXRoles.window }
    }

    /// After `Selection:`: a selection usually comes from the user.
    public static let selectionNote =
        "Note: this text is selected (by the user, or by an earlier pick_text); when the user refers to \"this\" or \"the selection\", they probably mean it."

    public static func footerLines(tree: SerializedTree, focusedHandle: Int?, selectedText: String?) -> [String] {
        var lines: [String] = []
        let focused = focusedElement(in: tree, focusedHandle: focusedHandle)
        if let f = focused {
            let label = f.label.map { " " + $0.rendered } ?? ""
            lines.append("Keyboard focus: #\(f.index) \(f.roleText)\(label)")
        }
        if let s = selectedText, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Selection: \"\(TreeFormat.clean(s))\"")
            lines.append(selectionNote)
        }
        if let f = focused, !f.displayActions.isEmpty {
            lines.append("More actions on #\(f.index): \(f.displayActions.joined(separator: ", "))")
        }
        return lines
    }

    public static func render(_ input: ObservationInput) -> ObservationOutput {
        var lines = headerLines(
            appName: input.appName, bundleId: input.bundleId, pid: input.pid, window: input.window,
            pageLoad: input.pageLoad, screenshot: input.screenshot, screenshotCaptured: input.screenshotCaptured,
            appKind: input.appKind)
        lines.append(contentsOf: input.notes)

        var isDiff = false
        // Chromium / Electron apps (appKind set) build their tree on demand: an empty tree
        // there is still loading, not a self-drawn UI.
        let sparse = input.appKind == nil
            && AccessibilitySparsity.isSparse(input.tree, window: input.window, hasWebContent: input.pageLoad != nil)
        if let previous = input.previousBaseline, !input.fullTree {
            switch TreeDiff.compute(previous: previous, current: input.tree.elements, ignoringRemoved: input.ignoredRemovals) {
            case .noChanges:
                isDiff = true
                lines.append(sparse ? AccessibilitySparsity.noChangesLine : TreeDiff.noChangesLine)
            case .changes(let changeLines):
                // Send the diff only when it is clearly smaller than the full tree
                //: a diff that rewrites most lines is harder to
                // read than the tree itself.
                if TreeDiff.isWorthSending(diffLines: changeLines, fullLines: input.tree.indentedLines) {
                    isDiff = true
                    if sparse { lines.append(AccessibilitySparsity.hint) }
                    lines.append(TreeDiff.header)
                    lines.append(contentsOf: changeLines)
                }
            case .tooLarge:
                isDiff = false
            }
        }
        if !isDiff {
            if sparse { lines.append(AccessibilitySparsity.hint) }
            lines.append(contentsOf: input.tree.indentedLines)
        }
        // After the first observation (diff or full tree — a diff that was not shorter
        // than the tree is sent in full, e.g. when a dialog window opened).
        if input.previousBaseline != nil, let change = input.screenshotChange {
            lines.append(ScreenshotChange.line(change))
        }
        if input.tree.truncated { lines.append(input.tree.truncationNotice) }
        lines.append(contentsOf: input.trailers)
        lines.append(
            contentsOf: footerLines(
                tree: input.tree, focusedHandle: input.focusedHandle, selectedText: input.selectedText))

        let text = lines.joined(separator: "\n")
        return ObservationOutput(text: text, isDiff: isDiff, baseline: input.tree.baseline)
    }
}

/// Apps that draw their own UI (Blender, Godot, game launchers) expose little more than
/// window chrome and the menu bar to accessibility: a diff of such a tree says "no
/// changes" although the window changed completely.
public enum AccessibilitySparsity {
    /// At most this many elements outside the menu bar.
    public static let maxElements = 15
    /// Only windows at least this large (pt²) count: a small native alert with a few
    /// buttons is not "drawing its own UI".
    public static let minWindowArea = 160_000
    /// Roles that mean the tree does carry the content.
    public static let contentRoles: Set<String> = [
        "AXWebArea", "AXTextArea", "AXTextField", "AXTable", "AXOutline", "AXList", "AXBrowser", "AXCollection",
    ]

    public static let hint = "Accessibility shows almost nothing for this app (it draws its own UI) — rely on the screenshot."
    public static let noChangesLine =
        "Accessibility shows almost nothing for this app (it draws its own UI) — rely on the screenshot; no accessibility changes."

    /// `hasWebContent`: the observed window shows web content (a `Page loading:` line).
    public static func isSparse(_ tree: SerializedTree, window: WindowSummary?, hasWebContent: Bool = false) -> Bool {
        guard !hasWebContent, let w = window, w.width > 0, w.height > 0, w.width * w.height >= minWindowArea,
            !tree.truncated
        else {
            return false
        }
        var count = 0
        var menuDepth: Int?
        for e in tree.elements {
            if let d = menuDepth {
                if e.depth > d { continue }
                menuDepth = nil
            }
            if e.role == AXRoles.menuBar {
                menuDepth = e.depth
                continue
            }
            if contentRoles.contains(e.role) { return false }
            count += 1
            if count > maxElements { return false }
        }
        return true
    }
}

/// Cheap "did the picture change" signal between two screenshots of one app in one
/// session: both are reduced to `side` × `side`
/// grayscale thumbnails; a cell counts as changed when its brightness moved by more than
/// `cellThreshold` levels.
public enum ScreenshotChange {
    public static let side = 32
    public static let cellThreshold = 8

    /// Fraction (0…1) of changed cells; nil when the thumbnails are not comparable.
    public static func fraction(previous: [UInt8], current: [UInt8]) -> Double? {
        guard previous.count == side * side, current.count == previous.count else { return nil }
        var changed = 0
        for i in 0..<current.count where abs(Int(current[i]) - Int(previous[i])) > cellThreshold {
            changed += 1
        }
        return Double(changed) / Double(current.count)
    }

    public static func line(_ fraction: Double) -> String {
        guard fraction > 0 else { return "Screenshot changed: no large change (small edits such as text in a field may not register; look at the image)" }
        let pct = fraction * 100
        let amount = pct < 1 ? "<1%" : "≈\(Int(pct.rounded()))%"
        return "Screenshot changed: yes (\(amount) of the image)"
    }
}

/// When a click by position must not be sent: since the agent's last look, while the agent
/// did nothing, the window turned into something else (more than `limit` of it changed) or
/// the spot under the click did (`localLimit` of the cells around it), and the window is
/// not simply moving (video, animation). Taps whose effect shows elsewhere (a calculator's
/// display above its buttons) leave the spot under the next tap alone and pass.
public enum StaleClickGuard {
    public static let limit = 0.3
    public static let localLimit = 0.5
    public static let movingLimit = 0.05

    /// Share of the cells around `target` (0…1 of the window) that changed.
    public static func localChange(previous: [UInt8], current: [UInt8], target: (x: Double, y: Double)) -> Double? {
        let side = ScreenshotChange.side
        guard previous.count == side * side, current.count == previous.count else { return nil }
        let cx = min(side - 1, max(0, Int(target.x * Double(side)))), cy = min(side - 1, max(0, Int(target.y * Double(side))))
        var cells = 0, changed = 0
        for y in max(0, cy - 1)...min(side - 1, cy + 1) {
            for x in max(0, cx - 1)...min(side - 1, cx + 1) {
                cells += 1
                if abs(Int(current[y * side + x]) - Int(previous[y * side + x])) > ScreenshotChange.cellThreshold { changed += 1 }
            }
        }
        return Double(changed) / Double(cells)
    }

    public static func refuse(changedSinceLook: Double?, changedAtTarget: Double?, stillMoving: Double?, actedSinceLook: Bool) -> Bool {
        guard !actedSinceLook else { return false }
        let different = (changedSinceLook ?? 0) >= limit || (changedAtTarget ?? 0) >= localLimit
        return different && (stillMoving ?? 0) <= movingLimit
    }
}

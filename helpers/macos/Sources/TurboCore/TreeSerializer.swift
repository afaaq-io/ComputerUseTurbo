import Foundation

/// One emitted element of a serialized tree.
public struct SerializedElement: Equatable, Sendable {
    public let index: Int
    /// Emitted depth (after pruned containers are hoisted). Indentation = 2 × depth.
    public let depth: Int
    /// The rendered line without indentation (`[3] button "OK" …`).
    public let line: String
    /// Helper handle of the source node.
    public let handle: Int
    /// Identity key (see `TreeSerializer.identityComponent`).
    public let identity: String
    /// `role` / `role (subrole)` as printed.
    public let roleText: String
    public let label: ElementLabel?
    /// Display action names (hidden ones removed, `AX` stripped).
    public let displayActions: [String]
    public let isFocused: Bool
    /// Raw AX role (for footer heuristics).
    public let role: String
    /// AXSecureTextField (role or subrole) when observed. The helper refuses
    /// fill_value / pick_text / write_text on such an index even if a later live
    /// re-check of the role cannot be answered.
    public let isSecure: Bool
}

/// The result of serializing an AX forest.
public struct SerializedTree: Equatable, Sendable {
    public var elements: [SerializedElement]
    /// True when the element cap stopped the walk.
    public var truncated: Bool
    public var maxElements: Int

    public var truncationNotice: String {
        "… tree truncated at \(maxElements) elements; act on visible elements or scroll"
    }

    /// Indented lines for the full-tree form.
    public var indentedLines: [String] {
        elements.map { String(repeating: "  ", count: $0.depth) + $0.line }
    }

    /// Diff baseline: index → line (indentation ignored).
    public var baseline: [Int: String] {
        var map: [Int: String] = [:]
        for e in elements { map[e.index] = e.line }
        return map
    }

    public func element(forHandle handle: Int) -> SerializedElement? {
        elements.first { $0.handle == handle }
    }

    public func element(forIndex index: Int) -> SerializedElement? {
        elements.first { $0.index == index }
    }
}

/// Walks an `AXNode` forest (windows first, then menu bar) and produces indexed lines
/// with pruning with hoisting, identity-stable indices (see
/// `IdentityIndexer`), element cap with a reservation for everything outside web content.
public enum TreeSerializer {
    private static let fieldSeparator = "\u{1F}"
    private static let pathSeparator = "\u{1E}"
    static let webAreaRole = "AXWebArea"

    /// Prunable = pure container, not disabled, no title/value/description/identifier,
    /// no meaningful action, and not carrying focus/selection state.
    public static func isPrunable(_ node: AXNode) -> Bool {
        guard AXRoles.prunableContainers.contains(node.role) else { return false }
        if node.isEnabled == false { return false }
        if node.isFocused || node.isSelected || node.isValueSettable { return false }
        if TreeFormat.label(for: node) != nil { return false }
        if !node.isSecure, let v = node.value, !v.text.isEmpty { return false }
        if node.actions.contains(where: { !AXRoles.passiveActions.contains($0) }) { return false }
        return true
    }

    /// The label as it enters the path key: windows contribute no title (a page load or
    /// a document rename must not re-key the window) but the file they show
    /// (`AXDocument`, `file:` URLs only — a browser reports the page URL there), so a
    /// document's window is told apart from the app's other windows by what it shows
    /// rather than by its position in focus order. Identifier labels are cut at the
    /// first `?` or `#` (Safari's `BrowserView?IsPageLoaded=true&WebViewProcessID=…`
    /// changes on every navigation). Other labels are kept, e.g. a web area's page title,
    /// so a new document's content gets new indices.
    public static func stableLabel(node: AXNode, label: ElementLabel?) -> String {
        if node.role == AXRoles.window {
            guard let doc = node.document, doc.lowercased().hasPrefix("file:") else { return "" }
            return "doc=" + doc
        }
        guard let label else { return "" }
        if label.kind == .identifier {
            let cut = label.raw.split(maxSplits: 1, omittingEmptySubsequences: false, whereSeparator: { $0 == "?" || $0 == "#" })
            return ElementLabel(kind: .identifier, raw: String(cut.first ?? "")).rendered
        }
        return label.rendered
    }

    /// What an element shows, for path-only matching after a relaunch
    /// (`IndexCandidate.content`): role, label and value (secure values are never read).
    public static func contentKey(node: AXNode, label: ElementLabel?) -> String {
        let value = node.isSecure ? "" : (node.value?.text ?? "")
        return [node.role, label?.rendered ?? "", value].joined(separator: fieldSeparator)
    }

    /// One path-key component: `(role, subrole, stable label, ordinal)`.
    public static func identityComponent(node: AXNode, label: ElementLabel?, ordinal: Int) -> String {
        return [node.role, node.subrole ?? "", stableLabel(node: node, label: label), String(ordinal)]
            .joined(separator: fieldSeparator)
    }

    /// Serialize `roots`. `indexer` supplies (and remembers) indices; `liveKeys[handle]`
    /// is the live element of the node with that handle (nil / out of range = none), and
    /// `isAlive` tells whether a previously indexed live element still exists.
    public static func serialize(
        roots: [AXNode], indexer: IdentityIndexer,
        liveKeys: [LiveKey?] = [], isAlive: (LiveKey) -> Bool = { _ in true },
        maxElements: Int = TurboProtocol.maxEmittedElements,
        maxDepth: Int = TurboProtocol.maxTreeDepth
    ) -> SerializedTree {
        // Everything outside web content is listed first-class: web content (descendants
        // of AXWebArea) gets only what is left of the cap, so a big page can never push
        // the toolbar, the window's other controls or other windows out of the tree.
        let outside = countOutsideWeb(roots, rawDepth: 0, maxDepth: maxDepth, limit: maxElements)
        var state = WalkState(webBudget: max(0, maxElements - outside), liveKeys: liveKeys)
        visit(
            roots, rawDepth: 0, emitDepth: 0, parentPath: "", inWeb: false, inMenuBar: false, clip: nil, noteTarget: nil,
            state: &state, maxElements: maxElements, maxDepth: maxDepth)
        let indices = indexer.assign(
            state.candidates.map {
                IndexCandidate(
                    stableKey: $0.path, liveKey: $0.keyedByTitle ? nil : $0.liveKey, role: $0.node.role,
                    subrole: $0.node.subrole, content: contentKey(node: $0.node, label: $0.label))
            }, isAlive: isAlive)
        // Keep the per-app index memory bounded (see IdentityIndexer).
        indexer.pruneIfNeeded()
        var elements: [SerializedElement] = []
        elements.reserveCapacity(state.candidates.count)
        for (c, index) in zip(state.candidates, indices) {
            let node = c.node
            var line: String
            if let summary = c.rowSummary {
                // Every row offers these: they say nothing on a one-line row.
                var plain = node
                plain.actions = node.actions.filter { !VisibleArea.incidentalActions.contains($0) }
                line = TreeFormat.line(index: index, node: plain) + ": " + summary
            } else {
                line = TreeFormat.line(index: index, node: node)
            }
            if c.hiddenOutside > 0 { line += " " + VisibleArea.note(hidden: c.hiddenOutside) }
            elements.append(
                SerializedElement(
                    index: index, depth: c.depth, line: line,
                    handle: node.handle, identity: c.path,
                    roleText: TreeFormat.roleText(role: node.role, subrole: node.subrole),
                    label: c.label, displayActions: TreeFormat.displayActions(node.actions),
                    isFocused: node.isFocused, role: node.role, isSecure: node.isSecure))
        }
        return SerializedTree(elements: elements, truncated: state.truncated, maxElements: maxElements)
    }

    private struct Candidate {
        let node: AXNode
        /// A table row printed on one line (its cells' text), children not listed.
        var rowSummary: String? = nil
        /// Descendants left out because they lie outside the visible area.
        var hiddenOutside = 0
        let depth: Int
        let path: String
        let label: ElementLabel?
        let liveKey: LiveKey?
        /// Identity is the path key alone (see `isKeyedByTitle`).
        let keyedByTitle: Bool
    }

    /// Menu-bar items (and the items of a menu opened from the menu bar) that have a
    /// title are identified by their title (path key: menu bar → title, ordinal among
    /// same-titled siblings), never by the live element: apps rebuild their menu bar
    /// when their menu set changes, and the live element at a position is then reused
    /// for a different menu, which made indices follow positions ("M #32 Edit" after
    /// it had been "File").
    public static func isKeyedByTitle(_ node: AXNode, inMenuBar: Bool) -> Bool {
        guard node.role == AXRoles.menuBarItem || (inMenuBar && node.role == AXRoles.menuItem) else { return false }
        return TreeFormat.nonEmpty(node.title) != nil
    }

    private struct WalkState {
        var candidates: [Candidate] = []
        /// Some element was left out (cap reached or web content over its share).
        var truncated = false
        /// The overall cap was reached: stop walking.
        var capped = false
        var webBudget: Int
        var webEmitted = 0
        let liveKeys: [LiveKey?]
        var seenLive = Set<LiveKey>()

        init(webBudget: Int, liveKeys: [LiveKey?]) {
            self.webBudget = webBudget
            self.liveKeys = liveKeys
        }

        func liveKey(_ node: AXNode) -> LiveKey? {
            node.handle >= 0 && node.handle < liveKeys.count ? liveKeys[node.handle] : nil
        }
    }

    /// Emittable (non-prunable) nodes outside web content, up to `limit`.
    private static func countOutsideWeb(_ nodes: [AXNode], rawDepth: Int, maxDepth: Int, limit: Int) -> Int {
        guard rawDepth < maxDepth else { return 0 }
        var n = 0
        for node in nodes {
            if n >= limit { break }
            if !isPrunable(node) { n += 1 }
            if node.role != webAreaRole {
                n += countOutsideWeb(node.children, rawDepth: rawDepth + 1, maxDepth: maxDepth, limit: limit - n)
            }
        }
        return min(n, limit)
    }

    private static func visit(
        _ nodes: [AXNode], rawDepth: Int, emitDepth: Int, parentPath: String, inWeb: Bool, inMenuBar: Bool,
        clip: NodeFrame?, noteTarget: Int?, state: inout WalkState, maxElements: Int, maxDepth: Int
    ) {
        guard rawDepth < maxDepth else { return }
        // Ordinals are counted among siblings sharing (role, subrole, stable label), over
        // the raw tree so a container's pruning decision never shifts its descendants'
        // keys.
        var ordinals: [String: Int] = [:]
        for node in nodes {
            if state.capped { return }
            let live = state.liveKey(node)
            if let live {
                // The same live element reachable twice (a sheet that is both the focused
                // window and a child of its document window): list it once.
                if state.seenLive.contains(live) { continue }
            }
            // Outside the visible part of its scroll area / page / window: left out, counted
            // on the nearest listed container. What has the keyboard stays.
            if let clip, let f = node.frame, f.hasArea, !f.showsIn(clip), !VisibleArea.holdsFocus(node) {
                if let t = noteTarget { state.candidates[t].hiddenOutside += 1 }
                continue
            }
            // A row / cell / group that shows nothing anywhere in it.
            if VisibleArea.isEmptySubtree(node) { continue }
            if inWeb && state.webEmitted >= state.webBudget {
                // Web content over its share of the cap: skip it, keep walking the rest.
                state.truncated = true
                continue
            }
            if let live { state.seenLive.insert(live) }
            let label = TreeFormat.label(for: node)
            let ordinalKey = [node.role, node.subrole ?? "", stableLabel(node: node, label: label)]
                .joined(separator: fieldSeparator)
            let ordinal = ordinals[ordinalKey, default: 0]
            ordinals[ordinalKey] = ordinal + 1
            let component = identityComponent(node: node, label: label, ordinal: ordinal)
            let path = parentPath.isEmpty ? component : parentPath + pathSeparator + component

            var childDepth = emitDepth
            var childTarget = noteTarget
            let summary = CompactRow.summary(node)
            if summary != nil || !isPrunable(node) {
                if state.candidates.count >= maxElements {
                    state.truncated = true
                    state.capped = true
                    return
                }
                state.candidates.append(
                    Candidate(
                        node: node, rowSummary: summary, depth: emitDepth, path: path, label: label, liveKey: live,
                        keyedByTitle: isKeyedByTitle(node, inMenuBar: inMenuBar)))
                if inWeb { state.webEmitted += 1 }
                childDepth = emitDepth + 1
                // Hidden items are counted on the container that cuts them off (the scroll
                // area / page / window), not on each partly visible card.
                if VisibleArea.clipsChildren(node) || noteTarget == nil { childTarget = state.candidates.count - 1 }
            }
            // A compact row lists its cells on its own line.
            if summary != nil { continue }
            // Menus are drawn outside their window: no clipping inside them.
            let isMenu = node.role == AXRoles.menuBar || node.role == AXRoles.menu
            var childClip = isMenu ? nil : clip
            if VisibleArea.clipsChildren(node), let f = node.frame, f.hasArea {
                childClip = childClip.map { $0.intersection(f) ?? NodeFrame(x: f.x, y: f.y, width: 0, height: 0) } ?? f
            }
            visit(
                node.children, rawDepth: rawDepth + 1, emitDepth: childDepth, parentPath: path,
                inWeb: inWeb || node.role == webAreaRole, inMenuBar: inMenuBar || node.role == AXRoles.menuBar,
                clip: childClip, noteTarget: childTarget, state: &state, maxElements: maxElements, maxDepth: maxDepth)
        }
    }
}

/// What is on screen: elements entirely outside the visible
/// part of their window, scroll area or web page are left out of the text, and empty rows,
/// cells and groups are dropped.
public enum VisibleArea {
    /// Containers whose frame bounds what their children can show.
    static let clippingRoles: Set<String> = [AXRoles.window, AXRoles.scrollArea, "AXWebArea", "AXSheet", "AXDrawer", "AXPopover"]

    public static func clipsChildren(_ node: AXNode) -> Bool { clippingRoles.contains(node.role) }

    public static func note(hidden: Int) -> String {
        "(… \(hidden) more item\(hidden == 1 ? "" : "s") outside the visible area; scroll to see \(hidden == 1 ? "it" : "them"))"
    }

    public static func holdsFocus(_ node: AXNode) -> Bool {
        node.isFocused || node.children.contains(where: holdsFocus)
    }

    static let emptyRoles: Set<String> = ["AXRow", "AXCell", "AXGroup", "AXUnknown", "AXColumn"]
    /// Actions every row / cell offers, which say nothing about content.
    static let incidentalActions: Set<String> = [
        "AXShowDefaultUI", "AXShowAlternateUI", "AXScrollToVisible", "AXShowMenu",
    ]

    /// A row / cell / group with nothing to show or do anywhere inside it.
    public static func isEmptySubtree(_ node: AXNode) -> Bool {
        // A text that shows nothing (an icon glyph, whitespace).
        if node.role == AXRoles.staticText, node.children.isEmpty, TreeFormat.staticTextContent(node) == nil,
            !node.isFocused, TreeFormat.meaningfulIdentifier(node.identifier) == nil
        {
            return true
        }
        guard emptyRoles.contains(node.role) else { return false }
        return !hasContent(node)
    }

    public static func hasContent(_ node: AXNode) -> Bool {
        if node.isFocused || node.isSelected || node.isSummaryOnly || node.rowSubset != nil { return true }
        if TreeFormat.label(for: node) != nil { return true }
        if !node.isSecure, let v = node.value, TreeFormat.nonEmpty(v.text) != nil { return true }
        if node.isSecure { return true }
        if !emptyRoles.contains(node.role) { return true }
        if node.actions.contains(where: { !incidentalActions.contains($0) }) { return true }
        return node.children.contains(where: hasContent)
    }
}

/// Table rows printed on one line: a row of plain cells (text,
/// values, images) becomes `#12 row: Siri | 19.26 | 3 | Apple`. Click / double-click the row
/// itself; rows with buttons, check boxes, password fields or the keyboard focus inside
/// are listed in full.
public enum CompactRow {
    static let plainRoles: Set<String> = ["AXCell", "AXStaticText", "AXTextField", "AXImage", "AXGroup", "AXUnknown"]
    static let plainActions: Set<String> = [
        "AXConfirm", "AXOpen", "AXShowDefaultUI", "AXShowAlternateUI", "AXScrollToVisible", "AXShowMenu",
    ]
    static let maxLength = 300

    public static func summary(_ row: AXNode) -> String? {
        guard row.role == AXRoles.row, !row.children.isEmpty else { return nil }
        var parts: [String] = []
        func walk(_ n: AXNode) -> Bool {
            guard plainRoles.contains(n.role), !n.isSecure, !n.isFocused,
                n.actions.allSatisfy({ plainActions.contains($0) })
            else { return false }
            if n.role != "AXImage" {
                let text = n.role == AXRoles.staticText ? TreeFormat.staticTextContent(n)
                    : (TreeFormat.nonEmpty(n.value?.text) ?? TreeFormat.label(for: n).map(\.raw))
                if let text, n.children.isEmpty || n.role != "AXCell" { parts.append(TreeFormat.inlineText(text, limit: 80)) }
            }
            return n.children.allSatisfy(walk)
        }
        guard row.children.allSatisfy(walk), !parts.isEmpty else { return nil }
        let joined = parts.joined(separator: " | ")
        return joined.count > maxLength ? String(joined.prefix(maxLength)) + "…" : joined
    }
}

/// Heuristics over a read tree.
public enum TreeHeuristics {
    /// Title-bar buttons, which every window has whatever its content.
    static let windowChromeSubroles: Set<String> = [
        "AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton", "AXToolbarButton",
    ]

    /// Whether the app's windows look empty to accessibility: fewer than `minimum`
    /// elements inside its windows show anything (a label or a non-empty value),
    /// ignoring the windows themselves and their title-bar buttons. Electron / Chromium
    /// apps that have not turned on their accessibility tree expose only unlabeled
    /// groups (Unity Hub showed nothing but `group {editable}`). No windows at all =
    /// not "empty" (there is nothing to judge).
    public static func looksEmpty(roots: [AXNode], minimum: Int = 3) -> Bool {
        let windows = roots.filter { $0.role == AXRoles.window }
        guard !windows.isEmpty else { return false }
        var shown = 0
        func walk(_ n: AXNode) {
            if shown >= minimum { return }
            if !(n.subrole.map(windowChromeSubroles.contains) ?? false) {
                let hasValue = !n.isSecure && !(n.value?.text.isEmpty ?? true)
                if TreeFormat.label(for: n) != nil || hasValue { shown += 1 }
            }
            for c in n.children { walk(c) }
        }
        for w in windows { for c in w.children { walk(c) } }
        return shown < minimum
    }

    /// Number of nodes in `roots` (all subtrees).
    public static func count(_ roots: [AXNode]) -> Int {
        roots.reduce(0) { $0 + $1.subtreeCount }
    }
}

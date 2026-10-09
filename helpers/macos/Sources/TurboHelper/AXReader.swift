import ApplicationServices
import TurboCore
import Foundation

/// A point-in-time read of an app's accessibility tree.
struct AXSnapshot {
    /// Windows (focused first), then app-level open menus, then the menu bar.
    var roots: [AXNode]
    /// handle → live element. `AXNode.handle` indexes into this array.
    var elements: [AXUIElement]
    /// The window used for the header, screenshot and coordinate mapping.
    var window: AXUIElement?
    var windowTitle: String
    var windowFrame: CGRect?
    var focusedHandle: Int?
    var selectedText: String?
    /// The raw-node cap, time budget or repeated timeouts stopped the read early.
    var cutShort: Bool
    /// Page-load signals of the observed window and the focused window (web areas not
    /// nested in other web areas, Safari page-group identifiers).
    var pageLoad = PageLoadSignals()
    /// The app's focused window at read time.
    var focusedWindow: AXUIElement?

    /// `elements` as identity keys for the serializer (`AXUIElement` hashes / compares
    /// with CFHash / CFEqual: two reads of one UI element are equal).
    var liveKeys: [LiveKey?] { elements.map { LiveKey($0) } }
}

extension LiveKey {
    /// The live element behind a key made by the helper.
    var axElement: AXUIElement? {
        let raw = base.base as AnyObject
        guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }
}

/// What an observation reads.
struct ObservationScope {
    /// Only the key (focused) window and the windows attached to it (sheets, popovers,
    /// drawers, floating panels / dialogs over it) are read in full; the app's other
    /// windows become one summary line each.
    var keyWindowOnly: Bool
    /// List the menu bar's top-level items (always when a menu is open).
    var includeMenuBar: Bool
    /// List the contents of surfaces that are not windows (Finder's desktop: every file on
    /// it). Off by default: one summary line; `full_tree` lists them.
    var listSurfaces = false

    /// Everything (the re-read behind a stale index): every window, the menu bar.
    static let everything = ObservationScope(keyWindowOnly: false, includeMenuBar: true)
}

/// Walks live `AXUIElement`s into the pure `AXNode` model.
final class AXReader {
    /// Raw elements visited per read (pruned containers count here but not toward the
    /// 1500 emitted-element cap).
    var maxRawNodes = 6000
    /// Wall-clock budget for one read.
    var timeBudget: TimeInterval = 10
    var maxDepth = TurboProtocol.maxTreeDepth

    private static let nodeAttributes: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
        kAXValueAttribute, kAXEnabledAttribute, kAXFocusedAttribute, kAXSelectedAttribute,
        kAXExpandedAttribute, kAXIdentifierAttribute, kAXPlaceholderValueAttribute,
        kAXLabelValueAttribute, kAXChildrenAttribute, "AXURL", kAXPositionAttribute, kAXSizeAttribute,
    ]
    /// Roots that are windows or attached to one (anything else among the app's windows is a
    /// surface such as a desktop).
    static let windowLikeRoles: Set<String> = [AXRoles.window, "AXSheet", "AXDrawer", "AXPopover", "AXDialog", "AXSystemDialog"]
    /// Roles whose rows are cut to the visible ones when there are many.
    static let rowContainerRoles: Set<String> = ["AXTable", "AXOutline", "AXList", "AXGrid", "AXCollection"]
    /// Windows read in full together with the key window.
    static let attachedWindowRoles: Set<String> = ["AXSheet", "AXDrawer", "AXPopover"]
    static let attachedWindowSubroles: Set<String> = [
        "AXFloatingWindow", "AXSystemFloatingWindow", "AXDialog", "AXSystemDialog", "AXUnknown",
    ]
    static let webAreaRole = "AXWebArea"
    static let loadAttributes = ["AXLoaded", "AXLoadingProgress", "AXURL"]

    /// A web area whose children are read after everything else (see `snapshot`).
    private struct DeferredWebArea {
        let kids: [AXUIElement]
        let depth: Int
        /// Index path of the web area node from the roots.
        let path: [Int]
        let root: Int
    }

    /// Decides whether UI owned by another process (pid ≠ the app's) must be hidden;
    /// returns the one-line placeholder to show instead, or nil to read it normally.
    typealias ForeignOwnerFilter = (_ ownerPid: pid_t) -> String?

    private final class WalkContext {
        var elements: [AXUIElement] = []
        var visited = 0
        var timeouts = 0
        var cutShort = false
        let maxNodes: Int
        let deadline: Date
        let maxDepth: Int
        let focused: AXUIElement?
        var focusedHandle: Int?
        let hostPid: pid_t
        let hideForeign: ForeignOwnerFilter?
        /// Every element read so far: one UI element reachable twice is read once.
        var visitedSet = Set<AXUIElement>()
        var deferred: [DeferredWebArea] = []
        /// Root index → page-load signals of that root (window).
        var pageSignals: [Int: PageLoadSignals] = [:]

        init(
            maxNodes: Int, deadline: Date, maxDepth: Int, focused: AXUIElement?, hostPid: pid_t,
            hideForeign: ForeignOwnerFilter?
        ) {
            self.maxNodes = maxNodes
            self.deadline = deadline
            self.maxDepth = maxDepth
            self.focused = focused
            self.hostPid = hostPid
            self.hideForeign = hideForeign
        }

        /// Placeholder text if `el` belongs to a process whose UI must not be read.
        func hiddenOwnerNote(_ el: AXUIElement) -> String? {
            guard let hideForeign, let owner = AX.pid(el), owner != hostPid else { return nil }
            return hideForeign(owner)
        }

        var exhausted: Bool {
            if cutShort { return true }
            if visited >= maxNodes || timeouts > 8 || Date() > deadline {
                cutShort = true
                return true
            }
            return false
        }
    }

    /// Read the whole app: windows (focused first) → open app-level menus → menu bar.
    /// `hideForeign` screens elements owned by other processes (see HelperService).
    /// The system's own "this window is being shared" badge (shown in the title bar while
    /// the window is streamed, see WindowFeeds) appears as a small window of the app holding
    /// one button with this title (drawn by an AppKit system service). It is not the app's
    /// UI: never listed, never a target.
    static let sharingBadgeTitle = "WindowSharingSessionButton"
    /// The app's status items (the right side of the menu bar).
    static let extrasMenuBarAttribute = "AXExtrasMenuBar"

    static func isSharingBadge(_ window: AXUIElement) -> Bool {
        (AX.elements(window, kAXChildrenAttribute) ?? []).contains {
            AX.string($0, kAXTitleAttribute) == sharingBadgeTitle
        }
    }

    func snapshot(pid: pid_t, hideForeign: ForeignOwnerFilter? = nil, scope: ObservationScope = .everything) -> AXSnapshot {
        let app = AX.application(pid)
        let focusedElement = AX.element(app, kAXFocusedUIElementAttribute)
        let ctx = WalkContext(
            maxNodes: maxRawNodes, deadline: Date().addingTimeInterval(timeBudget), maxDepth: maxDepth,
            focused: focusedElement, hostPid: pid, hideForeign: hideForeign)

        // Window order: focused first, then the rest of AXWindows.
        var windows: [AXUIElement] = []
        let focusedWindow = AX.element(app, kAXFocusedWindowAttribute)
        if let fw = focusedWindow { windows.append(fw) }
        for w in AX.elements(app, kAXWindowsAttribute) ?? [] where !windows.contains(where: { CFEqual($0, w) }) {
            windows.append(w)
        }
        windows.removeAll(where: Self.isSharingBadge)

        var roots: [AXNode] = []
        var rootWindows: [Int: AXUIElement] = [:]
        // Only a window that is on screen is read in full: a hidden or minimized one shows
        // nothing (one summary line each; the observation says how to bring one back).
        let onScreen = Self.chooseWindow(pid: pid, candidates: [focusedWindow, AX.element(app, kAXMainWindowAttribute)] + windows)
        let key = onScreen?.element
        let keyFrame = key.flatMap { AX.frame($0) }
        // The window holding keyboard focus is always read in full, whatever its subrole
        // (Finder's in-place rename field lives in a small window of its own).
        let focusWindow = focusedElement.flatMap { AX.element($0, kAXWindowAttribute) }
        for w in windows {
            if ctx.exhausted { break }
            let at = roots.count
            // A surface that is not a window (Finder's desktop) lists what is on it — the
            // user's files — only when asked for.
            let surface = !Self.windowLikeRoles.contains(AX.string(w, kAXRoleAttribute) ?? "") && !scope.listSurfaces
            let full =
                !surface && onScreen != nil
                && (!scope.keyWindowOnly || AX.same(w, key) || AX.same(w, focusWindow) || AX.same(w, focusedElement)
                    || Self.isAttached(w, keyFrame: keyFrame))
            if var node = readNode(w, depth: 0, ctx: ctx, descend: full, path: [at], root: full ? at : -1, inWeb: false) {
                // The sharing badge, when its button was not readable yet above.
                if node.children.contains(where: { $0.title == Self.sharingBadgeTitle }) { continue }
                if !full { node.isSummaryOnly = true }
                if surface { node.isSurface = true }
                roots.append(node)
                if full { rootWindows[at] = w }
            }
        }

        // Open context / pop-up menus that live directly under the application element.
        var menuOpen = false
        if !ctx.exhausted, let appChildren = AX.elements(app, kAXChildrenAttribute) {
            for child in appChildren where AX.string(child, kAXRoleAttribute) == AXRoles.menu {
                if ctx.exhausted { break }
                if var menu = readNode(child, depth: 0, ctx: ctx, descend: false, path: [roots.count], root: -1, inWeb: false) {
                    menu.children = readMenuItems(of: child, depth: 1, ctx: ctx)
                    roots.append(menu)
                    menuOpen = true
                }
            }
        }

        // Menu bar: top-level items only, plus the open menu's items. Listed when the
        // scope asks for it or a menu is open; elements read for a menu bar
        // that is then left out are dropped again (their handles stay unused).
        if !ctx.exhausted, let bar = AX.element(app, kAXMenuBarAttribute) {
            let mark = ctx.elements.count
            let visitedBefore = ctx.visitedSet
            if var barNode = readNode(bar, depth: 0, ctx: ctx, descend: false, path: [roots.count], root: -1, inWeb: false) {
                var barMenuOpen = false
                for item in AX.elements(bar, kAXChildrenAttribute) ?? [] {
                    if ctx.exhausted { break }
                    guard var itemNode = readNode(item, depth: 1, ctx: ctx, descend: false, path: [], root: -1, inWeb: false)
                    else { continue }
                    if itemNode.isSelected {
                        for menu in AX.elements(item, kAXChildrenAttribute) ?? []
                        where AX.string(menu, kAXRoleAttribute) == AXRoles.menu {
                            let items = readMenuItems(of: menu, depth: 2, ctx: ctx)
                            if !items.isEmpty { barMenuOpen = true }
                            itemNode.children.append(contentsOf: items)
                        }
                    }
                    barNode.children.append(itemNode)
                }
                if scope.includeMenuBar || menuOpen || barMenuOpen {
                    roots.append(barNode)
                } else {
                    ctx.elements.removeSubrange(mark...)
                    ctx.visitedSet = visitedBefore
                    if let h = ctx.focusedHandle, h >= mark { ctx.focusedHandle = nil }
                }
            }
        }

        // Status items the app shows on the right of the menu bar (the system's Control
        // Center and clock, a sync app's icon): always listed, with any menu one has open.
        // They are the only way into panels that are not windows of a regular app.
        if !ctx.exhausted, let extras = AX.element(app, Self.extrasMenuBarAttribute),
            var extrasNode = readNode(extras, depth: 0, ctx: ctx, descend: false, path: [roots.count], root: -1, inWeb: false)
        {
            for item in AX.elements(extras, kAXChildrenAttribute) ?? [] {
                if ctx.exhausted { break }
                // Read whole: an item may sit inside a hosting group, and an open one holds its menu.
                guard let itemNode = readNode(item, depth: 1, ctx: ctx, descend: true, path: [], root: -1, inWeb: false)
                else { continue }
                extrasNode.children.append(itemNode)
            }
            if !extrasNode.children.isEmpty {
                if (extrasNode.title ?? "").trimmingCharacters(in: .whitespaces).isEmpty { extrasNode.title = "status items" }
                roots.append(extrasNode)
            }
        }

        // Web content last: a big page must not use up the raw-node budget before the
        // toolbar, the rest of the window, other windows and the menu bar are read. Each
        // deferred web area's children are read in document order and patched into place
        // (nested web areas are deferred again, behind the outer content).
        var next = 0
        while next < ctx.deferred.count, !ctx.exhausted {
            let d = ctx.deferred[next]
            next += 1
            var kids: [AXNode] = []
            for kid in d.kids {
                if ctx.exhausted { break }
                if let child = readNode(
                    kid, depth: d.depth + 1, ctx: ctx, descend: true, path: d.path + [kids.count], root: d.root,
                    inWeb: true)
                {
                    kids.append(child)
                }
            }
            Self.setChildren(&roots, path: d.path[...], children: kids)
        }

        let chosen = Self.chooseWindow(pid: pid, candidates: [focusedWindow, AX.element(app, kAXMainWindowAttribute)] + windows)

        var pageLoad = PageLoadSignals()
        for (i, w) in rootWindows where AX.same(w, chosen?.element) || AX.same(w, focusedWindow) {
            if let signals = ctx.pageSignals[i] { pageLoad.merge(signals) }
        }

        var selected: String?
        if let f = focusedElement, !AX.isSecure(f), ctx.hiddenOwnerNote(f) == nil {
            selected = AX.string(f, kAXSelectedTextAttribute)
        }

        return AXSnapshot(
            roots: roots, elements: ctx.elements, window: chosen?.element,
            windowTitle: chosen.flatMap { AX.string($0.element, kAXTitleAttribute) } ?? "",
            windowFrame: chosen?.frame,
            focusedHandle: ctx.focusedHandle, selectedText: selected, cutShort: ctx.cutShort, pageLoad: pageLoad,
            focusedWindow: focusedWindow)
    }

    /// Replace the children of the node at `path` (root index first).
    private static func setChildren(_ nodes: inout [AXNode], path: ArraySlice<Int>, children: [AXNode]) {
        guard let first = path.first, first >= 0, first < nodes.count else { return }
        if path.count == 1 {
            nodes[first].children = children
        } else {
            setChildren(&nodes[first].children, path: path.dropFirst(), children: children)
        }
    }

    /// The window used for the header, screenshot and coordinate mapping:
    /// the first of focused, main, then the other AX windows that is not minimized, has
    /// a frame **and is actually on screen** (matches one of the app's on-screen windows
    /// in the window server list; available without Screen Recording). An app that is
    /// hidden, or whose windows are all on other Spaces, gets none: `window` and
    /// `screenshot` are then null and the text says so.
    static func chooseWindow(pid: pid_t, candidates: [AXUIElement?]) -> (element: AXUIElement, frame: CGRect)? {
        var seen: [AXUIElement] = []
        var usable: [(element: AXUIElement, frame: CGRect)] = []
        for candidate in candidates {
            guard let c = candidate, !seen.contains(where: { CFEqual($0, c) }) else { continue }
            seen.append(c)
            if AX.bool(c, kAXMinimizedAttribute) == true { continue }
            guard let frame = AX.frame(c), frame.width > 0, frame.height > 0 else { continue }
            usable.append((c, frame))
        }
        guard !usable.isEmpty else { return nil }
        let onScreen = WindowList.onScreenWindows().filter { $0.pid == pid && $0.bounds.width > 1 && $0.bounds.height > 1 }
        if let i = WindowMatcher.firstOnScreen(usable.map(\.frame), onScreen: onScreen.map(\.bounds)) {
            return usable[i]
        }
        // No exact match. Some toolkits report AX frames that are slightly off; as long as
        // the app has a normal on-screen window, use the AX window closest to one.
        let normal = onScreen.filter { $0.layer == 0 }.map(\.bounds)
        if let i = WindowMatcher.nearest(usable.map(\.frame), onScreen: normal) { return usable[i] }
        return nil
    }

    /// A window read in full with the key window: a sheet / drawer / popover, or a dialog /
    /// floating panel that overlaps the key window.
    static func isAttached(_ w: AXUIElement, keyFrame: CGRect?) -> Bool {
        let (_, v) = AX.multiple(w, [kAXRoleAttribute, kAXSubroleAttribute])
        let role = AX.stringValue(v[kAXRoleAttribute]) ?? ""
        if attachedWindowRoles.contains(role) { return true }
        guard let sub = AX.stringValue(v[kAXSubroleAttribute]), attachedWindowSubroles.contains(sub) else { return false }
        guard let keyFrame, let f = AX.frame(w) else { return false }
        return f.intersects(keyFrame)
    }

    /// Children of a large table / outline / list cut to the visible rows: nil when
    /// the element is small, or does not say which rows are visible.
    private func visibleRowSubset(_ el: AXUIElement, role: String) -> (kids: [AXUIElement], subset: RowSubset)? {
        var total: CFIndex = 0
        let rowsAttr = role == "AXTable" || role == "AXOutline" ? kAXRowsAttribute : kAXChildrenAttribute
        guard AXUIElementGetAttributeValueCount(el, rowsAttr as CFString, &total) == .success,
            total > RowSubset.threshold
        else { return nil }
        let visibleAttr = rowsAttr == kAXRowsAttribute ? kAXVisibleRowsAttribute : kAXVisibleChildrenAttribute
        guard let visible = AX.elements(el, visibleAttr), visible.count < total else { return nil }
        var kids: [AXUIElement] = []
        if let header = AX.element(el, kAXHeaderAttribute) { kids.append(header) }
        kids.append(contentsOf: visible)
        var first: Int?
        if let v = visible.first, let n = AX.value(v, kAXIndexAttribute) as? NSNumber { first = n.intValue + 1 }
        return (kids, RowSubset(shown: visible.count, total: total, firstRow: first))
    }

    private func readMenuItems(of menu: AXUIElement, depth: Int, ctx: WalkContext) -> [AXNode] {
        var out: [AXNode] = []
        for item in AX.elements(menu, kAXChildrenAttribute) ?? [] {
            if ctx.exhausted { break }
            if var n = readNode(item, depth: depth, ctx: ctx, descend: false, path: [], root: -1, inWeb: false) {
                // An open submenu (its item is highlighted and the submenu is on screen):
                // list its items too, so what the screenshot shows can be clicked by index.
                if n.isSelected, depth < 8 {
                    for sub in AX.elements(item, kAXChildrenAttribute) ?? []
                    where AX.string(sub, kAXRoleAttribute) == AXRoles.menu && AX.frame(sub).map({ $0.width > 0 && $0.height > 0 }) == true {
                        n.children.append(contentsOf: readMenuItems(of: sub, depth: depth + 1, ctx: ctx))
                    }
                }
                out.append(n)
            }
        }
        return out
    }

    /// `path` is the index path this node will have in the roots (only meaningful while
    /// `descend` is true); `root` the index of its window root (-1 outside windows);
    /// `inWeb` whether it lies inside a web area.
    private func readNode(
        _ el: AXUIElement, depth: Int, ctx: WalkContext, descend: Bool, path: [Int], root: Int, inWeb: Bool
    ) -> AXNode? {
        if ctx.exhausted { return nil }
        // The same UI element reachable twice (a sheet is the focused window and a child
        // of its document window): read it once.
        if ctx.visitedSet.contains(el) { return nil }
        ctx.visitedSet.insert(el)
        ctx.visited += 1
        if let note = ctx.hiddenOwnerNote(el) {
            // UI of a restricted app hosted inside this one: show that it is there, never
            // read its contents. Its index still maps to the element so that acting on it
            // is refused with a clear appProtected.
            var node = AXNode(role: "AXGroup", subrole: nil)
            node.description = note
            node.handle = ctx.elements.count
            ctx.elements.append(el)
            return node
        }
        let (err, attrs) = AX.multiple(el, Self.nodeAttributes)
        switch err {
        case .success: break
        case .cannotComplete:
            ctx.timeouts += 1
            return nil
        default:
            return nil
        }
        let role = AX.stringValue(attrs[kAXRoleAttribute]) ?? "AXUnknown"
        let subrole = AX.stringValue(attrs[kAXSubroleAttribute])
        var node = AXNode(role: role, subrole: subrole)
        node.title = AX.stringValue(attrs[kAXTitleAttribute])
        node.description = AX.stringValue(attrs[kAXDescriptionAttribute])
        node.labelValue = AX.stringValue(attrs[kAXLabelValueAttribute])
        node.placeholder = AX.stringValue(attrs[kAXPlaceholderValueAttribute])
        node.identifier = AX.stringValue(attrs[kAXIdentifierAttribute])
        if role == AXRoles.window {
            // The file a document window shows: part of the window's path key.
            node.document = AX.string(el, kAXDocumentAttribute)
        }
        // Never read a secure field's value into memory we might print.
        if !node.isSecure { node.value = AX.nodeValue(attrs[kAXValueAttribute]) }
        if attrs[kAXValueAttribute] != nil || node.isSecure {
            node.isValueSettable = AX.isSettable(el, kAXValueAttribute)
        }
        node.isEnabled = AX.boolValue(attrs[kAXEnabledAttribute])
        node.isSelected = AX.boolValue(attrs[kAXSelectedAttribute]) ?? false
        node.isExpanded = AX.boolValue(attrs[kAXExpandedAttribute]) ?? false
        // The element that has the keyboard is known (`ctx.focused`): many apps report
        // AXFocused on every cell of a focused list, which said nothing.
        var focused = ctx.focused == nil ? (AX.boolValue(attrs[kAXFocusedAttribute]) ?? false) : false
        node.frame = Self.frame(attrs)
        let handle = ctx.elements.count
        ctx.elements.append(el)
        node.handle = handle
        if let f = ctx.focused, CFEqual(f, el) {
            focused = true
            ctx.focusedHandle = handle
        }
        node.isFocused = focused
        node.actions = AX.actions(el)

        let isWebArea = role == Self.webAreaRole
        if root >= 0 && !inWeb {
            // Page-load signals of this window (top-level web areas only: an iframe that
            // is still loading an ad does not make the page "loading").
            if isWebArea {
                ctx.pageSignals[root, default: PageLoadSignals()].webAreas.append(Self.loadState(of: el))
            } else if PageLoadSignals.isPageGroupIdentifier(node.identifier), let id = node.identifier {
                ctx.pageSignals[root, default: PageLoadSignals()].pageGroupIdentifiers.append(id)
            }
        }

        // AXColumn children duplicate the row cells; skip them.
        if role == AXRoles.link { node.url = AX.urlString(attrs["AXURL"]) }
        if descend && depth + 1 < ctx.maxDepth && role != AXRoles.column {
            var kids: [AXUIElement]?
            if Self.rowContainerRoles.contains(role), let subset = visibleRowSubset(el, role: role) {
                kids = subset.kids
                node.rowSubset = subset.subset
            } else {
                kids = attrs[kAXChildrenAttribute].flatMap { AX.elementArray($0) }
                if kids == nil { kids = AX.elements(el, "AXVisibleChildren") }
            }
            if isWebArea {
                // Read after everything else (see `snapshot`).
                if let kids, !kids.isEmpty {
                    ctx.deferred.append(DeferredWebArea(kids: kids, depth: depth, path: path, root: root))
                }
                return node
            }
            for kid in kids ?? [] {
                if ctx.exhausted { break }
                if let child = readNode(
                    kid, depth: depth + 1, ctx: ctx, descend: true, path: path + [node.children.count], root: root,
                    inWeb: inWeb)
                {
                    node.children.append(child)
                }
            }
        }
        return node
    }

    static func frame(_ attrs: [String: CFTypeRef]) -> NodeFrame? {
        guard let p = attrs[kAXPositionAttribute], let s = attrs[kAXSizeAttribute],
            CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return NodeFrame(x: Double(point.x), y: Double(point.y), width: Double(size.width), height: Double(size.height))
    }

    /// `AXLoaded` / `AXLoadingProgress` / `AXURL` of a web area, in one round trip.
    static func loadState(of webArea: AXUIElement) -> WebAreaLoad {
        let (_, v) = AX.multiple(webArea, loadAttributes)
        var progress: Double?
        if let p = v["AXLoadingProgress"], CFGetTypeID(p) == CFNumberGetTypeID() { progress = (p as! NSNumber).doubleValue }
        return WebAreaLoad(loaded: AX.boolValue(v["AXLoaded"]), progress: progress, url: AX.urlString(v["AXURL"]))
    }
}

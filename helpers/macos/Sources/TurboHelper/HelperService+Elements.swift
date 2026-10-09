import AppKit
import ImageIO
import ApplicationServices
import TurboCore
import Foundation

// Finding the live element behind a number, and its frame on screen.
extension HelperService {
    /// Live element for `index`; re-reads the app once and re-matches if the retained
    /// element went stale (its replacement with the same
    /// path key inherits the index). Only the element map is refreshed (merged, so
    /// the other indices stay usable): the observed window (origin of screenshot
    /// coordinates) changes only on observe_app. Elements owned by a process that may not be controlled under
    /// this app's approval are refused.
    func element(_ index: Int, app: AppSessionState, pid: pid_t, policy: PolicyEvaluation) throws -> AXUIElement {
        var found: AXUIElement?
        if let el = app.elements[index], AX.isValid(el) {
            found = el
        } else {
            guard app.indexer.identity(for: index) != nil else { throw TurboError.elementInvalid(index) }
            // An index last seen before the app relaunched: its element is gone, and a
            // re-read here could only match it by path, which window order (focus order
            // after the relaunch) can point at another document. Only a new observation
            // may hand it on.
            if app.indexer.isDetached(index) {
                throw TurboError(
                    .staleElement,
                    "Element #\(index) is from before the app relaunched; call observe_app and use a current index.")
            }
            let snapshot = reader.snapshot(pid: pid, hideForeign: foreignOwnerFilter(hostRisk: policy.risk), scope: .everything)
            let tree = serialize(snapshot, app: app)
            applyElementMap(tree, snapshot, to: app, merge: true)
            if let el = app.elements[index], AX.isValid(el) { found = el }
        }
        guard let el = found else { throw TurboError.elementInvalid(index) }
        try refuseForeignOwner(el, index: index, hostPid: pid, hostRisk: policy.risk)
        return el
    }

    /// Approval and the deny lists were checked for the host app; UI another process
    /// hosts inside it (remote views, extensions) gets its own policy check.
    func refuseForeignOwner(_ el: AXUIElement, index: Int, hostPid: pid_t, hostRisk: PolicyRisk) throws {
        guard let ownerPid = AX.pid(el), ownerPid != hostPid else { return }
        let owner = owners.owner(of: ownerPid)
        guard
            let verdict = currentPolicy().evaluateForeignOwner(ownerBundleIds: owner.bundleIds, hostRisk: hostRisk)
        else { return }
        let id = owner.bundleIds.first ?? "pid \(ownerPid)"
        let why =
            verdict.decision == .protected
            ? (verdict.reason ?? "it is on the safety deny list")
            : "it manages passwords or other credentials and was not approved itself"
        throw TurboError(
            .appProtected,
            "#\(index) belongs to \(owner.name) (\(id)), which cannot be controlled through this app: \(TurboError.sentence(why)) Do not retry.")
    }

    /// Current frame of the observed window (falls back to the frame at observation time).
    func windowFrame(_ app: AppSessionState, name: String) throws -> CGRect {
        if let w = app.window, let f = AX.frame(w) {
            app.windowFrame = f
            return f
        }
        if let f = app.windowFrame { return f }
        throw TurboError(.noWindow, "\(name) has no window to target; call observe_app again.")
    }

    /// Screenshot pixel coordinates → global points (`window.origin + (x, y) / scale`),
    /// in the pixel space of the latest observation.
    func globalPoint(x: Double, y: Double, frame: CGRect, app: AppSessionState) throws -> CGPoint {
        let g = app.screenshotGeometry ?? ScreenshotScale.fit(width: Double(frame.width), height: Double(frame.height))
        guard ScreenshotScale.contains(x: x, y: y, in: g) else {
            throw TurboError.invalid(
                "(\(x), \(y)) is outside the window screenshot (\(g.pixelWidth)x\(g.pixelHeight) px); x/y are pixels of the latest observe_app screenshot.")
        }
        return ScreenshotScale.toScreen(x: x, y: y, origin: frame.origin, scale: g.scale)
    }

    /// Point to click for an element: the centre of its visible part. An element scrolled
    /// out of view is scrolled into view first when it supports AXScrollToVisible; if it
    /// stays out of view the click is refused — its unclipped centre lies over some other
    /// control.
    func center(of el: AXUIElement, index: Int, app: AppSessionState) throws -> CGPoint {
        if AX.actions(el).contains("AXScrollToVisible"), AX.perform(el, "AXScrollToVisible") == .success {
            usleep(50_000)
        }
        if let p = visibleCenter(of: el, app: app) { return p }
        // A scroll may still be animating.
        let until = Date().addingTimeInterval(0.3)
        while Date() < until {
            usleep(50_000)
            if let p = visibleCenter(of: el, app: app) { return p }
        }
        throw TurboError(
            .actionError,
            "Element #\(index) is scrolled out of view (or has no on-screen frame); scroll its container, or call observe_app again, before clicking it."
        )
    }

    /// Centre of the element's visible part: its frame clipped to the nearest enclosing
    /// scroll area and to its window (a text view's frame spans its whole document, so its
    /// raw centre can be far outside the window). nil when nothing of it is visible.
    func visibleCenter(of el: AXUIElement, app: AppSessionState) -> CGPoint? {
        guard let frame = AX.frame(el) else { return nil }
        let area = Self.enclosingScrollArea(of: el).flatMap { AX.frame($0) }
        return VisibleRegion.clip(frame, scrollArea: area, window: clipWindowFrame(for: el, app: app))
            .map(VisibleRegion.center(of:))
    }

    /// A menu of the app is open (a context / pop-up menu, or one from its menu bar).
    static func menuIsOpen(pid: pid_t) -> Bool {
        let app = AX.application(pid)
        if let focused = AX.element(app, kAXFocusedUIElementAttribute),
            let role = AX.string(focused, kAXRoleAttribute), role == AXRoles.menuItem || role == AXRoles.menu
        {
            return true
        }
        if (AX.elements(app, kAXChildrenAttribute) ?? []).contains(where: { AX.string($0, kAXRoleAttribute) == AXRoles.menu }) {
            return true
        }
        // A menu bar menu that is open marks its menu bar item selected (the only sign some
        // toolkits give — Mac Catalyst apps keep the focus in the window meanwhile).
        guard let bar = AX.element(app, kAXMenuBarAttribute) else { return false }
        return (AX.elements(bar, kAXChildrenAttribute) ?? []).contains { AX.bool($0, kAXSelectedAttribute) == true }
    }

    /// Close a menu left open in the app (cancel through accessibility, else Escape).
    func closeOpenMenu(pid: pid_t) {
        let app = AX.application(pid)
        var menus = (AX.elements(app, kAXChildrenAttribute) ?? []).filter { AX.string($0, kAXRoleAttribute) == AXRoles.menu }
        if let bar = AX.element(app, kAXMenuBarAttribute) {
            for item in AX.elements(bar, kAXChildrenAttribute) ?? [] where AX.bool(item, kAXSelectedAttribute) == true {
                menus += (AX.elements(item, kAXChildrenAttribute) ?? []).filter { AX.string($0, kAXRoleAttribute) == AXRoles.menu }
            }
        }
        for m in menus { AX.perform(m, kAXCancelAction) }
        usleep(60_000)
        if Self.menuIsOpen(pid: pid) {
            try? input.press(KeyChord(keyCode: USKeyboard.escapeKeyCode, modifiers: [], keyName: "escape"), pid: pid)
            usleep(80_000)
        }
        Log.info("closed an open menu of pid \(pid)\(Self.menuIsOpen(pid: pid) ? " (still open)" : "")")
    }

    /// A text field edited in place inside a list / table / outline / browser, or in a
    /// helper window of its own (Finder's rename field): it commits its value only on a
    /// real Return key press (or losing focus), not through AXConfirm or AXValue.
    static func isInPlaceEditor(_ el: AXUIElement) -> Bool {
        guard let role = AX.string(el, kAXRoleAttribute), role == "AXTextField" || role == "AXTextArea" else { return false }
        let containers: Set<String> = ["AXRow", "AXCell", "AXOutline", "AXTable", "AXList", "AXBrowser"]
        var current = AX.element(el, kAXParentAttribute)
        for _ in 0..<6 {
            guard let p = current, let r = AX.string(p, kAXRoleAttribute) else { break }
            if containers.contains(r) { return true }
            if r == AXRoles.window { break }
            current = AX.element(p, kAXParentAttribute)
        }
        guard let w = AX.element(el, kAXWindowAttribute), !AX.same(w, el) else {
            // A field that is a top-level element of its own (Finder's rename field is listed
            // among the app's windows): an in-place editor.
            return AX.string(AX.element(el, kAXParentAttribute) ?? el, kAXRoleAttribute) == "AXApplication"
                || AX.element(el, kAXParentAttribute) == nil
        }
        if let sub = AX.string(w, kAXSubroleAttribute) {
            return !["AXStandardWindow", "AXDialog", "AXSystemDialog", "AXFloatingWindow", "AXSystemFloatingWindow"].contains(sub)
        }
        return false
    }

    static let menuRoles: Set<String> = [AXRoles.menuBar, AXRoles.menuBarItem, AXRoles.menu, AXRoles.menuItem]

    /// The window an element is clipped against: its own AXWindow, else the observed
    /// window. Menu bar and menu elements live outside any window and are not clipped.
    func clipWindowFrame(for el: AXUIElement, app: AppSessionState) -> CGRect? {
        if let role = AX.string(el, kAXRoleAttribute), Self.menuRoles.contains(role) { return nil }
        if let w = AX.element(el, kAXWindowAttribute), let f = AX.frame(w) { return f }
        return app.window.flatMap { AX.frame($0) } ?? app.windowFrame
    }

    static func enclosingScrollArea(of el: AXUIElement) -> AXUIElement? {
        var current = AX.element(el, kAXParentAttribute)
        for _ in 0..<15 {
            guard let ancestor = current else { return nil }
            if AX.string(ancestor, kAXRoleAttribute) == AXRoles.scrollArea { return ancestor }
            current = AX.element(ancestor, kAXParentAttribute)
        }
        return nil
    }

    /// Frontmost on-screen, non-transparent window of `pid` (any layer) containing `point`.
    static func window(pid: pid_t, containing point: CGPoint) -> WindowList.Info? {
        WindowList.window(pid: pid, containing: point, in: WindowList.onScreenWindows())
    }

    func isFrontmost(_ pid: pid_t) -> Bool {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return true }
        // Second signal: the system-wide focused application (AX).
        if let focused = AX.element(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute),
            AX.pid(focused) == pid
        {
            return true
        }
        return false
    }

    /// Make the target app frontmost and raise the observed window; returns whether the
    /// app is frontmost afterwards. Used only for `focus.forceFrontApps` and the opt-in
    /// `focus.activateTarget` setting — other apps are never activated or raised. AXFrontmost works
    /// for a background accessory app; `NSRunningApplication.activate` is a best-effort
    /// fallback (macOS 14+ cooperative activation usually refuses it).
    @discardableResult
    func bringToFront(pid: pid_t, window: AXUIElement?) -> Bool {
        var front = isFrontmost(pid)
        if !front {
            let err = AX.set(AX.application(pid), kAXFrontmostAttribute, kCFBooleanTrue)
            if err != .success { Log.info("AXFrontmost on pid \(pid) failed (AXError \(err.rawValue))") }
            NSRunningApplication(processIdentifier: pid)?.activate(options: [])
            let until = Date().addingTimeInterval(1.5)
            while Date() < until {
                if isFrontmost(pid) {
                    front = true
                    break
                }
                usleep(50_000)
            }
            if front { usleep(100_000) }
        }
        // Raising the window would close an open menu: leave it while one is open.
        if let window, AX.bool(window, kAXMainAttribute) != true, !Self.menuIsOpen(pid: pid) {
            AX.perform(window, kAXRaiseAction)
            usleep(50_000)
        }
        return front
    }
}

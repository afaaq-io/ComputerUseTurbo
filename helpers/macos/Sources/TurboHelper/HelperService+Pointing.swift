import AppKit
import Carbon
import ImageIO
import ApplicationServices
import TurboCore
import Foundation

// Clicks, scrolls and drags.
extension HelperService {
    func click(target: ActionTarget, button: MouseButton, count: Int, _ c: ActionContext) throws -> String? {
        let app = c.app
        let pid = c.pid
        let point: CGPoint
        switch target {
        case .element(let index):
            let el = try element(index, app: app, pid: pid, policy: c.policy)
            let label = pillName(el, app: c.name)
            // One aim point for the pointer and (unless the element has to be scrolled into
            // view first) the mouse fallback: the centre of the element's visible part.
            let aim = aimPoint(of: el, app: app)
            // Menu items are clicked through accessibility only (`click`): mouse events
            // to an open menu would close it or hit the wrong item.
            if let role = AX.string(el, kAXRoleAttribute), role == AXRoles.menuItem || role == AXRoles.menuBarItem {
                return try clickMenuItem(el, index: index, label: label, button: button, count: count, c)
            }
            if let panel = Self.dialogSurfaceFrame(pid: pid), let p = aim ?? (try? center(of: el, index: index, app: app)),
                panel.contains(p), !(button == .left && count == 1 && AX.actions(el).contains(kAXPressAction))
            {
                // Double clicks, other buttons, elements without a press action in the system
                // panel: only real clicks reach it.
                return try clickInDialog(at: p, label: label, button: button, count: count, c)
            }
            // AXPress needs no mouse; every mouse click is preceded by mouse-moved events.
            let willPress = button == .left && count == 1 && AX.actions(el).contains(kAXPressAction)
            try travel(
                c, to: aim, moving: PointerLabel.moving(to: label), arrived: PointerLabel.clicking(label), hover: !willPress,
                assist: !willPress)
            if willPress {
                let err = AX.perform(el, kAXPressAction)
                let at = aim.map { " (pointer at screen point (\(GeometryGuard.displayInt($0.x)), \(GeometryGuard.displayInt($0.y))))" } ?? ""
                switch AXActionOutcome(rawError: err.rawValue) {
                case .performed:
                    pointer?.press()
                    return "Pressed #\(index) with its accessibility action\(at)."
                case .probablyPerformed:
                    // Delivered; the app did not reply within the 1 s messaging timeout
                    // (slow handler, modal alert, menu tracking). A fallback mouse click
                    // would activate the control a second time.
                    Log.info("AXPress on #\(index) timed out (\(err.rawValue)); treating it as performed")
                    pointer?.press()
                    return
                        "Pressed #\(index) with its accessibility action; the app did not confirm within 1 s (it may be busy or showing a dialog). Call observe_app to check the result before retrying."
                case .elementGone:
                    throw TurboError.elementInvalid(index)
                case .failed:
                    Log.info("AXPress on #\(index) failed (\(err.rawValue)); falling back to a mouse click")
                }
            }
            point = try center(of: el, index: index, app: app)
            if willPress || (aim.map({ hypot($0.x - point.x, $0.y - point.y) > 0.5 }) ?? true) {
                // The AXPress fallback (no mouse moves yet), or scrolled into view / had no
                // frame before: go where the click lands.
                try travel(
                    c, to: point, moving: PointerLabel.moving(to: label), arrived: PointerLabel.clicking(label), hover: true,
                    assist: true)
            }
        case .point(let x, let y):
            point = try globalPoint(x: x, y: y, frame: try windowFrame(app, name: c.name), app: app)
            if let panel = Self.dialogSurfaceFrame(pid: pid), panel.contains(point) {
                return try clickInDialog(at: point, label: c.name, button: button, count: count, c)
            }
            let label = c.name
            try travel(
                c, to: point, moving: PointerLabel.moving(to: label), arrived: PointerLabel.clicking(label), hover: true,
                assist: true)
        }
        // A click on a bare canvas (a spreadsheet grid, a drawing surface: no control under the
        // point, only a scroll area or an unknown area) is ignored by many apps unless it is a
        // real click with the app in front: made with the real mouse.
        if case .point = target, c.extras.assist == nil, Self.isCanvas(at: point, pid: pid) {
            return try clickInDialog(at: point, label: c.name, button: button, count: count, c, canvas: true)
        }
        try input.click(
            at: point, button: button, count: count, pid: pid,
            window: Self.window(pid: pid, containing: point))
        app.lastMousePoint = point
        pointer?.press()
        let what = count == 1 ? "click" : "\(count)-click"
        return
            "Posted a \(button.rawValue) \(what) at screen point (\(GeometryGuard.displayInt(point.x)), \(GeometryGuard.displayInt(point.y)))."
    }


    /// Whether the point is on a bare canvas of the app: the element there is a container
    /// or an unknown surface, not a control (nothing there to press, select or edit).
    /// The enabled shortcuts the system owns (System Settings ▸ Keyboard ▸ Keyboard Shortcuts).
    static func registeredSystemShortcuts() -> [SystemShortcuts.Registered] {
        var out: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&out) == noErr, let list = out?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return list.compactMap { hotKey in
            guard hotKey[kHISymbolicHotKeyEnabled as String] as? Bool == true,
                let code = (hotKey[kHISymbolicHotKeyCode as String] as? NSNumber)?.intValue,
                let mods = (hotKey[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.intValue
            else { return nil }
            return SystemShortcuts.Registered(keyCode: code, carbonModifiers: mods)
        }
    }

    /// A click or drag by position aims at what the last observation showed; see
    /// `StaleClickGuard` for when the window has turned into something else since.
    func refuseIfScreenChanged(_ c: ActionContext, at point: (x: Double, y: Double)) throws {
        let app = c.app
        func current() -> [UInt8]? { WindowFeeds.shared.latest(pid: c.pid).flatMap { Screenshotter.thumbnail($0.0) } }
        let acted = app.lastObservedAt.map { app.lastActionEnd >= $0 } ?? true
        guard !acted, let before = app.lastThumbnail, let now = current(), let g = app.screenshotGeometry,
            g.pixelWidth > 0, g.pixelHeight > 0
        else { return }
        let changed = ScreenshotChange.fraction(previous: before, current: now)
        let target = StaleClickGuard.localChange(
            previous: before, current: now, target: (point.x / Double(g.pixelWidth), point.y / Double(g.pixelHeight)))
        guard StaleClickGuard.refuse(changedSinceLook: changed, changedAtTarget: target, stillMoving: 0, actedSinceLook: false) else { return }
        usleep(150_000)
        let moving = current().flatMap { ScreenshotChange.fraction(previous: now, current: $0) }
        guard StaleClickGuard.refuse(changedSinceLook: changed, changedAtTarget: target, stillMoving: moving, actedSinceLook: false) else { return }
        let percent = Int(max(changed ?? 0, target ?? 0) * 100)
        Log.info("click by position refused: \(LogText.peer(c.name)) changed since the last observation (\(percent)% where it counts)")
        throw TurboError(
            .staleElement,
            "\(c.name) looks different from your last observe_app where you aimed (\(percent)% changed, and you have not acted since), so a click by position could land on something else. Nothing was sent. Call observe_app and aim again.")
    }

    /// A background process without a Dock icon (the system's menu bar extras, search
    /// panel, notification list) whose windows hold no keyboard focus.
    static func isSystemSurface(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy != .regular else { return false }
        return AX.element(AX.application(pid), kAXFocusedWindowAttribute) == nil
    }

    static func isCanvas(at point: CGPoint, pid: pid_t) -> Bool {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AX.application(pid), Float(point.x), Float(point.y), &hit) == .success,
            let hit
        else { return false }
        let role = AX.string(hit, kAXRoleAttribute) ?? ""
        guard ["AXScrollArea", "AXUnknown", "AXLayoutArea"].contains(role) else { return false }
        return !AX.actions(hit).contains(kAXPressAction)
    }

    /// A menu (bar) item: AXPress, else AXPick; never a mouse event.
    func clickMenuItem(
        _ el: AXUIElement, index: Int, label: String, button: MouseButton, count: Int, _ c: ActionContext
    ) throws -> String {
        guard button == .left, count == 1 else {
            throw TurboError(.notSupported, "#\(index) is a menu item: only a single left click is possible (it is pressed through accessibility).")
        }
        let available = AX.actions(el)
        if AX.string(el, kAXRoleAttribute) == AXRoles.menuBarItem, !isFrontmost(c.pid) {
            // A menu bar menu opened in a background app never shows and leaves the app in
            // menu tracking that swallows later shortcuts: borrow the front.
            try borrowFront(c, what: "opening the menu \"\(label)\" from the menu bar")
        }
        try travel(c, to: aimPoint(of: el, app: c.app), moving: PointerLabel.moving(to: label), arrived: PointerLabel.clicking(label))
        var lastError: AXError = .actionUnsupported
        for action in [kAXPressAction, kAXPickAction] where available.contains(action) || available.isEmpty {
            let err = AX.perform(el, action)
            switch AXActionOutcome(rawError: err.rawValue) {
            case .performed, .probablyPerformed:
                pointer?.press()
                return "Pressed the menu item #\(index) through accessibility (\(TreeFormat.displayName(forAction: action)))."
            case .elementGone:
                throw TurboError.elementInvalid(index)
            case .failed:
                lastError = err
            }
        }
        throw TurboError(.actionError, "Failed to click the menu item #\(index) through accessibility (AXError \(lastError.rawValue)); menu items are never clicked with the mouse. Observe again; the menu may have closed.")
    }

    func scroll(target: ActionTarget, direction: ScrollDirection, pages: Double, _ c: ActionContext) throws
        -> String?
    {
        let app = c.app
        let pid = c.pid
        let point: CGPoint
        var hit: AXUIElement?
        switch target {
        case .element(let index):
            let el = try element(index, app: app, pid: pid, policy: c.policy)
            hit = el
            if let p = visibleCenter(of: el, app: app) {
                point = p
            } else if let area = Self.enclosingScrollArea(of: el), let p = visibleCenter(of: area, app: app) {
                // The element itself is scrolled out of view: scroll its container.
                point = p
            } else {
                throw TurboError(
                    .actionError,
                    "Element #\(index) is out of view and has no visible scroll area to scroll; call observe_app again.")
            }
        case .point(let x, let y):
            point = try globalPoint(x: x, y: y, frame: try windowFrame(app, name: c.name), app: app)
            var found: AXUIElement?
            if AXUIElementCopyElementAtPosition(AX.application(pid), Float(point.x), Float(point.y), &found) == .success {
                hit = found
            }
        }
        try travel(
            c, to: point, moving: PointerLabel.moving(to: pillName(hit, app: c.name)), arrived: PointerLabel.scrolling,
            hover: true, assist: true)
        let vertical = direction == .up || direction == .down
        if c.extras.assist != nil, isFrontmost(pid) {
            // An app that takes input only under the real pointer (the assist placed it there)
            // ignores wheel events posted to it and moves about a point per wheel line: post
            // through the window server, a page being most of the window.
            let frame = try windowFrame(app, name: c.name)
            let page = Double(vertical ? frame.height : frame.width) * 0.75
            let points = Int((pages * page).rounded()) * ((direction == .up || direction == .left) ? 1 : -1)
            input.scrollThroughSystem(at: point, dy: vertical ? points : 0, dx: vertical ? 0 : points)
            usleep(400_000)
            return "Scrolled \(direction.rawValue) \(String(format: "%g", pages)) page(s)."
        }
        let lines = max(1, Int((pages * 10).rounded()))
        let sign = (direction == .up || direction == .left) ? 1 : -1
        let bar = hit.flatMap { Self.scrollBar(from: $0, vertical: vertical) }
        let before = bar.flatMap { Self.barValue($0.bar) }

        input.scroll(
            at: point, dy: vertical ? sign * lines : 0, dx: vertical ? 0 : sign * lines, pid: pid,
            window: Self.window(pid: pid, containing: point))

        guard let bar, let before, AX.isSettable(bar.bar, kAXValueAttribute) else {
            usleep(150_000)
            return "Scrolled \(direction.rawValue) \(String(format: "%g", pages)) page(s)."
        }
        // Wheel events are handled asynchronously: give them time to show up before
        // concluding they had no effect, or both mechanisms scroll and the view moves
        // twice as far as requested.
        let moved = Polling.waitForChange(
            from: before, timeout: 0.45, interval: 0.05, changed: { abs($1 - $0) >= 0.0001 },
            read: { Self.barValue(bar.bar) })
        if moved == nil {
            let delta = pages * bar.pageFraction
            // up/left = toward 0, down/right = toward 1.
            let target = min(1, max(0, before + (sign > 0 ? -delta : delta)))
            if abs(target - before) > 0.0001 {
                let err = AX.set(bar.bar, kAXValueAttribute, NSNumber(value: target))
                if err == .success {
                    return "Scrolled \(direction.rawValue) by adjusting the scroll bar."
                }
                Log.info("scroll: setting the scroll bar failed (AXError \(err.rawValue))")
                return
                    "Wheel events had no visible effect and adjusting the scroll bar failed (AXError \(err.rawValue)); call observe_app to check."
            }
        }
        return "Scrolled \(direction.rawValue) \(String(format: "%g", pages)) page(s)."
    }

    static func barValue(_ bar: AXUIElement) -> Double? {
        if case .number(let d)? = AX.nodeValue(AX.value(bar, kAXValueAttribute)) { return d }
        return nil
    }

    /// The scroll bar of the nearest enclosing scroll area, plus how much of the bar's
    /// 0…1 range one page represents.
    static func scrollBar(from start: AXUIElement, vertical: Bool) -> (bar: AXUIElement, pageFraction: Double)? {
        var current: AXUIElement? = start
        for _ in 0..<15 {
            guard let el = current else { return nil }
            if AX.string(el, kAXRoleAttribute) == AXRoles.scrollArea {
                let attr = vertical ? kAXVerticalScrollBarAttribute : kAXHorizontalScrollBarAttribute
                guard let bar = AX.element(el, attr) else { return nil }
                var fraction = 0.1
                if let area = AX.frame(el) {
                    let visible = vertical ? area.height : area.width
                    let content = (AX.elements(el, kAXChildrenAttribute) ?? [])
                        .filter { AX.string($0, kAXRoleAttribute) != AXRoles.scrollBar }
                        .compactMap { AX.frame($0) }
                        .map { vertical ? $0.height : $0.width }
                        .max()
                    if let content, content > visible + 1 {
                        fraction = Double(visible * 0.9 / (content - visible))
                    }
                }
                return (bar, fraction)
            }
            current = AX.element(el, kAXParentAttribute)
        }
        return nil
    }
}

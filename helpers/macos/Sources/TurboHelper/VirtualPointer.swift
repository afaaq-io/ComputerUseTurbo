import AppKit
import TurboCore
import Foundation
import QuartzCore

/// A glide the pointer is animating: the quadratic Bézier `from` → `to` (control point
/// `control`), starting `delay` s after `moveTo` (fade-in) and lasting `duration` s.
struct PointerGlide {
    let from: CGPoint
    let control: CGPoint
    let to: CGPoint
    let delay: TimeInterval
    let duration: TimeInterval
}

/// Mirrors the pointer's motion elsewhere (the live preview): the very same glide
/// (start, control and end point, start time on the `CACurrentMediaTime` clock, duration,
/// easing), drag steps, presses. Main thread. Called also while the pointer itself is not
/// drawn (target app not in front), so the preview moves smoothly in the background too.
protocol PointerMotionObserver: AnyObject {
    func pointerGlide(_ glide: PointerGlide, beginTime: CFTimeInterval)
    func pointerJump(to point: CGPoint)
    func pointerFollow(to point: CGPoint, duration: TimeInterval)
    func pointerPress()
    func pointerHidden()
}

/// The agent's own on-screen pointer ("Soft arrow" design): a clay
/// rounded arrow whose tip marks the exact point an action targets, with an action pill
/// ("Clicking Greet") attached below-right.
///
/// One transparent, borderless, non-activating, click-through panel per screen (its frame
/// is the screen's full `frame`), above normal windows and menus, on all Spaces, excluded
/// from screen captures (`sharingType = .none`). Every panel holds the same layers, placed
/// with `PointerGeometry.layerPoint` (explicit global top-left → y-up layer conversion; no
/// flipped geometry), so the pointer renders on whichever display the target is on, and
/// halfway across a display edge too.
///
/// Motion is Core Animation (a keyframe animation along a quadratic Bézier, ease-in-out
/// cubic), rendered by the window server at the display's refresh rate, so a busy main
/// thread cannot make it stutter. Phases (fade in → glide) are chained with transaction
/// completion blocks; the last one reports arrival. The arrow stays upright.
///
/// The pointer is drawn only while its target app is frontmost: it never draws over the
/// user's own work in another app. It hides with the overlay (idle, finishTurn,
/// Stop). Main thread only; the action threads use `PointerDriver`.
final class VirtualPointer: NSObject {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// One screen's panel and layers (y-up layer space, origin at the screen's bottom-left).
    private final class ScreenLayers {
        let panel: Panel
        let cocoaFrame: CGRect
        let primaryHeight: CGFloat
        let scale: CGFloat
        let group = CALayer()
        /// Zero-size layer whose position is the tip; carries the arrow and the pill.
        let cursor = CALayer()
        let arrow = CAShapeLayer()
        let pill = CALayer()
        let pillText = CATextLayer()

        init(screen: NSScreen, primaryHeight: CGFloat) {
            cocoaFrame = screen.frame
            self.primaryHeight = primaryHeight
            scale = screen.backingScaleFactor
            panel = Panel(
                contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                defer: false)
            panel.isFloatingPanel = true
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isMovable = false
            panel.isReleasedWhenClosed = false
            panel.animationBehavior = .none
            panel.sharingType = .none
            panel.title = "Computer Use pointer"
            // The whole screen (`frame`, not `visibleFrame`): layer (0,0) is the screen's
            // bottom-left corner, which `PointerGeometry.layerPoint` relies on.
            panel.setFrame(screen.frame, display: false)

            // A layer-hosting view (our layer, set before wantsLayer). Its geometry is the
            // default y-up one; nothing here is flipped.
            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            let root = CALayer()
            root.frame = view.bounds
            view.layer = root
            view.wantsLayer = true
            panel.contentView = view

            group.frame = CGRect(origin: .zero, size: screen.frame.size)
            group.opacity = 0
            root.addSublayer(group)

            cursor.bounds = .zero
            group.addSublayer(cursor)

            // Pill: top-left corner at the tip + (18, 20) pt (down-right), grows rightwards.
            pill.anchorPoint = CGPoint(x: 0, y: 1)
            pill.position = PointerGeometry.pillTopLeftFromTip
            pill.bounds = CGRect(x: 0, y: 0, width: 0, height: PointerStyle.pillHeight)
            pill.backgroundColor = VirtualPointer.clay
            pill.cornerRadius = PointerStyle.pillHeight / 2
            pill.masksToBounds = true
            pill.opacity = 0
            pillText.contentsScale = scale
            pillText.font = NSFont.systemFont(ofSize: PointerStyle.pillFontSize, weight: .medium)
            pillText.fontSize = PointerStyle.pillFontSize
            pillText.foregroundColor = CGColor(gray: 1, alpha: 1)
            pillText.alignmentMode = .left
            pillText.anchorPoint = .zero
            pill.addSublayer(pillText)
            // The action pill is not shown (removed at the user's request); the arrow stands alone.

            // Arrow: its tip (hotspot) is the anchor, so `cursor.position` IS the target.
            arrow.path = VirtualPointer.arrowPath
            arrow.bounds = CGRect(origin: .zero, size: PointerStyle.arrowSize)
            arrow.anchorPoint = PointerGeometry.arrowAnchor()
            arrow.position = .zero
            arrow.fillColor = VirtualPointer.clay
            arrow.strokeColor = CGColor(gray: 1, alpha: 1)
            arrow.lineWidth = PointerStyle.arrowStrokeWidth
            arrow.lineJoin = .round
            arrow.lineCap = .round
            arrow.contentsScale = scale
            arrow.shadowColor = CGColor(gray: 0, alpha: 1)
            arrow.shadowOpacity = 0.25
            arrow.shadowRadius = 1
            arrow.shadowOffset = CGSize(width: 0, height: -1)  // 1 pt down (y-up space)
            arrow.shadowPath = VirtualPointer.arrowPath
            cursor.addSublayer(arrow)
        }

        func local(_ p: CGPoint) -> CGPoint {
            PointerGeometry.layerPoint(global: p, screen: cocoaFrame, primaryHeight: primaryHeight)
        }
    }

    static let clay = CGColor(srgbRed: PointerStyle.clay.r, green: PointerStyle.clay.g, blue: PointerStyle.clay.b, alpha: 1)

    /// The arrow outline in its own y-up 22×24 box.
    static let arrowPath: CGPath = {
        let path = CGMutablePath()
        for segment in SoftArrow.yUpSegments() {
            switch segment {
            case .move(let p): path.move(to: p)
            case .line(let p): path.addLine(to: p)
            case .curve(let a, let b, let c): path.addCurve(to: c, control1: a, control2: b)
            case .close: path.closeSubpath()
            }
        }
        return path
    }()

    private var screens: [ScreenLayers] = []
    /// The live preview's arrow.
    weak var motionObserver: PointerMotionObserver?
    /// Global top-left position of the tip (model value).
    private(set) var position: CGPoint?
    /// The action pill next to the arrow is disabled.
    static let showsPill = false

    /// Text in the pill (nil = collapsed).
    private var pillLabel: String?
    /// A session is using the pointer (from the first move until `hide`).
    private var active = false
    /// The panels are on screen and the layers visible.
    private var shown = false
    private var targetPid: pid_t?
    private var idleTimer: Timer?
    /// Bumped to cancel pending animation phases.
    private var generation = 0
    private var capturable = false
    private var activationObserver: Any?

    func start() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.frontmostChanged(to: app?.processIdentifier)
        }
    }

    /// Settings that affect the panels (read per request: edits apply from the next action).
    func apply(_ settings: PointerSettings) {
        guard settings.debugCapturable != capturable else { return }
        capturable = settings.debugCapturable
        for s in screens { s.panel.sharingType = capturable ? .readOnly : .none }
    }

    // MARK: Screens

    private func ensureScreens() {
        let current = NSScreen.screens
        // The primary screen (menu bar, Cocoa origin (0,0)) is screens[0], not `main`.
        guard let primary = current.first else { return }
        if current.map(\.frame) == screens.map(\.cocoaFrame),
            screens.first?.primaryHeight == primary.frame.height
        {
            return
        }
        for s in screens { s.panel.orderOut(nil) }
        screens = current.map { ScreenLayers(screen: $0, primaryHeight: primary.frame.height) }
        for s in screens { s.panel.sharingType = capturable ? .readOnly : .none }
        shown = false
    }

    // MARK: Moves

    /// Glide the tip to `point` (global top-left). The pill says `moving` on the way and
    /// `arrived` once there. `targetFront`: the target app is frontmost (else nothing is
    /// drawn and the position is only remembered). `onArrive` runs (main thread) once the
    /// pointer has arrived; returns the expected total duration and the glide (nil when
    /// nothing moves on screen).
    @discardableResult
    func moveTo(
        _ point: CGPoint, moving: String, arrived: String, windowCenter: CGPoint?, targetPid pid: pid_t,
        targetFront: Bool, speed: Double, onArrive: @escaping () -> Void
    ) -> (total: TimeInterval, glide: PointerGlide?) {
        ensureScreens()
        active = true
        targetPid = pid
        guard targetFront, !screens.isEmpty else {
            if shown { fadeOutPanels() }
            // Not drawn (the user is in another app), but the live preview still shows
            // the same glide; the action does not wait for it.
            let from = position ?? windowCenter ?? point
            let distance = hypot(point.x - from.x, point.y - from.y)
            let duration = PointerMotion.duration(distance: distance, speed: speed)
            if duration > 0 {
                let factor = CGFloat.random(in: -PointerMotion.maxCurveFactor...PointerMotion.maxCurveFactor)
                let control = PointerMotion.controlPoint(from: from, to: point, factor: factor)
                motionObserver?.pointerGlide(
                    PointerGlide(from: from, control: control, to: point, delay: 0, duration: duration),
                    beginTime: CACurrentMediaTime())
            } else {
                motionObserver?.pointerJump(to: point)
            }
            position = point
            pillLabel = arrived
            onArrive()
            return (0, nil)
        }
        cancelPhases()
        idleTimer?.invalidate()
        var phases: [(TimeInterval, () -> Void)] = []
        var delay: TimeInterval = 0
        if !shown || position == nil {
            delay = PointerStyle.fadeInDuration
            let start = position ?? windowCenter ?? point
            phases.append((PointerStyle.fadeInDuration, { self.appear(at: start) }))
            position = start
        } else {
            setGroupOpacity(1, duration: 0.12)
        }
        let from = position ?? point
        let distance = hypot(point.x - from.x, point.y - from.y)
        let glide = PointerMotion.duration(distance: distance, speed: speed)
        var path: PointerGlide?
        if glide > 0 {
            pillLabel = moving
            if shown { setPill(moving) }
            let factor = CGFloat.random(in: -PointerMotion.maxCurveFactor...PointerMotion.maxCurveFactor)
            let control = PointerMotion.controlPoint(from: from, to: point, factor: factor)
            phases.append((glide, { self.glide(from: from, control: control, to: point, duration: glide) }))
            path = PointerGlide(from: from, control: control, to: point, delay: delay, duration: glide)
        }
        position = point
        if let path {
            motionObserver?.pointerGlide(path, beginTime: CACurrentMediaTime() + path.delay)
        } else {
            motionObserver?.pointerJump(to: point)
        }
        let total = run(phases) { [weak self] in
            self?.setPill(arrived)
            onArrive()
        }
        return (total, path)
    }

    /// Show `label` in the pill where the pointer is (e.g. "Pressing cmd+a").
    func announce(_ label: String) {
        pillLabel = label
        guard shown else { return }
        idleTimer?.invalidate()
        setGroupOpacity(1, duration: 0.12)
        setPill(label)
        restartIdleTimer(after: 0)
    }

    /// Click feedback: the arrow presses (0.86 → 1) and a ring expands from the tip.
    func press() {
        if position != nil { motionObserver?.pointerPress() }
        guard shown, let position else { return }
        for s in screens {
            let a = CABasicAnimation(keyPath: "transform.scale")
            a.fromValue = PointerStyle.pressScale
            a.toValue = 1
            a.duration = PointerStyle.pressDuration
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            s.arrow.add(a, forKey: "press")
            ring(in: s, at: s.local(position))
        }
        restartIdleTimer(after: PointerStyle.ringDuration)
    }

    /// One drag step: follow the posted drag events (linear, `duration` long).
    func follow(to point: CGPoint, duration: TimeInterval) {
        position = point
        motionObserver?.pointerFollow(to: point, duration: duration)
        guard shown else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for s in screens {
            let p = s.local(point)
            let a = CABasicAnimation(keyPath: "position")
            a.fromValue = NSValue(point: s.cursor.presentation()?.position ?? s.cursor.position)
            a.toValue = NSValue(point: p)
            a.duration = duration
            a.timingFunction = CAMediaTimingFunction(name: .linear)
            s.cursor.add(a, forKey: "follow")
            s.cursor.position = p
        }
        CATransaction.commit()
        restartIdleTimer(after: duration)
    }

    /// Stop any movement where it is (Stop / deadline while moving).
    func halt() {
        cancelPhases()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for s in screens {
            for layer in [s.cursor, s.group, s.pill] {
                if let p = layer.presentation() {
                    layer.position = p.position
                    layer.bounds = p.bounds
                    layer.opacity = p.opacity
                }
                layer.removeAllAnimations()
            }
        }
        CATransaction.commit()
        if let s = screens.first {
            position = PointerGeometry.globalPoint(
                layer: s.cursor.position, screen: s.cocoaFrame, primaryHeight: s.primaryHeight)
        }
        if let position { motionObserver?.pointerJump(to: position) }
    }

    /// Overlay hidden, finishTurn or Stop: fade out and forget the session's pointer.
    func hide() {
        motionObserver?.pointerHidden()
        active = false
        targetPid = nil
        idleTimer?.invalidate()
        cancelPhases()
        if shown { fadeOutPanels() }
        position = nil
        pillLabel = nil
    }

    // MARK: Frontmost tracking (draw only while the target app is in front)

    private func frontmostChanged(to pid: pid_t?) {
        guard active, let targetPid else { return }
        if pid == targetPid {
            if !shown, let position {
                cancelPhases()
                run([(PointerStyle.fadeInDuration, { self.appear(at: position) })], onArrive: {})
            }
        } else if shown {
            cancelPhases()
            fadeOutPanels()
        }
    }

    // MARK: Phases

    private func cancelPhases() { generation += 1 }

    @discardableResult
    private func run(_ phases: [(TimeInterval, () -> Void)], onArrive: @escaping () -> Void) -> TimeInterval {
        let total = phases.reduce(0) { $0 + $1.0 }
        let gen = generation
        func step(_ i: Int) {
            guard gen == generation else {
                onArrive()
                return
            }
            guard i < phases.count else {
                onArrive()
                restartIdleTimer(after: 0)
                return
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            CATransaction.setCompletionBlock { step(i + 1) }
            phases[i].1()
            CATransaction.commit()
        }
        step(0)
        return total
    }

    private func animate(
        _ layer: CALayer, _ keyPath: String, to value: Any, duration: TimeInterval, timing: CAMediaTimingFunction,
        from: Any? = nil
    ) {
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = from ?? layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
        a.toValue = value
        a.duration = duration
        a.timingFunction = timing
        layer.add(a, forKey: keyPath)
        layer.setValue(value, forKeyPath: keyPath)
    }

    private static func timing(_ c: (Double, Double, Double, Double)) -> CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: Float(c.0), Float(c.1), Float(c.2), Float(c.3))
    }

    /// Fade in with the tip at `point`.
    private func appear(at point: CGPoint) {
        for s in screens {
            s.panel.orderFrontRegardless()
            s.cursor.removeAllAnimations()
            s.cursor.position = s.local(point)
            animate(
                s.group, "opacity", to: Float(1), duration: PointerStyle.fadeInDuration,
                timing: CAMediaTimingFunction(name: .easeOut), from: Float(0))
        }
        shown = true
        if let pillLabel { setPill(pillLabel) }
    }

    private func glide(from: CGPoint, control: CGPoint, to: CGPoint, duration: TimeInterval) {
        for s in screens {
            let path = CGMutablePath()
            path.move(to: s.local(from))
            path.addQuadCurve(to: s.local(to), control: s.local(control))
            let a = CAKeyframeAnimation(keyPath: "position")
            a.path = path
            a.duration = duration
            a.timingFunction = Self.timing(PointerStyle.glideEasing)
            a.calculationMode = .linear
            a.rotationMode = nil  // the arrow stays upright
            s.cursor.add(a, forKey: "glide")
            s.cursor.position = s.local(to)
        }
    }

    /// Pill text: grows / shrinks to the new width (300 ms, ease-out), from 0 if collapsed.
    private func setPill(_ label: String?) {
        pillLabel = label
        guard shown, Self.showsPill else { return }
        let t = Self.timing(PointerStyle.pillEasing)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for s in screens {
            guard let label, !label.isEmpty else {
                animate(s.pill, "bounds.size.width", to: CGFloat(0), duration: PointerStyle.pillDuration, timing: t)
                animate(s.pill, "opacity", to: Float(0), duration: PointerStyle.pillDuration, timing: t)
                continue
            }
            let font = NSFont.systemFont(ofSize: PointerStyle.pillFontSize, weight: .medium)
            let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor.white])
            let size = text.size()
            let width = ceil(size.width) + 2 * PointerStyle.pillPadding
            s.pillText.string = text
            s.pillText.bounds = CGRect(x: 0, y: 0, width: ceil(size.width) + 2, height: ceil(size.height))
            s.pillText.position = CGPoint(
                x: PointerStyle.pillPadding, y: (PointerStyle.pillHeight - ceil(size.height)) / 2)
            let collapsed = s.pill.opacity == 0
            animate(
                s.pill, "bounds.size.width", to: width, duration: PointerStyle.pillDuration, timing: t,
                from: collapsed ? CGFloat(0) : nil)
            animate(s.pill, "opacity", to: Float(1), duration: PointerStyle.pillDuration * 0.5, timing: t)
        }
        CATransaction.commit()
    }

    private func ring(in s: ScreenLayers, at p: CGPoint) {
        let end = PointerStyle.ringEndDiameter
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: -end / 2, y: -end / 2, width: end, height: end), transform: nil)
        ring.fillColor = nil
        ring.strokeColor = Self.clay
        ring.lineWidth = 2
        ring.contentsScale = s.scale
        ring.position = p
        ring.opacity = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        s.group.insertSublayer(ring, below: s.cursor)
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = PointerStyle.ringStartDiameter / end
        scale.toValue = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = Float(PointerStyle.ringStartOpacity)
        fade.toValue = Float(0)
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = PointerStyle.ringDuration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(group, forKey: "ring")
        CATransaction.commit()
    }

    private func setGroupOpacity(_ value: Float, duration: TimeInterval) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for s in screens {
            animate(s.group, "opacity", to: value, duration: duration, timing: CAMediaTimingFunction(name: .easeInEaseOut))
        }
        CATransaction.commit()
    }

    private func fadeOutPanels() {
        shown = false
        idleTimer?.invalidate()
        let panels = screens.map(\.panel)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            // Only if nothing showed the pointer again meanwhile.
            guard let self, !self.shown else { return }
            for p in panels { p.orderOut(nil) }
        }
        for s in screens {
            animate(s.group, "opacity", to: Float(0), duration: 0.15, timing: CAMediaTimingFunction(name: .easeIn))
        }
        CATransaction.commit()
    }

    /// After 2 s without a move: fade to 40 % and collapse the pill.
    private func restartIdleTimer(after delay: TimeInterval) {
        idleTimer?.invalidate()
        let t = Timer(timeInterval: delay + PointerStyle.idleDelay, repeats: false) { [weak self] _ in
            guard let self, self.shown else { return }
            self.setGroupOpacity(Float(PointerStyle.idleOpacity), duration: 0.3)
            self.setPill(nil)
        }
        RunLoop.main.add(t, forMode: .common)
        idleTimer = t
    }
}

/// Thread-safe front end for the action threads: runs `VirtualPointer` on the main thread
/// and waits (bounded) for the pointer to arrive before the action posts its events.
final class PointerDriver: @unchecked Sendable {
    let ui: VirtualPointer
    let settingsURL: URL

    init(ui: VirtualPointer, settingsURL: URL) {
        self.ui = ui
        self.settingsURL = settingsURL
    }

    func settings() -> PointerSettings { PointerSettings.load(settingsURL) }

    private final class Box: @unchecked Sendable {
        var total: TimeInterval = 0
    }

    /// Animate the tip to `point` — the very point the action then uses — and wait until it
    /// is there. Returns false if `interrupted` became true meanwhile (the pointer then
    /// stops where it is and the action must not post anything). Never waits more than
    /// ≈ 2.5 s; if the main thread does not answer within 0.5 s the animation is skipped.
    /// The hover moves are posted only after arrival, never along the glide.
    /// `waitForArrival` false: start the glide and return at once (the real pointer does the
    /// click, so the animation is only for show).
    func travel(
        to point: CGPoint, moving: String, arrived: String, windowFrame: CGRect?, pid: pid_t, targetFront: Bool,
        waitForArrival: Bool = true, interrupted: () -> Bool
    ) -> Bool {
        let s = settings()
        guard s.enabled else { return !interrupted() }
        let started = DispatchSemaphore(value: 0)
        let arrivedSignal = DispatchSemaphore(value: 0)
        let box = Box()
        let center = windowFrame.map { CGPoint(x: $0.midX, y: $0.midY) }
        let ui = self.ui
        DispatchQueue.main.async {
            ui.apply(s)
            let r = ui.moveTo(
                point, moving: moving, arrived: arrived, windowCenter: center, targetPid: pid,
                targetFront: targetFront, speed: s.speed, onArrive: { arrivedSignal.signal() })
            box.total = r.total
            started.signal()
        }
        guard started.wait(timeout: .now() + 0.5) == .success else {
            Log.warn("pointer: main thread busy; skipping the animation")
            return !interrupted()
        }
        if !waitForArrival { return !interrupted() }
        let t0 = Date()
        let limit = t0.addingTimeInterval(min(box.total + 0.3, 2.5))
        while true {
            if interrupted() {
                DispatchQueue.main.async { ui.halt() }
                return false
            }
            if arrivedSignal.wait(timeout: .now() + 0.01) == .success { return true }
            if Date() > limit { return true }
        }
    }

    func announce(_ label: String) {
        guard settings().enabled else { return }
        DispatchQueue.main.async { [ui] in ui.announce(label) }
    }

    func press() {
        guard settings().enabled else { return }
        DispatchQueue.main.async { [ui] in ui.press() }
    }

    /// Drag step (async; the drag loop paces itself).
    func follow(to point: CGPoint, duration: TimeInterval) {
        DispatchQueue.main.async { [ui] in ui.follow(to: point, duration: duration) }
    }

    func hide() {
        DispatchQueue.main.async { [ui] in ui.hide() }
    }
}

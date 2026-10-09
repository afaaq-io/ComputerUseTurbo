import AppKit
import TurboCore
import Foundation
import QuartzCore
import ScreenCaptureKit

/// What the live preview shows: the window the session is working on.
struct PreviewTarget: Equatable {
    var pid: pid_t
    var appName: String
    var appPath: String
    /// The observed window's frame (global top-left points) — the capture matches it.
    var windowFrame: CGRect?
}

/// The live preview: a small floating picture-in-picture panel that
/// shows only a live image of the target app's window, with the agent pointer animated on
/// top of it. It hangs inside the top-right corner of the window of the app the agent runs
/// in — its host, detected at runtime (`AgentRegistry`) — following it as it moves; hidden
/// while that window is not visible; the main screen's top-right when no host is known or it
/// has no window. Ordered just above the host's window (floating while the host is
/// frontmost), non-activating, never captured (`sharingType = .none`). Frames
/// (~5 fps, ScreenCaptureKit, only the target app's matching window) are captured only while
/// the panel is visible and expanded; the arrow is its own layer, animated by Core Animation
/// at display refresh with exactly the on-screen pointer's motion (`PointerMotionObserver`).
/// The panel stays for the whole job: it closes on finishTurn or Stop/Esc (30 min without any
/// request is only a safety net). Main thread only.
final class LivePreviewController: NSObject, PointerMotionObserver {
    private let settingsURL: URL
    private var panel: PreviewPanel?
    private var content: PreviewContentView?
    private var target: PreviewTarget?
    private var lastActivity = Date.distantPast
    private var tick: Timer?
    private var frameTimer: Timer?
    private let capturer = PreviewCapturer()
    /// `show_preview`: nil = follow settings; true / false = shown / hidden on request.
    private var requested: Bool?
    /// A session is active (a gated request in the last 60 s, not ended).
    private var active = false
    private var settings = PreviewSettings.defaults
    private var capturable = false
    /// The user is dragging the panel.
    private var dragging = false

    init(settingsURL: URL) {
        self.settingsURL = settingsURL
        super.init()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: Driving it

    /// A gated request is running for `target` (the session is not stopped).
    func noteActivity(target: PreviewTarget, capturable: Bool) {
        settings = PreviewSettings.load(settingsURL)
        self.capturable = capturable
        if self.target?.pid != target.pid { capturer.reset() }
        self.target = target
        content?.windowFrameHint = target.windowFrame
        active = true
        lastActivity = Date()
        startTicking()
        update()
    }

    /// Every session is over (finishTurn with no other active session; Stop / Esc and the 30 min safety net go through their own paths).
    func sessionsEnded() {
        active = false
        target = nil
        update()
    }

    /// `show_preview`: returns whether the panel is (or will be) shown.
    @discardableResult
    func toggle(show: Bool) -> Bool {
        requested = show
        settings = PreviewSettings.load(settingsURL)
        if show { startTicking() }
        update()
        return shouldShow
    }

    var shouldShow: Bool {
        guard active, target != nil else { return false }
        if let requested { return requested }
        return settings.enabled
    }

    // MARK: Pointer mirror (PointerMotionObserver)

    func pointerGlide(_ glide: PointerGlide, beginTime: CFTimeInterval) {
        content?.glide(glide, beginTime: beginTime)
    }

    func pointerJump(to point: CGPoint) { content?.jump(to: point) }

    func pointerFollow(to point: CGPoint, duration: TimeInterval) { content?.follow(to: point, duration: duration) }

    func pointerPress() { content?.press() }

    func pointerHidden() { content?.hidePointer() }

    // MARK: Ticking (anchor + idle)

    private func startTicking() {
        guard tick == nil else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.update() }
        RunLoop.main.add(t, forMode: .common)
        tick = t
    }

    private func stopTicking() {
        tick?.invalidate()
        tick = nil
        frameTimer?.invalidate()
        frameTimer = nil
    }

    /// Re-anchor, show / hide, start / stop frames.
    private func update() {
        if active, Date().timeIntervalSince(lastActivity) > TurboProtocol.previewSessionSeconds {
            active = false
        }
        guard shouldShow, let target else {
            hidePanel()
            if !active { stopTicking() }
            return
        }
        let anchor = HostWindowAnchor.current()
        guard anchor.visible else {
            hidePanel()
            return
        }
        let p = ensurePanel()
        p.sharingType = capturable ? .readOnly : .none
        content?.setApp(name: target.appName, path: target.appPath)
        let collapsed = settings.collapsed
        content?.setCollapsed(collapsed)
        let size = PreviewGeometry.panelSize(aspect: aspect(target), collapsed: collapsed)
        let screen = anchor.screenVisibleFrame
        let frame = PreviewGeometry.frame(
            size: size, anchor: anchor.frame, screen: screen, offset: CGPoint(x: settings.offsetX, y: settings.offsetY))
        if !dragging {
            let cocoa = ScreenGeometry.cocoaRect(fromGlobal: frame, primaryHeight: ScreenGeometry.primaryHeight)
            if p.frame != cocoa { p.setFrame(cocoa, display: true) }
        }
        // Just above the host's window: floating while the host is in front, else ordered
        // right above its window (other apps' windows in front of the host cover it).
        if anchor.hostFrontmost || anchor.windowNumber == nil {
            if p.level != .floating { p.level = .floating }
            if !p.isVisible { p.orderFrontRegardless() }
        } else if let number = anchor.windowNumber {
            if p.level != .normal { p.level = .normal }
            p.order(.above, relativeTo: number)
        }
        if collapsed {
            frameTimer?.invalidate()
            frameTimer = nil
        } else if frameTimer == nil {
            let t = Timer(timeInterval: 1 / PreviewGeometry.framesPerSecond, repeats: true) { [weak self] _ in self?.captureFrame() }
            RunLoop.main.add(t, forMode: .common)
            frameTimer = t
            captureFrame()
        }
    }

    private func aspect(_ t: PreviewTarget) -> Double? {
        guard let f = t.windowFrame, f.height > 0 else { return nil }
        return Double(f.width / f.height)
    }

    private func hidePanel() {
        frameTimer?.invalidate()
        frameTimer = nil
        if let p = panel, p.isVisible { p.orderOut(nil) }
    }

    private func captureFrame() {
        guard let target, let content, panel?.isVisible == true, !SystemState.isScreenLocked else { return }
        // The window being worked on is streamed (WindowFeeds): show its newest frame.
        if let (image, windowFrame) = WindowFeeds.shared.latest(pid: target.pid) {
            content.show(image: image, windowFrame: windowFrame)
            return
        }
        let scale = panel?.backingScaleFactor ?? 2
        let box = content.imageBox.size
        capturer.capture(
            pid: target.pid, frame: target.windowFrame,
            maxPixelSize: CGSize(width: box.width * scale, height: box.height * scale)
        ) { [owner = WeakOwner(self)] image, windowFrame in
            DispatchQueue.main.async {
                guard let self = owner.value, self.target?.pid == target.pid else { return }
                self.content?.show(image: image, windowFrame: windowFrame)
            }
        }
    }

    /// The controller, held weakly by the capture callback (it is only used on the main
    /// queue, where the callback hops before touching it).
    private final class WeakOwner: @unchecked Sendable {
        weak var value: LivePreviewController?
        init(_ value: LivePreviewController) { self.value = value }
    }

    // MARK: Panel

    private func ensurePanel() -> PreviewPanel {
        if let panel { return panel }
        let p = PreviewPanel(
            contentRect: NSRect(x: 0, y: 0, width: PreviewGeometry.defaultWidth, height: 200),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = false
        p.level = .floating
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovable = false
        p.isMovableByWindowBackground = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .utilityWindow
        p.sharingType = .none
        p.acceptsMouseMovedEvents = true
        p.title = "Computer Use Turbo live preview"
        let view = PreviewContentView(frame: p.contentView?.bounds ?? .zero)
        view.autoresizingMask = [.width, .height]
        view.windowFrameHint = target?.windowFrame
        view.onToggleCollapse = { [weak self] in self?.toggleCollapsed() }
        view.onActivateTarget = { [weak self] in self?.activateTarget() }
        view.onDragBegan = { [weak self] in self?.dragging = true }
        view.onDragEnded = { [weak self] in self?.dragEnded() }
        p.contentView = view
        GlassTheme.shared.register(view)
        panel = p
        content = view
        return p
    }

    private func toggleCollapsed() {
        settings = PreviewSettings.load(settingsURL)
        settings.collapsed.toggle()
        save()
        update()
    }

    /// The user clicked the image: bring the target app to the front.
    private func activateTarget() {
        guard let target else { return }
        let err = AX.set(AX.application(target.pid), kAXFrontmostAttribute, kCFBooleanTrue)
        if err != .success { NSRunningApplication(processIdentifier: target.pid)?.activate(options: []) }
        Log.info("preview: the user brought \(LogText.peer(target.appName)) to the front")
    }

    private func dragEnded() {
        dragging = false
        guard let p = panel else { return }
        let anchor = HostWindowAnchor.current()
        let global = ScreenGeometry.globalRect(fromCocoa: p.frame, primaryHeight: ScreenGeometry.primaryHeight)
        let off = PreviewGeometry.offset(afterDragTo: global, anchor: anchor.frame, screen: anchor.screenVisibleFrame)
        settings = PreviewSettings.load(settingsURL)
        settings.offsetX = Double(off.x)
        settings.offsetY = Double(off.y)
        save()
        update()
    }

    private func save() {
        let data = settings.merged(into: try? Data(contentsOf: settingsURL))
        do {
            let tmp = settingsURL.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(settingsURL, withItemAt: tmp)
        } catch {
            try? data.write(to: settingsURL, options: .atomic)
        }
    }
}

/// Where the agent's host app window is (CGWindowList: no permission needed).
struct HostWindowAnchor {
    /// Its frontmost on-screen normal window (global top-left), nil = no host app known.
    var frame: CGRect?
    var windowNumber: Int?
    /// The panel may be shown: the host has an on-screen window, or there is no host app.
    var visible: Bool
    var hostFrontmost: Bool
    /// Visible frame of the screen the anchor is on (global top-left).
    var screenVisibleFrame: CGRect

    static func current() -> HostWindowAnchor {
        let hostPid = AgentRegistry.shared.current.hostPid
        let apps = hostPid.flatMap { NSRunningApplication(processIdentifier: $0) }.map { [$0] }?
            .filter { !$0.isTerminated && $0.activationPolicy == .regular } ?? []
        let front = hostPid != nil && NSWorkspace.shared.frontmostApplication?.processIdentifier == hostPid
        guard !apps.isEmpty else {
            // No agent window to sit beside (a headless or unknown host): the preview belongs
            // with the agent, never loose on the desktop.
            return HostWindowAnchor(frame: nil, windowNumber: nil, visible: false, hostFrontmost: false, screenVisibleFrame: mainVisible())
        }
        let pids = Set(apps.map(\.processIdentifier))
        if apps.allSatisfy(\.isHidden) {
            return HostWindowAnchor(frame: nil, windowNumber: nil, visible: false, hostFrontmost: front, screenVisibleFrame: mainVisible())
        }
        let win = WindowList.onScreenWindows().first {
            pids.contains($0.pid) && $0.layer == 0 && $0.alpha > 0.05 && $0.bounds.width >= 300 && $0.bounds.height >= 200
        }
        guard let win else {
            // Minimized, on another Space, or no window: hide.
            return HostWindowAnchor(frame: nil, windowNumber: nil, visible: false, hostFrontmost: front, screenVisibleFrame: mainVisible())
        }
        return HostWindowAnchor(
            frame: win.bounds, windowNumber: Int(win.number), visible: true, hostFrontmost: front,
            screenVisibleFrame: visibleFrame(containing: win.bounds))
    }

    static func mainVisible() -> CGRect {
        guard let s = NSScreen.screens.first else { return CGRect(x: 0, y: 0, width: 1440, height: 900) }
        return ScreenGeometry.globalRect(fromCocoa: s.visibleFrame, primaryHeight: ScreenGeometry.primaryHeight)
    }

    static func visibleFrame(containing r: CGRect) -> CGRect {
        let h = ScreenGeometry.primaryHeight
        let center = CGPoint(x: r.midX, y: r.minY + 10)
        for s in NSScreen.screens {
            let g = ScreenGeometry.globalRect(fromCocoa: s.frame, primaryHeight: h)
            if g.contains(center) { return ScreenGeometry.globalRect(fromCocoa: s.visibleFrame, primaryHeight: h) }
        }
        return mainVisible()
    }
}

extension ScreenGeometry {
    /// Height of the primary screen (`NSScreen.screens[0]`).
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func cocoaRect(fromGlobal r: CGRect, primaryHeight h: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    static func globalRect(fromCocoa r: CGRect, primaryHeight h: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }
}

final class PreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The panel's content: the live window image with the agent pointer on top (its own
/// layer, animated independently of the frames), a collapse control that appears only
/// while the mouse is over the panel, or — collapsed — a small pill with the app's icon and
/// name. Not flipped; layer geometry is y-up.
final class PreviewContentView: NSView, GlassThemable {
    var onToggleCollapse: (() -> Void)?
    var onActivateTarget: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?
    /// The observed window's frame (global), used to map the pointer until a frame arrives.
    var windowFrameHint: CGRect?

    private let background = CALayer()
    private let imageLayer = CALayer()
    /// Clips the arrow and rings to the image.
    private let pointerHost = CALayer()
    private let arrow = CAShapeLayer()
    private let placeholder = NSTextField(labelWithString: "Waiting for the window…")
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let collapseButton = NSButton(title: "", target: nil, action: nil)
    private var collapsed = false
    private var appPath = ""
    private var dragStart: NSPoint?
    private var dragOrigin: NSPoint?
    private var dragged = false
    private var hovering = false
    private var imageSize: CGSize?
    private var capturedWindow: CGRect?
    /// The pointer's latest target (global); nil = not shown.
    private var pointerGlobal: CGPoint?
    /// Until when an animation drives the arrow (CACurrentMediaTime clock).
    private var animatingUntil: CFTimeInterval = 0
    static let arrowScale: CGFloat = 0.8

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        background.cornerRadius = PreviewGeometry.cornerRadius
        background.borderWidth = 1
        background.masksToBounds = true
        layer?.addSublayer(background)

        imageLayer.contentsGravity = .resizeAspect
        imageLayer.cornerRadius = PreviewGeometry.cornerRadius - 3
        imageLayer.masksToBounds = true
        background.addSublayer(imageLayer)
        pointerHost.masksToBounds = true
        background.addSublayer(pointerHost)

        let path = CGMutablePath()
        for seg in SoftArrow.yUpSegments() {
            switch seg {
            case .move(let p): path.move(to: p)
            case .line(let p): path.addLine(to: p)
            case .curve(let a, let b, let c): path.addCurve(to: c, control1: a, control2: b)
            case .close: path.closeSubpath()
            }
        }
        arrow.path = path
        arrow.bounds = CGRect(origin: .zero, size: PointerStyle.arrowSize)
        arrow.anchorPoint = PointerGeometry.arrowAnchor()
        arrow.fillColor = VirtualPointer.clay
        arrow.strokeColor = CGColor(gray: 1, alpha: 1)
        arrow.lineWidth = PointerStyle.arrowStrokeWidth
        arrow.lineJoin = .round
        arrow.shadowColor = CGColor(gray: 0, alpha: 1)
        arrow.shadowOpacity = 0.25
        arrow.shadowRadius = 1
        arrow.shadowOffset = CGSize(width: 0, height: -1)
        arrow.transform = CATransform3DMakeScale(Self.arrowScale, Self.arrowScale, 1)
        arrow.isHidden = true
        arrow.contentsScale = 2
        pointerHost.addSublayer(arrow)

        for l in [title, placeholder] {
            l.lineBreakMode = .byTruncatingTail
            l.isSelectable = false
        }
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        placeholder.font = .systemFont(ofSize: 11)
        placeholder.alignment = .center
        collapseButton.bezelStyle = .inline
        collapseButton.isBordered = false
        collapseButton.wantsLayer = true
        collapseButton.layer?.backgroundColor = CGColor(gray: 0, alpha: 0.45)
        collapseButton.layer?.cornerRadius = 9
        collapseButton.contentTintColor = NSColor(white: 1, alpha: 0.9)
        collapseButton.target = self
        collapseButton.action = #selector(collapsePressed)
        collapseButton.setAccessibilityIdentifier("turboPreviewCollapse")
        collapseButton.isHidden = true
        icon.imageScaling = .scaleProportionallyUpOrDown
        for v in [icon, title, placeholder, collapseButton] as [NSView] { addSubview(v) }
        setAccessibilityIdentifier("turboPreview")
        applyPalette(GlassTheme.shared.palette, reduceTransparency: GlassTheme.shared.reduceTransparency)
    }

    /// Chrome colours follow the system light / dark appearance; the captured
    /// image and the clay arrow are unaffected.
    func applyPalette(_ p: GlassPalette, reduceTransparency: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        background.backgroundColor = p.previewBackground.cgColor
        background.borderColor = p.border.cgColor
        CATransaction.commit()
        title.textColor = p.textPrimary.nsColor
        placeholder.textColor = p.previewPlaceholder.nsColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The image area (y-up, view coordinates).
    var imageBox: CGRect { bounds.insetBy(dx: 3, dy: 3) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        collapseButton.isHidden = collapsed
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        collapseButton.isHidden = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        background.frame = bounds
        if collapsed {
            icon.frame = NSRect(x: 8, y: (bounds.height - 18) / 2, width: 18, height: 18)
            title.frame = NSRect(x: 32, y: (bounds.height - 16) / 2, width: bounds.width - 40, height: 16)
            icon.isHidden = false
            title.isHidden = false
            imageLayer.isHidden = true
            pointerHost.isHidden = true
            placeholder.isHidden = true
            collapseButton.isHidden = true
        } else {
            icon.isHidden = true
            title.isHidden = true
            imageLayer.isHidden = false
            pointerHost.isHidden = false
            imageLayer.frame = imageBox
            pointerHost.frame = imageBox
            placeholder.frame = NSRect(x: imageBox.minX, y: imageBox.midY - 8, width: imageBox.width, height: 16)
            placeholder.isHidden = imageLayer.contents != nil
            collapseButton.frame = NSRect(x: bounds.width - 26, y: bounds.height - 26, width: 18, height: 18)
            collapseButton.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Collapse")
            collapseButton.isHidden = !hovering
            repositionPointer()
        }
        CATransaction.commit()
    }

    func setApp(name: String, path: String) {
        if title.stringValue != name { title.stringValue = name }
        if path != appPath {
            appPath = path
            icon.image = path.isEmpty ? nil : NSWorkspace.shared.icon(forFile: path)
        }
    }

    func setCollapsed(_ c: Bool) {
        guard c != collapsed else { return }
        collapsed = c
        needsLayout = true
    }

    // MARK: Frames

    /// A new frame of the captured window (`windowFrame`, global top-left).
    func show(image: CGImage?, windowFrame: CGRect?) {
        guard let image else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        placeholder.isHidden = true
        let size = CGSize(width: image.width, height: image.height)
        let changed = size != imageSize || windowFrame != capturedWindow
        imageSize = size
        if let windowFrame { capturedWindow = windowFrame }
        if changed { repositionPointer() }
        CATransaction.commit()
    }

    // MARK: Pointer (mirrors VirtualPointer)

    /// The window being shown and where its image is drawn inside `pointerHost` (y-up).
    private var mapping: (window: CGRect, rect: CGRect)? {
        guard let window = capturedWindow ?? windowFrameHint, window.width > 0, window.height > 0 else { return nil }
        let size = imageSize ?? window.size
        let rect = PreviewGeometry.fit(imageSize: size, in: CGRect(origin: .zero, size: pointerHost.bounds.size))
        return (window, rect)
    }

    private func local(_ p: CGPoint) -> CGPoint? {
        mapping.map { PreviewGeometry.map(p, window: $0.window, into: $0.rect) }
    }

    /// Put the arrow where the pointer is, unless an animation is driving it.
    private func repositionPointer() {
        guard let g = pointerGlobal, let p = local(g) else {
            arrow.isHidden = true
            return
        }
        arrow.isHidden = false
        if CACurrentMediaTime() < animatingUntil { return }
        arrow.removeAnimation(forKey: "glide")
        arrow.position = p
    }

    func glide(_ g: PointerGlide, beginTime: CFTimeInterval) {
        pointerGlobal = g.to
        guard let from = local(g.from), let control = local(g.control), let to = local(g.to) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let start = arrow.isHidden ? from : (arrow.presentation()?.position ?? arrow.position)
        arrow.isHidden = false
        let path = CGMutablePath()
        // A glide that starts where the arrow already is: the exact on-screen curve. If the
        // arrow was elsewhere (it appeared mid-way), it starts from where it is.
        path.move(to: hypot(start.x - from.x, start.y - from.y) < 1 ? from : start)
        path.addQuadCurve(to: to, control: control)
        let a = CAKeyframeAnimation(keyPath: "position")
        a.path = path
        a.duration = g.duration
        a.beginTime = arrow.convertTime(beginTime, from: nil)
        a.fillMode = .backwards
        let e = PointerStyle.glideEasing
        a.timingFunction = CAMediaTimingFunction(controlPoints: Float(e.0), Float(e.1), Float(e.2), Float(e.3))
        a.calculationMode = .linear
        arrow.add(a, forKey: "glide")
        arrow.position = to
        animatingUntil = beginTime + g.duration
        CATransaction.commit()
    }

    func jump(to point: CGPoint) {
        pointerGlobal = point
        animatingUntil = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        repositionPointer()
        CATransaction.commit()
    }

    func follow(to point: CGPoint, duration: TimeInterval) {
        pointerGlobal = point
        guard let p = local(point) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arrow.isHidden = false
        let a = CABasicAnimation(keyPath: "position")
        a.fromValue = NSValue(point: arrow.presentation()?.position ?? arrow.position)
        a.toValue = NSValue(point: p)
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: .linear)
        arrow.add(a, forKey: "glide")
        arrow.position = p
        animatingUntil = CACurrentMediaTime() + duration
        CATransaction.commit()
    }

    /// Click feedback, as on screen: the arrow presses (0.86 → 1) and a clay ring expands
    /// from the tip (scaled like the image, never smaller than 40 % of its size on screen).
    func press() {
        guard !arrow.isHidden, let m = mapping else { return }
        let tip = arrow.presentation()?.position ?? arrow.position
        let s = Self.arrowScale
        let a = CABasicAnimation(keyPath: "transform.scale")
        a.fromValue = PointerStyle.pressScale * s
        a.toValue = s
        a.duration = PointerStyle.pressDuration
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        arrow.add(a, forKey: "press")
        let end = PointerStyle.ringEndDiameter * max(0.4, PreviewGeometry.scale(window: m.window, into: m.rect))
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: -end / 2, y: -end / 2, width: end, height: end), transform: nil)
        ring.fillColor = nil
        ring.strokeColor = VirtualPointer.clay
        ring.lineWidth = 1.5
        ring.contentsScale = 2
        ring.position = tip
        ring.opacity = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pointerHost.insertSublayer(ring, below: arrow)
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = PointerStyle.ringStartDiameter / PointerStyle.ringEndDiameter
        grow.toValue = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = Float(PointerStyle.ringStartOpacity)
        fade.toValue = Float(0)
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = PointerStyle.ringDuration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(group, forKey: "ring")
        CATransaction.commit()
    }

    func hidePointer() {
        pointerGlobal = nil
        animatingUntil = 0
        arrow.removeAllAnimations()
        arrow.isHidden = true
    }

    // MARK: Mouse

    @objc private func collapsePressed() { onToggleCollapse?() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragStart = NSEvent.mouseLocation
        dragOrigin = window?.frame.origin
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let origin = dragOrigin, let w = window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.x
        let dy = now.y - start.y
        if !dragged && hypot(dx, dy) < 3 { return }
        if !dragged {
            dragged = true
            onDragBegan?()
        }
        w.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStart = nil
            dragOrigin = nil
        }
        if dragged {
            dragged = false
            onDragEnded?()
            return
        }
        if collapsed {
            onToggleCollapse?()
        } else if imageBox.contains(convert(event.locationInWindow, from: nil)) {
            onActivateTarget?()
        }
    }
}

/// ScreenCaptureKit frames of the target app's window for the preview. Only a window of
/// `pid` is ever captured (the one matching the observed frame, else its frontmost normal
/// window); never more than one capture in flight; the window list is refreshed at most
/// every 2 s.
final class PreviewCapturer: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = false
    private var content: SCShareableContent?
    private var contentAt = Date.distantPast

    func reset() {
        lock.lock()
        content = nil
        lock.unlock()
    }

    func capture(pid: pid_t, frame: CGRect?, maxPixelSize: CGSize, completion: @escaping @Sendable (CGImage?, CGRect?) -> Void) {
        guard CGPreflightScreenCaptureAccess() else { return }
        lock.lock()
        if inFlight {
            lock.unlock()
            return
        }
        inFlight = true
        let cached = Date().timeIntervalSince(contentAt) < 2 ? content : nil
        lock.unlock()
        Task.detached { [weak self] in
            var image: CGImage?
            var windowFrame: CGRect?
            defer {
                self?.finish()
                completion(image, windowFrame)
            }
            guard let self else { return }
            do {
                var shareable = cached
                if shareable == nil {
                    shareable = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                    self.store(shareable)
                }
                guard let shareable else { return }
                let mine = shareable.windows.filter {
                    $0.owningApplication?.processID == pid && $0.frame.width > 40 && $0.frame.height > 40 && $0.isOnScreen
                }
                var window: SCWindow?
                if let frame {
                    let candidates = mine.map {
                        CaptureCandidate(id: $0.windowID, frame: $0.frame, layer: $0.windowLayer, isOnScreen: $0.isOnScreen)
                    }
                    if let best = WindowMatcher.bestCapture(frame, among: candidates) {
                        window = mine.first { $0.windowID == best.id }
                    }
                }
                if window == nil { window = mine.first { $0.windowLayer == 0 } }
                guard let window else { return }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let config = SCStreamConfiguration()
                // Pixels: the window's points × its backing scale, shrunk to fit the panel's
                // image area (no point capturing more than is shown).
                let w = max(1, window.frame.width)
                let h = max(1, window.frame.height)
                let fit = min(maxPixelSize.width / w, maxPixelSize.height / h)
                let s = max(0.05, min(CGFloat(filter.pointPixelScale), fit))
                config.width = max(1, Int(w * s))
                config.height = max(1, Int(h * s))
                config.scalesToFit = true
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                windowFrame = window.frame
            } catch {
                self.reset()
            }
        }
    }

    private func store(_ c: SCShareableContent?) {
        lock.lock()
        content = c
        contentAt = Date()
        lock.unlock()
    }

    private func finish() {
        lock.lock()
        inFlight = false
        lock.unlock()
    }
}

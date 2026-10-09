import AppKit
import ApplicationServices
import TurboCore
import Foundation

/// The "<agent> is working in <App>" floating panel with a Stop button.
///
/// A small non-activating `NSPanel` at the top-right of the main screen, on all Spaces,
/// drawn as the "light glass pill".12 (tokens in
/// `TurboCore/GlassDesign.swift`): pulsing clay dot, the target app's icon, "<agent> is working in
/// <App>" and a red-tinted Stop capsule with an "esc" hint. Never in screen captures
/// (`sharingType = .none`) unless `pointer.debugCapturable` is on.
/// Stop (button, or Esc via global + local key monitors while the panel is visible)
/// calls `onStop` and switches the text to "Stopped". The panel hides 60 s after the
/// last gated request, or on `finishTurn`. All methods must run on the main thread.
final class OverlayController: NSObject {
    var onStop: (() -> Void)?
    /// Called whenever the overlay hides or the user stops: the agent pointer
    /// disappears with it.
    var onHideOrStop: (() -> Void)?
    /// Called when the overlay hides (idle, finishTurn): the live preview hides too.
    var onHidden: (() -> Void)?
    /// Returns true while an approval dialog is up (Esc then belongs to the dialog).
    var isApprovalDialogVisible: () -> Bool = { false }

    private var panel: NSPanel?
    private var surface: GlassSurfaceView?
    private var dot: PulsingDotView?
    private var icon: NSImageView?
    private var label: NSTextField?
    private var button: GlassStopButton?
    private var iconPath: String?
    private var hideTimer: Timer?
    /// Polls the pointer while the panel is visible so the panel ignores the mouse
    /// everywhere except over an enabled Stop button.
    private var pointerTimer: Timer?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private(set) var isStopped = false

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Install the Esc monitors. The local one always; the global one only once the
    /// helper is trusted for Accessibility (key monitoring needs it), so starting the
    /// helper never causes a permission prompt. `noteActivity` retries the global one.
    func installKeyMonitors() {
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if self?.handleKey(event) == true { return nil }
                return event
            }
        }
        if globalMonitor == nil && AXIsProcessTrusted() {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleKey(event)
            }
            Log.info("overlay: global Esc monitor installed")
        }
    }

    @discardableResult
    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.keyCode == 53, isVisible, !isStopped, !isApprovalDialogVisible() else { return false }
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard mods.isEmpty else { return false }
        // Only the Esc key of a real keyboard stops: never the Esc presses we synthesize
        // ourselves (sendKeys "escape"), nor ones other programs post (scripts, automation
        // tools) — those come from a program's event source, not the hardware's.
        if let cg = event.cgEvent {
            if cg.getIntegerValueField(.eventSourceUserData) == InputSynthesizer.eventTag { return false }
            let source = cg.getIntegerValueField(.eventSourceStateID)
            if source == Int64(CGEventSourceStateID.combinedSessionState.rawValue)
                || source == Int64(CGEventSourceStateID.privateState.rawValue)
            {
                Log.info("overlay: Esc from a program (not the keyboard) ignored")
                return false
            }
        }
        Log.info("overlay: Esc pressed — stopping")
        stop()
        return true
    }

    /// A gated request passed the safety pipeline for `appName` (so its session is not
    /// stopped): show/refresh the panel in its active state and restart the idle timer.
    func noteActivity(appName: String, appPath: String = "", capturable: Bool = false) {
        installKeyMonitors()
        ensurePanel()
        panel?.sharingType = capturable ? .readOnly : .none
        isStopped = false
        setIcon(path: appPath, name: appName)
        label?.stringValue = OverlayTexts.using(appName)
        button?.isEnabled = true
        dot?.setActive(true)
        layoutContent()
        positionPanel()
        panel?.orderFrontRegardless()
        startPointerTracking()
        restartHideTimer()
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        stopPointerTracking()
        panel?.orderOut(nil)
        isStopped = false
        onHideOrStop?()
        onHidden?()
    }


    // MARK: Click-through outside the Stop button

    /// A borderless panel either takes every click or none (`ignoresMouseEvents`), so
    /// track the pointer (no permission needed for `NSEvent.mouseLocation`) and only
    /// accept mouse events while it is over the enabled Stop button. Everywhere else
    /// clicks fall through to the window underneath.
    private func startPointerTracking() {
        updateMousePassThrough()
        guard pointerTimer == nil else { return }
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.updateMousePassThrough()
        }
        RunLoop.main.add(t, forMode: .common)
        pointerTimer = t
    }

    private func stopPointerTracking() {
        pointerTimer?.invalidate()
        pointerTimer = nil
        panel?.ignoresMouseEvents = true
    }

    private func updateMousePassThrough() {
        guard let p = panel, let b = button, p.isVisible else { return }
        let onScreen = p.convertToScreen(b.convert(b.bounds, to: nil)).insetBy(dx: -2, dy: -2)
        let acceptsMouse = b.isEnabled && onScreen.contains(NSEvent.mouseLocation)
        if p.ignoresMouseEvents == acceptsMouse { p.ignoresMouseEvents = !acceptsMouse }
    }

    @objc private func stopPressed(_ sender: Any?) {
        Log.info("overlay: Stop button pressed")
        stop()
    }

    private func stop() {
        isStopped = true
        showStoppedState()
        updateMousePassThrough()
        onStop?()
        onHideOrStop?()
        restartHideTimer()
    }

    /// "Stopped": grey static dot, disabled Stop capsule.
    private func showStoppedState() {
        label?.stringValue = OverlayTexts.stopped
        button?.isEnabled = false
        dot?.setActive(false)
        layoutContent()
        positionPanel()
    }

    /// Debug preview: show the panel as it looks for
    /// `appName`, optionally in its stopped state, without stopping anything.
    private func restartHideTimer() {
        hideTimer?.invalidate()
        let t = Timer(timeInterval: TurboProtocol.overlayIdleSeconds, repeats: false) { [weak self] _ in
            self?.hide()
        }
        RunLoop.main.add(t, forMode: .common)
        hideTimer = t
    }

    private func ensurePanel() {
        if panel != nil { return }
        typealias O = GlassDesign.Overlay
        let size = NSSize(width: 280, height: O.height)
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovable = false
        p.isReleasedWhenClosed = false
        p.ignoresMouseEvents = true  // see updateMousePassThrough()
        p.sharingType = .none
        p.title = "Computer Use"

        let glass = GlassSurfaceView(frame: NSRect(origin: .zero, size: size), cornerRadius: O.cornerRadius)
        let dotView = PulsingDotView(
            frame: NSRect(x: 0, y: 0, width: O.dotSize * O.haloMaxScale, height: O.dotSize * O.haloMaxScale))
        let iconView = roundedIconView(path: "", size: O.iconSize, radius: O.iconCornerRadius, label: "")
        let text = glassLabel(OverlayTexts.using("…"), size: O.fontSize, weight: O.fontWeight)
        text.setAccessibilityIdentifier("turboOverlayLabel")
        let stop = GlassStopButton(target: self, action: #selector(stopPressed(_:)))
        stop.setAccessibilityIdentifier("turboOverlayStop")
        for v in [dotView, iconView, text, stop] as [NSView] { glass.addSubview(v) }
        p.contentView = glass
        // Follow the system light / dark appearance live.
        GlassTheme.shared.register(glass)
        panel = p
        surface = glass
        dot = dotView
        icon = iconView
        label = text
        button = stop
    }

    private func setIcon(path: String, name: String) {
        guard let icon, path != iconPath else { return }
        iconPath = path
        let img = path.isEmpty ? NSImage(named: NSImage.applicationIconName) : NSWorkspace.shared.icon(forFile: path)
        img?.size = NSSize(width: GlassDesign.Overlay.iconSize, height: GlassDesign.Overlay.iconSize)
        icon.image = img
        icon.setAccessibilityLabel(name)
    }

    /// Lay out dot → icon → text → Stop left to right and size the capsule to fit.
    private func layoutContent() {
        guard let p = panel, let dot, let icon, let label, let button else { return }
        typealias O = GlassDesign.Overlay
        let h = O.height
        // The attributed string's own size (a label's intrinsic size can lag behind a new
        // string value); +4 for the cell's text insets.
        let textWidth = min(O.maxTextWidth, ceil(label.attributedStringValue.size().width) + 4)
        var x = O.paddingLeft
        // The dot view is larger than the dot (room for the halo); centre the dot at x + dotSize/2.
        dot.frame.origin = NSPoint(x: x + O.dotSize / 2 - dot.frame.width / 2, y: (h - dot.frame.height) / 2)
        x += O.dotSize + O.gapAfterDot
        icon.frame = NSRect(x: x, y: (h - O.iconSize) / 2, width: O.iconSize, height: O.iconSize)
        x += O.iconSize + O.gapAfterIcon
        let textHeight = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: x, y: (h - textHeight) / 2, width: textWidth, height: textHeight)
        x += textWidth + O.gapBeforeStop
        button.frame.origin = NSPoint(x: x, y: (h - button.frame.height) / 2)
        x += button.frame.width + O.paddingRight
        p.setContentSize(NSSize(width: x, height: h))
        surface?.frame = NSRect(x: 0, y: 0, width: x, height: h)
        p.invalidateShadow()
    }

    private func positionPanel() {
        guard let p = panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.maxX - p.frame.width - GlassDesign.Overlay.marginRight,
            y: visible.maxY - p.frame.height - GlassDesign.Overlay.marginTop)
        p.setFrameOrigin(origin)
    }
}

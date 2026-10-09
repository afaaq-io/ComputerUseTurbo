import AppKit
import TurboCore
import Foundation

enum ApprovalChoice: String {
    case once, session, deny
}

/// The confirmation card shown before the agent uses a password manager (the only app
/// kind that asks): a borderless glass card shown by the helper, so the model can never
/// approve its own access.
///
/// `ask` is called from a socket thread; the card runs modally on the main thread and
/// the caller blocks on a semaphore. A 120 s timer stops the modal session → deny.
///
/// Input safety: the model decides when this dialog appears, possibly while the user is
/// clicking or typing in another app. So the allow buttons stay disabled for the first
/// `armDelay` seconds, keyboard focus starts on "Don't Allow", and no allow button has
/// the Return key equivalent. Esc / "Don't Allow" work immediately.
final class ApprovalPrompter {
    /// Allow buttons ignore input for this long after the dialog appears.
    static let armDelay: TimeInterval = ApprovalTexts.armDelay

    private let stateLock = NSLock()
    private var showing = false

    var isShowing: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return showing
    }

    private func setShowing(_ v: Bool) {
        stateLock.lock()
        showing = v
        stateLock.unlock()
    }

    private final class Box: @unchecked Sendable { var choice: ApprovalChoice = .deny }

    func ask(appName: String, bundleId: String, appPath: String, timeout: TimeInterval) -> ApprovalChoice {
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        // Run the modal alert from a run-loop block, NOT from a DispatchQueue.main block:
        // a nested run loop started inside a main-queue callout does not drain the main
        // dispatch queue, so for up to 120 s nothing else on .main would run (overlay
        // updates from other sessions, System Settings panes, …).
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) {
            box.choice = self.runAlert(appName: appName, bundleId: bundleId, appPath: appPath, timeout: timeout)
            done.signal()
        }
        CFRunLoopWakeUp(main)  // the main run loop may be asleep
        // The modal timer guarantees completion; the extra margin only guards against a
        // wedged main thread.
        if done.wait(timeout: .now() + timeout + 15) == .timedOut {
            Log.error("approval: main thread did not answer in time; denying")
            return .deny
        }
        return box.choice
    }

    private func runAlert(appName: String, bundleId: String, appPath: String, timeout: TimeInterval) -> ApprovalChoice {
        setShowing(true)
        defer { setShowing(false) }
        let previous = NSWorkspace.shared.frontmostApplication

        let card = ApprovalCard(appName: appName, bundleId: bundleId, appPath: appPath)
        card.onChoice = { choice in NSApp.stopModal(withCode: ApprovalCard.response(for: choice)) }

        // The card needs key focus while it is up (keyboard access, Esc): activate the
        // helper; afterwards the front goes back to the user's app (below).
        NSApp.activate(ignoringOtherApps: true)
        card.show()

        let timer = Timer(timeInterval: timeout, repeats: false) { _ in
            Log.info("approval: timed out after \(Int(timeout))s")
            NSApp.stopModal(withCode: .abort)
        }
        // Disarmed until `armDelay` has passed: a click or keystroke meant for another app
        // must not land on an allow button that just appeared under it.
        let arm = Timer(timeInterval: Self.armDelay, repeats: false) { _ in card.arm() }
        // Focus "Don't allow" once the modal session runs (with Keyboard Navigation on,
        // Space presses the focused button).
        let focus = Timer(timeInterval: 0, repeats: false) { _ in card.focusDeny() }
        for t in [timer, arm, focus] { RunLoop.main.add(t, forMode: .modalPanel) }
        let started = Date()
        let response = NSApp.runModal(for: card.panel)
        for t in [timer, arm, focus] { t.invalidate() }
        card.close()

        let choice = ApprovalCard.choice(for: response)
        Log.info(
            "approval: \(bundleId.isEmpty ? LogText.peer(appName) : bundleId) → \(choice.rawValue) after \(String(format: "%.1f", Date().timeIntervalSince(started)))s"
        )
        // Hand focus back to whatever the user had in front before the dialog —
        // never to the target app. The helper is active right now, so it may yield.
        if let previous, previous.processIdentifier != getpid(), !previous.isTerminated {
            NSApp.yieldActivation(to: previous)
            if !previous.activate(options: []) {
                Log.info("approval: could not hand the front back to \(previous.bundleIdentifier ?? "?")")
            }
        }
        return choice
    }
}

/// The borderless glass approval card ("D · Glass card"; tokens in
/// `TurboCore/GlassDesign.swift`). Keyboard: focus starts on "Not now"; Tab cycles
/// "For this task" → "Just this once" → "Not now"; Esc = "Not now"; Return approves
/// nothing (no button has it as key equivalent).
final class ApprovalCard: NSObject {
    let panel: ApprovalPanel
    var onChoice: ((ApprovalChoice) -> Void)?
    private var allowButtons: [GlassCardButton] = []
    private var denyButton: GlassCardButton!

    static func response(for choice: ApprovalChoice) -> NSApplication.ModalResponse {
        switch choice {
        case .once: return .init(rawValue: 1101)
        case .session: return .init(rawValue: 1102)
        case .deny: return .init(rawValue: 1104)
        }
    }

    static func choice(for response: NSApplication.ModalResponse) -> ApprovalChoice {
        switch response.rawValue {
        case 1101: return .once
        case 1102: return .session
        default: return .deny  // Don't allow, Esc, timeout (.abort)
        }
    }

    init(appName: String, bundleId: String, appPath: String) {
        typealias A = GlassDesign.Approval
        panel = ApprovalPanel(
            contentRect: NSRect(x: 0, y: 0, width: A.width, height: 300), styleMask: [.borderless], backing: .buffered,
            defer: false)
        super.init()
        let inner = A.width - 2 * A.padding
        let content = FlippedView(frame: NSRect(x: 0, y: 0, width: A.width, height: 300))
        var y = A.padding

        // Header: icon + title / subtitle.
        let icon = roundedIconView(path: appPath, size: A.iconSize, radius: A.iconCornerRadius, label: "\(appName) icon")
        icon.frame.origin = NSPoint(x: A.padding, y: y)
        content.addSubview(icon)
        let textX = A.padding + A.iconSize + A.gapAfterIcon
        let textWidth = A.width - A.padding - textX
        let title = glassLabel(ApprovalTexts.title(appName), size: A.titleFontSize, weight: A.titleFontWeight, wraps: true)
        let titleHeight = Self.place(title, x: textX, y: 0, width: textWidth)
        let subtitle = glassLabel(ApprovalTexts.subtitle, size: A.subtitleFontSize, weight: 400, role: .secondary)
        let subtitleHeight = Self.place(subtitle, x: textX, y: 0, width: textWidth)
        let headerTextHeight = titleHeight + 2 + subtitleHeight
        let headerHeight = max(A.iconSize, headerTextHeight)
        let textTop = y + (headerHeight - headerTextHeight) / 2
        title.frame.origin.y = textTop
        subtitle.frame.origin.y = textTop + titleHeight + 2
        icon.frame.origin.y = y + (headerHeight - A.iconSize) / 2
        content.addSubview(title)
        content.addSubview(subtitle)
        y += headerHeight + A.sectionGap

        func addLine(_ text: String, size: Double, weight: Int = 400, role: GlassTextRole = .primary, indent: Double = 0) {
            let l = glassLabel(text, size: size, weight: weight, role: role, wraps: true)
            y += Self.place(l, x: A.padding + indent, y: y, width: inner - indent)
            content.addSubview(l)
        }

        addLine(ApprovalTexts.intro(), size: A.bodyFontSize, weight: 500)
        for bullet in ApprovalTexts.bullets(appName) {
            y += A.lineGap
            addLine("•  " + bullet, size: A.bodyFontSize, role: .secondary, indent: A.bulletIndent / 2)
        }
        y += A.lineGap + 4
        addLine("⚠︎  " + ApprovalTexts.sensitiveWarning(appName), size: A.warningFontSize, role: .warning)
        y += A.lineGap + 2
        let foot = bundleId.isEmpty ? ApprovalTexts.stopHint : "\(ApprovalTexts.stopHint)  (\(bundleId))"
        addLine(foot, size: A.footnoteFontSize, role: .tertiary)
        y += A.sectionGap

        // Buttons: primary, then Just this once, then Not now.
        let primary = GlassCardButton(title: ApprovalTexts.allowSession, style: .primary, target: self, action: #selector(allowSession(_:)))
        primary.frame = NSRect(x: A.padding, y: y, width: inner, height: A.buttonHeight)
        content.addSubview(primary)
        y += A.buttonHeight + A.buttonGap
        let once = GlassCardButton(title: ApprovalTexts.allowOnce, style: .glass, target: self, action: #selector(allowOnce(_:)))
        once.frame = NSRect(x: A.padding, y: y, width: inner, height: A.buttonHeight)
        content.addSubview(once)
        y += A.buttonHeight + A.buttonGap
        let deny = GlassCardButton(title: ApprovalTexts.deny, style: .text, target: self, action: #selector(denyPressed(_:)))
        deny.frame = NSRect(x: A.padding, y: y, width: inner, height: A.buttonHeight - 4)
        deny.keyEquivalent = "\u{1b}"  // Esc
        content.addSubview(deny)
        y += A.buttonHeight - 4 + A.padding

        allowButtons = [primary, once]
        denyButton = deny
        for b in allowButtons { b.isEnabled = false }
        // Tab order: primary → once → Don't allow → primary.
        let loop: [NSView] = allowButtons + [deny]
        for (i, v) in loop.enumerated() { v.nextKeyView = loop[(i + 1) % loop.count] }

        let height = y
        let glass = GlassSurfaceView(frame: NSRect(x: 0, y: 0, width: A.width, height: height), cornerRadius: A.cornerRadius)
        content.frame = glass.bounds
        content.autoresizingMask = [.width, .height]
        glass.addSubview(content)
        panel.setContentSize(NSSize(width: A.width, height: height))
        panel.contentView = glass
        panel.initialFirstResponder = deny
        panel.onCancel = { [weak self] in self?.choose(.deny) }
        panel.setAccessibilityLabel(ApprovalTexts.title(appName))
        panel.setAccessibilitySubrole(.dialog)
    }

    /// Size a wrapping label to `width` at (x, y); returns its height.
    private static func place(_ label: NSTextField, x: Double, y: Double, width: Double) -> Double {
        label.preferredMaxLayoutWidth = width
        let h = ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)).height ?? 16)
        label.frame = NSRect(x: x, y: y, width: width, height: h)
        return h
    }

    func show() {
        position()
        if let root = panel.contentView { GlassTheme.shared.register(root) }
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
    }

    /// Centred (slightly above) on the screen with the mouse, else the main screen.
    func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
        if let v = screen?.visibleFrame {
            let f = panel.frame
            panel.setFrameOrigin(NSPoint(x: (v.midX - f.width / 2).rounded(), y: (v.midY - f.height / 2 + v.height * 0.08).rounded()))
        }
    }

    func arm() { for b in allowButtons { b.isEnabled = true } }

    func focusDeny() { _ = panel.makeFirstResponder(denyButton) }

    func close() {
        if let root = panel.contentView { GlassTheme.shared.unregister(root) }
        panel.orderOut(nil)
    }

    private func choose(_ choice: ApprovalChoice) { onChoice?(choice) }

    @objc private func allowSession(_ sender: Any?) { choose(.session) }
    @objc private func allowOnce(_ sender: Any?) { choose(.once) }
    @objc private func denyPressed(_ sender: Any?) { choose(.deny) }
}

/// Borderless panel that can take key focus (borderless windows cannot by default) and
/// maps Esc / ⌘. to "Don't allow".
final class ApprovalPanel: NSPanel {
    var onCancel: (() -> Void)?

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backing, defer: flag)
        level = .modalPanel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        title = "Computer Use approval"
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Top-down layout container.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}


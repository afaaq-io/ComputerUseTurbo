import AppKit
import TurboCore
import QuartzCore

// AppKit rendering of the glass design tokens (TurboCore/GlassDesign.swift):
// the glass surface, the pulsing status dot, the overlay's Stop button and the
// approval card's buttons. Main thread only.

extension GlassColor {
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var cgColor: CGColor { nsColor.cgColor }
}

extension GlassShadow {
    var nsShadow: NSShadow {
        let s = NSShadow()
        s.shadowColor = color.nsColor
        // AppKit's y axis points up.
        s.shadowOffset = NSSize(width: offsetX, height: -offsetY)
        s.shadowBlurRadius = blur
        return s
    }
}

enum GlassFont {
    static func system(_ size: Double, weight: Int) -> NSFont {
        let w: NSFont.Weight
        switch weight {
        case ..<450: w = .regular
        case 450..<550: w = .medium
        case 550..<650: w = .semibold
        default: w = .bold
        }
        return .systemFont(ofSize: size, weight: w)
    }
}

/// A rounded glass surface: behind-window blur (`NSVisualEffectView`, `.hudWindow`), a
/// hairline white border and a faint highlight along the top edge. Used as a window's
/// content view; children go into it.
final class GlassSurfaceView: NSVisualEffectView, GlassThemable {
    private let highlight = CAGradientLayer()
    /// Palette tint over the blur (keeps text contrast independent of what is behind);
    /// becomes the opaque surface when transparency is reduced.
    private let tint = CALayer()
    private let cornerRadius: CGFloat

    init(frame: NSRect, cornerRadius: Double) {
        self.cornerRadius = cornerRadius
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        // The mask image gives the window its rounded shape (and its shadow).
        maskImage = Self.roundedMask(radius: cornerRadius)
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        layer?.borderWidth = GlassDesign.borderWidth
        // y-up layer space: start at the top edge.
        highlight.startPoint = CGPoint(x: 0.5, y: 1)
        highlight.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(tint)
        layer?.addSublayer(highlight)
        autoresizingMask = [.width, .height]
        applyPalette(GlassTheme.shared.palette, reduceTransparency: GlassTheme.shared.reduceTransparency)
    }

    func applyPalette(_ p: GlassPalette, reduceTransparency: Bool) {
        appearance = NSAppearance(named: p.appearance == .dark ? .darkAqua : .aqua)
        material = p.material == "popover" ? .popover : .hudWindow
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.borderColor = p.border.cgColor
        tint.backgroundColor = (reduceTransparency ? p.surfaceOpaque : p.surfaceTint).cgColor
        highlight.colors = [p.innerHighlight.cgColor, GlassColor.white(0).cgColor]
        highlight.isHidden = reduceTransparency
        CATransaction.commit()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let h = bounds.height * GlassDesign.highlightFraction
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.frame = CGRect(x: 0, y: bounds.height - h, width: bounds.width, height: h)
        tint.frame = bounds
        CATransaction.commit()
    }

    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// What a label shows; its colour comes from the current palette.
enum GlassTextRole {
    case primary, secondary, tertiary, warning, keycap, stop

    func color(in p: GlassPalette) -> GlassColor {
        switch self {
        case .primary: return p.textPrimary
        case .secondary: return p.textSecondary
        case .tertiary: return p.textTertiary
        case .warning: return p.warning
        case .keycap: return p.keycapText
        case .stop: return p.stopText
        }
    }
}

/// A label on glass, re-coloured with the system appearance.
final class GlassLabel: NSTextField, GlassThemable {
    var role: GlassTextRole = .primary

    func applyPalette(_ p: GlassPalette, reduceTransparency: Bool) {
        textColor = role.color(in: p).nsColor
        shadow = (role == .keycap) ? nil : p.textShadow?.nsShadow
    }
}

func glassLabel(_ text: String, size: Double, weight: Int, role: GlassTextRole = .primary, wraps: Bool = false)
    -> NSTextField
{
    let label = wraps ? GlassLabel(wrappingLabelWithString: text) : GlassLabel(labelWithString: text)
    if !wraps { label.lineBreakMode = .byTruncatingTail }
    label.role = role
    label.font = GlassFont.system(size, weight: weight)
    label.backgroundColor = .clear
    label.isSelectable = false
    label.applyPalette(GlassTheme.shared.palette, reduceTransparency: false)
    return label
}

/// App icon clipped to a rounded square.
func roundedIconView(path: String, size: Double, radius: Double, label: String) -> NSImageView {
    let view = NSImageView(frame: NSRect(x: 0, y: 0, width: size, height: size))
    let icon = path.isEmpty ? NSImage(named: NSImage.applicationIconName) : NSWorkspace.shared.icon(forFile: path)
    icon?.size = NSSize(width: size, height: size)
    view.image = icon
    view.imageScaling = .scaleProportionallyUpOrDown
    view.wantsLayer = true
    view.layer?.cornerRadius = radius
    view.layer?.masksToBounds = true
    view.setAccessibilityLabel(label)
    return view
}

/// The overlay's 8 pt clay status dot with a soft expanding halo (1.6 s loop).
final class PulsingDotView: NSView, GlassThemable {
    private let dot = CALayer()
    private let halo = CALayer()
    private var active = true
    private var palette = GlassTheme.shared.palette

    func applyPalette(_ p: GlassPalette, reduceTransparency: Bool) {
        palette = p
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.backgroundColor = (active ? p.dotActive : p.dotStopped).cgColor
        halo.backgroundColor = p.dotActive.cgColor
        CATransaction.commit()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        let d = GlassDesign.Overlay.dotSize
        for l in [halo, dot] {
            l.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            l.cornerRadius = d / 2
            l.position = CGPoint(x: frame.width / 2, y: frame.height / 2)
            l.backgroundColor = GlassDesign.Overlay.dotColor.cgColor
            layer?.addSublayer(l)
        }
        halo.opacity = 0
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setActive(_ active: Bool) {
        self.active = active
        applyPalette(palette, reduceTransparency: false)
        halo.removeAllAnimations()
        guard active else {
            halo.opacity = 0
            return
        }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = GlassDesign.Overlay.haloMaxScale
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = GlassDesign.Overlay.haloStartOpacity
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = GlassDesign.Overlay.haloPeriod
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        halo.add(group, forKey: "pulse")
    }
}

/// The overlay's capsule Stop button: red-tinted glass, a white rounded-square stop glyph,
/// "Stop" and an "esc" key-cap hint.
final class GlassStopButton: NSControl, GlassThemable {
    private let titleField: NSTextField
    private let keycap: NSTextField
    private let glyph = CALayer()
    private let cap = NSView()
    private var palette = GlassTheme.shared.palette
    private var pressed = false { didSet { updateColors() } }

    func applyPalette(_ p: GlassPalette, reduceTransparency: Bool) {
        palette = p
        updateColors()
    }

    init(target: AnyObject, action: Selector) {
        typealias S = GlassDesign.Overlay.Stop
        titleField = glassLabel(OverlayTexts.stop, size: S.fontSize, weight: S.fontWeight, role: .stop)
        keycap = glassLabel(OverlayTexts.escHint, size: S.keycapFontSize, weight: 500, role: .keycap)
        titleField.sizeToFit()
        keycap.sizeToFit()
        let keycapWidth = ceil(keycap.frame.width) + S.keycapPaddingX * 2
        let width =
            S.paddingLeft + S.glyphSize + S.gapAfterGlyph + ceil(titleField.frame.width) + S.gapBeforeKeycap + keycapWidth
            + S.paddingRight
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: S.height))
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.cornerRadius = S.cornerRadius
        layer?.borderWidth = 1

        glyph.frame = CGRect(x: S.paddingLeft, y: (S.height - S.glyphSize) / 2, width: S.glyphSize, height: S.glyphSize)
        glyph.cornerRadius = S.glyphCornerRadius
        layer?.addSublayer(glyph)

        var x = S.paddingLeft + S.glyphSize + S.gapAfterGlyph
        titleField.frame.origin = NSPoint(x: x, y: (S.height - titleField.frame.height) / 2)
        addSubview(titleField)
        x += ceil(titleField.frame.width) + S.gapBeforeKeycap
        cap.frame = NSRect(x: x, y: (S.height - S.keycapHeight) / 2, width: keycapWidth, height: S.keycapHeight)
        cap.wantsLayer = true
        cap.layer?.cornerRadius = S.keycapCornerRadius
        cap.layer?.borderWidth = 1
        keycap.frame.origin = NSPoint(x: S.keycapPaddingX, y: (S.keycapHeight - keycap.frame.height) / 2)
        cap.addSubview(keycap)
        addSubview(cap)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isEnabled: Bool {
        didSet { updateColors() }
    }

    private func updateColors() {
        typealias S = GlassDesign.Overlay.Stop
        let p = palette
        layer?.backgroundColor = (pressed ? p.stopFillPressed : p.stopFill).cgColor
        layer?.borderColor = p.stopBorder.cgColor
        glyph.backgroundColor = p.stopText.cgColor
        cap.layer?.borderColor = p.keycapBorder.cgColor
        alphaValue = isEnabled ? 1 : S.disabledOpacity
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
        // Track until mouse up; fire if released inside.
        while let e = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            let inside = bounds.contains(convert(e.locationInWindow, from: nil))
            pressed = inside
            if e.type == .leftMouseUp {
                pressed = false
                if inside { sendAction(action, to: target) }
                return
            }
        }
    }

    // Accessibility: a button named "Stop <agent> (Esc)".
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { OverlayTexts.stopAccessibilityLabel() }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        sendAction(action, to: target)
        return true
    }
}

/// A button of the approval card: filled clay (primary), glass, or plain text. A real
/// `NSButton` (Space / VoiceOver / Tab work), drawn by its layer; it is always in the key
/// view loop (Tab works without Full Keyboard Access) and draws a rounded focus ring.
final class GlassCardButton: NSButton, GlassThemable {
    enum Style { case primary, glass, text }
    let style: Style
    private var isPressed = false
    private var palette = GlassTheme.shared.palette

    func applyPalette(_ p: GlassPalette, reduceTransparency: Bool) {
        palette = p
        let color: GlassColor
        switch style {
        case .primary: color = p.primaryText
        case .glass: color = p.buttonText
        case .text: color = p.textButtonText
        }
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: GlassFont.system(GlassDesign.Approval.buttonFontSize, weight: style == .text ? 500 : 500),
                .foregroundColor: color.nsColor,
            ])
        updateColors()
    }

    init(title: String, style: Style, target: AnyObject, action: Selector) {
        self.style = style
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = GlassDesign.Approval.buttonCornerRadius
        focusRingType = .exterior
        setAccessibilityLabel(title)
        applyPalette(palette, reduceTransparency: false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var canBecomeKeyView: Bool { isEnabled }
    override var acceptsFirstResponder: Bool { isEnabled }

    override var isEnabled: Bool {
        didSet { updateColors() }
    }

    override func highlight(_ flag: Bool) {
        isPressed = flag
        updateColors()
    }

    private func updateColors() {
        typealias A = GlassDesign.Approval
        let p = palette
        switch style {
        case .primary:
            layer?.backgroundColor = p.primaryFill.nsColor.blended(withFraction: isPressed ? 0.15 : 0, of: .black)?.cgColor
            layer?.borderWidth = 0
        case .glass:
            layer?.backgroundColor = (isPressed ? p.buttonFillPressed : p.buttonFill).cgColor
            layer?.borderWidth = 1
            layer?.borderColor = p.buttonBorder.cgColor
        case .text:
            layer?.backgroundColor = (isPressed ? p.buttonFillPressed : p.textButtonFill).cgColor
            layer?.borderWidth = 0
        }
        alphaValue = isEnabled ? 1 : A.disabledOpacity
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        let r = GlassDesign.Approval.buttonCornerRadius
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
    }
}

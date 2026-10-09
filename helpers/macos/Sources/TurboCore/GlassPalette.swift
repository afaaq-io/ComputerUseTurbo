import Foundation

// Light / dark palettes of the glass UI, read from
// `shared/design-tokens.json` — the same file the Windows / Linux helper reads. They follow the
// system appearance: Aqua / Dark Aqua, "Reduce transparency" → `surfaceOpaque`, "Increase
// contrast" → `increasedContrast()`. Every text colour meets WCAG contrast ≥ 4.5:1 on the glass.

public enum GlassAppearance: String, Sendable, CaseIterable {
    case light, dark
}

public struct GlassPalette: Equatable, Sendable {
    public var appearance: GlassAppearance
    /// macOS material name for the blur ("popover" light, "hudWindow" dark).
    public var material: String
    /// Translucent tint drawn over the blur so text contrast does not depend on what is behind.
    public var surfaceTint: GlassColor
    /// Solid surface when transparency is reduced / unavailable.
    public var surfaceOpaque: GlassColor
    public var border: GlassColor
    public var innerHighlight: GlassColor
    public var textPrimary: GlassColor
    public var textSecondary: GlassColor
    public var textTertiary: GlassColor
    /// Soft text shadow (dark palette only; nil = none).
    public var textShadow: GlassShadow?
    public var warning: GlassColor
    public var dotActive: GlassColor
    public var dotStopped: GlassColor
    public var stopFill: GlassColor
    public var stopFillPressed: GlassColor
    public var stopBorder: GlassColor
    public var stopText: GlassColor
    public var keycapBorder: GlassColor
    public var keycapText: GlassColor
    public var primaryFill: GlassColor
    public var primaryText: GlassColor
    public var buttonFill: GlassColor
    public var buttonFillPressed: GlassColor
    public var buttonBorder: GlassColor
    public var buttonText: GlassColor
    public var textButtonFill: GlassColor
    public var textButtonText: GlassColor
    public var focusRing: GlassColor
    /// Live preview chrome.
    public var previewBackground: GlassColor
    public var previewPlaceholder: GlassColor

    public static let light = load(.light)
    public static let dark = load(.dark)

    /// One palette from the design tokens file (bundled with the app, or `shared/` in a
    /// development build). The app cannot draw its UI without it, so a missing file is fatal.
    static func load(_ appearance: GlassAppearance, sourceFile: String = #filePath) -> GlassPalette {
        guard let data = TurboPaths.sharedFileCandidates("design-tokens.json", sourceFile: sourceFile).lazy
                .compactMap({ try? Data(contentsOf: $0) }).first,
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let t = root[appearance.rawValue] as? [String: Any]
        else { fatalError("design-tokens.json is missing or invalid") }
        func c(_ key: String) -> GlassColor {
            let v = t[key] as? [String: Double] ?? [:]
            return GlassColor(v["r"] ?? 0, v["g"] ?? 0, v["b"] ?? 0, v["a"] ?? 1)
        }
        return GlassPalette(
            appearance: appearance, material: t["material"] as? String ?? "popover",
            surfaceTint: c("surfaceTint"), surfaceOpaque: c("surfaceOpaque"), border: c("border"),
            innerHighlight: c("innerHighlight"), textPrimary: c("textPrimary"), textSecondary: c("textSecondary"),
            textTertiary: c("textTertiary"),
            // A soft shadow keeps light text readable on the dark glass.
            textShadow: appearance == .dark ? GlassShadow(color: .black(0.35), offsetX: 0, offsetY: 1, blur: 2) : nil,
            warning: c("warning"), dotActive: c("dotActive"), dotStopped: c("dotStopped"), stopFill: c("stopFill"),
            stopFillPressed: c("stopFillPressed"), stopBorder: c("stopBorder"), stopText: c("stopText"),
            keycapBorder: c("keycapBorder"), keycapText: c("keycapText"), primaryFill: c("primaryFill"),
            primaryText: c("primaryText"), buttonFill: c("buttonFill"), buttonFillPressed: c("buttonFillPressed"),
            buttonBorder: c("buttonBorder"), buttonText: c("buttonText"), textButtonFill: c("textButtonFill"),
            textButtonText: c("textButtonText"), focusRing: c("focusRing"), previewBackground: c("previewBackground"),
            previewPlaceholder: c("previewPlaceholder"))
    }

    public static func forAppearance(_ a: GlassAppearance, increaseContrast: Bool = false) -> GlassPalette {
        let p = a == .light ? light : dark
        return increaseContrast ? p.increasedContrast() : p
    }

    /// "Increase contrast": stronger borders, secondary/tertiary text promoted one step.
    public func increasedContrast() -> GlassPalette {
        var p = self
        p.border = border.withAlpha(min(1, border.alpha * 2.5))
        p.buttonBorder = buttonBorder.withAlpha(min(1, buttonBorder.alpha * 2.5))
        p.stopBorder = stopBorder.withAlpha(min(1, stopBorder.alpha * 1.8))
        p.keycapBorder = keycapBorder.withAlpha(min(1, keycapBorder.alpha * 1.8))
        p.textTertiary = textSecondary
        p.textSecondary = textPrimary
        p.textButtonText = textPrimary
        p.surfaceTint = surfaceTint.withAlpha(min(1, surfaceTint.alpha + 0.2))
        return p
    }
}

public extension GlassColor {
    init(srgbRed r: Double, green g: Double, blue b: Double, alpha a: Double) { self.init(r, g, b, a) }

    func withAlpha(_ a: Double) -> GlassColor { GlassColor(red, green, blue, a) }
}

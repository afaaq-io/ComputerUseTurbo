import Foundation

// Platform-neutral visual spec of the helper's own UI: the status
// overlay ("A · Light glass pill") and the approval card ("D · Glass card").
// Plain numbers and strings only — no AppKit — so a Windows / Linux helper can
// draw the same design from the same tokens. Sizes are points; colours are sRGB 0–1.

public struct GlassColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `0xRRGGBB` plus alpha.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(
            Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255, alpha)
    }

    /// 0–255 channels plus alpha (CSS `rgba()`).
    public static func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> GlassColor {
        GlassColor(r / 255, g / 255, b / 255, a)
    }

    public static func white(_ alpha: Double) -> GlassColor { GlassColor(1, 1, 1, alpha) }
    public static func black(_ alpha: Double) -> GlassColor { GlassColor(0, 0, 0, alpha) }
}

public struct GlassShadow: Equatable, Sendable {
    public var color: GlassColor
    /// Offset in points, y down (CSS convention).
    public var offsetX: Double
    public var offsetY: Double
    public var blur: Double
}

public enum GlassDesign {
    /// Accent (clay).
    public static let clay = GlassColor(hex: 0xD97757)
    /// Warning amber (sensitive line).
    public static let amber = GlassColor(hex: 0xF5B041)
    /// Hairline border of every glass surface.
    public static let border = GlassColor.white(0.28)
    public static let borderWidth: Double = 1
    /// The faint inner highlight along the top edge of a glass surface (a vertical
    /// gradient from this colour to clear over `highlightFraction` of the height).
    public static let innerHighlight = GlassColor.white(0.16)
    public static let highlightFraction: Double = 0.5
    /// Text on glass: white, with a soft shadow so it stays legible over light content.
    public static let text = GlassColor.white(0.96)
    public static let textShadow = GlassShadow(color: .black(0.35), offsetX: 0, offsetY: 1, blur: 2)

    // MARK: Status overlay — "A · Light glass pill"

    public enum Overlay {
        public static let height: Double = 38
        /// Fully rounded capsule.
        public static var cornerRadius: Double { height / 2 }
        public static let paddingLeft: Double = 14
        public static let paddingRight: Double = 7
        /// Gaps between dot → icon → text → Stop button.
        public static let gapAfterDot: Double = 10
        public static let gapAfterIcon: Double = 8
        public static let gapBeforeStop: Double = 12
        /// Distance from the top-right corner of the main screen's visible frame.
        public static let marginTop: Double = 12
        public static let marginRight: Double = 16
        public static let maxTextWidth: Double = 240

        public static let dotSize: Double = 8
        public static let dotColor = clay
        /// Soft expanding halo around the dot: scale 1 → `haloMaxScale`, opacity
        /// `haloStartOpacity` → 0, ease-out, repeating every `haloPeriod` seconds.
        public static let haloPeriod: Double = 1.6
        public static let haloMaxScale: Double = 2.6
        public static let haloStartOpacity: Double = 0.55

        public static let iconSize: Double = 22
        public static let iconCornerRadius: Double = 6

        public static let fontSize: Double = 13
        /// CSS-style weight (500 = medium).
        public static let fontWeight = 500

        public enum Stop {
            public static let height: Double = 26
            public static var cornerRadius: Double { height / 2 }
            public static let paddingLeft: Double = 9
            public static let paddingRight: Double = 6
            public static let fill = GlassColor.rgba(255, 80, 80, 0.22)
            public static let border = GlassColor.rgba(255, 120, 120, 0.45)
            public static let glyphSize: Double = 8
            public static let glyphCornerRadius: Double = 2
            public static let gapAfterGlyph: Double = 5
            public static let fontSize: Double = 12
            public static let fontWeight = 600
            public static let gapBeforeKeycap: Double = 6
            /// The "esc" key-cap hint.
            public static let keycapFontSize: Double = 9.5
            public static let keycapHeight: Double = 15
            public static let keycapPaddingX: Double = 4
            public static let keycapCornerRadius: Double = 4
            public static let keycapBorder = GlassColor.white(0.45)
            public static let keycapText = GlassColor.white(0.8)
            /// Whole button when disabled (after Stop).
            public static let disabledOpacity: Double = 0.4
        }
    }

    // MARK: Approval card — "D · Glass card"

    public enum Approval {
        public static let width: Double = 320
        public static let padding: Double = 20
        public static let cornerRadius: Double = 22
        public static let shadow = GlassShadow(color: .black(0.35), offsetX: 0, offsetY: 12, blur: 40)

        public static let iconSize: Double = 44
        public static let iconCornerRadius: Double = 12
        public static let gapAfterIcon: Double = 12
        public static let titleFontSize: Double = 15
        public static let titleFontWeight = 500
        public static let subtitleFontSize: Double = 12
        /// Header → body, body lines, body → buttons.
        public static let sectionGap: Double = 16
        public static let lineGap: Double = 6
        public static let bodyFontSize: Double = 13
        public static let bulletIndent: Double = 14
        public static let footnoteFontSize: Double = 11
        public static let warningFontSize: Double = 12

        public static let buttonHeight: Double = 34
        public static let buttonCornerRadius: Double = 10
        public static let buttonGap: Double = 8
        public static let buttonFontSize: Double = 13
        public static let primaryFill = clay
        public static let primaryText = GlassColor.white(1)
        /// Allow buttons while disarmed (the first `ApprovalTexts.armDelay` seconds).
        public static let disabledOpacity: Double = 0.45
        /// Keyboard focus ring.
        public static let focusRing = GlassColor.white(0.85)
    }
}

/// User-facing strings of the overlay and the approval card (steps 6–7). `agent` is the
/// driving agent's display name (`AgentRegistry`); it is never a built-in name.
public enum OverlayTexts {
    public static func using(_ app: String, agent: String = AgentRegistry.shared.current.name) -> String {
        "\(agent) is working in \(app)"
    }
    public static let stopped = "Stopped"
    public static let stop = "Stop"
    public static let escHint = "esc"
    public static func stopAccessibilityLabel(agent: String = AgentRegistry.shared.current.name) -> String {
        "Stop \(agent) (Esc)"
    }
}

public enum ApprovalTexts {
    /// Allow buttons ignore input for this long after the card appears.
    public static let armDelay: TimeInterval = 0.75

    public static func title(_ app: String, agent: String = AgentRegistry.shared.current.name) -> String {
        "Let \(agent) control \(app)?"
    }
    public static let subtitle = "Requested for this task"
    public static func intro(agent: String = AgentRegistry.shared.current.name) -> String {
        "\(agent) will be able to:"
    }
    public static func bullets(_ app: String) -> [String] {
        ["See \(app)'s window and what it shows", "Click, type and scroll in it, without taking over your screen"]
    }
    public static func sensitiveWarning(_ app: String, agent: String = AgentRegistry.shared.current.name) -> String {
        "\(app) holds passwords or other credentials. \(agent) could see secrets shown in it, and text inside it could try to steer \(agent) (prompt injection). Continue only if you started this task and trust it."
    }
    public static let stopHint = "Stop anytime with the Stop button or Esc."
    public static let allowSession = "For this task"
    public static let allowOnce = "Just this once"
    public static let deny = "Not now"
}

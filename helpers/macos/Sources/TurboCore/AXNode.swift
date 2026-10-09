import Foundation

/// A scalar accessibility value (`AXValue`) the serializer knows how to print.
public enum AXNodeValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)

    /// Text form used in `value="…"`. Integral numbers print without a fraction.
    public var text: String {
        switch self {
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .number(let d):
            if d.isFinite, d.rounded() == d, abs(d) < 1e15 { return String(Int64(d)) }
            return String(d)
        }
    }

    /// Whether this value means "on" for a checkbox / radio button.
    public var isOn: Bool {
        switch self {
        case .number(let d): return d == 1
        case .bool(let b): return b
        case .string(let s): return s == "1"
        }
    }
}

/// A plain snapshot of one accessibility element. The helper builds a tree of these from
/// live `AXUIElement`s; everything downstream (pruning, indices, text, diff) is pure.
public struct AXNode: Equatable, Sendable {
    /// `AXRole`, e.g. `AXButton`.
    public var role: String
    public var subrole: String?
    public var title: String?
    public var description: String?
    public var labelValue: String?
    public var placeholder: String?
    public var identifier: String?
    /// `AXDocument` of a window (the file it shows), read for windows only. A `file:`
    /// URL becomes the window's path-key label (see `TreeSerializer.stableLabel`).
    public var document: String?
    /// Never populated for secure text fields.
    public var value: AXNodeValue?
    /// `AXValue` is settable → `editable`.
    public var isValueSettable: Bool
    /// `AXEnabled`; `nil` when the element doesn't expose it.
    public var isEnabled: Bool?
    public var isFocused: Bool
    public var isSelected: Bool
    public var isExpanded: Bool
    /// Raw AX action names (`AXPress`, `AXIncrement`, …).
    public var actions: [String]
    public var children: [AXNode]
    /// Opaque handle the helper uses to map back to the live element (-1 = none).
    public var handle: Int
    /// `AXURL` of a link (rendered Markdown-style, shortened).
    public var url: String?
    /// A large table / list / outline whose rows were cut to the visible ones.
    public var rowSubset: RowSubset?
    /// A window outside the observation scope (not the key window or one of its
    /// sheets / popovers): listed as one summary line, its contents not read.
    public var isSummaryOnly: Bool = false
    /// On-screen frame (global points) when known: elements entirely outside the visible
    /// part of their scroll area / page / window are left out of the text.
    public var frame: NodeFrame?
    /// A surface that is not a window (Finder's desktop), listed as one line.
    public var isSurface = false

    public init(
        role: String, subrole: String? = nil, title: String? = nil, description: String? = nil,
        labelValue: String? = nil, placeholder: String? = nil, identifier: String? = nil,
        document: String? = nil, value: AXNodeValue? = nil, isValueSettable: Bool = false, isEnabled: Bool? = nil,
        isFocused: Bool = false, isSelected: Bool = false, isExpanded: Bool = false,
        actions: [String] = [], children: [AXNode] = [], handle: Int = -1
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.description = description
        self.labelValue = labelValue
        self.placeholder = placeholder
        self.identifier = identifier
        self.document = document
        self.value = value
        self.isValueSettable = isValueSettable
        self.isEnabled = isEnabled
        self.isFocused = isFocused
        self.isSelected = isSelected
        self.isExpanded = isExpanded
        self.actions = actions
        self.children = children
        self.handle = handle
    }

    /// Password fields: role or subrole `AXSecureTextField`.
    public var isSecure: Bool {
        role == AXRoles.secureTextField || subrole == AXRoles.secureTextField
    }

    /// Total number of nodes in this subtree (including self).
    public var subtreeCount: Int {
        1 + children.reduce(0) { $0 + $1.subtreeCount }
    }
}

/// A screen rectangle (points), kept free of CoreGraphics so the logic stays pure.
public struct NodeFrame: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var hasArea: Bool { width > 0.5 && height > 0.5 }

    public func intersects(_ o: NodeFrame) -> Bool {
        x < o.x + o.width && o.x < x + width && y < o.y + o.height && o.y < y + height
    }

    /// Whether a meaningful part (at least 2 × 2 points) lies inside `area`. Some toolkits
    /// (Chromium) report content scrolled out of view squeezed into a 1-point strip on the
    /// edge of the visible area: that is not visible.
    public func showsIn(_ area: NodeFrame) -> Bool {
        guard let i = intersection(area) else { return false }
        return i.width >= 2 && i.height >= 2
    }

    public func intersection(_ o: NodeFrame) -> NodeFrame? {
        let x0 = max(x, o.x), y0 = max(y, o.y)
        let x1 = min(x + width, o.x + o.width), y1 = min(y + height, o.y + o.height)
        guard x1 > x0, y1 > y0 else { return nil }
        return NodeFrame(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

/// Rows of a large table / list / outline that the reader limited to the visible ones.
public struct RowSubset: Equatable, Sendable {
    /// Rows listed (the visible ones).
    public var shown: Int
    /// All rows (`AXRows` / children count).
    public var total: Int
    /// 1-based position of the first visible row, when known (`AXIndex`).
    public var firstRow: Int?

    public init(shown: Int, total: Int, firstRow: Int? = nil) {
        self.shown = shown
        self.total = total
        self.firstRow = firstRow
    }

    /// `(rows 41–58 of 1200 shown; 1182 more rows hidden; scroll to see them)`.
    public var note: String {
        let hidden = max(0, total - shown)
        let range: String
        if let f = firstRow, shown > 0 { range = "rows \(f)–\(f + shown - 1) of \(total) shown" } else { range = "\(shown) of \(total) rows shown" }
        return "(\(range); \(hidden) more rows hidden; scroll to see them)"
    }

    /// Lists with more children than this are cut to their visible rows.
    public static let threshold = 50
}

/// Role / action names used by the pure logic (mirrors the AX constants without importing AX).
public enum AXRoles {
    public static let window = "AXWindow"
    public static let menuBar = "AXMenuBar"
    public static let menuBarItem = "AXMenuBarItem"
    public static let menu = "AXMenu"
    public static let menuItem = "AXMenuItem"
    public static let checkBox = "AXCheckBox"
    public static let radioButton = "AXRadioButton"
    public static let secureTextField = "AXSecureTextField"
    public static let scrollArea = "AXScrollArea"
    public static let scrollBar = "AXScrollBar"
    public static let column = "AXColumn"
    public static let staticText = "AXStaticText"
    public static let link = "AXLink"
    public static let row = "AXRow"

    /// Pure container roles that may be pruned.
    public static let prunableContainers: Set<String> = [
        "AXCell",
        "AXGroup", "AXSplitGroup", "AXLayoutArea", "AXUnknown", "AXScrollArea", "AXGenericElement",
    ]

    /// Actions hidden from `actions=`.
    public static let hiddenActions: Set<String> = ["AXPress", "AXShowMenu", "AXScrollToVisible"]
    /// Actions that do not make an element "actionable" for pruning purposes.
    public static let passiveActions: Set<String> = ["AXShowMenu", "AXScrollToVisible"]

}

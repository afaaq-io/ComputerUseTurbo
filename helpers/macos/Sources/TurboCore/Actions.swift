import Foundation

/// Where a click/scroll lands: an element index from the latest tree, or a point in
/// screenshot pixel coordinates (= window-relative points).
public enum ActionTarget: Equatable, Sendable {
    case element(Int)
    case point(x: Double, y: Double)
}

public enum MouseButton: String, Sendable { case left, right, middle }
public enum ScrollDirection: String, Sendable { case up, down, left, right }

/// The `action` payload, validated.
public enum TurboAction: Equatable, Sendable {
    case click(target: ActionTarget, button: MouseButton, clickTimes: Int)
    case scroll(target: ActionTarget, direction: ScrollDirection, pages: Double)
    case drag(startX: Double, startY: Double, endX: Double, endY: Double)
    case writeText(text: String, elementNumber: Int?)
    case sendKeys(key: String)
    case fillValue(elementNumber: Int, value: String)
    case pickText(elementNumber: Int, text: String, prefix: String?, suffix: String?, selection: TextSelectionMode)
    case invokeAction(elementNumber: Int, action: String)
    /// Put `text` on the pasteboard (as `format`), press ⌘V, restore the pasteboard.
    case paste(text: String, format: PasteFormat)
    /// Press the menu command at `path` (menu bar title first), found live by title.
    case runCommand(path: [String])

    /// The `type` tag.
    public var typeName: String {
        switch self {
        case .click: return "clickAt"
        case .scroll: return "scrollView"
        case .drag: return "dragItem"
        case .writeText: return "writeText"
        case .sendKeys: return "sendKeys"
        case .fillValue: return "fillValue"
        case .pickText: return "pickText"
        case .invokeAction: return "invokeAction"
        case .paste: return "pasteText"
        case .runCommand: return "runCommand"
        }
    }

    /// Element index referenced by the action, if any.
    public var elementNumber: Int? {
        switch self {
        case .click(let t, _, _), .scroll(let t, _, _):
            if case .element(let i) = t { return i }
            return nil
        case .writeText(_, let i): return i
        case .fillValue(let i, _), .pickText(let i, _, _, _, _), .invokeAction(let i, _): return i
        case .drag, .sendKeys, .paste, .runCommand: return nil
        }
    }

    /// Parse and validate. Malformed fields → `4017 badArguments`; an unknown
    /// `type` → `4019 notSupported`.
    public static func parse(_ value: JSONValue?) throws -> TurboAction {
        guard let value, case .object(let o) = value else {
            throw TurboError.invalid("payload.step must be an object with a \"type\" field")
        }
        guard let type = o["type"]?.stringValue else {
            throw TurboError.invalid("payload.step.type must be a string")
        }
        switch type {
        case "clickAt":
            let target = try parseTarget(o)
            let button = try parseEnum(o, "button", default: MouseButton.left)
            let count = try optionalInt(o, "clickTimes") ?? 1
            guard (1...3).contains(count) else { throw TurboError.invalid("clickTimes must be 1, 2 or 3") }
            return .click(target: target, button: button, clickTimes: count)
        case "scrollView":
            let target = try parseTarget(o)
            guard o["direction"] != nil else { throw TurboError.invalid("scroll requires direction (up/down/left/right)") }
            let direction = try parseEnum(o, "direction", default: ScrollDirection.down)
            let pages = try optionalNumber(o, "pages") ?? 1
            guard pages >= 0.1 && pages <= 20 else { throw TurboError.invalid("pages must be between 0.1 and 20") }
            return .scroll(target: target, direction: direction, pages: pages)
        case "dragItem":
            let fx = try requiredCoordinate(o, "startX")
            let fy = try requiredCoordinate(o, "startY")
            let tx = try requiredCoordinate(o, "endX")
            let ty = try requiredCoordinate(o, "endY")
            return .drag(startX: fx, startY: fy, endX: tx, endY: ty)
        case "writeText":
            guard let text = o["text"]?.stringValue else { throw TurboError.invalid("writeText requires a string text") }
            guard !text.isEmpty else { throw TurboError.invalid("writeText text must not be empty") }
            return .writeText(text: text, elementNumber: try optionalIndex(o, "elementNumber"))
        case "sendKeys":
            guard let key = o["key"]?.stringValue, !key.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw TurboError.invalid("sendKeys requires a non-empty key chord")
            }
            return .sendKeys(key: key)
        case "fillValue":
            let index = try requiredIndex(o, "elementNumber")
            let value: String
            switch o["value"] {
            case .some(.string(let s)): value = s
            case .some(.int(let i)): value = String(i)
            case .some(.double(let d)): value = AXNodeValue.number(d).text
            case .some(.bool(let b)): value = b ? "1" : "0"
            default: throw TurboError.invalid("fillValue requires a string value")
            }
            return .fillValue(elementNumber: index, value: value)
        case "pickText":
            let index = try requiredIndex(o, "elementNumber")
            guard let text = o["text"]?.stringValue, !text.isEmpty else {
                throw TurboError.invalid("pickText requires a non-empty text")
            }
            let prefix = try optionalString(o, "prefix")
            let suffix = try optionalString(o, "suffix")
            let selection = try parseEnum(o, "selection", default: TextSelectionMode.text)
            return .pickText(elementNumber: index, text: text, prefix: prefix, suffix: suffix, selection: selection)
        case "invokeAction":
            let index = try requiredIndex(o, "elementNumber")
            guard let action = o["name"]?.stringValue, !action.isEmpty else {
                throw TurboError.invalid("invokeAction requires an action name")
            }
            return .invokeAction(elementNumber: index, action: action)
        case "pasteText":
            guard let text = o["text"]?.stringValue, !text.isEmpty else {
                throw TurboError.invalid("paste requires a non-empty text")
            }
            guard let format = PasteFormat.parse(present(o, "format")?.stringValue) else {
                throw TurboError.invalid("paste format must be text, markdown or html")
            }
            if present(o, "format") != nil, o["format"]?.stringValue == nil {
                throw TurboError.invalid("paste format must be a string")
            }
            return .paste(text: text, format: format)
        case "runCommand":
            return .runCommand(path: try MenuTitle.validatePath(o["path"]))
        default:
            throw TurboError(
                .notSupported,
                "Unsupported action type \"\(type)\". Supported: clickAt, scrollView, dragItem, writeText, sendKeys, fillValue, pickText, invokeAction, pasteText, runCommand."
            )
        }
    }

    // MARK: field helpers

    private static func present(_ o: [String: JSONValue], _ key: String) -> JSONValue? {
        guard let v = o[key], !v.isNull else { return nil }
        return v
    }

    private static func parseTarget(_ o: [String: JSONValue]) throws -> ActionTarget {
        let index = try optionalIndex(o, "elementNumber")
        let hasX = present(o, "x") != nil
        let hasY = present(o, "y") != nil
        if let index {
            guard !hasX && !hasY else {
                throw TurboError.invalid("Provide either elementNumber or x and y, not both")
            }
            return .element(index)
        }
        guard hasX && hasY else {
            throw TurboError.invalid("Provide either elementNumber or both x and y")
        }
        return .point(x: try requiredCoordinate(o, "x"), y: try requiredCoordinate(o, "y"))
    }

    private static func optionalIndex(_ o: [String: JSONValue], _ key: String) throws -> Int? {
        guard let v = present(o, key) else { return nil }
        // Tolerate a stringified index ("12") as well as a number.
        if let s = v.stringValue, let i = Int(s.trimmingCharacters(in: .whitespaces)), i >= 0 { return i }
        guard let i = v.intValue, i >= 0 else { throw TurboError.invalid("\(key) must be a non-negative integer") }
        return i
    }

    private static func requiredIndex(_ o: [String: JSONValue], _ key: String) throws -> Int {
        guard let i = try optionalIndex(o, key) else { throw TurboError.invalid("\(key) is required") }
        return i
    }

    private static func optionalInt(_ o: [String: JSONValue], _ key: String) throws -> Int? {
        guard let v = present(o, key) else { return nil }
        guard let i = v.intValue else { throw TurboError.invalid("\(key) must be an integer") }
        return i
    }

    private static func optionalNumber(_ o: [String: JSONValue], _ key: String) throws -> Double? {
        guard let v = present(o, key) else { return nil }
        guard let d = v.doubleValue, d.isFinite else { throw TurboError.invalid("\(key) must be a number") }
        return d
    }

    private static func requiredCoordinate(_ o: [String: JSONValue], _ key: String) throws -> Double {
        guard let d = try optionalNumber(o, key) else { throw TurboError.invalid("\(key) is required") }
        guard d >= 0 else { throw TurboError.invalid("\(key) must be >= 0 (screenshot pixel coordinates)") }
        return d
    }

    private static func optionalString(_ o: [String: JSONValue], _ key: String) throws -> String? {
        guard let v = present(o, key) else { return nil }
        guard let s = v.stringValue else { throw TurboError.invalid("\(key) must be a string") }
        return s
    }

    private static func parseEnum<E: RawRepresentable>(_ o: [String: JSONValue], _ key: String, default def: E) throws
        -> E where E.RawValue == String
    {
        guard let v = present(o, key) else { return def }
        guard let s = v.stringValue, let e = E(rawValue: s.lowercased()) else {
            throw TurboError.invalid("Invalid \(key) \(v)")
        }
        return e
    }
}

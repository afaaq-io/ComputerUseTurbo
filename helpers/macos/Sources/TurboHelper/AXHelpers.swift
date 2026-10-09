import ApplicationServices
import TurboCore
import Foundation

/// Thin, typed wrappers over the C Accessibility API.
enum AX {
    /// Per-call messaging timeout: applied globally at startup and to
    /// every application element we create.
    static let messagingTimeout: Float = 1.0

    static func configureGlobalTimeout() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)
    }

    static func application(_ pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, messagingTimeout)
        return el
    }

    // MARK: attributes

    static func copy(_ el: AXUIElement, _ attribute: String) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, attribute as CFString, &value)
        return (err, value)
    }

    static func value(_ el: AXUIElement, _ attribute: String) -> CFTypeRef? {
        let (err, v) = copy(el, attribute)
        return err == .success ? v : nil
    }

    static func string(_ el: AXUIElement, _ attribute: String) -> String? {
        stringValue(value(el, attribute))
    }

    static func bool(_ el: AXUIElement, _ attribute: String) -> Bool? {
        boolValue(value(el, attribute))
    }

    static func element(_ el: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let v = value(el, attribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func elements(_ el: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        guard let v = value(el, attribute) else { return nil }
        return elementArray(v)
    }

    /// AXPosition in global top-left-origin points. The value comes from the target app,
    /// so NaN / infinite / absurd values are treated as "no position" (they would trap
    /// in `Int(_:)` further down).
    static func point(_ el: AXUIElement, _ attribute: String = kAXPositionAttribute) -> CGPoint? {
        guard let v = value(el, attribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        guard AXValueGetValue(v as! AXValue, .cgPoint, &p) else { return nil }
        return GeometryGuard.sanePoint(p)
    }

    /// AXSize; non-finite, negative or absurd sizes are treated as "no size".
    static func size(_ el: AXUIElement, _ attribute: String = kAXSizeAttribute) -> CGSize? {
        guard let v = value(el, attribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        guard AXValueGetValue(v as! AXValue, .cgSize, &s) else { return nil }
        return GeometryGuard.saneSize(s)
    }

    /// Frame in global top-left-origin points.
    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = point(el), let s = size(el) else { return nil }
        return CGRect(origin: p, size: s)
    }

    static func isSettable(_ el: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        let err = AXUIElementIsAttributeSettable(el, attribute as CFString, &settable)
        return err == .success && settable.boolValue
    }

    static func actions(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success, let names else { return [] }
        return (names as? [String]) ?? []
    }

    @discardableResult
    static func set(_ el: AXUIElement, _ attribute: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(el, attribute as CFString, value)
    }

    @discardableResult
    static func perform(_ el: AXUIElement, _ action: String) -> AXError {
        AXUIElementPerformAction(el, action as CFString)
    }

    static func pid(_ el: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(el, &pid) == .success ? pid : nil
    }

    /// Cheap liveness check: `kAXErrorInvalidUIElement` means the element is gone.
    static func isValid(_ el: AXUIElement) -> Bool {
        let (err, _) = copy(el, kAXRoleAttribute)
        return err != .invalidUIElement
    }

    /// Fetch several attributes in one IPC round trip. Missing attributes are absent.
    static func multiple(_ el: AXUIElement, _ attributes: [String]) -> (AXError, [String: CFTypeRef]) {
        var values: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(
            el, attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        guard err == .success, let values else { return (err, [:]) }
        var out: [String: CFTypeRef] = [:]
        let count = CFArrayGetCount(values)
        for i in 0..<min(count, attributes.count) {
            guard let raw = CFArrayGetValueAtIndex(values, i) else { continue }
            let v = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
            if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError { continue }
            if CFGetTypeID(v) == CFNullGetTypeID() { continue }
            out[attributes[i]] = v
        }
        return (.success, out)
    }

    // MARK: CF → Swift conversions

    static func stringValue(_ v: CFTypeRef?) -> String? {
        guard let v else { return nil }
        if CFGetTypeID(v) == CFStringGetTypeID() { return (v as! CFString) as String }
        if CFGetTypeID(v) == CFAttributedStringGetTypeID() {
            return CFAttributedStringGetString((v as! CFAttributedString)) as String
        }
        return nil
    }

    /// CFURL (or string) → absolute string.
    static func urlString(_ v: CFTypeRef?) -> String? {
        guard let v else { return nil }
        if CFGetTypeID(v) == CFURLGetTypeID() { return CFURLGetString((v as! CFURL)) as String }
        return stringValue(v)
    }

    static func boolValue(_ v: CFTypeRef?) -> Bool? {
        guard let v else { return nil }
        if CFGetTypeID(v) == CFBooleanGetTypeID() { return CFBooleanGetValue((v as! CFBoolean)) }
        if CFGetTypeID(v) == CFNumberGetTypeID() { return ((v as! NSNumber).intValue != 0) }
        return nil
    }

    /// AXValue → printable scalar (string / number / bool); other kinds are ignored.
    static func nodeValue(_ v: CFTypeRef?) -> AXNodeValue? {
        guard let v else { return nil }
        let type = CFGetTypeID(v)
        if type == CFBooleanGetTypeID() { return .bool(CFBooleanGetValue((v as! CFBoolean))) }
        if type == CFNumberGetTypeID() { return .number((v as! NSNumber).doubleValue) }
        if let s = stringValue(v) { return .string(s) }
        return nil
    }

    static func elementArray(_ v: CFTypeRef) -> [AXUIElement]? {
        guard CFGetTypeID(v) == CFArrayGetTypeID() else { return nil }
        let array = v as! CFArray
        var out: [AXUIElement] = []
        let count = CFArrayGetCount(array)
        out.reserveCapacity(count)
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(array, i) else { continue }
            let item = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
            if CFGetTypeID(item) == AXUIElementGetTypeID() { out.append(item as! AXUIElement) }
        }
        return out
    }

    // MARK: secure fields

    /// Three-valued secure-field check (role or subrole AXSecureTextField). `.unknown`
    /// when the app did not answer (e.g. the 1 s messaging timeout): input-gating callers
    /// must refuse in that case rather than fail open.
    static func secureCheck(_ el: AXUIElement) -> SecureFieldCheck {
        let (roleError, role) = copy(el, kAXRoleAttribute)
        let (subroleError, subrole) = copy(el, kAXSubroleAttribute)
        return SecureFieldCheck.evaluate(
            roleError: roleError.rawValue, role: stringValue(role),
            subroleError: subroleError.rawValue, subrole: stringValue(subrole))
    }

    /// For callers that only decide whether a value may be *read* (tree, footer, settle
    /// fingerprint): anything not definitely "not secure" counts as secure.
    static func isSecure(_ el: AXUIElement) -> Bool {
        secureCheck(el) != .notSecure
    }

    /// The app's currently focused element, if any.
    static func focusedElement(pid: pid_t) -> AXUIElement? {
        element(application(pid), kAXFocusedUIElementAttribute)
    }

    enum FocusRead {
        case element(AXUIElement)
        /// Definitely nothing focused.
        case none
        /// The app did not answer in time (or failed): unknown.
        case unknown
    }

    /// Three-valued read of the focused element (see `FocusReadKind`).
    static func focusedElementRead(pid: pid_t) -> FocusRead {
        let (err, v) = copy(application(pid), kAXFocusedUIElementAttribute)
        let element = v.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        switch FocusReadKind.classify(rawError: err.rawValue, gotElement: element != nil) {
        case .element: return element.map { .element($0) } ?? .none
        case .nothingFocused: return .none
        case .unknown: return .unknown
        }
    }

    static func same(_ a: AXUIElement?, _ b: AXUIElement?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let x?, let y?): return CFEqual(x, y)
        default: return false
        }
    }
}

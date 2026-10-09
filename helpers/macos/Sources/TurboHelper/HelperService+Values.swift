import AppKit
import ImageIO
import ApplicationServices
import TurboCore
import Foundation

// Setting values, selecting text and named accessibility actions.
extension HelperService {
    /// Sets the value; returns the read-back check to run once the UI has settled
    /// (`fillValue`).
    func fillValue(index: Int, value: String, _ c: ActionContext) throws -> () -> String? {
        let app = c.app
        let name = c.name
        let el = try element(index, app: app, pid: c.pid, policy: c.policy)
        try refuseIfSecureElement(el, index: index, app: app, appName: name)
        try travel(
            c, to: aimPoint(of: el, app: app), moving: PointerLabel.moving(to: pillName(el, app: name)),
            arrived: PointerLabel.settingValue)
        guard AX.isSettable(el, kAXValueAttribute) else {
            throw TurboError(.notSupported, "The value of #\(index) is not settable; try click_at + write_text instead.")
        }
        // Some text fields only take a value while they are being edited (Safari's address
        // field shows a value set while unfocused but navigates to the old one): focus
        // first, as write_text does.
        if FillValuePolicy.shouldFocusFirst(
            role: AX.string(el, kAXRoleAttribute), isFocused: AX.bool(el, kAXFocusedAttribute),
            focusSettable: AX.isSettable(el, kAXFocusedAttribute))
        {
            AX.set(el, kAXFocusedAttribute, kCFBooleanTrue)
            usleep(80_000)
            // Focus can move into a different (secure) field in odd UIs: check again.
            try refuseIfSecureElement(el, index: index, app: app, appName: name)
        }
        let current = AX.value(el, kAXValueAttribute)
        // What the element held before: a read-back equal to it is a revert, anything
        // else that differs from the request is the app reformatting the value.
        let previous = AX.isSecure(el) ? nil : AX.nodeValue(current)
        let newValue: CFTypeRef
        if let current, CFGetTypeID(current) == CFNumberGetTypeID(), let d = Double(value.trimmingCharacters(in: .whitespaces)) {
            newValue = NSNumber(value: d)
        } else if let current, CFGetTypeID(current) == CFBooleanGetTypeID() {
            // Only explicit words: anything else is refused rather than read as "false".
            guard let flag = FillValuePolicy.booleanValue(value) else {
                throw TurboError.invalid(
                    "#\(index) holds a true/false value; use one of \(FillValuePolicy.booleanWordsText) instead of \"\(TreeFormat.clean(value, limit: 40))\".")
            }
            newValue = flag ? kCFBooleanTrue : kCFBooleanFalse
        } else {
            newValue = value as CFString
        }
        let err = AX.set(el, kAXValueAttribute, newValue)
        guard err == .success else {
            throw TurboError(.actionError, "Setting the value of #\(index) failed (AXError \(err.rawValue)).")
        }
        if Self.isInPlaceEditor(el) {
            c.extras.addNote(
                "#\(index) is an in-place editor (such as a rename field): the new text is only shown in the field until editing ends. Commit it with send_keys \"return\" (or cancel with \"escape\"); nothing is saved before that.")
        }
        return {
            // Read back: some apps revert or ignore a value set through accessibility.
            guard AX.isValid(el), !AX.isSecure(el) else { return nil }
            switch FillValuePolicy.compare(
                requested: value, readBack: AX.nodeValue(AX.value(el, kAXValueAttribute)), previous: previous)
            {
            case .kept, .unknown:
                return nil
            case .notKept(let actual):
                Log.info("fillValue on #\(index): value not kept")
                return FillValuePolicy.notKeptNote(index: index, requested: value, actual: actual)
            case .reformatted(let actual):
                Log.info("fillValue on #\(index): value reformatted by the app")
                return FillValuePolicy.reformattedNote(index: index, requested: value, actual: actual)
            }
        }
    }

    func pickText(
        index: Int, text: String, prefix: String?, suffix: String?, mode: TextSelectionMode, _ c: ActionContext
    ) throws -> String? {
        let el = try element(index, app: c.app, pid: c.pid, policy: c.policy)
        try refuseIfSecureElement(el, index: index, app: c.app, appName: c.name)
        guard let haystack = AX.string(el, kAXValueAttribute) else {
            throw TurboError(.notSupported, "#\(index) has no text value to select in.")
        }
        guard let range = TextRangeFinder.find(in: haystack, text: text, prefix: prefix, suffix: suffix, mode: mode) else {
            throw TurboError.invalid("Text \"\(TreeFormat.clean(text, limit: 60))\" was not found in #\(index) (with the given prefix/suffix).")
        }
        try travel(
            c, to: aimPoint(of: el, app: c.app), moving: PointerLabel.moving(to: pillName(el, app: c.name)),
            arrived: PointerLabel.selecting)
        AX.set(el, kAXFocusedAttribute, kCFBooleanTrue)
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let axRange = AXValueCreate(.cfRange, &cfRange) else {
            throw TurboError(.helperFault, "Could not create a range value.")
        }
        let err = AX.set(el, kAXSelectedTextRangeAttribute, axRange)
        guard err == .success else {
            throw TurboError(.actionError, "Selecting text in #\(index) failed (AXError \(err.rawValue)).")
        }
        return nil
    }

    func invokeAction(index: Int, name: String, _ c: ActionContext) throws -> String? {
        let el = try element(index, app: c.app, pid: c.pid, policy: c.policy)
        let available = AX.actions(el)
        // Accepts the raw AX name and the form printed after actions= / in the footer.
        guard let match = ActionNameMatcher.match(name, in: available) else {
            let shown = TreeFormat.displayActions(available)
            throw TurboError(
                .notSupported,
                "Action \"\(TreeFormat.clean(name, limit: 80))\" is not available on #\(index). Available: \(shown.isEmpty ? "none" : shown.joined(separator: ", "))."
            )
        }
        let shownName = TreeFormat.displayName(forAction: match)
        let label = pillName(el, app: c.name)
        try travel(
            c, to: aimPoint(of: el, app: c.app), moving: PointerLabel.moving(to: label),
            arrived: PointerLabel.truncate("\(shownName) \(label)"))
        let err = AX.perform(el, match)
        pointer?.press()
        switch AXActionOutcome(rawError: err.rawValue) {
        case .performed:
            return nil
        case .probablyPerformed:
            // Delivered but unconfirmed (e.g. AXShowMenu enters menu tracking): not a
            // retryable failure, repeating it would run the action twice.
            Log.info("\(LogText.peer(shownName)) on #\(index) timed out (\(err.rawValue)); treating it as performed")
            return
                "Performed \(shownName) on #\(index); the app did not confirm within 1 s (it may be busy or showing a menu or dialog). Call observe_app to check the result before retrying."
        case .elementGone:
            throw TurboError.elementInvalid(index)
        case .failed:
            throw TurboError(.actionError, "Performing \(shownName) on #\(index) failed (AXError \(err.rawValue)).")
        }
    }
}

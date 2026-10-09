import AppKit
import ImageIO
import ApplicationServices
import TurboCore
import Foundation

// Typing text (`writeText`): through accessibility where possible, else as keys.
extension HelperService {
    /// `writeText`: text runs are inserted through accessibility
    /// (`kAXSelectedTextAttribute`, read back) when the element allows it — no focus
    /// change needed — else typed as key events; newlines / tabs are key presses in the
    /// foreground and keyless alternatives in the background.
    func writeText(_ text: String, index: Int?, _ c: ActionContext) throws -> String {
        var target: AXUIElement?
        if let index {
            let el = try element(index, app: c.app, pid: c.pid, policy: c.policy)
            try refuseIfSecureElement(el, index: index, app: c.app, appName: c.name)
            target = el
        }
        let total = text.count
        let runs = WriteTextPlan.runs(text)
        // Pause after each key of the key-event path (settings.json "typing.keyDelayMs").
        let keyDelay = TypingSettings.load(paths.settings).keyDelayMs
        if let pointerTarget = target ?? AX.focusedElement(pid: c.pid) {
            try travel(
                c, to: aimPoint(of: pointerTarget, app: c.app), moving: PointerLabel.moving(to: pillName(pointerTarget, app: c.name)),
                arrived: PointerLabel.typing)
        }
        if let el = target, AX.bool(el, kAXFocusedAttribute) != true {
            AX.set(el, kAXFocusedAttribute, kCFBooleanTrue)
            usleep(80_000)
        }
        if c.focus.mode == .background, !backgroundKeysAllowed(c) {
            // Refuse up front, before inserting anything, when the element the text goes to
            // first cannot take it without key events.
            let first = target ?? AX.focusedElement(pid: c.pid)
            if runs.contains(where: \.isText), first.map(canInsertViaAX) != true {
                // Like send_keys: bring the app forward for this call (while the user is idle).
                try borrowFront(c, what: "typing into this element (it does not accept text through accessibility)", partial: " Nothing was typed.")
            }
            if let keyRun = runs.first(where: { !$0.isText }),
                WriteTextPlan.keyless(
                    keyRun, role: first.flatMap { AX.string($0, kAXRoleAttribute) }, actions: first.map { AX.actions($0) } ?? [])
                    == .needsKey
            {
                try borrowFront(c, what: "pressing \(keyRun == .newline ? "Return" : "Tab")", partial: " Nothing was typed.")
            }
        }
        var typed = 0
        var viaAX = 0
        var viaKeys = 0
        /// Key presses went to an element that does not take text (described), if any.
        var nonTextTarget: String?
        func partial() -> String {
            typed > 0
                ? " Typed \(typed) of \(total) character(s) before stopping; call observe_app to check the app before doing anything else."
                : " Nothing was typed."
        }
        for (i, run) in runs.enumerated() {
            if c.interrupted() {
                throw interruptionError(c.sessionId, deadline: c.deadline, detail: typed > 0 ? "Typing stopped after \(typed) of \(total) character(s)." : "Nothing was typed.")
            }
            if i > 0, runs[i - 1].movesFocus { waitForFocusToSettle(pid: c.pid) }
            // Return / Tab can move focus into a password field: check before every run.
            let focused = try refuseIfSecureInput(pid: c.pid, appName: c.name, typedSoFar: typed, total: total)
            let dest = (i == 0 ? target : nil) ?? focused ?? target
            switch run {
            case .text(let chunk):
                if let dest, insertViaAX(chunk, into: dest) {
                    typed += chunk.count
                    viaAX += chunk.count
                    continue
                }
                if nonTextTarget == nil, !(dest.map(Self.acceptsText) ?? false) {
                    nonTextTarget = dest.map(Self.describeElement) ?? "no element (nothing has the keyboard focus)"
                }
                let route = try keyRoute(
                    c, what: "typing into this element (it does not accept text through accessibility)", partial: partial())
                var chunk = chunk
                if route == .background { c.extras.addNote(FocusModeText.backgroundKeysNote(app: c.name)) }
                if route == .background, c.app.backgroundKeysWork == nil, let dest,
                    let before = AX.string(dest, kAXValueAttribute), let first = chunk.first
                {
                    // First background key event for this app: check that it arrives.
                    try input.deliver(.text(String(first)), pid: c.pid, keyDelayMs: keyDelay)
                    let arrived = Polling.waitForChange(
                        from: before, timeout: 0.5, interval: 0.04, changed: { $0 != $1 },
                        read: { AX.string(dest, kAXValueAttribute) }) != nil
                    c.app.backgroundKeysWork = arrived
                    Log.info("writeText: background key events \(arrived ? "arrive" : "do not arrive") in \(LogText.peer(c.name))")
                    if arrived {
                        typed += 1
                        viaKeys += 1
                        chunk = String(chunk.dropFirst())
                        if chunk.isEmpty { continue }
                    } else {
                        // The key went somewhere, but not into this field: say so, and type the
                        // text with the app in front instead (like send_keys).
                        c.extras.addNote(
                            "The first character \"\(TreeFormat.clean(String(first), limit: 4))\" was sent in the background but did not appear in the field; it may have had another effect in \(c.name) (check with observe_app).")
                        if try keyRoute(
                            c, what: "typing into this element (\(c.name) ignores key events while it is in the background)",
                            partial: " The first character was sent in the background but did not appear in the field; nothing else was typed.")
                            == .foreground
                        {
                            c.extras.removeNote(FocusModeText.backgroundKeysNote(app: c.name))
                        }
                    }
                }
                let outcome = try TypingDriver.run(
                    TextChunker.segments(chunk, maxUTF16: 20), interrupted: c.interrupted, settle: {},
                    guardFocus: { n in
                        try self.refuseIfSecureInput(pid: c.pid, appName: c.name, typedSoFar: typed + n, total: total)
                    },
                    deliver: { segment in try self.input.deliver(segment, pid: c.pid, keyDelayMs: keyDelay) })
                switch outcome {
                case .completed(let n):
                    typed += n
                    viaKeys += n
                case .interrupted(let n):
                    typed += n
                    throw interruptionError(
                        c.sessionId, deadline: c.deadline, detail: "Typing stopped after \(typed) of \(total) character(s).")
                }
            case .newline, .tab:
                let keyName = run == .newline ? "Return" : "Tab"
                if !isFrontmost(c.pid), run == .newline, let dest, Self.isInPlaceEditor(dest) {
                    // An in-place editor (rename field) commits only on a real Return.
                    try borrowFront(c, what: "committing the in-place editor with Return", partial: partial())
                }
                if !isFrontmost(c.pid), Self.dialogSurfaceFrame(pid: c.pid) == nil {
                    let role = dest.flatMap { AX.string($0, kAXRoleAttribute) }
                    if run == .newline, DialogKey.defaultButton.applies(focusedRole: role),
                        try dialogButtonViaAX(.defaultButton, shown: "Return", c) != nil
                    {
                        // Return in a field of a window with a default button presses it
                        // (AppKit's key equivalent; inactive apps never see it).
                        typed += 1
                        continue
                    }
                    let actions = dest.map { AX.actions($0) } ?? []
                    switch WriteTextPlan.keyless(run, role: role, actions: actions) {
                    case .insertCharacter:
                        if let dest, insertViaAX(run == .newline ? "\n" : "\t", into: dest) {
                            typed += 1
                            viaAX += 1
                            continue
                        }
                    case .confirm:
                        if let dest, AXActionOutcome(rawError: AX.perform(dest, "AXConfirm").rawValue) != .failed {
                            typed += 1
                            continue
                        }
                    case .needsKey:
                        break
                    }
                }
                if try keyRoute(c, what: "pressing \(keyName)", partial: partial()) == .background {
                    c.extras.addNote(FocusModeText.backgroundKeysNote(app: c.name))
                }
                try input.deliver(run == .newline ? .returnKey : .tab, pid: c.pid)
                typed += 1
                viaKeys += 1
            }
        }
        if nonTextTarget != nil, let id = NSRunningApplication(processIdentifier: c.pid)?.bundleIdentifier,
            focusProfiles.profile(id)?.selfDrawn == true
        {
            // An app that draws its own UI reports no focused field: the screenshot is the
            // only way to see where the keys went (not a sign they went nowhere).
            return "Typed \(viaKeys) character(s) as key presses. \(c.name) draws its own UI, so whether they became text shows only in the screenshot: check with observe_app."
        }
        if let nonTextTarget {
            // The keys were sent, but nothing says they became text (writeText).
            return
                "Sent \(viaKeys) character(s) as key presses, but the keyboard focus was on \(nonTextTarget), which does not take text: they may have done nothing, or triggered keyboard shortcuts of \(c.name). Check with observe_app; to type into a field, click it first (or pass its element)."
        }
        let how: String
        switch (viaAX > 0, viaKeys > 0) {
        case (true, false): how = " (inserted through accessibility)"
        case (true, true): how = " (partly through accessibility, partly as key events)"
        default: how = ""
        }
        return "Typed \(total) character(s)\(how)."
    }

    /// Whether key presses to `el` become text: a text role, or an element with a caret /
    /// text selection (editable web content, custom text views).
    static func acceptsText(_ el: AXUIElement) -> Bool {
        let (_, v) = AX.multiple(el, [kAXRoleAttribute, kAXSelectedTextRangeAttribute, "AXInsertionPointLineNumber", "AXEditableAncestor"])
        let role = AX.stringValue(v[kAXRoleAttribute]) ?? ""
        if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSecureTextField"].contains(role) { return true }
        return v[kAXSelectedTextRangeAttribute] != nil || v["AXInsertionPointLineNumber"] != nil || v["AXEditableAncestor"] != nil
    }

    /// `group "Welcome"` — role and label of an element, for notes.
    static func describeElement(_ el: AXUIElement) -> String {
        let (_, v) = AX.multiple(el, [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute])
        let role = TreeFormat.roleText(role: AX.stringValue(v[kAXRoleAttribute]) ?? "AXUnknown", subrole: AX.stringValue(v[kAXSubroleAttribute]))
        let label = [AX.stringValue(v[kAXTitleAttribute]), AX.stringValue(v[kAXDescriptionAttribute])].compactMap { $0 }.first { !$0.isEmpty }
        return label.map { "\(role) \"\(TreeFormat.clean($0, limit: 60))\"" } ?? role
    }

    /// Insert `text` at the element's caret / over its selection by setting
    /// `kAXSelectedTextAttribute`, then read `AXValue` back. false = not available or the
    /// value did not change (the caller falls back to key events).
    func canInsertViaAX(_ el: AXUIElement) -> Bool {
        AX.secureCheck(el) == .notSecure && AX.isSettable(el, kAXSelectedTextAttribute)
            && AX.string(el, kAXValueAttribute) != nil
    }

    func insertViaAX(_ text: String, into el: AXUIElement) -> Bool {
        guard canInsertViaAX(el), let before = AX.string(el, kAXValueAttribute) else { return false }
        var selection: UTF16Range?
        if let v = AX.value(el, kAXSelectedTextRangeAttribute), CFGetTypeID(v) == AXValueGetTypeID() {
            var r = CFRange()
            if AXValueGetValue(v as! AXValue, .cfRange, &r) { selection = UTF16Range(location: r.location, length: r.length) }
        }
        let err = AX.set(el, kAXSelectedTextAttribute, text as CFString)
        guard err == .success else {
            Log.info("writeText: setting AXSelectedText failed (AXError \(err.rawValue)); using key events")
            return false
        }
        let expected = AXInsertion.expected(before: before, selection: selection, inserted: text)
        let until = Date().addingTimeInterval(0.5)
        repeat {
            let after = AX.string(el, kAXValueAttribute)
            if AXInsertion.verdict(before: before, after: after) == .took {
                if !AXInsertion.isExact(after: after, expected: expected) {
                    Log.info("writeText: accessibility insertion took; the app adjusted the value")
                }
                return true
            }
            usleep(25_000)
        } while Date() < until
        Log.info("writeText: accessibility insertion did not change the value; using key events")
        // Put the selection back: an insertion that did not take may still have moved or
        // collapsed it, and the fallback (or the user) expects it where it was.
        if let selection {
            var r = CFRange(location: selection.location, length: selection.length)
            if let v = AXValueCreate(.cfRange, &r) { AX.set(el, kAXSelectedTextRangeAttribute, v) }
        }
        return false
    }

    /// After Return / Tab: give the app a moment to move keyboard focus before the next
    /// secure-field check (returns once two reads agree, at most ≈ 0.35 s).
    func waitForFocusToSettle(pid: pid_t) {
        usleep(50_000)
        var last = AX.focusedElement(pid: pid)
        let until = Date().addingTimeInterval(0.3)
        while Date() < until {
            usleep(25_000)
            let next = AX.focusedElement(pid: pid)
            if AX.same(next, last) { return }
            last = next
        }
    }

    func secureFieldError(_ suffix: String = "") -> TurboError {
        TurboError(
            .passwordGuard,
            "The target is a secure (password) field. Computer Use never types into or reads password fields; ask the user to enter it.\(suffix)"
        )
    }

    func unansweredError(_ appName: String, _ suffix: String = "") -> TurboError {
        TurboError(
            .actionError,
            "\(appName) did not answer an accessibility query in time, so the input was refused to avoid a possible password field; retry.\(suffix)"
        )
    }

    /// Refuse keyboard input when secure event input is on, or the focused element is a
    /// password field — or cannot be identified (fail closed). Returns the focused element.
    @discardableResult
    func refuseIfSecureInput(pid: pid_t, appName: String, typedSoFar: Int = 0, total: Int = 0) throws
        -> AXUIElement?
    {
        let partial =
            typedSoFar > 0
            ? " Typing stopped after \(typedSoFar) of \(total) character(s); call observe_app to check the app before doing anything else."
            : ""
        if SystemState.isSecureInputEnabled {
            throw TurboError(
                .passwordGuard,
                "Secure keyboard input is active (a password field is focused somewhere, or Secure Keyboard Entry is enabled). Keyboard input is refused; ask the user to handle it.\(partial)"
            )
        }
        switch AX.focusedElementRead(pid: pid) {
        case .none:
            return nil
        case .unknown:
            throw unansweredError(appName, partial)
        case .element(let el):
            switch AX.secureCheck(el) {
            case .notSecure: return el
            case .secure: throw secureFieldError(partial)
            case .unknown: throw unansweredError(appName, partial)
            }
        }
    }

    /// fill_value / pick_text / write_text target: refused if it was a secure field when
    /// observed, is one now, or its role cannot be read (fail closed).
    func refuseIfSecureElement(_ el: AXUIElement, index: Int, app: AppSessionState, appName: String) throws {
        if app.secureIndices.contains(index) { throw secureFieldError() }
        switch AX.secureCheck(el) {
        case .notSecure: return
        case .secure: throw secureFieldError()
        case .unknown: throw unansweredError(appName)
        }
    }
}

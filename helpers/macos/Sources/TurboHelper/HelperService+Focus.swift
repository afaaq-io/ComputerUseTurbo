import AppKit
import ImageIO
import ApplicationServices
import TurboCore
import Foundation

// Focus mode: working in the background, borrowing the front, and the agent pointer.
extension HelperService {
    /// What an action needs from the surrounding request.
    struct ActionContext {
        let session: SessionState
        let sessionId: String
        let app: AppSessionState
        let pid: pid_t
        let name: String
        let policy: PolicyEvaluation
        let deadline: RequestDeadline
        let focus: FocusOutcome
        let interrupted: () -> Bool
        /// Notes and the real-pointer assist of this action.
        let extras = ActionExtras()
    }

    /// Mutable per-action state shared by the action's steps.
    final class ActionExtras {
        var assist: RealPointerAssist?
        var notes: [String] = []

        func addNote(_ note: String) {
            if !notes.contains(note) { notes.append(note) }
        }

        func removeNote(_ note: String) {
            notes.removeAll { $0 == note }
        }

        /// Put the user's real pointer back (if the assist moved it). Idempotent.
        func finishAssist() {
            assist?.finish()
            assist = nil
        }
    }

    struct FocusOutcome {
        /// `.foreground` only when the target already was the frontmost app.
        let mode: FocusMode
        /// Notes for the result (working in the background).
        let notes: [String]
    }

    /// Hardware input timing (CGEventSource HID state; events the helper posts to a pid
    /// never count).
    enum UserInput {
        static func secondsSince(_ types: [CGEventType]) -> TimeInterval {
            types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
        }
        static var keyboard: TimeInterval { secondsSince([.keyDown, .flagsChanged]) }
        static var clickOrScroll: TimeInterval {
            secondsSince([.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel])
        }
        /// Any use of the real mouse, plain movement included (real-pointer assist).
        static var mouse: TimeInterval {
            secondsSince([
                .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .rightMouseDragged,
                .otherMouseDragged, .scrollWheel,
            ])
        }
    }

    func frontmostPid() -> pid_t? {
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier { return pid }
        if let app = AX.element(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute) { return AX.pid(app) }
        return nil
    }

    /// Decide foreground / background for this action. The helper never brings the
    /// target forward — the user may be working in another app — except with the opt-in
    /// `focus.activateTarget` setting while the user is idle.
    func prepareFocus(session: SessionState, pid: pid_t, app: AppSessionState, name: String) -> FocusOutcome {
        var forcedNote: String?
        if forceFrontIfNeeded(pid: pid, app: app, name: name) {
            forcedNote = "\(name) was brought to the front: it draws its own UI and only takes input while it is the app in front (detected automatically)."
        }
        var front = frontmostPid()
        if front != pid,
            FocusSettings.load(paths.settings).shouldActivate(
                targetFront: false, secondsSinceUserInput: min(UserInput.keyboard, UserInput.clickOrScroll))
        {
            Log.info("focus: activating \(LogText.peer(name)) (settings focus.activateTarget)")
            if bringToFront(pid: pid, window: app.window) { front = pid }
        }
        var notes: [String] = forcedNote.map { [$0] } ?? []
        let (mode, transition) = session.focus.evaluate(targetPid: pid, frontmostPid: front)
        let sid = LogText.peer(String(session.id.prefix(8)), limit: 8)
        switch transition {
        case .none:
            break
        case .enteredBackground:
            let frontName = front.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier } ?? "?"
            Log.info("focus: session \(sid) works on \(LogText.peer(name)) in the background (frontmost \(frontName))")
            notes.append(FocusModeText.backgroundNote(app: name))
        case .targetInFront:
            Log.info("focus: session \(sid): \(LogText.peer(name)) is in front (the user brought it forward)")
        }
        return FocusOutcome(mode: mode, notes: notes)
    }

    /// What `bundleId` needs: settings overrides, else what was learned,
    /// else detection (a self-drawn UI needs the front). Never a hard-coded app list.
    func focusNeed(bundleId: String) -> FocusNeed {
        FocusPolicy.decide(
            bundleId: bundleId, profile: focusProfiles.profile(bundleId), focus: FocusSettings.load(paths.settings),
            hover: HoverSettings.load(paths.settings))
    }

    /// Apps that only work in front (detected or learned) are brought there — after
    /// waiting (≤ 2 s) for a 1 s pause in the user's typing so their keystrokes do not land
    /// in the target. Returns true if the app was activated now.
    @discardableResult
    func forceFrontIfNeeded(pid: pid_t, app: AppSessionState, name: String) -> Bool {
        guard focusNeed(bundleId: app.key) != .background, !isFrontmost(pid) else { return false }
        let until = Date().addingTimeInterval(FocusSettings.forceFrontMaxWait)
        while UserInput.keyboard < FocusSettings.forceFrontQuietSeconds, Date() < until { usleep(100_000) }
        let ok = bringToFront(pid: pid, window: app.window)
        Log.info("focus: brought \(LogText.peer(name)) to the front (\(focusNeed(bundleId: app.key).rawValue)) → \(ok ? "in front" : "failed")")
        return ok
    }

    /// Borrowed front: bring the app forward for this one action, which cannot work
    /// while it is in the background. Waits (≤ 2 s) for the user to pause typing and mousing;
    /// otherwise 4022 userActive with nothing sent. The front goes back after the action
    /// (`restoreBorrowedFront`). No-op when the app already is in front.
    func borrowFront(_ c: ActionContext, what: String, partial: String = "") throws {
        if isFrontmost(c.pid) { return }
        guard FocusSettings.load(paths.settings).borrowFront else { throw userBusyError(c, what: what, partial: partial) }
        func idle() -> Bool {
            BorrowFrontPolicy.userIdle(secondsSinceKeyboard: UserInput.keyboard, secondsSinceMouse: UserInput.mouse)
        }
        let until = Date().addingTimeInterval(BorrowFrontPolicy.maxWait)
        while !idle(), Date() < until, !c.interrupted() { usleep(100_000) }
        if c.interrupted() { throw interruptionError(c.sessionId, deadline: c.deadline, detail: "Nothing was sent.") }
        guard idle() else {
            Log.info("borrow front: \(LogText.peer(c.name)) refused, the user is busy")
            throw TurboError(.userActive, FocusModeText.borrowBusyMessage(app: c.name, what: what) + partial)
        }
        let previous = NSWorkspace.shared.frontmostApplication
        guard bringToFront(pid: c.pid, window: c.app.window) else {
            throw userBusyError(c, what: what, partial: partial)
        }
        if let previous, previous.processIdentifier != c.pid, previous.processIdentifier != getpid() {
            borrows.record(pid: c.pid, previous: previous)
        }
        Log.info("borrow front: \(LogText.peer(c.name)) brought forward for \(what) (from \(previous?.bundleIdentifier ?? "?"))")
    }

    /// Hand a borrowed front back: after `holdAfter`, unless the user took over, or a
    /// menu of the app is open (kept until the next action / finish; `force` ignores
    /// the menu). Returns a note for the result, if any.
    func restoreBorrowedFront(pid: pid_t, force: Bool = false) -> String? {
        guard let b = borrows.pending(pid: pid) else { return nil }
        let held = ProcessInfo.processInfo.systemUptime - b.at
        if held < BorrowFrontPolicy.holdAfter { usleep(useconds_t((BorrowFrontPolicy.holdAfter - held) * 1_000_000)) }
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "The app"
        var menuOpen = Self.menuIsOpen(pid: pid)
        if menuOpen {
            // A shortcut flashes its menu's title for a moment; only a menu still open after
            // that is one the agent opened.
            usleep(300_000)
            menuOpen = Self.menuIsOpen(pid: pid)
        }
        let decision = BorrowFrontPolicy.restore(
            targetStillFront: isFrontmost(pid), menuOpen: menuOpen,
            secondsSinceUserInput: secondsSinceUserInputExcludingOurs(),
            heldFor: ProcessInfo.processInfo.systemUptime - b.at, force: force)
        switch decision {
        case .keep:
            return FocusModeText.borrowKeptForMenuNote(app: name)
        case .drop:
            borrows.clear(pid: pid)
            Log.info("borrow front: pid \(pid) left as is (the user switched or used the Mac)")
            return nil
        case .restore:
            borrows.clear(pid: pid)
            handedBackAt[pid] = ProcessInfo.processInfo.systemUptime
            guard let previous = NSRunningApplication(processIdentifier: b.previousPid), !previous.isTerminated else { return nil }
            if force, menuOpen {
                // Close the open menu first (it would otherwise stay open in a background app).
                closeOpenMenu(pid: pid)
            }
            let err = AX.set(AX.application(b.previousPid), kAXFrontmostAttribute, kCFBooleanTrue)
            if err != .success { previous.activate(options: []) }
            Log.info("borrow front: front handed back to \(previous.bundleIdentifier ?? "?")")
            return FocusModeText.borrowedNote(app: name, previous: previous.localizedName)
        }
    }

    /// Seconds since the user's last key press / click, not counting the input the helper
    /// itself posted through the window server (it shows up as HID input too).
    func secondsSinceUserInputExcludingOurs() -> TimeInterval {
        let since = min(UserInput.keyboard, UserInput.clickOrScroll)
        if let ours = input.lastSystemPost, since >= ProcessInfo.processInfo.systemUptime - ours - 0.25 { return .infinity }
        return since
    }

    func userBusyError(_ c: ActionContext, what: String, partial: String = "") -> TurboError {
        TurboError(.userActive, FocusModeText.userBusyMessage(app: c.name, what: what) + partial)
    }

    /// How key events reach the app.
    enum KeyRoute: Equatable {
        /// The app is in front: events go to it as usual.
        case foreground
        /// The user works in another app: events are posted to the app's pid without
        /// taking the front (⌘-shortcuts go through their menu items instead).
        case background
    }

    /// Key events: if the target is the frontmost app right now (the user put it
    /// there), events go to it as usual. Otherwise they are posted to the pid without ever
    /// taking the front, unless that is turned off in settings or was found not to work for
    /// this app: then 4022 userActive (nothing sent). Never activates the app.
    func keyRoute(_ c: ActionContext, what: String, partial: String = "") throws -> KeyRoute {
        if Self.dialogSurfaceFrame(pid: c.pid) != nil {
            // A dialog or sheet has the keyboard: its content may be drawn by another process
            // (file panels are), which keys posted to the app never reach.
            try borrowFront(c, what: "\(what) in the dialog or sheet of \(c.name) (input posted to the app may not reach it)", partial: partial)
            input.routeThroughSystem = true
            return .foreground
        }
        if isFrontmost(c.pid) { return .foreground }
        if focusNeed(bundleId: c.app.key) != .background || !backgroundKeysAllowed(c) {
            // Keys this app would not take in the background: borrow the front.
            try borrowFront(c, what: what, partial: partial)
            return .foreground
        }
        return .background
    }

    func backgroundKeysAllowed(_ c: ActionContext) -> Bool {
        BackgroundKeySettings.load(paths.settings).enabled && c.app.backgroundKeysWork != false
    }

    /// `sendKeys`: a dead key alone is typed as its character; in the background a
    /// ⌘-chord presses the menu item that owns the shortcut through accessibility (key
    /// equivalents reach only the active app), other keys are posted to the pid.
    func sendKeys(_ key: String, _ c: ActionContext) throws -> String? {
        let chord = try KeyChordParser.parse(key, characterMap: KeyboardLayout.characterMap)
        let shown = TreeFormat.clean(key, limit: 40)
        if Self.isSystemSurface(pid: c.pid), !chord.modifiers.isEmpty {
            try refuseIfSecureInput(pid: c.pid, appName: c.name)
            // A background system process without a focused window (the search panel, the
            // menu bar extras) has no keyboard of its own: its shortcuts are the system's
            // (⌘Space). A press through the system reaches the app in front unless the system
            // owns the chord, so only registered system shortcuts go, while the user is idle.
            guard SystemShortcuts.contains(chord, in: Self.registeredSystemShortcuts()) else {
                throw TurboError(
                    .actionError,
                    "\(shown) is not one of the system's own shortcuts; pressed system-wide it would reach the app in front, so nothing was sent. Click a status item of \(c.name) instead.")
            }
            guard BorrowFrontPolicy.userIdle(secondsSinceKeyboard: UserInput.keyboard, secondsSinceMouse: UserInput.mouse) else {
                throw TurboError(.userActive, FocusModeText.borrowBusyMessage(app: c.name, what: "pressing the system-wide shortcut \"\(shown)\""))
            }
            pointer?.announce(PointerLabel.pressing(key))
            input.routeThroughSystem = true
            defer { input.routeThroughSystem = false }
            try input.press(chord, pid: c.pid)
            return "Pressed \(shown) as a system-wide shortcut (\(c.name) runs in the background without a window of its own). Observe to see what it opened."
        }
        let route = try keyRoute(c, what: "the key press \"\(shown)\"")
        try refuseIfSecureInput(pid: c.pid, appName: c.name)
        if route == .background, !input.routeThroughSystem, !chord.modifiers.isDisjoint(with: [.command, .control]),
            Self.actsOnActiveWindow(pid: c.pid)
        {
            // A shortcut of a Chromium-based app acts on its active window (see runCommand).
            try borrowFront(c, what: "the shortcut \"\(shown)\" (\(c.name) runs shortcuts in its active window, which it only has while in front)")
            try input.press(chord, pid: c.pid)
            return "Pressed \(shown) with \(c.name) in front (its shortcuts act on its active window)."
        }
        if !input.routeThroughSystem, Self.sheetFrame(pid: c.pid) != nil, !chord.modifiers.isDisjoint(with: [.command, .control]) {
            // A sheet has the keyboard: its shortcut belongs to the sheet, never to a menu item
            // of the app; a shortcut reaches a sheet only with the app in front.
            try borrowFront(c, what: "the key press \"\(shown)\" in the sheet of \(c.name)")
            input.routeThroughSystem = true
        }
        if input.routeThroughSystem {
            pointer?.announce(PointerLabel.pressing(key))
            try input.press(chord, pid: c.pid)
            return "Pressed \(shown) in the \(Self.dialogSurfaceFrame(pid: c.pid) != nil ? "dialog" : "sheet") of \(c.name) with it in front (keys there go to the dialog, not to the app's menus)."
        }
        pointer?.announce(PointerLabel.pressing(key))
        if route == .background, !chord.modifiers.isDisjoint(with: [.command, .control]) {
            var hit = MenuShortcuts.find(chord, pid: c.pid)
            if hit?.enabled == true, let at = handedBackAt[c.pid] {
                // Still the state it had in front (see `staleMenuStateSeconds`): read it again later.
                let left = Self.staleMenuStateSeconds - (ProcessInfo.processInfo.systemUptime - at)
                if left > 0 {
                    usleep(useconds_t(left * 1_000_000))
                    hit = MenuShortcuts.find(chord, pid: c.pid)
                }
            }
            if hit?.enabled != true, let edit = TextEditShortcut.from(chord), let note = try textEditViaAX(edit, c) {
                return note
            }
            if hit?.enabled != true, let note = try closeWindowViaAX(chord, c) {
                return note
            }
            if Self.menuIsOpen(pid: c.pid) {
                // A menu left open in a background app swallows shortcuts: close it first.
                closeOpenMenu(pid: c.pid)
            }
            if let hit, !hit.enabled {
                // Often disabled only because the app is not active (AppKit validates
                // against the key window): borrow the front and press it normally.
                try borrowFront(c, what: "the shortcut \"\(shown)\" (its menu item \(TreeFormat.clean(hit.path, limit: 60)) is disabled while \(c.name) is in the background)")
                try input.press(chord, pid: c.pid)
                return "Pressed \(shown) (menu item \(TreeFormat.clean(hit.path, limit: 80))) with \(c.name) in front."
            }
            if let hit {
                let err = AX.perform(hit.item, kAXPressAction)
                if AXActionOutcome(rawError: err.rawValue) == .failed {
                    throw TurboError(.actionError, "Pressing the menu item \(TreeFormat.clean(hit.path, limit: 80)) failed (AXError \(err.rawValue)).")
                }
                Log.info("sendKeys: \(LogText.peer(shown)) in the background → menu item \(LogText.peer(hit.path))")
                return "Pressed the menu item \(TreeFormat.clean(hit.path, limit: 80)) (shortcut \(shown)) through accessibility; \(c.name) stayed in the background."
            }
            if MenuShortcutMatcher.needsMenu(chord) {
                try borrowFront(c, what: "the shortcut \"\(shown)\" (no menu item of \(c.name) has it, and ⌘-shortcuts only reach the app in front)")
                try input.press(chord, pid: c.pid)
                return "Pressed \(shown) with \(c.name) in front."
            }
        }
        if route == .background, chord.keyCode == USKeyboard.returnKeyCode, chord.modifiers.isEmpty,
            let focused = AX.focusedElement(pid: c.pid), Self.isInPlaceEditor(focused)
        {
            // Return commits an in-place editor (a rename field) only as a real key press.
            try borrowFront(c, what: "committing the in-place editor with Return")
            try input.press(chord, pid: c.pid)
            return "Pressed Return in the in-place editor with \(c.name) in front, to commit it."
        }
        if route == .background, let key = DialogKey.from(chord), let note = try dialogButtonViaAX(key, shown: shown, c) {
            return note
        }
        if route == .background { c.extras.addNote(FocusModeText.backgroundKeysNote(app: c.name)) }
        if Self.isBareDeadKey(chord) {
            // On this layout the key is a dead key: pressing it alone would only start a
            // composition in the app, so deliver the character itself.
            try input.typeUnicode(chord.keyName, pid: c.pid)
        } else {
            try input.press(chord, pid: c.pid)
        }
        return nil
    }

    /// Return / Escape in the background: the focused window's default / cancel button
    /// is a key equivalent, which AppKit handles only in the active app — press the button
    /// through accessibility instead. nil = no such button here (the key is posted).
    func dialogButtonViaAX(_ key: DialogKey, shown: String, _ c: ActionContext) throws -> String? {
        let appEl = AX.application(c.pid)
        let focused = AX.focusedElement(pid: c.pid)
        guard key.applies(focusedRole: focused.flatMap { AX.string($0, kAXRoleAttribute) }),
            let window = AX.element(appEl, kAXFocusedWindowAttribute),
            let button = AX.element(window, key.windowAttribute), AX.bool(button, kAXEnabledAttribute) != false,
            AX.actions(button).contains(kAXPressAction)
        else { return nil }
        let title = TreeFormat.clean(AX.string(button, kAXTitleAttribute) ?? AX.string(button, kAXDescriptionAttribute) ?? "", limit: 40)
        let err = AX.perform(button, kAXPressAction)
        if AXActionOutcome(rawError: err.rawValue) == .failed {
            throw TurboError(.actionError, "Pressing the window's \(key == .defaultButton ? "default" : "cancel") button \"\(title)\" failed (AXError \(err.rawValue)).")
        }
        Log.info("sendKeys: \(LogText.peer(shown)) in the background → \(key == .defaultButton ? "default" : "cancel") button \(LogText.peer(title))")
        return "Pressed the window's \(key == .defaultButton ? "default" : "cancel") button \"\(title)\" through accessibility (\(shown)); \(c.name) stayed in the background."
    }

    /// ⌘W in the background when Close is unavailable from the menu (disabled while the
    /// app is inactive): press the close button of the app's focused window through
    /// accessibility. nil = not ⌘W or no such button.
    func closeWindowViaAX(_ chord: KeyChord, _ c: ActionContext) throws -> String? {
        guard chord.modifiers == [.command], chord.keyName.lowercased() == "w" else { return nil }
        let appEl = AX.application(c.pid)
        guard let window = AX.element(appEl, kAXFocusedWindowAttribute) ?? AX.element(appEl, kAXMainWindowAttribute),
            let button = AX.element(window, kAXCloseButtonAttribute), AX.actions(button).contains(kAXPressAction)
        else { return nil }
        let title = TreeFormat.clean(AX.string(window, kAXTitleAttribute) ?? "", limit: 60)
        let err = AX.perform(button, kAXPressAction)
        if AXActionOutcome(rawError: err.rawValue) == .failed {
            throw TurboError(.actionError, "Pressing the close button of the window \"\(title)\" failed (AXError \(err.rawValue)).")
        }
        Log.info("sendKeys: cmd+w in the background → close button of \(LogText.peer(title))")
        return "Closed the window \"\(title)\" with its close button through accessibility (⌘W); \(c.name) stayed in the background."
    }

    /// ⌘A / ⌘C / ⌘X / ⌘V on the focused text element through accessibility (background,
    /// when the Edit menu item is unavailable). nil = not possible here.
    func textEditViaAX(_ edit: TextEditShortcut, _ c: ActionContext) throws -> String? {
        guard let el = AX.focusedElement(pid: c.pid), AX.secureCheck(el) == .notSecure,
            let value = AX.string(el, kAXValueAttribute)
        else { return nil }
        switch edit {
        case .selectAll:
            guard AX.isSettable(el, kAXSelectedTextRangeAttribute) else { return nil }
            var r = CFRange(location: 0, length: (value as NSString).length)
            guard let v = AXValueCreate(.cfRange, &r), AX.set(el, kAXSelectedTextRangeAttribute, v) == .success else { return nil }
            return "Selected all text of the focused element through accessibility (⌘A); \(c.name) stayed in the background."
        case .copy, .cut:
            guard let selected = AX.string(el, kAXSelectedTextAttribute), !selected.isEmpty else { return nil }
            if edit == .cut, !AX.isSettable(el, kAXSelectedTextAttribute) { return nil }
            DispatchQueue.main.sync {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(selected, forType: .string)
            }
            if edit == .cut, AX.set(el, kAXSelectedTextAttribute, "" as CFString) != .success {
                return "Copied the selected text, but removing it through accessibility failed (⌘X)."
            }
            return "\(edit == .cut ? "Cut" : "Copied") the selected text (\(selected.count) character(s)) through accessibility (\(edit == .cut ? "⌘X" : "⌘C")); \(c.name) stayed in the background."
        case .paste:
            guard let text = DispatchQueue.main.sync(execute: { NSPasteboard.general.string(forType: .string) }), !text.isEmpty,
                insertViaAX(text, into: el)
            else { return nil }
            return "Inserted the clipboard's text (\(text.count) character(s)) through accessibility (⌘V); \(c.name) stayed in the background."
        }
    }

    /// `paste`: the content goes on the pasteboard (the user's contents saved), ⌘V
    /// is delivered (the Paste menu item in the background), the helper waits until the app
    /// read the pasteboard (≤ 1 s) and puts the user's contents back unless they changed.
    func paste(_ text: String, format: PasteFormat, _ c: ActionContext) throws -> String? {
        let route = try keyRoute(c, what: "pasting (⌘V)")
        try refuseIfSecureInput(pid: c.pid, appName: c.name)
        let pasteChord = KeyChord(keyCode: KeyboardLayout.characterMap["v"]?.keyCode ?? 0x09, modifiers: [.command], keyName: "v")
        var menuItem: MenuShortcuts.Hit?
        if route == .background {
            if let hit = MenuShortcuts.find(pasteChord, pid: c.pid), hit.enabled {
                menuItem = hit
            } else {
                // Edit ▸ Paste is disabled while the app is inactive: plain text goes in
                // through accessibility (the clipboard is not touched); formatted text, or
                // an element that does not take it, borrows the front.
                let plain = PastePayload.make(text: text, format: format).plain
                if format == .text, let el = AX.focusedElement(pid: c.pid), canInsertViaAX(el), insertViaAX(plain, into: el) {
                    return "Inserted \(plain.count) character(s) through accessibility (plain text; \(c.name) is in the background, so its Paste command was not available). The clipboard was not used."
                }
                try borrowFront(c, what: "pasting (\(c.name) has no enabled Paste menu item to use in the background)")
                if let hit = MenuShortcuts.find(pasteChord, pid: c.pid), hit.enabled { menuItem = hit }
            }
        }
        if let target = AX.focusedElement(pid: c.pid) {
            try travel(c, to: aimPoint(of: target, app: c.app), moving: PointerLabel.moving(to: pillName(target, app: c.name)), arrived: PointerLabel.typing)
        }
        let payload = PastePayload.make(text: text, format: format)
        let swap = PasteboardSwap()
        DispatchQueue.main.sync { swap.install(payload) }
        swap.pasteSentAt = Date()
        do {
            if let menuItem {
                let err = AX.perform(menuItem.item, kAXPressAction)
                if AXActionOutcome(rawError: err.rawValue) == .failed {
                    throw TurboError(.actionError, "Pressing \(TreeFormat.clean(menuItem.path, limit: 60)) failed (AXError \(err.rawValue)).")
                }
            } else {
                try input.press(pasteChord, pid: c.pid)
            }
        } catch {
            _ = DispatchQueue.main.sync { swap.restore() }
            throw error
        }
        let reads = swap.waitForRead(timeout: PasteRestore.readTimeout, quiet: PasteRestore.readQuiet)
        let decision = DispatchQueue.main.sync { swap.restore() }
        var parts = ["Pasted \(text.count) character(s) as \(format.rawValue)\(menuItem.map { " with the menu item \(TreeFormat.clean($0.path, limit: 60))" } ?? " (⌘V)")."]
        if reads.isEmpty {
            parts.append("\(c.name) did not read the clipboard within \(Int(PasteRestore.readTimeout)) s, so the paste may not have happened (is a text field focused?); call observe_app to check.")
        }
        if swap.readsBeforePaste > 0 {
            parts.append("Another app read the clipboard before the paste (a clipboard manager, or the user pasting): check the result.")
        }
        switch decision {
        case .restore: parts.append("The user's clipboard was restored.")
        case .leaveChanged: parts.append("The clipboard changed meanwhile (the user copied something), so it was left as it is.")
        }
        Log.info("paste: \(text.count) char(s) as \(format.rawValue) into \(LogText.peer(c.name)), \(reads.count) read(s), \(decision == .restore ? "restored" : "left changed")")
        return parts.joined(separator: " ")
    }

    /// Move the agent pointer's tip to `point` — the same global point the action then
    /// posts its events at (or, for an accessibility action, the element's visible centre)
    /// — and wait for it to arrive. The pill says `moving` on the way and `arrived` there.
    /// Throws if the user stopped (or the screen locked / the deadline passed) meanwhile:
    /// nothing has been posted then.
    ///
    /// `hover` (mouse actions: click, scroll, drag start): once the pointer is there, post
    /// the final approach — a few mouse-moved events within a few points of `point`,
    /// ending exactly on it — and a short pause, so apps that take the click position from
    /// the last mouse-moved event (Blender) see the mouse there before mouseDown, without
    /// ever sweeping it across other controls. `assist` (button actions:
    /// click, drag): for apps that need the user's real pointer over their window, move it
    /// onto `point` first (`ActionExtras.finishAssist` puts it
    /// back). Otherwise the user's real cursor is never moved.
    func travel(
        _ c: ActionContext, to point: CGPoint?, moving: String, arrived: String, hover: Bool = false,
        assist: Bool = false
    ) throws {
        guard let point, GeometryGuard.sanePoint(point) != nil else { return }
        if hover, !isFrontmost(c.pid), focusNeed(bundleId: c.app.key) != .background {
            // Mouse input this app would ignore in the background: refuse before
            // anything is posted.
            throw TurboError(.userActive, FocusModeText.foregroundInputMessage(app: c.name, what: "mouse input (clicks, scrolling, dragging)"))
        }
        let frame = c.app.window.flatMap { AX.frame($0) } ?? c.app.windowFrame
        let hoverSettings = HoverSettings.load(paths.settings)
        // When the real pointer does the click, the agent pointer's glide is only for show.
        let realPointer = assist && (hoverSettings.needsRealPointer(bundleId: c.app.key) || focusNeed(bundleId: c.app.key) == .frontWithRealPointer)
        if let pointer {
            let ok = pointer.travel(
                to: point, moving: PointerLabel.truncate(moving), arrived: PointerLabel.truncate(arrived),
                windowFrame: frame, pid: c.pid, targetFront: isFrontmost(c.pid), waitForArrival: !realPointer,
                interrupted: c.interrupted)
            if !ok {
                throw interruptionError(c.sessionId, deadline: c.deadline, detail: "Nothing was sent.")
            }
        }
        guard hover else { return }
        if assist { try placeRealPointer(c, at: point, settings: hoverSettings) }
        guard hoverSettings.enabled else { return }
        let poster = HoverPoster(
            input: input, pid: c.pid, target: point, from: c.app.lastMousePoint, windowFrame: frame,
            settings: hoverSettings)
        if !poster.post(interrupted: c.interrupted) {
            throw interruptionError(c.sessionId, deadline: c.deadline, detail: poster.detailIfStopped)
        }
        c.app.lastMousePoint = point
    }

    /// Real-pointer assist: for apps listed in settings `hover.realPointerApps`, move
    /// the user's real pointer onto `point` — only when the app already is in front and
    /// nobody is using the mouse or keyboard. Otherwise 4022 userActive with nothing sent:
    /// the helper never activates the app or takes the mouse from the user.
    func placeRealPointer(_ c: ActionContext, at point: CGPoint, settings: HoverSettings) throws {
        var settings = settings
        if focusNeed(bundleId: c.app.key) == .frontWithRealPointer, !settings.needsRealPointer(bundleId: c.app.key) {
            settings.realPointerApps.append(c.app.key)  // learned
        }
        if settings.needsRealPointer(bundleId: c.app.key) {
            // Wait (≤ 2 s) for a pause in the user's mouse / keyboard use before borrowing the pointer.
            let idle = RealPointerAssistPolicy.idleSeconds
            let until = Date().addingTimeInterval(FocusSettings.forceFrontMaxWait)
            while (UserInput.mouse < idle || UserInput.keyboard < idle), Date() < until, !c.interrupted() { usleep(100_000) }
        }
        let decision = RealPointerAssistPolicy.decide(
            settings: settings, bundleId: c.app.key, targetFront: isFrontmost(c.pid),
            secondsSinceUserMouse: UserInput.mouse, secondsSinceKeyboard: UserInput.keyboard)
        switch decision {
        case .notNeeded:
            return
        case .refused(let reason):
            Log.info("real-pointer assist for \(LogText.peer(c.name)) refused: \(reason.rawValue)")
            throw TurboError(.userActive, RealPointerAssistPolicy.refusedMessage(app: c.name, reason: reason))
        case .assist:
            let a = c.extras.assist ?? RealPointerAssist(appName: c.name)
            c.extras.assist = a
            pointer?.announce(PointerLabel.borrowingMouse)
            a.place(at: point)
            c.extras.addNote(RealPointerAssistPolicy.note(app: c.name))
        }
    }

    /// Centre of the element's visible part without scrolling (nil = not visible) — the
    /// same computation `center(of:)` uses for the mouse fallback.
    func aimPoint(of el: AXUIElement, app: AppSessionState) -> CGPoint? {
        visibleCenter(of: el, app: app)
    }

    /// Short name of an element for the pointer's pill.
    func pillName(_ el: AXUIElement?, app: String) -> String {
        guard let el, !AX.isSecure(el) else { return app }
        for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute] {
            if let v = AX.string(el, attr)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
        }
        if let role = AX.string(el, kAXRoleDescriptionAttribute), !role.isEmpty { return role }
        return app
    }
}

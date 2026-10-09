import AppKit
import CoreGraphics
import TurboCore
import Foundation

/// Synthesizes mouse / keyboard input with `CGEvent.postToPid`.
///
/// Events go straight to the target process; the user's real cursor is never warped.
/// Every event is tagged in `eventSourceUserData` so our own Esc presses are not
/// mistaken for the user's Stop gesture by the overlay's key monitors.
///
/// Routing pid-targeted mouse/scroll events: AppKit dispatches such an event to a window
/// only if the event names the window (undocumented event field 51, plus the public
/// `mouseEventWindowUnderMousePointer…` fields) and carries a window-local location,
/// which is set with CoreGraphics' exported-but-undocumented `CGEventSetWindowLocation`
/// (looked up with `dlsym`, so a missing symbol degrades gracefully instead of failing
/// to launch). Without these, the event reaches the process but no view sees it.
final class InputSynthesizer {
    /// "CUTB" — marks events we synthesized.
    static let eventTag: Int64 = 0x4355_5442

    /// Undocumented `CGEventField` that carries the target window number.
    private static let windowNumberField = CGEventField(rawValue: 51)

    private typealias SetWindowLocationFn = @convention(c) (CGEvent, CGPoint) -> Void
    private static let setWindowLocation: SetWindowLocationFn? = {
        guard let handle = dlopen(nil, RTLD_NOW), let sym = dlsym(handle, "CGEventSetWindowLocation") else {
            return nil
        }
        return unsafeBitCast(sym, to: SetWindowLocationFn.self)
    }()

    /// Address `event` to `window` (number + window-local location of `point`).
    private func route(_ event: CGEvent, at point: CGPoint, window: WindowList.Info?) {
        guard let window else { return }
        let number = Int64(window.number)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: number)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: number)
        if let field = Self.windowNumberField { event.setIntegerValueField(field, value: number) }
        if let setLocation = Self.setWindowLocation {
            setLocation(event, CGPoint(x: point.x - window.bounds.minX, y: point.y - window.bounds.minY))
        }
    }

    private let source: CGEventSource?

    init() {
        // A private state source keeps the user's physically held modifiers out of our events.
        source = CGEventSource(stateID: .privateState)
    }

    /// Post through the window server like real input (to whatever window has the keyboard /
    /// is under the pointer) instead of to the pid: for UI another process draws inside the
    /// app (system open / save panels in a sheet), which events posted to the app never reach.
    /// Only ever set while the app is in front (a borrowed front) and the user is idle.
    var routeThroughSystem = false
    /// Monotonic time of the latest event posted through the window server (it counts as HID
    /// input; the borrowed-front hand-back must not take it for the user's).
    private(set) var lastSystemPost: TimeInterval?

    private func send(_ e: CGEvent, _ pid: pid_t) {
        if routeThroughSystem {
            e.post(tap: .cghidEventTap)
            lastSystemPost = ProcessInfo.processInfo.systemUptime
        } else {
            e.postToPid(pid)
        }
    }

    private func tag(_ e: CGEvent) {
        e.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
    }

    private func pause(_ ms: Int) { usleep(useconds_t(ms * 1000)) }

    // MARK: mouse

    private func mouseTypes(_ button: MouseButton) -> (down: CGEventType, up: CGEventType, drag: CGEventType, cg: CGMouseButton) {
        switch button {
        case .left: return (.leftMouseDown, .leftMouseUp, .leftMouseDragged, .left)
        case .right: return (.rightMouseDown, .rightMouseUp, .rightMouseDragged, .right)
        case .middle: return (.otherMouseDown, .otherMouseUp, .otherMouseDragged, .center)
        }
    }

    private func mouseEvent(
        _ type: CGEventType, at point: CGPoint, button: CGMouseButton, clickState: Int, window: WindowList.Info?
    ) -> CGEvent? {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        else { return nil }
        e.flags = []
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        if button == .center { e.setIntegerValueField(.mouseEventButtonNumber, value: 2) }
        route(e, at: point, window: window)
        tag(e)
        return e
    }

    /// One `kCGEventMouseMoved` at `move.point` (with its integer deltas), routed like a
    /// click (window number fields + window-local location). Posted to the pid only: the
    /// user's real cursor does not move. Apps such as Blender take the click position
    /// and hover state from the last mouse-moved event.
    func moveMouse(_ move: HoverMove, pid: pid_t, window: WindowList.Info?) {
        guard
            let e = CGEvent(
                mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: move.point, mouseButton: .left)
        else { return }
        e.flags = []
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(move.dx))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(move.dy))
        route(e, at: move.point, window: window)
        tag(e)
        e.postToPid(pid)
    }

    /// Click `count` times (click state 1…count, so the app sees a double/triple click).
    func click(at point: CGPoint, button: MouseButton, count: Int, pid: pid_t, window: WindowList.Info?) throws {
        let t = mouseTypes(button)
        for n in 1...max(1, count) {
            guard let down = mouseEvent(t.down, at: point, button: t.cg, clickState: n, window: window),
                let up = mouseEvent(t.up, at: point, button: t.cg, clickState: n, window: window)
            else { throw TurboError(.actionError, "Could not create mouse events.") }
            send(down, pid)
            pause(30)
            send(up, pid)
            pause(n < count ? 60 : 20)
        }
    }

    /// mouseDown at `from`, ≥ 10 interpolated drags (each carrying its integer delta), and
    /// mouseUp at `to`. Returns false if `shouldStop` interrupted it: nothing is posted if
    /// it is already true, and a drag stopped midway moves back to `from` and releases
    /// there (a no-op drop) — releasing at `to` would complete the drop the user stopped.
    /// `onStep(point, seconds)` reports each posted position (the agent pointer follows it).
    func drag(
        from: CGPoint, to: CGPoint, pid: pid_t, window: WindowList.Info?, shouldStop: () -> Bool,
        onStep: (CGPoint, TimeInterval) -> Void = { _, _ in }
    ) throws -> Bool {
        if shouldStop() { return false }
        guard let down = mouseEvent(.leftMouseDown, at: from, button: .left, clickState: 1, window: window)
        else { throw TurboError(.actionError, "Could not create mouse events.") }
        down.postToPid(pid)
        pause(60)
        var last = from
        var interrupted = false
        for step in DragPlan.steps(from: from, to: to) {
            if shouldStop() {
                interrupted = true
                break
            }
            postDragged(step, pid: pid, window: window)
            onStep(step.point, 0.012)
            last = step.point
            pause(12)
        }
        pause(40)
        if interrupted {
            if last != from {
                postDragged(DragPlan.returnStep(from: last, to: from), pid: pid, window: window)
                onStep(from, 0.012)
                pause(12)
            }
            mouseEvent(.leftMouseUp, at: from, button: .left, clickState: 1, window: window)?.postToPid(pid)
            pause(20)
            return false
        }
        mouseEvent(.leftMouseUp, at: to, button: .left, clickState: 1, window: window)?.postToPid(pid)
        pause(20)
        return true
    }

    /// A drag with the real mouse (system drags): the events go
    /// through the HID event tap, so the real cursor moves and a system drag session
    /// (Finder files, …) follows it. The caller borrows the front first and makes sure the
    /// user is not using the mouse; the cursor is put back afterwards. Same stop semantics
    /// as `drag`.
    func dragWithRealPointer(
        from: CGPoint, to: CGPoint, shouldStop: () -> Bool, onStep: (CGPoint, TimeInterval) -> Void = { _, _ in }
    ) throws -> Bool {
        if shouldStop() { return false }
        let original = CGEvent(source: nil)?.location
        defer {
            if let original {
                pause(60)
                CGWarpMouseCursorPosition(original)
            }
        }
        func post(_ type: CGEventType, _ p: CGPoint, dx: Int = 0, dy: Int = 0) {
            guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
            else { return }
            e.flags = []
            e.setIntegerValueField(.mouseEventClickState, value: 1)
            if type == .leftMouseDragged || type == .mouseMoved {
                e.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
                e.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
            }
            tag(e)
            e.post(tap: .cghidEventTap)
        }
        post(.mouseMoved, from)
        pause(80)
        post(.leftMouseDown, from)
        pause(120)
        var last = from
        var interrupted = false
        // Slower than the posted drag: drag sessions start after a few points of movement
        // and drop targets highlight on hover.
        for step in DragPlan.steps(from: from, to: to) {
            if shouldStop() {
                interrupted = true
                break
            }
            post(.leftMouseDragged, step.point, dx: Int(step.dx), dy: Int(step.dy))
            onStep(step.point, 0.03)
            last = step.point
            pause(30)
        }
        if interrupted {
            if last != from { post(.leftMouseDragged, from) }
            pause(60)
            post(.leftMouseUp, from)
            return false
        }
        // Hover over the drop target so it accepts the drop.
        post(.leftMouseDragged, to)
        pause(250)
        post(.leftMouseUp, to)
        pause(150)
        return true
    }

    private func postDragged(_ step: DragStep, pid: pid_t, window: WindowList.Info?) {
        guard let e = mouseEvent(.leftMouseDragged, at: step.point, button: .left, clickState: 1, window: window)
        else { return }
        // postToPid delivers the event as built; nothing fills in the deltas for us.
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(step.dx))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(step.dy))
        e.postToPid(pid)
    }

    /// Scroll-wheel events in line units at `point`. Positive `dy` scrolls up, positive `dx` left.
    func scroll(at point: CGPoint, dy: Int, dx: Int, pid: pid_t, window: WindowList.Info?) {
        // Deliver in small increments, like a physical wheel.
        var remainingY = dy
        var remainingX = dx
        while remainingY != 0 || remainingX != 0 {
            let stepY = max(-3, min(3, remainingY))
            let stepX = max(-3, min(3, remainingX))
            remainingY -= stepY
            remainingX -= stepX
            guard
                let e = CGEvent(
                    scrollWheelEvent2Source: source, units: .line, wheelCount: 2,
                    wheel1: Int32(stepY), wheel2: Int32(stepX), wheel3: 0)
            else { return }
            e.location = point
            e.flags = []
            route(e, at: point, window: window)
            tag(e)
            e.postToPid(pid)
            pause(16)
        }
    }

    /// Scroll-wheel lines posted through the window server, as a real mouse does, for an app
    /// that takes input only under the real pointer (the caller placed the pointer over its
    /// window and the app is in front). Such views (mirrored phone screens, apps drawing their
    /// own UI) move about a point per line, so `dy` / `dx` here are in points.
    func scrollThroughSystem(at point: CGPoint, dy: Int, dx: Int) {
        var remainingY = dy
        var remainingX = dx
        while remainingY != 0 || remainingX != 0 {
            let stepY = max(-40, min(40, remainingY))
            let stepX = max(-40, min(40, remainingX))
            remainingY -= stepY
            remainingX -= stepX
            guard
                let e = CGEvent(
                    scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: Int32(stepY), wheel2: Int32(stepX),
                    wheel3: 0)
            else { return }
            e.location = point
            e.flags = []
            tag(e)
            e.post(tap: .cghidEventTap)
            lastSystemPost = ProcessInfo.processInfo.systemUptime
            pause(16)
        }
    }

    // MARK: keyboard

    private func keyEvent(_ code: UInt16, down: Bool, flags: CGEventFlags) -> CGEvent? {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down) else { return nil }
        e.flags = flags
        tag(e)
        return e
    }

    /// Press a chord: modifier downs, key down/up, modifier ups. A modifier key pressed
    /// on its own ("Shift_L") is a flags-changed down / up pair.
    func press(_ chord: KeyChord, pid: pid_t) throws {
        if let own = chord.modifierFlag {
            var held: CGEventFlags = []
            var pressed: [(ModifierFlags, UInt16)] = []
            for (flag, code) in ModifierFlags.pressOrder where chord.modifiers.contains(flag) {
                held.insert(CGEventFlags(rawValue: flag.rawValue))
                if let e = keyEvent(code, down: true, flags: held) {
                    e.type = .flagsChanged
                    send(e, pid)
                }
                pressed.append((flag, code))
                pause(8)
            }
            guard let down = keyEvent(chord.keyCode, down: true, flags: held.union(CGEventFlags(rawValue: own.rawValue))),
                let up = keyEvent(chord.keyCode, down: false, flags: held)
            else { throw TurboError(.actionError, "Could not create keyboard events.") }
            down.type = .flagsChanged
            up.type = .flagsChanged
            send(down, pid)
            pause(25)
            send(up, pid)
            pause(8)
            for (flag, code) in pressed.reversed() {
                held.remove(CGEventFlags(rawValue: flag.rawValue))
                if let e = keyEvent(code, down: false, flags: held) {
                    e.type = .flagsChanged
                    send(e, pid)
                }
                pause(8)
            }
            return
        }
        var held: CGEventFlags = []
        var pressedModifiers: [(ModifierFlags, UInt16)] = []
        for (flag, code) in ModifierFlags.pressOrder where chord.modifiers.contains(flag) {
            held.insert(CGEventFlags(rawValue: flag.rawValue))
            keyEvent(code, down: true, flags: held).map { send($0, pid) }
            pressedModifiers.append((flag, code))
            pause(8)
        }
        let keyFlags = held.union(CGEventFlags(rawValue: chord.impliedHardwareFlags.rawValue))
        guard let down = keyEvent(chord.keyCode, down: true, flags: keyFlags),
            let up = keyEvent(chord.keyCode, down: false, flags: keyFlags)
        else { throw TurboError(.actionError, "Could not create keyboard events.") }
        send(down, pid)
        pause(25)
        send(up, pid)
        pause(8)
        for (flag, code) in pressedModifiers.reversed() {
            held.remove(CGEventFlags(rawValue: flag.rawValue))
            keyEvent(code, down: false, flags: held).map { send($0, pid) }
            pause(8)
        }
    }

    /// Deliver one `writeText` segment: text (≤ 20 UTF-16 units, the
    /// unit of the safety checks) goes out ONE character per keyDown/keyUp pair — the
    /// layout's real keycode + shift when the character is on a key, else Unicode-only —
    /// with `keyDelayMs` after each; tabs are a Unicode tab, newlines a real Return key
    /// press. `TypingDriver` decides when segments are delivered and runs the safety
    /// checks; `shouldStop` is polled between characters.
    func deliver(_ segment: TypingSegment, pid: pid_t, keyDelayMs: Int = TypingSettings.defaults.keyDelayMs) throws {
        switch segment {
        case .returnKey:
            try press(KeyChord(keyCode: USKeyboard.returnKeyCode, modifiers: [], keyName: "return"), pid: pid)
        case .tab:
            try typeUnicode("\t", pid: pid)
        case .text(let chunk):
            let keys = KeyTyping.plan(
                chunk, characterMap: KeyboardLayout.characterMap, deadKeys: KeyboardLayout.deadKeyCharacters)
            for key in keys { try type(key, pid: pid, delayMs: keyDelayMs) }
        }
    }

    /// One character: keyDown/keyUp on its real key (or the carrier key) with the
    /// character as the events' Unicode string, then `delayMs`.
    func type(_ key: TypedKey, pid: pid_t, delayMs: Int) throws {
        let code = key.keyCode ?? USKeyboard.unicodeCarrierKeyCode
        let flags: CGEventFlags = key.shift ? .maskShift : []
        guard let down = keyEvent(code, down: true, flags: flags), let up = keyEvent(code, down: false, flags: flags)
        else { throw TurboError(.actionError, "Could not create keyboard events.") }
        let units = Array(key.text.utf16)
        units.withUnsafeBufferPointer { buf in
            down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
        }
        send(down, pid)
        pause(4)
        send(up, pid)
        pause(max(0, delayMs))
    }

    /// One key down/up pair carrying `chunk` as its Unicode string.
    func typeUnicode(_ chunk: String, pid: pid_t) throws {
        let units = Array(chunk.utf16)
        guard let down = keyEvent(USKeyboard.unicodeCarrierKeyCode, down: true, flags: []),
            let up = keyEvent(USKeyboard.unicodeCarrierKeyCode, down: false, flags: [])
        else { throw TurboError(.actionError, "Could not create keyboard events.") }
        units.withUnsafeBufferPointer { buf in
            down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
        }
        send(down, pid)
        pause(4)
        send(up, pid)
        pause(12)
    }
}

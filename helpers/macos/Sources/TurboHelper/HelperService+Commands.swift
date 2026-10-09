import AppKit
import ImageIO
import ApplicationServices
import TurboCore
import Foundation

// Menu commands: listing them and running one in the background.
extension HelperService {
    /// `appCommands {app, knownSignature?, checkPaths?, launch?}`: the app's menu commands, or
    /// `unchanged` when `knownSignature` still matches; `states` tells whether each of
    /// `checkPaths` can run right now.
    func appCommands(env: RequestEnvelope, resolved: inout ResolvedApp) throws -> JSONValue {
        if resolved.runningApplication == nil {
            guard env.payload["launch"]?.boolValue ?? true else {
                return ["resolved": resolved.json, "running": false]
            }
            resolved = try launch(resolved)
        }
        guard let pid = resolved.pid else { throw TurboError(.helperFault, "The app has no pid.") }
        let started = Date()
        // Menu items are validated against the key window, which an app in the background
        // does not have: their enabled state means something only while the app is in front.
        let front = isFrontmost(pid)
        let signature = MenuIndex.signature(pid: pid, appPath: resolved.path)
        var out: [String: JSONValue] = ["resolved": resolved.json, "running": true, "signature": .string(signature)]
        // Chromium-based apps fill their menus for their active window, which they only
        // have while in front: read in the background, the list is partial.
        if !front, Self.actsOnActiveWindow(pid: pid) { out["partial"] = true }
        if let known = env.payload["knownSignature"]?.stringValue, known == signature, !signature.isEmpty {
            out["unchanged"] = true
        } else {
            let read = MenuIndex.read(pid: pid)
            out["commands"] = .array(read.commands.map { c in
                var c = c
                if !front { c.enabled = nil }
                return c.json
            })
            out["truncated"] = .bool(read.truncated)
            Log.info(
                "appCommands \(resolved.bundleId): read \(read.commands.count) command(s) in \(Int(Date().timeIntervalSince(started) * 1000)) ms\(read.truncated ? " (cut short)" : "")")
        }
        if let paths = env.payload["checkPaths"]?.arrayValue {
            out["states"] = .array(paths.prefix(50).map { p in
                guard let titles = p.arrayValue?.compactMap(\.stringValue), !titles.isEmpty,
                    let hit = MenuIndex.locate(titles, pid: pid)
                else { return .null }
                if hit.hasSubmenu { return ["enabled": false] }
                return front ? ["enabled": .bool(hit.enabled)] : ["found": true]
            })
        }
        return .object(out)
    }

    /// Step `runCommand`: press a menu command through accessibility, in the background.
    /// A command the app disables while it is inactive gets a borrowed front.
    func runCommand(_ path: [String], _ c: ActionContext) throws -> String {
        let shown = MenuTitle.display(path)
        guard path.count >= 2 else {
            throw TurboError(.badArguments, "\"\(shown)\" is a whole menu; name a command inside it (use find_command).")
        }
        if Self.menuIsOpen(pid: c.pid) { closeOpenMenu(pid: c.pid) }
        guard var hit = MenuIndex.locate(path, pid: c.pid) else {
            throw TurboError(
                .badArguments,
                "\(c.name) has no menu command \(shown) right now (menus can change with the window or document in front). Call find_command to see the current commands.")
        }
        guard !hit.hasSubmenu else {
            throw TurboError(.badArguments, "\(MenuTitle.display(hit.path)) opens a submenu; name one of its commands (use find_command).")
        }
        pointer?.announce(PointerLabel.pressing(path.last ?? shown))
        var inFront = isFrontmost(c.pid)
        if !inFront, Self.actsOnActiveWindow(pid: c.pid) {
            // Chromium-based apps run menu commands in their active window, which they only
            // have while in front: in the background a command meant for a window acts on a
            // new one (VS Code's New Text File opened a new window).
            try borrowFront(c, what: "the command \(shown) (\(c.name) runs menu commands in its active window, which it only has while in front)")
            inFront = true
            usleep(150_000)
            if let again = MenuIndex.locate(path, pid: c.pid) { hit = again }
        }
        let windowsBefore = Self.windowsAndSheets(pid: c.pid)
        let commandKey = MenuTitle.display(hit.path).lowercased()
        if hit.enabled, !inFront {
            // Right after the app was in front its menu items still read as they did there
            // (validated against its key window); pressed in the background now they would do
            // nothing. Wait until the state is the app's background one again.
            if let at = handedBackAt[c.pid] {
                let left = Self.staleMenuStateSeconds - (ProcessInfo.processInfo.systemUptime - at)
                if left > 0 {
                    usleep(useconds_t(left * 1_000_000))
                    if let again = MenuIndex.locate(path, pid: c.pid) { hit = again }
                }
            }
            // A command already seen greyed out in the background works only in front.
            if frontOnlyCommands[c.app.key]?.contains(commandKey) == true { hit = MenuIndex.Located(item: hit.item, path: hit.path, enabled: false, hasSubmenu: hit.hasSubmenu) }
        }
        if !hit.enabled, !inFront {
            frontOnlyCommands[c.app.key, default: []].insert(commandKey)
            // Often greyed out only because the app is not active (AppKit validates menu
            // items against the key window).
            try borrowFront(c, what: "the command \(shown) (unavailable while \(c.name) is in the background)")
            inFront = true
            // The app revalidates its menus once it is active.
            let until = Date().addingTimeInterval(0.4)
            repeat {
                usleep(100_000)
                if let again = MenuIndex.locate(path, pid: c.pid) { hit = again }
            } while !hit.enabled && Date() < until
        }
        if !hit.enabled, inFront {
            // An app revalidates its menus when one opens or a shortcut is pressed, not when it
            // merely becomes active: press the item's own shortcut (validated like the
            // menu), else open its menu so the app revalidates it, then look again.
            if let chord = MenuIndex.chord(of: hit.item), hit.path.count >= 2 {
                try refuseIfSecureInput(pid: c.pid, appName: c.name)
                try input.press(chord, pid: c.pid)
                pointer?.press()
                Log.info("runCommand: \(LogText.peer(MenuTitle.display(hit.path))) via its shortcut (in front)")
                return "Ran \(MenuTitle.display(hit.path)) by pressing its shortcut with \(c.name) in front (the menu item only becomes available in an active app)."
            }
            if let top = MenuIndex.topItem(hit.path, pid: c.pid) {
                _ = AX.perform(top, kAXPressAction)
                usleep(250_000)
                if let again = MenuIndex.locate(path, pid: c.pid) { hit = again }
                if !hit.enabled { closeOpenMenu(pid: c.pid) }
            }
        }
        guard hit.enabled else {
            throw TurboError(
                .actionError,
                "The command \(MenuTitle.display(hit.path)) is unavailable (greyed out) in \(c.name) right now: it may need a selection or an open document, or a sheet or dialog of the app is open (observe_app shows it). Nothing was pressed.")
        }
        let err = AX.perform(hit.item, kAXPressAction)
        switch AXActionOutcome(rawError: err.rawValue) {
        case .performed, .probablyPerformed:
            pointer?.press()
            Log.info("runCommand: \(LogText.peer(MenuTitle.display(hit.path))) in \(LogText.peer(c.name))\(inFront ? " (in front)" : " (background)")")
            var note = "Ran the menu command \(MenuTitle.display(hit.path)) through accessibility" + (inFront ? "." : "; \(c.name) stayed in the background.")
            if let opened = Self.newWindowNote(before: windowsBefore, pid: c.pid, app: c.name) { note += " " + opened }
            return note
        case .elementGone:
            throw TurboError(.actionError, "The menu changed while pressing \(shown); call find_command and try again.")
        case .failed:
            throw TurboError(.actionError, "Pressing the menu command \(shown) failed (AXError \(err.rawValue)).")
        }
    }
}

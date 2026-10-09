import ApplicationServices
import TurboCore
import Foundation

/// Key equivalents through the menu bar: a ⌘-chord reaches an app only
/// while it is active, but the menu item that owns the shortcut can be pressed through
/// accessibility while the app stays in the background. Walks the app's menu bar
/// (≤ 3 levels, ≤ 600 items, 1.5 s), reading each item's shortcut attributes.
enum MenuShortcuts {
    struct Hit {
        let item: AXUIElement
        let title: String
        let path: String
        let enabled: Bool
    }

    static let shortcutAttributes = [
        "AXMenuItemCmdChar", "AXMenuItemCmdVirtualKey", "AXMenuItemCmdModifiers", kAXTitleAttribute, kAXEnabledAttribute,
        kAXChildrenAttribute, kAXRoleAttribute,
    ]

    /// The enabled menu item whose shortcut is `chord`, if any.
    static func find(_ chord: KeyChord, pid: pid_t) -> Hit? {
        guard let bar = AX.element(AX.application(pid), kAXMenuBarAttribute) else { return nil }
        let deadline = Date().addingTimeInterval(1.5)
        var visited = 0
        var fallback: Hit?
        func walk(_ el: AXUIElement, depth: Int, path: String) -> Hit? {
            if visited > 600 || Date() > deadline || depth > 4 { return nil }
            // The Apple menu (the first menu bar item) is the system's, not the app's: Lock
            // Screen, Log Out, Force Quit… are never pressed for a key chord.
            for child in (AX.elements(el, kAXChildrenAttribute) ?? []).enumerated().filter({ depth > 0 || $0.offset > 0 }).map(\.element) {
                visited += 1
                let (_, v) = AX.multiple(child, shortcutAttributes)
                let role = AX.stringValue(v[kAXRoleAttribute]) ?? ""
                let title = AX.stringValue(v[kAXTitleAttribute]) ?? ""
                if role == AXRoles.menuItem {
                    let ch = AX.stringValue(v["AXMenuItemCmdChar"])
                    let vk = (v["AXMenuItemCmdVirtualKey"] as? NSNumber)?.intValue
                    let mods = (v["AXMenuItemCmdModifiers"] as? NSNumber)?.intValue ?? 0
                    if (ch?.isEmpty == false) || vk != nil {
                        let shortcut = MenuShortcut(character: ch, virtualKey: vk, axModifiers: mods)
                        if MenuShortcutMatcher.matches(chord, shortcut) {
                            let enabled = AX.boolValue(v[kAXEnabledAttribute]) ?? true
                            let hit = Hit(item: child, title: title, path: path.isEmpty ? title : "\(path) ▸ \(title)", enabled: enabled)
                            if enabled { return hit }
                            fallback = fallback ?? hit
                        }
                    }
                }
                // Menu bar item → its menu → items; a menu item → its submenu.
                if role == AXRoles.menuBarItem || role == AXRoles.menu || role == AXRoles.menuItem || role == AXRoles.menuBar {
                    let nextPath = role == AXRoles.menu ? path : (path.isEmpty ? title : (title.isEmpty ? path : "\(path) ▸ \(title)"))
                    if let h = walk(child, depth: depth + 1, path: nextPath) { return h }
                }
            }
            return nil
        }
        return walk(bar, depth: 0, path: "") ?? fallback
    }
}

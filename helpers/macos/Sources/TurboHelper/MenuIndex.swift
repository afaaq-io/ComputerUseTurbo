import AppKit
import ApplicationServices
import TurboCore
import Foundation

/// The app's menu bar as a list of commands: every menu
/// item with its path of titles and its shortcut, read through accessibility without opening
/// a menu. The MCP server keeps the list on disk per app and asks again only when the
/// signature changes, so a returning agent finds commands instantly.
enum MenuIndex {
    struct Read {
        var commands: [AppCommand]
        var truncated: Bool
    }

    static let maxItems = 4000
    static let maxDepth = 6
    static let readBudget: TimeInterval = 6

    private static let itemAttributes = [
        kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXEnabledAttribute, kAXChildrenAttribute,
        "AXMenuItemCmdChar", "AXMenuItemCmdVirtualKey", "AXMenuItemCmdModifiers", "AXIdentifier",
    ]

    /// The app's own top-level menus: the Apple menu (the system's: Lock Screen, Log Out,
    /// Force Quit…) is never listed or pressed.
    static func topMenus(pid: pid_t) -> [(title: String, element: AXUIElement)] {
        guard let bar = AX.element(AX.application(pid), kAXMenuBarAttribute) else { return [] }
        let items = AX.elements(bar, kAXChildrenAttribute) ?? []
        return items.dropFirst().compactMap { item in
            let title = AX.string(item, kAXTitleAttribute) ?? ""
            return title.isEmpty ? nil : (title, item)
        }
    }

    /// Cheap change check: the app's version plus each top menu's title and item count.
    static func signature(pid: pid_t, appPath: String) -> String {
        var parts: [String] = []
        if let bundle = Bundle(path: appPath) {
            parts.append((bundle.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "")
            parts.append((bundle.infoDictionary?["CFBundleVersion"] as? String) ?? "")
        }
        for (title, item) in topMenus(pid: pid) {
            let menu = AX.elements(item, kAXChildrenAttribute)?.first
            let count = menu.flatMap { AX.elements($0, kAXChildrenAttribute)?.count } ?? 0
            parts.append("\(title)#\(count)")
        }
        return parts.joined(separator: "|")
    }

    /// Every command under the app's menus. Submenus that the system fills in (Services)
    /// are skipped; separators and untitled items too.
    static func read(pid: pid_t) -> Read {
        let deadline = Date().addingTimeInterval(readBudget)
        var out: [AppCommand] = []
        var truncated = false
        func walk(_ menuOwner: AXUIElement, path: [String], depth: Int) {
            guard depth <= maxDepth else { return }
            for menu in AX.elements(menuOwner, kAXChildrenAttribute) ?? [] where AX.string(menu, kAXRoleAttribute) == AXRoles.menu {
                let items = (AX.elements(menu, kAXChildrenAttribute) ?? []).map { ($0, AX.multiple($0, itemAttributes).1) }
                // Lists the app fills in itself (recent documents, history, open windows) are
                // content, not commands: they are never listed or saved.
                let ids = items.map { AX.stringValue($0.1["AXIdentifier"]) }
                let filled = AppFilledItems.identifiers(ids)
                let titles = items.map { AX.stringValue($0.1[kAXTitleAttribute]) ?? "" }
                let shortcuts = items.map { AX.stringValue($0.1["AXMenuItemCmdChar"]).map { !$0.isEmpty } ?? false }
                for (i, (item, v)) in items.enumerated() {
                    if MenuSection.isHeading(at: i, titles: titles, identifiers: ids, hasShortcut: shortcuts) { continue }
                    if out.count >= maxItems || Date() > deadline {
                        truncated = true
                        return
                    }
                    guard AX.stringValue(v[kAXRoleAttribute]) == AXRoles.menuItem else { continue }
                    if let id = AX.stringValue(v["AXIdentifier"]), filled.contains(id) { continue }
                    let title = (AX.stringValue(v[kAXTitleAttribute])).flatMap { $0.isEmpty ? nil : $0 }
                        ?? AX.stringValue(v[kAXDescriptionAttribute]) ?? ""
                    guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                    let itemPath = path + [title]
                    let children = (v[kAXChildrenAttribute]).flatMap { AX.elementArray($0) } ?? []
                    if !children.isEmpty {
                        walk(item, path: itemPath, depth: depth + 1)
                        continue
                    }
                    let ch = AX.stringValue(v["AXMenuItemCmdChar"])
                    let vk = (v["AXMenuItemCmdVirtualKey"] as? NSNumber)?.intValue
                    let mods = (v["AXMenuItemCmdModifiers"] as? NSNumber)?.intValue ?? 0
                    var shortcut: String?
                    if ch?.isEmpty == false || vk != nil {
                        shortcut = MenuShortcut(character: ch, virtualKey: vk, axModifiers: mods).comboText
                    }
                    out.append(AppCommand(path: itemPath, shortcut: shortcut, enabled: AX.boolValue(v[kAXEnabledAttribute]) ?? true))
                }
            }
        }
        for (title, item) in topMenus(pid: pid) {
            walk(item, path: [title], depth: 1)
            if truncated { break }
        }
        return Read(commands: out, truncated: truncated)
    }

    /// The item's own shortcut as a chord the helper can press, if it has one.
    static func chord(of item: AXUIElement) -> KeyChord? {
        let (_, v) = AX.multiple(item, ["AXMenuItemCmdChar", "AXMenuItemCmdVirtualKey", "AXMenuItemCmdModifiers"])
        let ch = AX.stringValue(v["AXMenuItemCmdChar"])
        let vk = (v["AXMenuItemCmdVirtualKey"] as? NSNumber)?.intValue
        guard ch?.isEmpty == false || vk != nil else { return nil }
        let mods = (v["AXMenuItemCmdModifiers"] as? NSNumber)?.intValue ?? 0
        guard let combo = MenuShortcut(character: ch, virtualKey: vk, axModifiers: mods).comboText else { return nil }
        return try? KeyChordParser.parse(combo, characterMap: KeyboardLayout.characterMap)
    }

    /// The top-level menu bar item of `path`.
    static func topItem(_ path: [String], pid: pid_t) -> AXUIElement? {
        guard let first = path.first else { return nil }
        return topMenus(pid: pid).first(where: { MenuTitle.same($0.title, first) })?.element
    }

    struct Located {
        let item: AXUIElement
        let path: [String]
        let enabled: Bool
        let hasSubmenu: Bool
    }

    /// The live menu item at `path` (titles compared without case or a trailing "…").
    static func locate(_ path: [String], pid: pid_t) -> Located? {
        guard let first = path.first, let top = topMenus(pid: pid).first(where: { MenuTitle.same($0.title, first) }) else {
            return nil
        }
        var owner = top.element
        var actual = [top.title]
        for (i, wanted) in path.dropFirst().enumerated() {
            guard let menu = (AX.elements(owner, kAXChildrenAttribute) ?? []).first(where: { AX.string($0, kAXRoleAttribute) == AXRoles.menu }),
                let item = (AX.elements(menu, kAXChildrenAttribute) ?? []).first(where: { el in
                    let t = AX.string(el, kAXTitleAttribute).flatMap { $0.isEmpty ? nil : $0 } ?? AX.string(el, kAXDescriptionAttribute) ?? ""
                    return AX.string(el, kAXRoleAttribute) == AXRoles.menuItem && MenuTitle.same(t, wanted)
                })
            else { return nil }
            actual.append(AX.string(item, kAXTitleAttribute) ?? wanted)
            owner = item
            if i == path.count - 2 {
                let hasSubmenu = !(AX.elements(item, kAXChildrenAttribute) ?? []).isEmpty
                return Located(item: item, path: actual, enabled: AX.bool(item, kAXEnabledAttribute) ?? true, hasSubmenu: hasSubmenu)
            }
        }
        // A path of one title names a whole menu, not a command.
        return Located(item: top.element, path: actual, enabled: true, hasSubmenu: true)
    }
}

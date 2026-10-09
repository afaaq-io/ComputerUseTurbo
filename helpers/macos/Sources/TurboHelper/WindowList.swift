import CoreGraphics
import Foundation

/// Window-server queries. Owner pid, number, layer and bounds are available without
/// Screen Recording permission (window titles are not, and we don't use them).
enum WindowList {
    struct Info {
        let number: CGWindowID
        let pid: pid_t
        let layer: Int
        let bounds: CGRect
        /// `kCGWindowAlpha` (1 when not reported).
        var alpha: Double = 1
    }

    static func onScreenWindows() -> [Info] {
        guard
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return [] }
        return list.compactMap { dict in
            guard let number = dict[kCGWindowNumber as String] as? Int,
                let pid = dict[kCGWindowOwnerPID as String] as? Int,
                let boundsDict = dict[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            let layer = dict[kCGWindowLayer as String] as? Int ?? 0
            let alpha = (dict[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            return Info(number: CGWindowID(number), pid: pid_t(pid), layer: layer, bounds: bounds, alpha: alpha)
        }
    }

    /// Pids that own at least one normal-layer on-screen window.
    static func pidsWithWindows() -> Set<pid_t> {
        Set(onScreenWindows().filter { $0.layer == 0 && $0.bounds.width > 1 && $0.bounds.height > 1 }.map(\.pid))
    }

    static func hasWindow(pid: pid_t) -> Bool {
        onScreenWindows().contains { $0.pid == pid && $0.layer == 0 && $0.bounds.width > 1 && $0.alpha > 0.05 }
    }

    /// The window a pid-routed mouse event at `point` is addressed to: the frontmost
    /// on-screen window of `pid` containing it (any layer: menus and popovers are
    /// windows too), from `list` (one window-server query per action).
    static func window(pid: pid_t, containing point: CGPoint, in list: [Info]) -> Info? {
        list.first { $0.pid == pid && $0.bounds.contains(point) && $0.alpha > 0.05 }
    }

    static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }
}

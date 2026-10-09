import AppKit
import TurboCore

/// Follows the system appearance for all glass UI: light / dark from
/// `NSApp.effectiveAppearance`, plus "Reduce transparency" and "Increase contrast". Views that
/// draw palette colours conform to `GlassThemable`; windows register their content view and
/// are re-coloured live when any of these change. Main thread only.
protocol GlassThemable: AnyObject {
    func applyPalette(_ palette: GlassPalette, reduceTransparency: Bool)
}

final class GlassTheme {
    static let shared = GlassTheme()

    private var roots: [WeakView] = []
    private var appearanceObservation: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []
    private var started = false

    private struct WeakView { weak var view: NSView? }

    var appearance: GlassAppearance {
        let match = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        return match == .darkAqua ? .dark : .light
    }

    var reduceTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
    var increaseContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }

    var palette: GlassPalette { GlassPalette.forAppearance(appearance, increaseContrast: increaseContrast) }

    var nsAppearance: NSAppearance? { NSAppearance(named: appearance == .dark ? .darkAqua : .aqua) }

    func start() {
        guard !started else { return }
        started = true
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshAll() }
        }
        let dnc = DistributedNotificationCenter.default()
        observers.append(
            dnc.addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) {
                [weak self] _ in self?.refreshAll()
            })
        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.refreshAll() })
    }

    /// Colour `root` now and keep it in sync with the system.
    func register(_ root: NSView) {
        start()
        roots.removeAll { $0.view == nil || $0.view === root }
        roots.append(WeakView(view: root))
        apply(to: root)
    }

    func unregister(_ root: NSView) {
        roots.removeAll { $0.view == nil || $0.view === root }
    }

    func refreshAll() {
        roots.removeAll { $0.view == nil }
        for r in roots { if let v = r.view { apply(to: v) } }
    }

    func apply(to root: NSView) {
        let p = palette
        let reduce = reduceTransparency
        root.window?.appearance = nsAppearance
        func walk(_ v: NSView) {
            (v as? GlassThemable)?.applyPalette(p, reduceTransparency: reduce)
            for s in v.subviews { walk(s) }
        }
        walk(root)
        root.window?.invalidateShadow()
    }
}

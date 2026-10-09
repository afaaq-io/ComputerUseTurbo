import AppKit
import CoreGraphics
import TurboCore
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// A captured window image on disk.
struct Screenshot {
    let url: URL
    let width: Int
    let height: Int
    /// Pixels per window point (≤ 1).
    let scale: Double
    /// Every capture path returned a near-uniform image (the app may still be rendering).
    let possiblyBlank: Bool
    /// Which capture path produced it (for the log).
    let path: String
    /// `ScreenshotChange.side`² grayscale thumbnail (change signal).
    var thumbnail: [UInt8]? = nil

    var json: JSONValue {
        [
            "path": .string(url.path), "mimeType": "image/jpeg", "width": .int(width), "height": .int(height),
            "scale": .double(scale),
        ]
    }
}

/// ScreenCaptureKit capture of the observed window, normalized to point resolution (then
/// downscaled to `ScreenshotScale` limits) and encoded as JPEG (quality 0.8) into
/// `~/Library/Caches/ComputerUseTurbo/shots/<uuid>.jpg`.
///
/// The window is matched **exactly** (same frame within `WindowMatcher.tolerance`), never
/// "the nearest window of the app": screenshot pixels are mapped to clicks as
/// `window.origin + (x, y) / scale`, so an image of a different window would send clicks
/// to the wrong place. Among the app's windows with that frame, on-screen, opaque, layer 0
/// and the largest area win (`WindowMatcher.bestCapture`): transparent or off-screen
/// helper windows some toolkits stack on the real one are ignored.
///
/// Capture paths, in order, until one gives an image that is not near-uniform
/// (`ImageUniformity`; a Chromium/CEF window captured on its own can come back all
/// white although it is visibly rendered):
///   1. `display`  the app's windows overlapping the frame composited on its display and
///                 cropped to the frame (sheets, popovers, open menus included);
///   2. `window`   the window alone (`desktopIndependentWindow`);
///   3. `region`   the display region of the frame with every application's windows
///                 excluded except this app's and its helper processes' (content a
///                 Chromium app draws from a child process); no other app leaks in;
///   4. `cgwindow` `CGWindowListCreateImage` of the window (when the symbol still exists).
/// If every image is near-uniform the first one is returned with `possiblyBlank`.
/// While a job runs, a window captured through path 1 or 3 is then streamed
/// (`WindowFeeds`): later looks take the feed's newest frame (`feed`) and skip the chain.
final class Screenshotter {
    let shotsDir: URL
    var jpegQuality: CGFloat = 0.8
    var timeout: TimeInterval = 8
    /// Screenshot files older than this are deleted by `purge` (the MCP server reads and
    /// deletes each file right after the response; this catches the rest).
    static let maxAge: TimeInterval = 10 * 60

    init(shotsDir: URL) {
        self.shotsDir = shotsDir
    }

    private final class Box: @unchecked Sendable {
        var images: [(image: CGImage, path: String)] = []
        var chosen: (image: CGImage, path: String, blank: Bool)?
        var error: String?
    }

    /// Capture `pid`'s window whose frame matches `frame` (global points) at `geometry`'s
    /// pixel size. Returns nil when Screen Recording is not granted (checked with the
    /// non-prompting preflight first), when no on-screen window matches the frame, or on
    /// failure. `relatedPids` are the app's helper processes (included by path 3).
    func capture(pid: pid_t, frame: CGRect, geometry: ScreenshotGeometry, relatedPids: Set<pid_t> = []) -> Screenshot? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        guard GeometryGuard.isSane(frame), frame.width >= 1, frame.height >= 1 else { return nil }
        let width = max(1, geometry.pixelWidth)
        let height = max(1, geometry.pixelHeight)
        let alphaById = Dictionary(
            WindowList.onScreenWindows().map { ($0.number, $0.alpha) }, uniquingKeysWith: { a, _ in a })
        let started = Date()
        let box = Box()
        // A live feed of this window (a job in progress) answers at once.
        if let img = WindowFeeds.shared.image(pid: pid, frame: frame, pixelSize: CGSize(width: width, height: height)) {
            if !Self.isDegenerate(img) {
                box.chosen = (img, "feed", false)
            } else {
                Log.info("screenshot: feed frame looks blank (near-uniform); capturing once instead")
            }
        }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            defer { done.signal() }
            if box.chosen != nil { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let mine = content.windows.filter {
                    $0.owningApplication?.processID == pid && $0.frame.width > 1 && $0.frame.height > 1
                }
                let candidates = mine.map {
                    CaptureCandidate(
                        id: $0.windowID, frame: $0.frame, layer: $0.windowLayer, alpha: alphaById[$0.windowID],
                        isOnScreen: $0.isOnScreen)
                }
                guard let best = WindowMatcher.bestCapture(frame, among: candidates),
                    let window = mine.first(where: { $0.windowID == best.id })
                else {
                    box.error = "no on-screen window of pid \(pid) matches the observed window frame \(frame)"
                    return
                }
                let display = content.displays.first(where: { $0.frame.contains(frame) })
                func config(sourceRect: CGRect?) -> SCStreamConfiguration {
                    let c = SCStreamConfiguration()
                    // Ask for exactly the screenshot size → pixels = points × scale.
                    c.width = width
                    c.height = height
                    c.scalesToFit = true
                    c.showsCursor = false
                    if let sourceRect {
                        c.sourceRect = sourceRect
                        c.ignoreShadowsDisplay = true
                    } else {
                        c.ignoreShadowsSingleWindow = true
                    }
                    return c
                }
                let crop = display.map {
                    CGRect(
                        x: frame.minX - $0.frame.minX, y: frame.minY - $0.frame.minY, width: frame.width,
                        height: frame.height)
                }
                let keep = relatedPids.union([pid])
                /// From the next look on, stream the window (the app's windows cropped to the
                /// frame, as paths 1 and 3 show it).
                func startFeed() {
                    guard let display else { return }
                    let apps = content.applications.filter { keep.contains($0.processID) }
                    WindowFeeds.shared.open(
                        window: window, display: display, apps: apps, frame: frame,
                        pixelSize: CGSize(width: width, height: height))
                }
                /// Records the image; true = good (not near-uniform), stop trying.
                func accept(_ image: CGImage?, _ path: String) -> Bool {
                    guard let image else { return false }
                    box.images.append((image, path))
                    if !Self.isDegenerate(image) {
                        box.chosen = (image, path, false)
                        if path.hasPrefix("display") || path.hasPrefix("region") { startFeed() }
                        return true
                    }
                    Log.info("screenshot: \(path) capture looks blank (near-uniform); trying the next path")
                    return false
                }

                // 1. The app's windows overlapping the frame, composited on the display.
                if let display, let crop {
                    let included = mine.filter { $0.isOnScreen && $0.frame.intersects(frame) && (alphaById[$0.windowID] ?? 1) > 0.05 }
                    let filter = SCContentFilter(display: display, including: included.isEmpty ? [window] : included)
                    do {
                        let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config(sourceRect: crop))
                        if accept(img, "display (\(included.count) window(s))") { return }
                    } catch {
                        Log.warn("screenshot: display capture failed (\(error))")
                    }
                }
                // 2. The window alone.
                do {
                    let img = try await SCScreenshotManager.captureImage(
                        contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config(sourceRect: nil))
                    if accept(img, "window") { return }
                } catch {
                    Log.warn("screenshot: window capture failed (\(error))")
                }
                // 3. The display region with only this app (and its helper processes).
                if let display, let crop {
                    let others = content.applications.filter { !keep.contains($0.processID) }
                    let filter = SCContentFilter(display: display, excludingApplications: others, exceptingWindows: [])
                    do {
                        let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config(sourceRect: crop))
                        if accept(img, "region (app + \(keep.count - 1) helper process(es))") { return }
                    } catch {
                        Log.warn("screenshot: region capture failed (\(error))")
                    }
                }
                // 4. Legacy window-server capture, if the symbol still exists.
                if accept(Self.legacyWindowImage(frame: frame, windowID: window.windowID), "cgwindow") { return }
            } catch {
                box.error = String(describing: error)
            }
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            Log.warn("screenshot: timed out after \(timeout)s")
            return nil
        }
        var blank = false
        var path = ""
        var picked: CGImage
        if let c = box.chosen {
            picked = c.image
            path = c.path
        } else if let first = box.images.first {
            picked = first.image
            path = first.path
            blank = true
            Log.warn("screenshot: every capture path looked blank (\(box.images.map(\.path).joined(separator: ", "))); returning the \(path) image")
        } else {
            Log.warn("screenshot: \(box.error ?? "no image")")
            return nil
        }
        if picked.width != width || picked.height != height, let scaled = Self.scale(picked, width: width, height: height) {
            picked = scaled
        }
        do {
            try TurboPaths.ensureDirectory(shotsDir, mode: 0o700)
            let url = shotsDir.appendingPathComponent("\(UUID().uuidString.lowercased()).jpg")
            try writeJPEG(picked, to: url)
            Log.info(
                "screenshot: \(picked.width)x\(picked.height) (scale \(geometry.scaleText)) via \(path) in \(Int(Date().timeIntervalSince(started) * 1000)) ms\(blank ? ", possibly blank" : "")")
            return Screenshot(
                url: url, width: picked.width, height: picked.height, scale: geometry.scale, possiblyBlank: blank, path: path,
                thumbnail: Self.thumbnail(picked))
        } catch {
            Log.error("screenshot: write failed: \(error)")
            return nil
        }
    }

    /// Grayscale `ScreenshotChange.side`² rendition (cell averages) for the change signal.
    static func thumbnail(_ image: CGImage) -> [UInt8]? {
        let side = ScreenshotChange.side
        var buffer = [UInt8](repeating: 0, count: side * side)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard
                let ctx = CGContext(
                    data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return ok ? buffer : nil
    }

    /// Near-uniform image (`ImageUniformity`), judged on a 128×128 rendition.
    static func isDegenerate(_ image: CGImage) -> Bool {
        let side = 128
        let bytesPerRow = side * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * side)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard
                let ctx = CGContext(
                    data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard ok else { return false }
        return ImageUniformity.isNearlyUniform(
            bytes: buffer, width: side, height: side, bytesPerRow: bytesPerRow, bytesPerPixel: 4)
    }

    private typealias LegacyCapture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    /// `CGWindowListCreateImage`, looked up at run time (unavailable in the current SDK;
    /// a missing symbol only skips this path).
    private static let legacyCapture: LegacyCapture? = {
        guard let handle = dlopen(nil, RTLD_NOW), let sym = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(sym, to: LegacyCapture.self)
    }()

    static func legacyWindowImage(frame: CGRect, windowID: CGWindowID) -> CGImage? {
        guard let fn = legacyCapture else { return nil }
        let optionIncludingWindow: UInt32 = 1 << 3  // kCGWindowListOptionIncludingWindow
        let options: UInt32 = (1 << 0) | (1 << 3)  // boundsIgnoreFraming | bestResolution
        return fn(frame, optionIncludingWindow, windowID, options)?.takeRetainedValue()
    }

    static func scale(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard
            let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    private func writeJPEG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw TurboError(.helperFault, "cannot create JPEG destination")
        }
        let props = [kCGImageDestinationLossyCompressionQuality as String: jpegQuality] as CFDictionary
        CGImageDestinationAddImage(dest, image, props)
        guard CGImageDestinationFinalize(dest) else { throw TurboError(.helperFault, "JPEG encoding failed") }
        chmod(url.path, 0o600)
    }

    /// Delete screenshots older than `age` (at startup and periodically, see AppDelegate).
    /// Returns how many files were deleted.
    @discardableResult
    func purge(olderThan age: TimeInterval, now: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: shotsDir, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return 0 }
        let cutoff = now.addingTimeInterval(-age)
        var removed = 0
        for url in items where url.pathExtension == "jpg" {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if date < cutoff, (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    /// Running processes that belong to the app at `appPath` (helper apps inside its
    /// bundle, e.g. Chromium / CEF renderer and GPU processes) or are its direct children.
    static func relatedPids(of pid: pid_t, appPath: String) -> Set<pid_t> {
        guard !appPath.isEmpty else { return [] }
        let prefix = appPath.hasSuffix("/") ? appPath : appPath + "/"
        var out = Set<pid_t>()
        for app in NSWorkspace.shared.runningApplications where app.processIdentifier != pid {
            if let path = app.bundleURL?.path, path.hasPrefix(prefix) { out.insert(app.processIdentifier) }
        }
        return out
    }
}

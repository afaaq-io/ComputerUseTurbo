import CoreGraphics
import Foundation

/// Size of the screenshot the model sees and how its pixels map to the screen
///.
///
/// Screenshots are normalized to the window's point size and, when that is larger than
/// what vision models take in, downscaled so the longest side is ≤ 1568 px and the area
/// ≤ 1.15 megapixels (keeping the aspect ratio). A client that downscales a larger image
/// itself would silently put every coordinate off by its own factor (a 2560×1320 window
/// shown at 2000 px wide needed every x/y × 1.28). All x/y arguments are pixels of this
/// image: `screen point = window origin + (x, y) / scale`.
public struct ScreenshotGeometry: Equatable, Sendable {
    /// Image size in pixels.
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// Pixels per window point (≤ 1; 1 = no downscale, pixels are points).
    public let scale: Double

    public init(pixelWidth: Int, pixelHeight: Int, scale: Double) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
    }

    public var isDownscaled: Bool { scale < 1 }

    /// The scale as printed (up to 4 decimals, no trailing zeros).
    public var scaleText: String { ScreenshotScale.format(scale) }
}

public enum ScreenshotScale {
    public static let maxLongSide = 1568
    public static let maxPixels = 1_150_000

    /// Geometry for a window of `width` × `height` points.
    public static func fit(width: Double, height: Double) -> ScreenshotGeometry {
        guard width.isFinite, height.isFinite, width >= 1, height >= 1 else {
            return ScreenshotGeometry(
                pixelWidth: max(1, Int(width.isFinite ? max(1, width.rounded()) : 1)),
                pixelHeight: max(1, Int(height.isFinite ? max(1, height.rounded()) : 1)), scale: 1)
        }
        let w = width.rounded()
        let h = height.rounded()
        var scale = 1.0
        scale = min(scale, Double(maxLongSide) / max(w, h))
        scale = min(scale, (Double(maxPixels) / (w * h)).squareRoot())
        if scale >= 1 {
            return ScreenshotGeometry(pixelWidth: Int(w), pixelHeight: Int(h), scale: 1)
        }
        // Floor, so both limits hold after rounding; then the scale actually used is
        // the width ratio (the two axes differ by < 1 px).
        // (+1e-9: 1568/3000 × 3000 must not round down to 1567.)
        let pw = max(1, Int((w * scale + 1e-9).rounded(.down)))
        let ph = max(1, Int((h * scale + 1e-9).rounded(.down)))
        return ScreenshotGeometry(pixelWidth: pw, pixelHeight: ph, scale: Double(pw) / w)
    }

    /// Screenshot pixel (x, y) → global top-left screen point for a window whose
    /// top-left corner is `origin`.
    public static func toScreen(x: Double, y: Double, origin: CGPoint, scale: Double) -> CGPoint {
        let s = scale.isFinite && scale > 0 ? scale : 1
        return CGPoint(x: origin.x + CGFloat(x / s), y: origin.y + CGFloat(y / s))
    }

    /// Whether (x, y) lies on the screenshot (half a pixel of slack on the far edges).
    public static func contains(x: Double, y: Double, in g: ScreenshotGeometry) -> Bool {
        x.isFinite && y.isFinite && x >= -0.5 && y >= -0.5 && x <= Double(g.pixelWidth) + 0.5
            && y <= Double(g.pixelHeight) + 0.5
    }

    public static func format(_ scale: Double) -> String {
        guard scale.isFinite else { return "1" }
        var s = String(format: "%.4f", scale)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}

/// Detects screenshots that came back blank: a capture API can return an all-white (or
/// all-black / transparent) frame for a window that is visibly rendered (Chromium / CEF
/// apps composite their content in a way window capture sometimes misses).
public enum ImageUniformity {
    /// Samples per axis.
    public static let grid = 32
    /// Largest per-channel difference from the reference colour that still counts as
    /// "the same colour".
    public static let tolerance = 6
    /// Fraction of samples that must match for the image to count as degenerate.
    public static let threshold = 0.99

    /// Whether ≥ `threshold` of a `grid` × `grid` sample of the image lies within
    /// `tolerance` (every channel) of one colour (the most common one, after
    /// quantizing). `pixels` is a packed buffer: `bytesPerRow` per row, `bytesPerPixel`
    /// (≥ 1, all channels compared) per pixel. Empty / malformed input is degenerate.
    public static func isNearlyUniform(
        pixels: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int, bytesPerPixel: Int,
        grid: Int = grid, tolerance: Int = tolerance, threshold: Double = threshold
    ) -> Bool {
        guard width > 0, height > 0, bytesPerPixel > 0, bytesPerRow >= width * bytesPerPixel,
            pixels.count >= bytesPerRow * (height - 1) + width * bytesPerPixel, grid > 0
        else { return true }
        let nx = min(grid, width)
        let ny = min(grid, height)
        var samples: [[UInt8]] = []
        samples.reserveCapacity(nx * ny)
        for j in 0..<ny {
            // Centres of the grid cells.
            let y = min(height - 1, Int((Double(j) + 0.5) * Double(height) / Double(ny)))
            for i in 0..<nx {
                let x = min(width - 1, Int((Double(i) + 0.5) * Double(width) / Double(nx)))
                let base = y * bytesPerRow + x * bytesPerPixel
                var px = [UInt8](repeating: 0, count: bytesPerPixel)
                for c in 0..<bytesPerPixel { px[c] = pixels[base + c] }
                samples.append(px)
            }
        }
        // Reference: the most common colour (quantized to 16 levels per channel).
        var buckets: [[UInt8]: Int] = [:]
        var firstOf: [[UInt8]: [UInt8]] = [:]
        for s in samples {
            let q = s.map { $0 >> 4 }
            buckets[q, default: 0] += 1
            if firstOf[q] == nil { firstOf[q] = s }
        }
        guard let top = buckets.max(by: { $0.value < $1.value })?.key, let reference = firstOf[top] else { return true }
        var matching = 0
        for s in samples {
            var same = true
            for c in 0..<bytesPerPixel where abs(Int(s[c]) - Int(reference[c])) > tolerance {
                same = false
                break
            }
            if same { matching += 1 }
        }
        return Double(matching) >= threshold * Double(samples.count)
    }

    /// Convenience: a byte array.
    public static func isNearlyUniform(bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int, bytesPerPixel: Int)
        -> Bool
    {
        bytes.withUnsafeBytes {
            isNearlyUniform(pixels: $0, width: width, height: height, bytesPerRow: bytesPerRow, bytesPerPixel: bytesPerPixel)
        }
    }
}

/// A window-server window considered for a screenshot.
public struct CaptureCandidate: Equatable, Sendable {
    public let id: UInt32
    public let frame: CGRect
    public let layer: Int
    /// `kCGWindowAlpha` (nil = unknown, treated as opaque).
    public let alpha: Double?
    public let isOnScreen: Bool

    public init(id: UInt32, frame: CGRect, layer: Int, alpha: Double? = nil, isOnScreen: Bool = true) {
        self.id = id
        self.frame = frame
        self.layer = layer
        self.alpha = alpha
        self.isOnScreen = isOnScreen
    }
}

extension WindowMatcher {
    /// The window to capture for the AX window frame `target`: among the app's windows
    /// that are on screen, not transparent (alpha > 0.05), larger than 1×1 and the same
    /// window as `target` (frames within `tolerance`), prefer layer 0, then the largest
    /// area, then the closest frame. nil when none matches: a different window would
    /// make screenshot coordinates map to the wrong place.
    public static func bestCapture(
        _ target: CGRect, among candidates: [CaptureCandidate], tolerance: CGFloat = tolerance
    ) -> CaptureCandidate? {
        let usable = candidates.filter { c in
            c.isOnScreen && (c.alpha ?? 1) > 0.05 && c.frame.width > 1 && c.frame.height > 1
                && GeometryGuard.isSane(c.frame) && distance(c.frame, target) <= tolerance
        }
        return usable.min { a, b in
            let la = a.layer == 0 ? 0 : 1
            let lb = b.layer == 0 ? 0 : 1
            if la != lb { return la < lb }
            let areaA = a.frame.width * a.frame.height
            let areaB = b.frame.width * b.frame.height
            if areaA != areaB { return areaA > areaB }
            return distance(a.frame, target) < distance(b.frame, target)
        }
    }
}

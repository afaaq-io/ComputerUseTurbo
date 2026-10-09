import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import TurboCore
import VideoToolbox

/// Live capture of the window the agent works on.
///
/// While a job runs, the window is streamed with ScreenCaptureKit instead of captured once
/// per look: the latest frame is always at hand, so screenshots and the live preview are
/// instant. A feed shows the app's own windows (and its helper processes', for Chromium
/// apps) cropped to the observed window's frame — the same picture as the one-shot
/// `display` path — so sheets, popovers and open menus are included and other apps never
/// leak in. macOS marks a streamed window with its "being shared" badge while the feed runs.
///
/// Feeds close after `idleClose` without use, on finishTurn when no other session works,
/// and on Stop / Esc. Anything a feed cannot serve (no frame yet, window moved to another
/// display, a blank frame) falls back to the one-shot capture.
final class WindowFeeds: @unchecked Sendable {
    static let shared = WindowFeeds()

    /// A feed nobody asked for a frame in this long is closed.
    static let idleClose: TimeInterval = 20
    /// At most this many windows are streamed at once (the least recently used goes).
    static let maxFeeds = 2
    /// How long a look waits for the feed to report the window's current state.
    static let freshWait: TimeInterval = 0.15
    static let framesPerSecond: Int32 = 20

    private let lock = NSLock()
    private var feeds: [Key: Feed] = [:]
    private var reaper: DispatchSourceTimer?
    /// The user ended sharing (Control Center's "Stop Sharing"): no feed until the job ends;
    /// looks capture once each.
    private var userStopped = false

    struct Key: Hashable {
        let pid: pid_t
        let windowID: CGWindowID
    }

    // MARK: Using it

    /// The window's current picture at `pixelSize`, from a live feed of `pid`'s window
    /// whose frame is `frame` (global points); nil when no feed serves it yet. Waits at
    /// most `freshWait` for the feed to report the state after this call.
    func image(pid: pid_t, frame: CGRect, pixelSize: CGSize) -> CGImage? {
        guard let feed = find(pid: pid, frame: frame), feed.serves(frame: frame, pixelSize: pixelSize) else { return nil }
        return feed.image(after: Date(), wait: Self.freshWait)
    }

    /// The newest frame of any feed of `pid` (the live preview; any size), with the frame
    /// of the window it shows.
    func latest(pid: pid_t) -> (CGImage, CGRect)? {
        lock.lock()
        let feed = feeds.values.filter { $0.key.pid == pid }.max { $0.lastUsed < $1.lastUsed }
        lock.unlock()
        guard let feed, let img = feed.image(after: nil, wait: 0) else { return nil }
        return (img, feed.frame)
    }

    /// Start (or retarget) a feed of `window` cropped to `frame` at `pixelSize`. Returns
    /// at once; frames arrive shortly after.
    func open(window: SCWindow, display: SCDisplay, apps: [SCRunningApplication], frame: CGRect, pixelSize: CGSize) {
        let key = Key(pid: window.owningApplication?.processID ?? 0, windowID: window.windowID)
        lock.lock()
        if userStopped {
            lock.unlock()
            return
        }
        if let feed = feeds[key] {
            lock.unlock()
            feed.retarget(display: display, frame: frame, pixelSize: pixelSize)
            return
        }
        var evicted: [Feed] = []
        while feeds.count >= Self.maxFeeds, let oldest = feeds.values.min(by: { $0.lastUsed < $1.lastUsed }) {
            feeds[oldest.key] = nil
            evicted.append(oldest)
        }
        let feed = Feed(key: key, display: display, apps: apps, frame: frame, pixelSize: pixelSize) { [weak self] key, byUser in
            self?.drop(key, byUser: byUser)
        }
        feeds[key] = feed
        startReaper()
        lock.unlock()
        evicted.forEach { $0.stop("replaced by a newer window") }
        feed.start()
    }

    /// Close every feed (the job is over, or the user pressed Stop).
    func closeAll(_ why: String) {
        lock.lock()
        let all = Array(feeds.values)
        feeds.removeAll()
        userStopped = false
        reaper?.cancel()
        reaper = nil
        lock.unlock()
        all.forEach { $0.stop(why) }
    }

    // MARK: Internals

    private func find(pid: pid_t, frame: CGRect) -> Feed? {
        lock.lock()
        defer { lock.unlock() }
        return feeds.values.first { $0.key.pid == pid && WindowMatcher.distance($0.frame, frame) < 0.5 }
    }

    private func drop(_ key: Key, byUser: Bool) {
        lock.lock()
        feeds[key] = nil
        let others = byUser ? Array(feeds.values) : []
        if byUser {
            userStopped = true
            feeds.removeAll()
        }
        lock.unlock()
        others.forEach { $0.stop("the user stopped sharing") }
    }

    private func startReaper() {
        guard reaper == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dev.cuturbo.helper.feeds"))
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.reap() }
        t.resume()
        reaper = t
    }

    private func reap() {
        lock.lock()
        let idle = feeds.values.filter { Date().timeIntervalSince($0.lastUsed) > Self.idleClose }
        for f in idle { feeds[f.key] = nil }
        if feeds.isEmpty {
            reaper?.cancel()
            reaper = nil
        }
        lock.unlock()
        idle.forEach { $0.stop("idle for \(Int(Self.idleClose)) s") }
    }
}

/// One SCStream.
private final class Feed: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let key: WindowFeeds.Key
    private let lock = NSLock()
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "dev.cuturbo.helper.feed")
    private let onEnd: (WindowFeeds.Key, Bool) -> Void
    private var display: SCDisplay
    private let apps: [SCRunningApplication]
    private(set) var frame: CGRect
    private var pixelSize: CGSize
    /// The newest complete frame and when it arrived.
    private var buffer: CVPixelBuffer?
    private var bufferAt = Date.distantPast
    /// When the stream last reported anything (a new frame or "unchanged").
    private var heardAt = Date.distantPast
    /// Frames arriving before this belong to the previous crop / size.
    private var validFrom = Date.distantFuture
    private(set) var lastUsed = Date()
    private var stopped = false

    init(
        key: WindowFeeds.Key, display: SCDisplay, apps: [SCRunningApplication], frame: CGRect, pixelSize: CGSize,
        onEnd: @escaping (WindowFeeds.Key, Bool) -> Void
    ) {
        self.key = key
        self.display = display
        self.apps = apps
        self.frame = frame
        self.pixelSize = pixelSize
        self.onEnd = onEnd
    }

    private func configuration() -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = max(1, Int(pixelSize.width))
        c.height = max(1, Int(pixelSize.height))
        c.scalesToFit = true
        c.showsCursor = false
        c.ignoreShadowsDisplay = true
        c.sourceRect = CGRect(
            x: frame.minX - display.frame.minX, y: frame.minY - display.frame.minY, width: frame.width, height: frame.height)
        c.minimumFrameInterval = CMTime(value: 1, timescale: WindowFeeds.framesPerSecond)
        c.queueDepth = 4
        c.pixelFormat = kCVPixelFormatType_32BGRA
        return c
    }

    func start() {
        let filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        let s = SCStream(filter: filter, configuration: configuration(), delegate: self)
        do {
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        } catch {
            Log.warn("feed: cannot attach to the stream (\(error))")
            end()
            return
        }
        lock.lock()
        stream = s
        lock.unlock()
        let started = Date()
        s.startCapture { [weak self] error in
            guard let self else { return }
            if let error {
                Log.warn("feed: window \(self.key.windowID) did not start (\(error))")
                self.end()
                return
            }
            self.lock.lock()
            self.validFrom = Date()
            self.lock.unlock()
            Log.info("feed: streaming window \(self.key.windowID) of pid \(self.key.pid) (started in \(Int(Date().timeIntervalSince(started) * 1000)) ms)")
        }
    }

    /// The window moved, was resized, or the screenshot size changed.
    func retarget(display newDisplay: SCDisplay, frame newFrame: CGRect, pixelSize newSize: CGSize) {
        lock.lock()
        lastUsed = Date()
        let same = newDisplay.displayID == display.displayID
        let unchanged = same && newFrame == frame && newSize == pixelSize
        let s = stream
        lock.unlock()
        if unchanged { return }
        guard same, let s else {
            stop("the window moved to another display")
            return
        }
        lock.lock()
        frame = newFrame
        pixelSize = newSize
        validFrom = .distantFuture
        let config = configuration()
        lock.unlock()
        s.updateConfiguration(config) { [weak self] error in
            guard let self else { return }
            if let error {
                self.stop("could not follow the window (\(error))")
                return
            }
            self.lock.lock()
            self.validFrom = Date()
            self.lock.unlock()
        }
    }

    /// Whether this feed currently streams `frame` at `pixelSize`.
    func serves(frame f: CGRect, pixelSize size: CGSize) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        lastUsed = Date()
        return !stopped && validFrom <= Date() && WindowMatcher.distance(frame, f) < 0.5 && Int(pixelSize.width) == Int(size.width)
            && Int(pixelSize.height) == Int(size.height)
    }

    /// The newest frame; with `after`, first waits (≤ `wait`) until the stream reports
    /// something later than `after`, so the picture is not older than the call.
    func image(after: Date?, wait: TimeInterval) -> CGImage? {
        let until = Date().addingTimeInterval(wait)
        while true {
            lock.lock()
            lastUsed = Date()
            let ready = after.map { heardAt >= $0 } ?? true
            let pb = bufferAt >= validFrom ? buffer : nil
            lock.unlock()
            if ready || Date() >= until {
                guard let pb else { return nil }
                var img: CGImage?
                VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &img)
                return img
            }
            usleep(10_000)
        }
    }

    func stop(_ why: String) {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let s = stream
        stream = nil
        buffer = nil
        lock.unlock()
        s?.stopCapture { _ in }
        Log.info("feed: closed window \(key.windowID) of pid \(key.pid) (\(why))")
    }

    private func end(byUser: Bool = false) {
        stop(byUser ? "the user stopped sharing" : "stream ended")
        onEnd(key, byUser)
    }

    // MARK: SCStreamOutput / SCStreamDelegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw)
        else { return }
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        switch status {
        case .complete:
            if let pb = sampleBuffer.imageBuffer {
                buffer = pb
                bufferAt = now
            }
            heardAt = now
        case .idle:
            heardAt = now
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let byUser = (error as NSError).code == SCStreamError.Code.userStopped.rawValue
        Log.info("feed: window \(key.windowID) stream stopped (\(error.localizedDescription))")
        end(byUser: byUser)
    }
}

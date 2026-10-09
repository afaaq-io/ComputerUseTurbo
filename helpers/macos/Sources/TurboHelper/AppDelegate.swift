import AppKit
import TurboCore
import Foundation

/// Wires the pieces together once AppKit is up (the overlay, approval dialog and
/// keyboard-layout table all need the main thread).
final class AppDelegate: NSObject, NSApplicationDelegate {
    let paths: TurboPaths
    private var server: SocketServer?
    private var service: HelperService?
    private var preview: LivePreviewController?
    private var signalSources: [DispatchSourceSignal] = []
    private var housekeeping: DispatchSourceTimer?
    /// Signals are handled here, not on the main queue: the main thread can be busy
    /// (e.g. running a modal approval dialog) and shutdown must still work.
    private let signalQueue = DispatchQueue(label: "dev.cuturbo.helper.signals")
    /// Sessions with no request for this long are forgotten (their MCP server most likely
    /// died without sending finishTurn).
    static let idleSessionExpiry: TimeInterval = 4 * 3600
    static let housekeepingInterval: TimeInterval = 5 * 60

    init(paths: TurboPaths) {
        self.paths = paths
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AX.configureGlobalTimeout()
        KeyboardLayout.buildOnMainThread()
        Log.info("keyboard layout: \(KeyboardLayout.sourceDescription)")

        let overlay = OverlayController()
        let pointerUI = VirtualPointer()
        pointerUI.start()
        let pointer = PointerDriver(ui: pointerUI, settingsURL: paths.settings)
        overlay.onHideOrStop = { pointerUI.hide() }
        // Live preview: follows the overlay's life cycle and mirrors the pointer.
        let preview = LivePreviewController(settingsURL: paths.settings)
        pointerUI.motionObserver = preview
        // The preview does NOT follow the overlay's 60 s idle hide: it stays for the whole job
        // and closes on finishTurn (HelperService.endTurn) or Stop/Esc.
        let userInput = UserInputMonitor()
        userInput.installIfNeeded()
        let service = HelperService(paths: paths, overlay: overlay, pointer: pointer, preview: preview, userInput: userInput)
        overlay.onStop = { [weak service, weak preview] in
            service?.userPressedStop()
            preview?.sessionsEnded()
        }
        overlay.isApprovalDialogVisible = { [weak service] in service?.prompter.isShowing ?? false }
        overlay.installKeyMonitors()
        self.service = service

        service.screenshotter.purge(olderThan: Screenshotter.maxAge)
        self.preview = preview
        startHousekeeping(service)

        let server = SocketServer(socketPath: paths.socket.path) { Dispatcher(service: service) }
        do {
            try server.start()
        } catch let error as SocketServer.ServerError {
            Log.error("cannot start server: \(error)")
            Log.flush()
            if case .alreadyServing = error { exit(0) }
            exit(1)
        } catch {
            Log.error("cannot start server: \(error)")
            Log.flush()
            exit(1)
        }
        self.server = server

        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
            // `server` is captured strongly: this runs off the main thread. stop() only
            // closes the listening fd and unlinks the socket; Log has its own queue.
            source.setEventHandler { [server] in
                Log.info("signal \(sig): shutting down")
                server.stop()
                Log.flush()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }

        Log.info(
            "ready: accessibility=\(Permissions.accessibility) screenRecording=\(Permissions.screenRecording)")
    }

    /// Periodic cleanup: screenshots older than `Screenshotter.maxAge` (they may show
    /// sensitive windows and nothing needs them once the server has read them), and
    /// sessions idle for `idleSessionExpiry` together with their screenshots.
    private func startHousekeeping(_ service: HelperService) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dev.cuturbo.helper.housekeeping"))
        timer.schedule(deadline: .now() + Self.housekeepingInterval, repeating: Self.housekeepingInterval)
        timer.setEventHandler { [weak service] in
            guard let service else { return }
            let expired = service.sessions.expireIdle(olderThan: Self.idleSessionExpiry)
            for f in expired.screenshots { try? FileManager.default.removeItem(at: f) }
            let purged = service.screenshotter.purge(olderThan: Screenshotter.maxAge)
            if expired.sessions > 0 || purged > 0 {
                Log.info("housekeeping: expired \(expired.sessions) idle session(s), deleted \(purged) old screenshot(s)")
            }
        }
        timer.resume()
        housekeeping = timer
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        Log.info("terminating")
        Log.flush()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

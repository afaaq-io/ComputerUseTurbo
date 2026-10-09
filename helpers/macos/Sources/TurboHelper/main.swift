import AppKit
import TurboCore
import Foundation

// TurboHelper entry point.
//
// An LSUIElement (accessory) app that owns the TCC grants and serves the
// computer-use-turbo protocol on a per-user AF_UNIX socket.

let arguments = CommandLine.arguments
if arguments.contains("--version") {
    print("TurboHelper \(TurboProtocol.helperVersion) (\(TurboProtocol.apiVersion))")
    exit(0)
}

let paths = TurboPaths()
do {
    try TurboPaths.ensureDirectory(paths.supportDir, mode: 0o700)
} catch {
    _ = Log.safeWrite(Data("cannot create \(paths.supportDir.path): \(error)\n".utf8), to: FileHandle.standardError)
    exit(1)
}
Log.setup(paths: paths, echo: arguments.contains("--log-stderr"))

guard SingleInstance.acquire(lockURL: paths.lockFile) else {
    Log.info("another TurboHelper instance holds \(paths.lockFile.path); exiting")
    Log.flush()
    exit(0)
}

signal(SIGPIPE, SIG_IGN)
Log.info(
    "TurboHelper \(TurboProtocol.helperVersion) starting (pid \(getpid()), bundle \(Bundle.main.bundleIdentifier ?? "none"))"
)

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let appDelegate = AppDelegate(paths: paths)
application.delegate = appDelegate
application.run()

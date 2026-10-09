import TurboCore
import Foundation

/// `flock`-based single-instance guard on `<support>/helper.lock`.
///
/// The lock is held for the lifetime of the process (the descriptor is intentionally
/// never closed) and released automatically by the kernel when the process exits.
enum SingleInstance {
    nonisolated(unsafe) private static var lockFD: Int32 = -1

    /// Try to take the lock. Returns false if another helper instance holds it.
    static func acquire(lockURL: URL) -> Bool {
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            Log.error("cannot open lock file \(lockURL.path): errno \(errno)")
            // Without a lock file we cannot guarantee exclusivity; refuse to run.
            return false
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        // Record our pid for diagnostics.
        ftruncate(fd, 0)
        let pidLine = "\(getpid())\n"
        _ = pidLine.withCString { write(fd, $0, strlen($0)) }
        lockFD = fd
        return true
    }
}

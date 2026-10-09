import TurboCore
import Foundation

/// Append-only file logger for `~/Library/Logs/ComputerUseTurbo/helper.log`.
///
/// Writes happen on a private serial queue so callers on any thread never block on I/O.
/// The file is rotated to `helper.log.1` when it exceeds 5 MB. Never log typed text,
/// values of secure fields, or screenshots — only sizes and identifiers.
///
/// Logging can never terminate the process: only the throwing `FileHandle` APIs are used
/// (the legacy `write(_:)`, `offsetInFile`, `synchronizeFile()` raise an uncatchable
/// Objective-C exception on any I/O error such as a full disk), and a line that cannot be
/// written is dropped. Every message is forced onto a single line, so text that came from
/// a peer can never forge extra log entries.
enum Log {
    private static let queue = DispatchQueue(label: "dev.cuturbo.helper.log")
    private static var handle: FileHandle?
    private static var fileURL: URL?
    private static let maxBytes: UInt64 = 5 * 1024 * 1024
    nonisolated(unsafe) private static var echoToStderr = false

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func setup(paths: TurboPaths, echo: Bool = false) {
        echoToStderr = echo
        queue.sync {
            do {
                try TurboPaths.ensureDirectory(paths.logDir, mode: 0o700)
                if !FileManager.default.fileExists(atPath: paths.logFile.path) {
                    FileManager.default.createFile(
                        atPath: paths.logFile.path, contents: nil,
                        attributes: [.posixPermissions: NSNumber(value: Int16(0o600))])
                }
                fileURL = paths.logFile
                handle = try openForAppending(paths.logFile)
            } catch {
                _ = safeWrite(Data("log setup failed: \(error)\n".utf8), to: FileHandle.standardError)
            }
        }
    }

    static func info(_ message: @autoclosure () -> String) { write("info", message()) }
    static func warn(_ message: @autoclosure () -> String) { write("warn", message()) }
    static func error(_ message: @autoclosure () -> String) { write("error", message()) }

    private static func write(_ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(LogText.singleLine(message))\n"
        queue.async {
            let data = Data(line.utf8)
            if echoToStderr { _ = safeWrite(data, to: FileHandle.standardError) }
            guard let handle else { return }
            if !safeWrite(data, to: handle) {
                // Drop the line; reopen once (the file may have been removed or rotated
                // by someone else). If the disk is full the next write simply fails again.
                try? handle.close()
                self.handle = fileURL.flatMap { try? openForAppending($0) }
                return
            }
            rotateIfNeeded()
        }
    }

    /// Write without ever raising: returns false on any I/O error.
    static func safeWrite(_ data: Data, to handle: FileHandle) -> Bool {
        do {
            try handle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    private static func rotateIfNeeded() {
        guard let handle, let fileURL else { return }
        guard let size = try? handle.offset(), size > maxBytes else { return }
        try? handle.close()
        let rotated = fileURL.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: fileURL, to: rotated)
        self.handle = try? openForAppending(fileURL)
    }

    /// Open (creating with 0600 if needed) in O_APPEND mode. Appending matters: a second
    /// helper instance logs one line before exiting on the lock, and without O_APPEND the
    /// running instance would overwrite that line from its own stale file offset.
    private static func openForAppending(_ url: URL) throws -> FileHandle {
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Block until queued lines are written (used right before exit).
    static func flush() {
        queue.sync { try? handle?.synchronize() }
    }
}

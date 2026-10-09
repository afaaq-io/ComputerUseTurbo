import Foundation

/// Filesystem locations shared by helper and MCP server.
public struct TurboPaths: Sendable {
    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    /// `~/Library/Application Support/ComputerUseTurbo/` (mode 0700).
    public var supportDir: URL {
        home.appendingPathComponent("Library/Application Support/ComputerUseTurbo", isDirectory: true)
    }
    public var socket: URL { supportDir.appendingPathComponent("turbo.sock") }
    public var lockFile: URL { supportDir.appendingPathComponent("helper.lock") }
    /// User-only escape hatch for the protected list.
    public var allowProtected: URL { supportDir.appendingPathComponent("allow-protected.txt") }
    /// Optional user settings (pointer): `{"pointer":{"enabled":true,"speed":1.0}}`.
    public var settings: URL { supportDir.appendingPathComponent("settings.json") }

    public var logDir: URL { home.appendingPathComponent("Library/Logs/ComputerUseTurbo", isDirectory: true) }
    public var logFile: URL { logDir.appendingPathComponent("helper.log") }

    public var cacheDir: URL { home.appendingPathComponent("Library/Caches/ComputerUseTurbo", isDirectory: true) }
    public var shotsDir: URL { cacheDir.appendingPathComponent("shots", isDirectory: true) }

    /// Create `url` (and parents) if missing and force its mode (e.g. 0700).
    public static func ensureDirectory(_ url: URL, mode: Int16 = 0o700) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            if !isDir.boolValue {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
            }
        } else {
            try fm.createDirectory(
                at: url, withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: mode)])
        }
        try fm.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
    }

    /// Where a file of the repository's `shared/` folder is found: the app bundle's resources
    /// (copied there by build-app.sh), then `shared/<name>` above `sourceFile` (development builds).
    public static func sharedFileCandidates(_ name: String, sourceFile: String) -> [URL] {
        var out: [URL] = []
        if let res = Bundle.main.resourceURL { out.append(res.appendingPathComponent(name)) }
        var dir = URL(fileURLWithPath: sourceFile).deletingLastPathComponent()
        for _ in 0..<6 {
            out.append(dir.appendingPathComponent("shared/\(name)"))
            dir = dir.deletingLastPathComponent()
        }
        return out
    }
}

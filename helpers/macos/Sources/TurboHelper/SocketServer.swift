import TurboCore
import Darwin
import Foundation

/// AF_UNIX stream server.
///
/// * The support directory is forced to 0700, the socket to 0600.
/// * An existing socket file is removed only after a connect probe fails (stale).
/// * Every accepted peer must have our uid (`getpeereid`), else it is closed.
/// * Each connection gets its own thread that reads a frame, handles it, writes the
///   response, and only then reads the next frame (per-connection serial handling).
final class SocketServer {
    enum ServerError: Error, CustomStringConvertible {
        case pathTooLong(String)
        case alreadyServing(String)
        case posix(String, Int32)

        var description: String {
            switch self {
            case .pathTooLong(let p): return "socket path too long: \(p)"
            case .alreadyServing(let p): return "another process is already serving \(p)"
            case .posix(let what, let e): return "\(what) failed: \(String(cString: strerror(e)))"
            }
        }
    }

    let socketPath: String
    private let makeHandler: () -> ConnectionHandler
    private var listenFD: Int32 = -1
    private var connectionCounter = 0

    init(socketPath: String, makeHandler: @escaping () -> ConnectionHandler) {
        self.socketPath = socketPath
        self.makeHandler = makeHandler
    }

    func start() throws {
        let dir = (socketPath as NSString).deletingLastPathComponent
        try TurboPaths.ensureDirectory(URL(fileURLWithPath: dir, isDirectory: true), mode: 0o700)

        if FileManager.default.fileExists(atPath: socketPath) || isSymlink(socketPath) {
            if Self.probe(socketPath) {
                throw ServerError.alreadyServing(socketPath)
            }
            Log.info("removing stale socket \(socketPath)")
            unlink(socketPath)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.posix("socket", errno) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        var addr = try Self.makeAddress(socketPath)
        // Create the socket node with 0600 from the start, then chmod for good measure.
        let oldMask = umask(0o177)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(oldMask)
        guard bindResult == 0 else {
            let e = errno
            close(fd)
            throw ServerError.posix("bind", e)
        }
        chmod(socketPath, 0o600)
        guard listen(fd, 16) == 0 else {
            let e = errno
            close(fd)
            throw ServerError.posix("listen", e)
        }
        listenFD = fd
        Log.info("listening on \(socketPath)")

        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "turbo.accept"
        thread.start()
    }

    /// Remove the socket file (on shutdown).
    func stop() {
        if listenFD >= 0 {
            // Mark stopped before closing, so the accept thread that wakes up with EBADF
            // sees a deliberate shutdown instead of logging an error.
            let fd = listenFD
            listenFD = -1
            close(fd)
        }
        unlink(socketPath)
    }

    private func isSymlink(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    private func acceptLoop() {
        while listenFD >= 0 {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                if listenFD < 0 { return }
                Log.error("accept failed: errno \(errno)")
                usleep(100_000)
                continue
            }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                Log.warn("rejecting socket peer with uid \(uid) (expected \(getuid()))")
                close(client)
                continue
            }
            connectionCounter += 1
            let id = connectionCounter
            let handler = makeHandler()
            let thread = Thread {
                Connection(fd: client, id: id, handler: handler).run()
            }
            thread.name = "turbo.conn.\(id)"
            thread.stackSize = 8 * 1024 * 1024  // deep AX trees recurse
            thread.start()
        }
    }

    static func makeAddress(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw ServerError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    /// True if something accepts connections on `path`.
    static func probe(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard var addr = try? makeAddress(path) else { return false }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return rc == 0
    }
}

/// Per-connection protocol state handed to the dispatcher.
protocol ConnectionHandler: AnyObject {
    /// Handle one frame; return the response frame body, or nil for no response.
    func handle(frame: Data, connectionId: Int) -> Data?
    func connectionClosed(connectionId: Int)
}

/// Blocking read → handle → write loop for one client.
final class Connection {
    let fd: Int32
    let id: Int
    let handler: ConnectionHandler

    init(fd: Int32, id: Int, handler: ConnectionHandler) {
        self.fd = fd
        self.id = id
        self.handler = handler
    }

    func run() {
        Log.info("conn \(id): opened")
        defer {
            close(fd)
            handler.connectionClosed(connectionId: id)
            Log.info("conn \(id): closed")
        }
        while true {
            let frame: Data
            do {
                guard let f = try readFrame() else { return }  // clean EOF
                frame = f
            } catch {
                Log.warn("conn \(id): protocol error: \(error); closing")
                return
            }
            guard let response = autoreleasepool(invoking: { handler.handle(frame: frame, connectionId: id) }) else {
                continue
            }
            do {
                try writeFrame(response)
            } catch {
                Log.warn("conn \(id): write failed: \(error); closing")
                return
            }
        }
    }

    enum IOError: Error { case eof, posix(Int32) }

    /// Read exactly `count` bytes; nil on EOF before the first byte.
    private func readExactly(_ count: Int, allowEOF: Bool) throws -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = buffer.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress!.advanced(by: got), count - got)
            }
            if n == 0 {
                if got == 0 && allowEOF { return nil }
                throw IOError.eof
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw IOError.posix(errno)
            }
            got += n
        }
        return buffer
    }

    private func readFrame() throws -> Data? {
        guard let header = try readExactly(Framing.headerLength, allowEOF: true) else { return nil }
        let length = try Framing.decodeLength(header)
        guard let body = try readExactly(length, allowEOF: false) else { throw IOError.eof }
        return Data(body)
    }

    private func writeFrame(_ body: Data) throws {
        let data = try Framing.encode(body)
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw IOError.posix(errno)
                }
                offset += n
            }
        }
    }
}

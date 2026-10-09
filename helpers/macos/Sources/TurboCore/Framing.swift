import Foundation

/// Framing errors. Both are fatal for the connection.
public enum FramingError: Error, Equatable, CustomStringConvertible {
    case emptyFrame
    case frameTooLarge(Int)

    public var description: String {
        switch self {
        case .emptyFrame: return "zero-length frame"
        case .frameTooLarge(let n): return "frame of \(n) bytes exceeds the \(Framing.maxFrameLength)-byte cap"
        }
    }
}

/// `uint32 little-endian length N` + `N bytes UTF-8 JSON`, 0 < N <= 8 MiB.
public enum Framing {
    public static let maxFrameLength = TurboProtocol.maxFrameLength
    public static let headerLength = 4

    /// Validate a payload length (shared by encoder and decoder).
    public static func validate(length: Int) throws {
        if length == 0 { throw FramingError.emptyFrame }
        if length > maxFrameLength { throw FramingError.frameTooLarge(length) }
    }

    /// The 4-byte header for a payload of `length` bytes.
    public static func header(length: Int) throws -> [UInt8] {
        try validate(length: length)
        let n = UInt32(length)
        return [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 24) & 0xFF)]
    }

    /// Decode a 4-byte header and validate it.
    public static func decodeLength<C: Collection>(_ header: C) throws -> Int where C.Element == UInt8 {
        precondition(header.count == headerLength, "header must be 4 bytes")
        var n: UInt32 = 0
        for (i, b) in header.enumerated() { n |= UInt32(b) << (8 * UInt32(i)) }
        let length = Int(n)
        try validate(length: length)
        return length
    }

    /// Header + payload.
    public static func encode(_ payload: Data) throws -> Data {
        var out = Data(try header(length: payload.count))
        out.append(payload)
        return out
    }
}

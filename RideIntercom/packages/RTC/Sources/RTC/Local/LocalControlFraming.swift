import Foundation

/// Message boundaries on the reliable control stream: a four-byte big-endian length, then the message.
/// The limit is the one local control already has; a peer that announces more is not read any further.
struct LocalControlFraming {
    static let maximumMessageBytes = 65_536
    enum Failure: Error, Equatable { case oversized }

    static func frame(_ message: Data) throws -> Data {
        guard message.count <= maximumMessageBytes else { throw Failure.oversized }
        return withUnsafeBytes(of: UInt32(message.count).bigEndian) { Data($0) } + message
    }

    private var buffer = Data()

    /// Takes the next bytes of the stream and returns every message they complete, in order.
    mutating func receive(_ bytes: Data) throws -> [Data] {
        buffer.append(bytes)
        var messages: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard length <= Self.maximumMessageBytes else { buffer.removeAll(); throw Failure.oversized }
            guard buffer.count >= 4 + length else { break }
            messages.append(Data(buffer.dropFirst(4).prefix(length)))
            buffer = Data(buffer.dropFirst(4 + length))
        }
        return messages
    }
}

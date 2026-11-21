import Darwin
import Foundation
import Network

/// An owned loopback NAT: media can be dropped while reverse receipts keep
/// forwarding. Neither the host interface nor the real peer is disconnected.
public final class MediaBlackhole: @unchecked Sendable {
    private let queue = DispatchQueue(label: "rtc.tests.media-blackhole")
    private let key = DispatchSpecificKey<Bool>()
    private let front: Int32, back: Int32
    private var sources: [DispatchSourceRead] = []
    private var client: sockaddr_in?
    private var blocked = false
    private var dropped = 0
    public let port: NWEndpoint.Port
    public init(target: NWEndpoint.Port) throws {
        let front = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        let back = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        self.front = front; self.back = back
        guard front >= 0, back >= 0 else {
            if front >= 0 { Darwin.close(front) }; if back >= 0 { Darwin.close(back) }
            throw POSIXError(.EMFILE)
        }
        do {
            port = try Self.bindLoopback(descriptor: front)
        } catch {
            Darwin.close(front); Darwin.close(back)
            throw error
        }
        queue.setSpecific(key: key, value: true)
        for descriptor in [front, back] { _ = fcntl(descriptor, F_SETFL, O_NONBLOCK) }
        let destination = Self.address(port: target.rawValue)
        for descriptor in [front, back] { monitor(descriptor: descriptor, destination: destination) }
    }

    private static func bindLoopback(descriptor: Int32) throws -> NWEndpoint.Port {
        var address = Self.address(port: 0)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw POSIXError(.EADDRINUSE) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
        }
        guard named == 0, let port = NWEndpoint.Port(rawValue: UInt16(bigEndian: address.sin_port)) else {
            throw POSIXError(.EINVAL)
        }
        return port
    }

    private func monitor(descriptor: Int32, destination: sockaddr_in) {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setCancelHandler { Darwin.close(descriptor) }
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                var sender = Self.address(port: 0), size = socklen_t(MemoryLayout<sockaddr_in>.size)
                let count = withUnsafeMutablePointer(to: &sender) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(descriptor, &buffer, buffer.count, 0, $0, &size)
                    }
                }
                guard count > 0 else { break }
                let bytes = Data(buffer.prefix(count))
                if descriptor == self.front {
                    self.client = sender
                    if !self.blocked {
                        Self.send(bytes, descriptor: self.back, to: destination)
                    } else {
                        self.dropped += 1
                    }
                } else if let client = self.client { Self.send(bytes, descriptor: self.front, to: client) }
            }
        }
        sources.append(source); source.resume()
    }

    deinit { stop() }
    public var droppedCount: Int { queue.sync { dropped } }
    public func setBlocked(_ blocked: Bool) { queue.sync { self.blocked = blocked } }
    public func stop() {
        let stop = { self.sources.forEach { $0.cancel() }; self.sources.removeAll() }
        if DispatchQueue.getSpecific(key: key) == true { stop() } else { queue.sync(execute: stop) }
    }
    private static func address(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian; return address
    }
    private static func send(_ bytes: Data, descriptor: Int32, to destination: sockaddr_in) {
        var destination = destination
        bytes.withUnsafeBytes { buffer in
            withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(
                        descriptor, buffer.baseAddress, buffer.count, 0, $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}

import Foundation

/// These are audio-device directions, not group participant identities.
public enum RTCAudioDeviceRole: String, Codable, Sendable {
    case controller, device
    var opposite: Self { self == .controller ? .device : .controller }
    var peer: PeerID { .init(rawValue: rawValue) }
}

/// Pass this discovery tuple through an authenticated companion channel.
/// It contains neither account credentials nor a group identifier.
public struct RTCAudioDeviceEndpoint: Codable, Equatable, Sendable {
    public let name: String
    public let type: String
    public let domain: String

    public init(name: String, type: String, domain: String) {
        self.name = name; self.type = type; self.domain = domain
    }
}

public enum RTCAudioDeviceLinkError: Error, Equatable {
    case invalidKey, invalidPacket, stopped
}

/// One disposable, encrypted audio-device pair. No CallSession, group admission,
/// discovery browser, reliable audio, resend, or background bootstrap is created.
public final class RTCAudioDeviceLink: @unchecked Sendable {
    private let transport: AudioDeviceDuplexFlow
    public init(sessionID: UUID, key: Data, role: RTCAudioDeviceRole,
                onReceive: @escaping @Sendable (RTCAudioPacket) -> Void,
                onEndpointChange: @escaping @Sendable (RTCAudioDeviceEndpoint?) -> Void = { _ in },
                onSendAvailabilityChange: @escaping @Sendable (Bool) -> Void = { _ in },
                onFailure: @escaping @Sendable (String) -> Void = { _ in }) throws {
        transport = try AudioDeviceDuplexFlow(sessionID: sessionID, key: key, role: role,
            onReceive: onReceive, onEndpointChange: onEndpointChange,
            onAvailability: onSendAvailabilityChange, onFailure: onFailure)
    }

    deinit { transport.stop() }
    public var endpoint: RTCAudioDeviceEndpoint? { transport.synchronized { transport.endpoint } }
    public var isSendReady: Bool { transport.synchronized { transport.ready } }
    public var lastReceivedAt: TimeInterval? { transport.synchronized { transport.lastReceivedAt } }
    public var statistics: RTCNetworkStatistics { transport.statistics }
    public func start() throws { try transport.start() }
    @discardableResult public func connect(to endpoint: RTCAudioDeviceEndpoint) -> Bool {
        transport.connect(to: endpoint)
    }
    @discardableResult public func send(_ packet: RTCAudioPacket) -> Bool { transport.send(packet) }
    public func stop() { transport.stop() }
}

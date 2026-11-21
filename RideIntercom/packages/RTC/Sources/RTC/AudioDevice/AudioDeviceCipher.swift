import CryptoKit
import Foundation

/// AES.GCM is the same authenticated primitive used by GroupRelay; group
/// membership/credentials/forwarding never enter the audio-device link.
struct AudioDeviceCipher {
    private struct Envelope: Codable {
        let session: UUID
        let role: RTCAudioDeviceRole
        let sequence: UInt64
        let packet: RTCAudioPacket?
        let kind: String?
    }
    private let session: UUID
    private let role: RTCAudioDeviceRole
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sequence: UInt64 = 0
    private var lastReceived: UInt64?
    private static let namespace = Data("rtc.audio-device.v1".utf8)

    init(sessionID: UUID, key: Data, role: RTCAudioDeviceRole) throws {
        guard key.count == 32 else { throw RTCAudioDeviceLinkError.invalidKey }
        session = sessionID; self.role = role
        func directionKey(_ direction: RTCAudioDeviceRole) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key), salt: Data(sessionID.uuidString.utf8),
                info: Self.namespace + Data(direction.rawValue.utf8), outputByteCount: 32)
        }
        sendKey = directionKey(role); receiveKey = directionKey(role.opposite)
    }

    mutating func seal(_ packet: RTCAudioPacket) throws -> Data {
        guard Self.valid(packet) else { throw RTCAudioDeviceLinkError.invalidPacket }
        return try seal(packet: packet, kind: nil)
    }

    enum Message { case audio(RTCAudioPacket), hello, ack }
    enum Control: String { case hello, ack }

    mutating func sealControl(_ control: Control) throws -> Data {
        try seal(packet: nil, kind: control.rawValue)
    }

    private mutating func seal(packet: RTCAudioPacket?, kind: String?) throws -> Data {
        guard sequence < UInt64.max else { throw RTCAudioDeviceLinkError.invalidPacket }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let plain = try encoder.encode(Envelope(session: session, role: role, sequence: sequence,
                                                packet: packet, kind: kind))
        sequence += 1
        guard let combined = try AES.GCM.seal(plain, using: sendKey, authenticating: Self.namespace).combined else {
            throw RTCAudioDeviceLinkError.invalidPacket
        }
        return combined
    }

    mutating func open(_ bytes: Data) -> RTCAudioPacket? {
        guard case .audio(let packet) = openMessage(bytes) else { return nil }
        return packet
    }

    mutating func openMessage(_ bytes: Data, accepting: (Message) -> Bool = { _ in true }) -> Message? {
        guard bytes.count <= 32_768,
              let box = try? AES.GCM.SealedBox(combined: bytes),
              let plain = try? AES.GCM.open(box, using: receiveKey, authenticating: Self.namespace),
              let envelope = try? PropertyListDecoder().decode(Envelope.self, from: plain),
              envelope.session == session, envelope.role == role.opposite,
              lastReceived.map({ envelope.sequence > $0 }) ?? true else { return nil }
        let result: Message
        switch (envelope.kind, envelope.packet) {
        case (nil, .some(let packet)) where Self.valid(packet): result = .audio(packet)
        case ("hello", nil): result = .hello
        case ("ack", nil): result = .ack
        default: return nil
        }
        guard accepting(result) else { return nil }
        lastReceived = envelope.sequence
        return result
    }

    private static func valid(_ packet: RTCAudioPacket) -> Bool {
        // Match the decoder's common allocation bound, without parsing any codec.
        // This audio-only link has no empty control/DTX packet representation.
        !packet.payload.isEmpty && packet.payload.count <= 8192 && packet.capturedAt.isFinite &&
        packet.format.sampleRate.isFinite && (8_000...48_000).contains(packet.format.sampleRate) &&
        (1...2).contains(packet.format.channelCount) &&
        (packet.sampleCount.map({ (1...(96_000 * packet.format.channelCount)).contains($0) }) ?? true) &&
        (packet.bitRate.map({ (0...1_536_000).contains($0) }) ?? true)
    }
}

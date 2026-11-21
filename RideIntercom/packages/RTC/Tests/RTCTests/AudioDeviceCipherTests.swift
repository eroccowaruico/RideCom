import CryptoKit
import Foundation
import Testing
@testable import RTC

struct AudioDeviceCipherTests {
    let session = UUID()
    let key = Data(repeating: 7, count: 32)
    func packet(_ value: UInt8 = 1) -> RTCAudioPacket {
        .init(sequenceNumber: 42, codec: .pcm16, format: .init(sampleRate: 24_000, channelCount: 1),
            capturedAt: 123, sampleCount: 240, payload: Data(repeating: value, count: 480))
    }
    @Test func pairPreservesPacketsInBothDirections() throws {
        var phone = try AudioDeviceCipher(sessionID: session, key: key, role: .controller)
        var device = try AudioDeviceCipher(sessionID: session, key: key, role: .device)
        #expect(try device.open(phone.seal(packet())) == packet())
        #expect(try phone.open(device.seal(packet(2))) == packet(2))
    }
    @Test func reflectionTamperingWrongKeyAndOldSessionAreRejected() throws {
        var sender = try AudioDeviceCipher(sessionID: session, key: key, role: .controller)
        var reflected = try AudioDeviceCipher(sessionID: session, key: key, role: .controller)
        var receiver = try AudioDeviceCipher(sessionID: session, key: key, role: .device)
        var old = try AudioDeviceCipher(sessionID: UUID(), key: key, role: .device)
        var wrong = try AudioDeviceCipher(sessionID: session, key: Data(repeating: 8, count: 32), role: .device)
        let bytes = try sender.seal(packet())
        var changed = bytes; changed[changed.count - 1] ^= 1
        #expect(reflected.open(bytes) == nil)
        #expect(old.open(bytes) == nil)
        #expect(wrong.open(bytes) == nil)
        #expect(receiver.open(changed) == nil)
        #expect(receiver.open(bytes) == packet(), "Unauthenticated bytes cannot advance replay state")
    }
    @Test func replayAndOldSequenceAreNotDeliveredTwice() throws {
        var sender = try AudioDeviceCipher(sessionID: session, key: key, role: .controller)
        var receiver = try AudioDeviceCipher(sessionID: session, key: key, role: .device)
        let first = try sender.seal(packet())
        #expect(receiver.open(first) != nil)
        #expect(receiver.open(first) == nil)
        let held = try sender.seal(packet(2))
        for _ in 0..<1025 { #expect(receiver.open(try sender.seal(packet(3))) != nil) }
        #expect(receiver.open(held) == nil)
    }
    @Test func controlUsesDirectionalAuthenticationAndSharedReplayProtection() throws {
        var device = try AudioDeviceCipher(sessionID: session, key: key, role: .device)
        var phone = try AudioDeviceCipher(sessionID: session, key: key, role: .controller)
        var wrong = try AudioDeviceCipher(sessionID: session, key: Data(repeating: 8, count: 32), role: .controller)
        var reflected = try AudioDeviceCipher(sessionID: session, key: key, role: .device)
        var old = try AudioDeviceCipher(sessionID: UUID(), key: key, role: .controller)
        let hello = try device.sealControl(.hello)
        #expect(wrong.openMessage(hello) == nil)
        #expect(reflected.openMessage(hello) == nil)
        #expect(old.openMessage(hello) == nil)
        // A valid message on an ineligible flow must not consume its sequence.
        #expect(phone.openMessage(hello, accepting: { _ in false }) == nil)
        guard case .hello = phone.openMessage(hello) else { Issue.record("Valid hello rejected"); return }
        #expect(phone.openMessage(hello) == nil)
        let packet = try device.seal(packet())
        #expect(phone.open(packet) != nil)
        #expect(phone.openMessage(hello) == nil)
        let ack = try phone.sealControl(.ack)
        guard case .ack = device.openMessage(ack) else { Issue.record("Valid acknowledgement rejected"); return }
        #expect(device.openMessage(ack) == nil)
    }
    @Test func invalidKeyAndOversizedOrInvalidPacketAreRejected() throws {
        #expect(throws: RTCAudioDeviceLinkError.invalidKey) {
            _ = try AudioDeviceCipher(sessionID: session, key: Data(), role: .controller)
        }
        var sender = try AudioDeviceCipher(sessionID: session, key: key, role: .controller)
        var receiver = try AudioDeviceCipher(sessionID: session, key: key, role: .device)
        var large = packet(); large.payload = Data(repeating: 1, count: 8193)
        #expect(throws: RTCAudioDeviceLinkError.invalidPacket) { try sender.seal(large) }
        large = packet(); large.format.sampleRate = .infinity
        #expect(throws: RTCAudioDeviceLinkError.invalidPacket) { try sender.seal(large) }
        #expect(receiver.open(Data(repeating: 0, count: 32769)) == nil)
    }
    @Test func decodedMetadataCannotBypassBoundsOrConsumeReplayState() throws {
        var sender = try AudioDeviceCipher(sessionID: session, key: key, role: .controller)
        let original = try sender.seal(packet())
        let namespace = Data("rtc.audio-device.v1".utf8)
        let sendKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key),
            salt: Data(session.uuidString.utf8), info: namespace + Data("controller".utf8), outputByteCount: 32)
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: original), using: sendKey, authenticating: namespace)
        let values = try #require(PropertyListSerialization.propertyList(from: plain, format: nil) as? [String: Any])
        let invalid: [(String, Any)] = [("n", -1), ("n", 0), ("n", 96_001), ("n", Int.max),
            ("b", -1), ("b", 1_536_001), ("b", Int.max), ("t", Double.nan), ("t", Double.infinity), ("p", Data())]
        for (field, value) in invalid {
            var envelope = values
            var fields = try #require(envelope["packet"] as? [String: Any]); fields[field] = value
            envelope["packet"] = fields
            let encoded = try PropertyListSerialization.data(fromPropertyList: envelope, format: .binary, options: 0)
            let malicious = try #require(AES.GCM.seal(encoded, using: sendKey, authenticating: namespace).combined)
            var receiver = try AudioDeviceCipher(sessionID: session, key: key, role: .device)
            #expect(receiver.open(malicious) == nil, "Invalid decoded metadata must be rejected")
            #expect(receiver.open(original) == packet(), "Rejected metadata must not consume its sequence")
        }
    }
    @Test func localMetadataBoundsMatchReceivedPacketBounds() throws {
        var sender = try AudioDeviceCipher(sessionID: session, key: key, role: .controller)
        var invalid = packet(); invalid.sampleCount = -1
        #expect(throws: RTCAudioDeviceLinkError.invalidPacket) { try sender.seal(invalid) }
        invalid = packet(); invalid.capturedAt = .nan
        #expect(throws: RTCAudioDeviceLinkError.invalidPacket) { try sender.seal(invalid) }
        invalid = packet(); invalid.bitRate = Int.max
        #expect(throws: RTCAudioDeviceLinkError.invalidPacket) { try sender.seal(invalid) }
        var valid = packet(); valid.sampleCount = 96_000; valid.bitRate = 1_536_000
        var receiver = try AudioDeviceCipher(sessionID: session, key: key, role: .device)
        #expect(receiver.open(try sender.seal(valid)) == valid)
        valid.sampleCount = nil; valid.bitRate = nil
        #expect(receiver.open(try sender.seal(valid)) == valid)
    }
    @Test func reorderedPacketsAreAuthenticatedOnceWithoutWaiting() throws {
        var sender = try AudioDeviceCipher(sessionID: session, key: key, role: .controller)
        var receiver = try AudioDeviceCipher(sessionID: session, key: key, role: .device)
        let earlier = try sender.seal(packet(1)), later = try sender.seal(packet(2))
        #expect(receiver.open(later) == packet(2))
        #expect(receiver.open(earlier) == nil, "A late older audio packet must not play after a newer one")
    }
}

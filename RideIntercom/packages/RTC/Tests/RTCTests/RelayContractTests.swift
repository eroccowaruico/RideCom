import Foundation
import Testing
@testable import RTC

@Suite struct RelayContractTests {
    let credential = RTCCredential.derived(groupID: "group", secret: "secret")
    func relay(
        _ id: String, codecs: [RTCAudioCodecIdentifier] = [.pcm16, .opus], credential: RTCCredential? = nil
    ) -> GroupRelay {
        GroupRelay(request: .init(sessionID: "group", localPeer: .init(id: .init(rawValue: id), displayName: id),
                credential: credential ?? self.credential, audioPolicy: .init(preferredCodecs: codecs)))
    }
    @Test func audioPolicyChangeKeepsPeerIdentityAndReplayProtection() throws {
        var sender = relay("a"), receiver = relay("b", codecs: [.pcm16])
        let peer = PeerID(rawValue: "a")
        let presence = try sender.make(.presence, now: 0)
        #expect(receiver.receive(presence, from: peer, now: 0) != nil)
        receiver.updateAudioPolicy(.init(preferredCodecs: [.opus]))
        #expect(receiver.receive(presence, from: peer, now: 1) == nil)
        let packet = RTCAudioPacket(sequenceNumber: 8, codec: .opus, payload: Data([1]))
        let received = try #require(receiver.receive(try sender.make(.audio(packet), now: 1), from: peer, now: 1))
        #expect(received.didRestart == false)
        #expect(receiver.members(now: 1).map(\.id) == [peer])
    }
    @Test func codecAndFormatMetadataSurviveCommonEncryptedPath() throws {
        var sender = relay("a"), receiver = relay("b", codecs: [.opus])
        let peer = PeerID(rawValue: "a")
        _ = receiver.receive(try sender.make(.presence, now: 0), from: peer, now: 0)
        for (format, preparation): (RTCAudioFormat, TimeInterval?) in [
            (.init(sampleRate: 24_000, channelCount: 2), nil), (.init(sampleRate: 48_000, channelCount: 1), 0.0153)
        ] {
            var packet = RTCAudioPacket(sequenceNumber: 99, codec: .opus, format: format, capturedAt: 123,
                                        sampleCount: 480, bitRate: 32000, payload: Data([1, 2, 3]))
            packet.captureToSendQueue = preparation
            let reception = try #require(receiver.receive(try sender.make(.audio(packet), now: 1), from: peer, now: 1))
            guard case .audio(let received) = reception.body else { Issue.record("Missing audio"); return }
            #expect(received.codec == packet.codec && received.format == packet.format)
            #expect(received.capturedAt == packet.capturedAt && received.sampleCount == packet.sampleCount)
            #expect(received.bitRate == packet.bitRate && received.payload == packet.payload)
            #expect(received.captureToSendQueue == preparation)
        }
        let unsupported = RTCAudioPacket(sequenceNumber: 0, codec: .pcm16, payload: Data([1]))
        let wire = try sender.make(.audio(unsupported), now: 1)
        #expect(receiver.receive(wire, from: peer, now: 1) == nil)
        receiver.updateAudioPolicy(.init(preferredCodecs: [.pcm16]))
        #expect(receiver.receive(wire, from: peer, now: 1) != nil)
        #expect(receiver.receive(wire, from: peer, now: 1) == nil)
    }
    @Test func outOfWindowSendQueueAgeDoesNotAffectAudio() throws {
        var packet = RTCAudioPacket(sequenceNumber: 3, codec: .opus, payload: Data([1]))
        for invalid in [-0.001, 0.121, .infinity, .nan] {
            packet.captureToSendQueue = invalid
            #expect(packet.captureToSendQueue == nil)
        }
        let encoded = try JSONEncoder().encode(packet)
        guard var fields = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            Issue.record("Expected an audio packet object"); return
        }
        #expect(fields["a"] == nil)
        for invalid in [-1, 1_201] {
            fields["a"] = invalid
            let data = try JSONSerialization.data(withJSONObject: fields)
            let decoded = try JSONDecoder().decode(RTCAudioPacket.self, from: data)
            #expect(decoded.captureToSendQueue == nil)
            #expect(decoded.payload == packet.payload)
        }
    }
    @Test func sendQueueAgeRequiresAGroupCredential() throws {
        let peer = PeerID(rawValue: "a")
        var sender = GroupRelay(request: .init(sessionID: "group", localPeer: .init(id: peer, displayName: "a")))
        var receiver = GroupRelay(request: .init(sessionID: "group",
            localPeer: .init(id: .init(rawValue: "b"), displayName: "b")))
        #expect(receiver.receive(try sender.make(.presence, now: 0), from: peer, now: 0) != nil)
        var packet = RTCAudioPacket(sequenceNumber: 0, codec: .pcm16, payload: Data([1]))
        packet.captureToSendQueue = 0.01
        let wire = try sender.make(.audio(packet), now: 1)
        let plist = try PropertyListSerialization.propertyList(from: wire, format: nil)
        var envelope = try #require(plist as? [String: Any])
        let body = try #require(envelope["b"] as? [String: Any])
        let audio = try #require(body["audio"] as? [String: Any])
        var fields = try #require(audio["_0"] as? [String: Any])
        #expect(fields["a"] == nil)
        fields["a"] = 100
        envelope["b"] = ["audio": ["_0": fields]]
        let unencrypted = try PropertyListSerialization.data(fromPropertyList: envelope, format: .binary, options: 0)
        let result = receiver.receive(unencrypted, from: peer, now: 1)
        let reception = try #require(result)
        guard case .audio(let received) = reception.body else { Issue.record("Missing audio"); return }
        #expect(received.captureToSendQueue == nil)
        #expect(received.payload == packet.payload)
    }
    @Test func commonPathRejectsPlaintextWrongSecretAndRetiredEpoch() throws {
        let peer = PeerID(rawValue: "a")
        var sender = relay("a"), receiver = relay("b")
        var wrong = relay("a", credential: .derived(groupID: "group", secret: "wrong"))
        var plain = GroupRelay(request: .init(sessionID: "group", localPeer: .init(id: peer, displayName: "a")))
        #expect(receiver.receive(try wrong.make(.presence, now: 0), from: peer, now: 0) == nil)
        #expect(receiver.receive(try plain.make(.presence, now: 0), from: peer, now: 0) == nil)
        let oldPresence = try sender.make(.presence, now: 0)
        _ = receiver.receive(oldPresence, from: peer, now: 0)
        var restarted = relay("a")
        #expect(receiver.receive(try restarted.make(.presence, now: 1), from: peer, now: 1)?.didRestart == true)
        #expect(receiver.receive(oldPresence, from: peer, now: 1) == nil)
        #expect(
            receiver.receive(
                try sender.make(.audio(.init(sequenceNumber: 0, codec: .pcm16, payload: Data([1]))), now: 1),
                from: peer, now: 1) == nil)
    }
    @Test func tenMinutesOfCommonDuplexAudioPreserveFramesAndBoundQueues() throws {
        var relayA = relay("a"), relayB = relay("b")
        var queueA = PacketAudioReceiveBuffer(), queueB = PacketAudioReceiveBuffer()
        let peerA = PeerID(rawValue: "a"), peerB = PeerID(rawValue: "b")
        var deliveredA = 0, deliveredB = 0
        func receive(
            _ data: Data, hop: PeerID, relay: inout GroupRelay, queue: inout PacketAudioReceiveBuffer, now: Double
        ) throws {
            let received = relay.receive(data, from: hop, now: now, preparesAudioForwarding: false)
            let result = try #require(received)
            guard case .audio(let packet) = result.body else { Issue.record("Missing audio"); return }
            try #require(result.forward == nil)
            queue.enqueue(.init(received: .init(peerID: result.peer.id, packet: packet)), receivedAt: now)
            #expect(relay.receive(data, from: hop, now: now) == nil)
            #expect(queue.queuedPacketCount <= 2)
        }
        for frame in 0..<30_000 {
            let now = Double(frame) * 0.02
            if frame % 100 == 0 {
                _ = relayB.receive(try relayA.make(.presence, now: now), from: peerA, now: now)
                _ = relayA.receive(try relayB.make(.presence, now: now), from: peerB, now: now)
            }
            let packet = RTCAudioPacket(
                sequenceNumber: UInt64(frame), codec: .pcm16, payload: Data([UInt8(frame % 251)]))
            try receive(relayA.make(.audio(packet), now: now), hop: peerA, relay: &relayB, queue: &queueB, now: now)
            try receive(relayB.make(.audio(packet), now: now), hop: peerB, relay: &relayA, queue: &queueA, now: now)
            let framesA = queueA.drain(now: now).readyPackets, framesB = queueB.drain(now: now).readyPackets
            for received in framesA {
                #expect(received.packet.payload == Data([UInt8(deliveredA % 251)])); deliveredA += 1
            }
            for received in framesB {
                #expect(received.packet.payload == Data([UInt8(deliveredB % 251)])); deliveredB += 1
            }
        }
        deliveredA += queueA.drain(now: 600).readyPackets.count
        deliveredB += queueB.drain(now: 600).readyPackets.count
        #expect(deliveredA == 30_000 && deliveredB == 30_000)
        queueA.reset(); queueB.reset()
        #expect(queueA.queuedPacketCount == 0 && queueB.queuedPacketCount == 0)
    }
}

extension RelayContractTests {
    @Test func localControlWirePreservesNamespaceDeliveryAndPayload() throws {
        for delivery in [ApplicationDataDelivery.reliable, .unreliable] {
            let message = ApplicationDataMessage(namespace: "control", payload: Data([1, 2]), delivery: delivery)
            let data = try JSONEncoder().encode(message)
            let frame = try LocalControlFraming.frame(data)
            var decoder = LocalControlFraming()
            let decoded = try #require(try decoder.receive(frame).first)
            #expect(try JSONDecoder().decode(ApplicationDataMessage.self, from: decoded) == message)
        }
    }

    @Test func eightParticipantChainReachesEveryMemberAndStopsAtHopLimit() throws {
        var nodes = (0..<8).map { relay(String($0)) }
        let origin = PeerID(rawValue: "0")
        for body in [RelayBody.presence, .audio(.init(sequenceNumber: 0, codec: .pcm16, payload: Data([42])))] {
            var data = try nodes[0].make(body, now: 0)
            for receiver in 1..<8 {
                let reception = nodes[receiver].receive(data, from: .init(rawValue: String(receiver - 1)), now: 0)
                let result = try #require(reception)
                #expect(result.peer.id == origin)
                #expect(result.path.count == receiver + 1)
                if receiver == 7 { #expect(result.forward == nil) } else { data = try #require(result.forward) }
            }
        }
        var receiver = relay("receiver")
        for index in 0..<7 {
            #expect(
                receiver.receive(try nodes[index].make(.presence, now: 0), from: .init(rawValue: String(index)), now: 0)
                    != nil)
        }
        #expect(receiver.receive(try nodes[7].make(.presence, now: 0), from: .init(rawValue: "7"), now: 0) == nil)
        _ = receiver.receive(try nodes[0].make(.leave, now: 1), from: origin, now: 1)
        #expect(receiver.receive(try nodes[7].make(.presence, now: 1), from: .init(rawValue: "7"), now: 1) != nil)
        #expect(receiver.members(now: 1).count == 7)
    }

    @Test func replayWindowAndPeerQueueResetKeepOtherSpeakerIntact() throws {
        var sender = relay("a"), receiver = relay("b")
        let peerA = PeerID(rawValue: "a"), peerB = PeerID(rawValue: "b")
        _ = receiver.receive(try sender.make(.presence, now: 0), from: peerA, now: 0)
        let old = try sender.make(.audio(.init(sequenceNumber: 0, codec: .pcm16, payload: Data([1]))), now: 0)
        for _ in 0..<1025 { _ = receiver.receive(try sender.make(.presence, now: 0), from: peerA, now: 0) }
        #expect(receiver.receive(old, from: peerA, now: 0) == nil)
        var buffer = PacketAudioReceiveBuffer()
        for peer in [peerA, peerB] {
            buffer.enqueue(
                .init(
                    received: .init(
                        peerID: peer, packet: .init(sequenceNumber: 10, codec: .pcm16, payload: Data([1])))),
                receivedAt: 0)
        }
        buffer.removePeer(peerA)
        #expect(buffer.drain(now: 0.02).readyPackets.map(\.peerID) == [peerB])
        buffer.enqueue(
            .init(
                received: .init(peerID: peerA, packet: .init(sequenceNumber: 0, codec: .pcm16, payload: Data([1])))
            ), receivedAt: 0.03)
        #expect(buffer.drain(now: 0.05).readyPackets.map(\.peerID) == [peerA])
    }
}

@Test func controlDeliveryIsReliableAndLiveAudioKeepsMembershipDuringControlOutage() throws {
    #expect(RelayBody.presence.delivery == .reliable)
    #expect(RelayBody.leave.delivery == .reliable)
    let tests = RelayContractTests()
    var sender = tests.relay("a"), receiver = tests.relay("b")
    let peer = PeerID(rawValue: "a")
    _ = receiver.receive(try sender.make(.presence, now: 0), from: peer, now: 0)
    let packet = RTCAudioPacket(sequenceNumber: 0, codec: .pcm16, payload: Data([1]))
    #expect(RelayBody.audio(packet).delivery == .unreliable)
    for second in 1...20 {
        #expect(
            receiver.receive(try sender.make(.audio(packet), now: Double(second)), from: peer, now: Double(second))
                != nil)
    }
    #expect(receiver.members(now: 20).map(\.id) == [peer])
    #expect(receiver.members(now: 29).isEmpty)
    #expect(receiver.receive(try sender.make(.audio(packet), now: 29), from: peer, now: 29) == nil)
    let delayedControl = ApplicationDataMessage(namespace: "old-settings", payload: Data([1]))
    _ = receiver.receive(try sender.make(.application(delayedControl), now: 29), from: peer, now: 29)
    #expect(receiver.members(now: 29).isEmpty, "Queued control cannot revive an expired audio membership")
    #expect(receiver.receive(try sender.make(.audio(packet), now: 29.1), from: peer, now: 29.1) == nil)
}

import Foundation
import Testing
@testable import RTC

@Test func packetAudioReceiveBufferDrainsPacketsAfterDelayInStableOrder() {
    var buffer = PacketAudioReceiveBuffer(configuration: PacketAudioReceiveConfiguration(
            playoutDelay: 0.08,
            packetLifetime: 1.0
        ))

    buffer.enqueue(makeFilteredPacketAudioPacket(peerID: "remote", sequenceNumber: 0), receivedAt: 9.9)
    #expect(buffer.drain(now: 9.9).readyPackets.map(\.packet.sequenceNumber) == [0])

    buffer.enqueue(makeFilteredPacketAudioPacket(peerID: "remote", sequenceNumber: 2), receivedAt: 10.00)
    buffer.enqueue(makeFilteredPacketAudioPacket(peerID: "remote", sequenceNumber: 1), receivedAt: 10.01)

    // The missing predecessor arrived before the timer: release the complete
    // ordered sequence immediately instead of imposing a fixed wait.
    let ready = buffer.drain(now: 10.05).readyPackets

    #expect(ready.map(\.packet.sequenceNumber) == [1, 2])
    #expect(buffer.queuedPacketCount == 0)
}

@Test func packetAudioReceiveBufferDropsExpiredPackets() {
    var buffer = PacketAudioReceiveBuffer(configuration: PacketAudioReceiveConfiguration(
            playoutDelay: 0.01,
            packetLifetime: 0.50
        ))

    buffer.enqueue(makeFilteredPacketAudioPacket(peerID: "remote", sequenceNumber: 1), receivedAt: 20.00)
    buffer.enqueue(makeFilteredPacketAudioPacket(peerID: "remote", sequenceNumber: 2), receivedAt: 20.00)

    let report = buffer.drain(now: 20.60)

    #expect(report.readyPackets.isEmpty)
    #expect(report.expiredPacketCount == 2)
    #expect(report.receivedPacketCount == 2)
    #expect(report.droppedPacketCount == 2)
    #expect(report.queuedPacketCount == 0)
    #expect(buffer.queuedPacketCount == 0)
    #expect(buffer.droppedPacketCount == 2)
}

private func makeFilteredPacketAudioPacket(
    peerID: String,
    sequenceNumber: UInt64
) -> FilteredPacketAudioPacket {
    FilteredPacketAudioPacket(
        received: ReceivedAudioPacket(
            peerID: PeerID(rawValue: peerID),
            packet: makePacket(sequenceNumber: sequenceNumber)
        )
    )
}

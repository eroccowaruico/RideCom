import AudioCore
import AVFAudio
import Foundation
import Testing
@testable import AudioMixer

@Test(arguments: [false, true])
func captureWindowAcceptsItsExactUpperBoundaryAndRebasesBeyondIt(outside: Bool) throws {
    let mixer = AudioMixer()
    let bus = try mixer.createBus("window-boundary")
    let source = try bus.addPCMSource(id: "voice", maximumBufferedDuration: 0.125, captureTimePlayoutDelay: 0)
    _ = source.captureTimeReservation(.init(capturedAt: 0, arrivedAt: 0, frameLength: 480,
        duration: 0.01, audible: true, position: (0, 0), nativeLead: 0,
        delay: 0, limit: 0.125, packetizationJitter: 0))
    let timestamp = 0.125 + (outside ? 1.0 / 48000 : 0)
    let next = source.captureTimeReservation(.init(capturedAt: timestamp, arrivedAt: timestamp, frameLength: 480,
        duration: 0.01, audible: true, position: (0, 0), nativeLead: 0,
        delay: 0, limit: 0.125, packetizationJitter: 0))
    #expect(next.startSample == (outside ? 0 : 6000))
    #expect(source.playbackResetCount == (outside ? 1 : 0))
    #expect(next.options.isEmpty)
}

@Test func sourceAcceptsExactFrameBudgetAndRecoversAfterAnOversizedFrame() throws {
    let format = AudioFormat(sampleRate: 48000, channelCount: 1)
    let mixer = try AudioMixer(audioFormat: format)
    let bus = try mixer.createBus("frame-budget")
    let source = try bus.addPCMSource(id: "voice", maximumBufferedDuration: 0.1)
    _ = try source.schedule(.init(sequenceNumber: 0, format: format, samples: Array(repeating: 0.2, count: 4800)))
    #expect(throws: (any Error).self) {
        try source.schedule(.init(sequenceNumber: 1, format: format, samples: Array(repeating: 0.2, count: 4801)))
    }
    _ = try source.schedule(.init(sequenceNumber: 2, format: format, samples: Array(repeating: 0.3, count: 480)))
    #expect(bus.snapshot().sources.first?.lastFailure == nil)
}

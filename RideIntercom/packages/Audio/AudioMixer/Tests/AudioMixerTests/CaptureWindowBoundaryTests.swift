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

@Test(arguments: [0, 256, 512])
func lateReservationCountsTheRenderBlockOnce(writableLead: Int) throws {
    let mixer = try AudioMixer(audioFormat: .init())
    let bus = try mixer.createBus("late-reservation")
    let source = try bus.addPCMSource(id: "voice", maximumBufferedDuration: 0.12,
        captureTimePlayoutDelay: 0.002, adaptivePlayout: true)
    let lead = AVAudioFramePosition(writableLead)
    let nativeHandoff = min(lead, 96)
    let initial = source.captureTimeReservation(.init(capturedAt: 0, arrivedAt: 0.013, frameLength: 480,
        duration: 0.01, audible: true, position: (0, lead), nativeLead: nativeHandoff,
        delay: 0.002, limit: 0.12, packetizationJitter: 0), observesAnchor: true)
    let initialLead = try #require(initial.anchorLead)
    #expect(initialLead.nativeLeadFrames == nativeHandoff)
    #expect(initialLead.configuredDelay == 0.002)
    #expect(initialLead.packetizationJitter == 0)
    #expect(initialLead.retainedJitterFramesBefore == 0 && initialLead.retainedJitterFramesAfter == 0)
    let expiredPosition = initial.startSample + 1200
    let completed = expiredPosition + 32
    let recovered = source.captureTimeReservation(.init(capturedAt: 0.025, arrivedAt: 0.048, frameLength: 480,
        duration: 0.01, audible: true, position: (completed, completed + lead), nativeLead: nativeHandoff,
        delay: 0.002, limit: 0.12, packetizationJitter: 0), observesAnchor: true)
    let recoveryLead = try #require(recovered.anchorLead)
    #expect(recoveryLead.retainedJitterFramesBefore == 0 && recoveryLead.retainedJitterFramesAfter > 0)
    let additionalWait = recovered.startSample - completed
    let expectedWait = max(lead, 480) + 480 + nativeHandoff + 96
    #expect(abs(additionalWait - expectedWait) <= 1)
    #expect(source.lastPlayoutAdjustment?.reason == .pastRenderPosition)
    #expect(source.lastPlayoutAdjustment?.previousSample == expiredPosition)
    #expect(source.playbackResetCount == 0)
}

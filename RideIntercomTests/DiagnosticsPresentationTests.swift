import RTC
import Testing
import VADGate
@testable import RideIntercom

extension AppTests {
@MainActor
struct DiagnosticsPresentationTests {
    @Test func transmitProjectionPreservesFailureMuteAndFallbackWithoutReadingLiveState() {
        let h = AppTestSupport.makeHarness()
        var input = DiagnosticsInput(h.viewModel)
        input.audioErrorMessage = "failed"
        input.isMuted = true
        input.isAudioReady = true
        input.preferredTransmitCodec = .opus
        input.selectedTransmitCodec = .pcm16
        let presentation = TransmitPipelinePresentation(input: input)
        h.viewModel.audioErrorMessage = nil
        h.viewModel.isMuted = false
        #expect(presentation.sessionStep.state == .blocked)
        #expect(presentation.inputStreamStep.state == .muted)
        #expect(presentation.codecStep.state == .waiting)
        #expect(presentation.codecStep.detail.contains("Fallback"))
        #expect(presentation.rtcStep.accessibilityIdentifier == "pipeline-rtc-step")
    }

    @Test func transmitProjectionDoesNotReportEncodedAudioAsNetworkDelivery() {
        let h = AppTestSupport.makeHarness()
        h.viewModel.isAudioReady = true
        h.viewModel.sentVoicePacketCount = 10
        var input = DiagnosticsInput(h.viewModel)
        input.isVoiceActive = true
        input.selectedGroupConnectionState = .localConnected
        let presentation = TransmitPipelinePresentation(input: input)

        #expect(presentation.rtcStep.detail.contains("Control Connected"))
        #expect(!presentation.rtcStep.detail.contains("10"))
        #expect(presentation.encodedAudioPacketCount == 10)
        #expect(presentation.codecStep.state == .passing)
        input.encodedAudioPacketCount = 0
        #expect(TransmitPipelinePresentation(input: input).codecStep.state == .waiting)
        input.isAudioReady = false
        let paused = TransmitPipelinePresentation(input: input)
        #expect(paused.encodedAudioPacketCount == nil)
        #expect(paused.rtcStep.detail == presentation.rtcStep.detail)
    }

    @Test func transmitProjectionDisplaysAnalyzerInputOnlyWhenActive() throws {
        let h = AppTestSupport.makeHarness()
        let gate = VADGate(configuration: .init())
        let analysis = gate.process(samples: Array(repeating: 0.001, count: 480), duration: 0.010)
        h.viewModel.vadGateRuntimeSnapshot = gate.runtimeSnapshot
        var input = DiagnosticsInput(h.viewModel)
        #expect(TransmitPipelinePresentation(input: input).voiceActivityAnalysis == nil)

        input.isAudioReady = true
        let measured = try #require(TransmitPipelinePresentation(input: input).voiceActivityAnalysis)
        #expect(measured == analysis)
        #expect(abs(measured.rmsDBFS + 60) < 0.01)

        input.isMuted = true
        #expect(TransmitPipelinePresentation(input: input).voiceActivityAnalysis == nil)
    }

    @Test func receiveProjectionPreservesUnknownCodecAndFallbackPeerDetails() {
        let h = AppTestSupport.makeHarness(groups: [])
        var input = DiagnosticsInput(h.viewModel)
        input.authenticatedPeerIDs = ["new-peer"]
        input.peerVolumes = ["new-peer": 0.25]
        let presentation = ReceivePipelinePresentation(input: input)
        #expect(presentation.receivePeerBuses.count == 1)
        #expect(presentation.receivePeerBuses[0].id == "new-peer")
        #expect(presentation.receivePeerBuses[0].activeCodec == nil)
        #expect(presentation.receivePeerBuses[0].outputVolume == 0.25)
        #expect(presentation.outputStep.accessibilityIdentifier == "receive-pipeline-output-step")
        #expect(presentation.masterEffectStages.isEmpty)
        input.isOutputMuted = true
        #expect(ReceivePipelinePresentation(input: input).outputStep.state == .muted)
        input.isOutputMuted = false
        input.masterOutputVolume = 0
        #expect(ReceivePipelinePresentation(input: input).outputStep.state == .waiting)
    }
}
}

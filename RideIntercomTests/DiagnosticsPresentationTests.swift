import AudioMixer
import Foundation
import RTC
import Testing
import VADGate
#if os(iOS)
import SwiftUI
#endif
@testable import RideIntercom

extension AppTests {
@MainActor
struct DiagnosticsPresentationTests {
    #if os(iOS)
    @Test func renderNetworkAtStandardAndLargestTextSizes() throws {
        let model = AppTestSupport.makeHarness().viewModel
        let origin = PeerID(rawValue: "11111111-origin")
        let firstRelay = PeerID(rawValue: "22222222-relay")
        let secondRelay = PeerID(rawValue: "33333333-relay")
        let receiver = PeerID(rawValue: "44444444-receiver")
        let direct = PeerID(rawValue: "55555555-direct")
        let group = try IntercomGroup(name: "Paths Ride", members: [
            .init(id: origin.rawValue, displayName: "Haruka from the Ridge Team"),
            .init(id: direct.rawValue, displayName: "Kenta"),
            .init(id: receiver.rawValue, displayName: "Me")
        ])
        model.selectedGroup = group
        model.activeGroupID = group.id
        let now = Date().timeIntervalSince1970
        var internet = RTCNetworkStatistics(roundTripTime: 0.042, bufferedBytes: 12_345)
        internet.packetLoss = 0.004
        var drops = RTCEventDropReport()
        drops.overflow = 7
        drops.expired = 12
        model.lastRouteMetrics = .init(route: .webRTC, jitter: 0.006)
        model.networkDiagnostics = .init(generatedAt: now - 20,
                                        routes: [.init(route: .webRTC, statistics: internet, eventDrops: ["transport": drops])],
                                        peers: [
            .init(peerID: origin, route: .multipeer, path: [origin, firstRelay, secondRelay, receiver], observedAt: now - 2),
            .init(peerID: direct, route: .webRTC, path: [direct, receiver], observedAt: now - 20)
        ])

        for (name, size) in [("standard", DynamicTypeSize.large), ("accessibility", .accessibility5)] {
            let view = DiagnosticsNetworkView(viewModel: model)
                .padding(12)
                .frame(width: 320)
                .background(AppColorPalette.listScreenBackground)
                .environment(\.dynamicTypeSize, size)
            let renderer = ImageRenderer(content: view)
            let frame = try #require(renderer.uiImage?.cgImage)
            let cards = try #require(frame.cropping(to: CGRect(
                x: 0, y: 0, width: frame.width, height: min(frame.height, 2900)
            )))
            Attachment.record(try #require(UIImage(cgImage: cards).pngData()), named: "network-metrics-\(name).png")
            let height = min(frame.height, 2500)
            let focused = try #require(frame.cropping(to: CGRect(
                x: 0, y: frame.height - height, width: frame.width, height: height
            )))
            let data = try #require(UIImage(cgImage: focused).pngData())
            Attachment.record(data, named: "network-paths-\(name).png")
        }
    }

    @Test func networkQueueRowFitsAtTheLargestTextSize() throws {
        let title = "Send queue"
        let value = "12345 B"
        let row = DiagnosticsValueRow(title, value: value)
            .frame(width: 260)
            .environment(\.dynamicTypeSize, .accessibility5)
        let stacked = VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(verbatim: title)
            Text(verbatim: value).monospacedDigit()
        }
        .font(.subheadline)
        .frame(width: 260)
        .environment(\.dynamicTypeSize, .accessibility5)

        let actualHeight = try #require(ImageRenderer(content: row).uiImage?.size.height)
        let stackedHeight = try #require(ImageRenderer(content: stacked).uiImage?.size.height)
        #expect(actualHeight <= stackedHeight + 1)
    }
    #endif

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

    @Test func transmitBranchesDistinguishOffersLocalCoverageAndStaleReports() throws {
        let model = AppTestSupport.makeHarness().viewModel
        let now = Date().timeIntervalSince1970
        let groups = IntercomSeedData.recentGroups
        model.activeGroupID = groups[0].id
        model.selectedGroup = groups[1]
        model.isAudioReady = true
        model.networkDiagnostics = .init(generatedAt: now,
            routes: [.init(route: .webRTC, statistics: .init(bufferedBytes: 1228))],
            outboundAudioDispatch: .init(offeredRoutes: [.multipeer], internetCoveredByLocal: true, observedAt: now - 2,
                transportAcceptance: [.multipeer: true]))
        let otherGroup = TransmitPipelinePresentation(input: DiagnosticsInput(model)).outboundRoutes(now: now)
        #expect(otherGroup.branches.map(\.state) == [.idle, .idle])
        #expect(otherGroup.branches.first?.detail == "No audio dispatch observed")

        model.selectedGroup = groups[0]
        let local = TransmitPipelinePresentation(input: DiagnosticsInput(model)).outboundRoutes(now: now)
        #expect(local.summary == "Last audio dispatch · 2s ago")
        #expect(local.branches.map(\.state) == [.passing, .idle])
        #expect(local.branches.first?.detail == "Accepted by transport")
        #expect(local.branches.last?.detail == "Covered by Local / Send queue: 1228 B")

        model.networkDiagnostics?.outboundAudioDispatch?.offeredRoutes = [.multipeer, .webRTC]
        model.networkDiagnostics?.outboundAudioDispatch?.internetCoveredByLocal = false
        model.networkDiagnostics?.outboundAudioDispatch?.transportAcceptance = nil
        let older = TransmitPipelinePresentation(input: DiagnosticsInput(model)).outboundRoutes(now: now)
        #expect(older.branches.map(\.state) == [.waiting, .waiting])
        #expect(older.branches.first?.detail == "Acceptance not measured")

        model.networkDiagnostics?.outboundAudioDispatch?.transportAcceptance = [.multipeer: true, .webRTC: false]
        let mixed = TransmitPipelinePresentation(input: DiagnosticsInput(model))
        let branches = mixed.outboundRoutes(now: now).branches
        #expect(branches.map(\.state) == [.passing, .waiting])
        #expect(branches.last?.detail == "Not accepted by transport / Send queue: 1228 B")
        let stale = mixed.outboundRoutes(now: now + 16)
        #expect(stale.branches.map(\.state) == [.idle, .idle])
        #expect(stale.branches.last?.detail == "Last dispatch is stale / Send queue: Not measured")

        #if os(iOS)
        for (name, size) in [("standard", DynamicTypeSize.large), ("accessibility", .accessibility5)] {
            let view = LiveTransmitPipelineView(viewModel: model, expandedStage: .constant("rtc"))
                .frame(width: 370)
                .padding()
                .background(AppColorPalette.listScreenBackground)
                .environment(\.dynamicTypeSize, size)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let data = try #require(renderer.uiImage?.pngData())
            Attachment.record(data, named: "tx-dispatch-\(name).png")
        }
        #endif
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

    @Test func receivePeerDetailsUseCapturedValuesAndKeepPeerEffectsSeparate() {
        let model = AppTestSupport.makeHarness().viewModel
        model.remoteOutputVolumes = ["first": 0.4, "second": 0.8]
        var input = DiagnosticsInput(model, now: 100)
        input.audioMixerSnapshot.buses = [
            .init(id: "rx-peer-first", volume: 1, sourceCount: 0, effectCount: 1,
                effectChain: [.init(id: "first-effect", typeName: "Test", index: 0, state: .active,
                    parameters: [.init(id: "shortLabel", value: "First"), .init(id: "detail", value: "Ready")])]),
            .init(id: "rx-peer-second", volume: 1, sourceCount: 0, effectCount: 0)
        ]
        let presentation = ReceivePipelinePresentation(input: input)
        model.remoteOutputVolumes["first"] = 0.9
        input.audioMixerSnapshot.buses.removeAll()
        let first = presentation.peerDetail(for: "first")
        let second = presentation.peerDetail(for: "second")
        #expect(first.volume == 0.4)
        #expect(second.volume == 0.8)
        #expect(first.effectSummary == "1 stages / First Ready")
        #expect(second.effectSummary == "No effects")
        #expect(first.paths == "Path not measured")
        #expect(first.age == nil)
        #expect(ReceivePipelinePresentation(input: input).peerDetail(for: "first").effectSummary == "No effects")
    }

    @Test func receiveProjectionPreservesUnknownCodecAndFallbackPeerDetails() {
        let h = AppTestSupport.makeHarness(groups: [])
        var input = DiagnosticsInput(h.viewModel)
        input.authenticatedPeerIDs = ["new-peer"]
        let presentation = ReceivePipelinePresentation(input: input)
        #expect(presentation.receiveParticipants.map(\.id) == ["new-peer"])
        #expect(presentation.receiveParticipants.first?.activeCodec == nil)
        #expect(presentation.receivePeerStates.isEmpty)
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

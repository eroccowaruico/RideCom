import AVFAudio
import Foundation
import AudioCore
import AudioMixer
import Codec
import RTC
import SessionManager
import Testing
import VADGate
import SoundIsolation
import PeakLimiter
@testable import RideIntercom

extension AppTests {
@MainActor
struct ArchitectureTests {
    @Test func appDoesNotRequestUnusedICloudServices() throws {
        let url = AppTestSupport.workspaceRoot().appendingPathComponent("RideIntercom/RideIntercom.entitlements")
        let entitlements = try #require(
            PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil) as? [String: Any]
        )
        #expect(entitlements.keys.contains { $0.hasPrefix("com.apple.developer.icloud-") } == false)
    }

    @Test func appTargetSupportsIOSAndMacOSWithoutAudioUnitLinkage() throws {
        let project = try AppTestSupport.source("RideIntercom.xcodeproj/project.pbxproj")

        #expect(project.contains("iphoneos iphonesimulator macosx"))
        #expect(project.contains("AudioUnit.framework in Frameworks") == false)
        #expect(project.contains("RTCNativeWebRTC"))
    }

    @Test func appSourcesDoNotContainTestOnlyLaunchSwitchesOrObsoleteAudioPipeline() throws {
        let obsoleteTerms = [
            "UI-TEST",
            "isUITestProcess",
            "ProcessInfo.processInfo.arguments",
            "SystemAudioInputMonitor",
            "SystemAudioOutputRenderer",
            "SystemAudioSessionAdapter",
            "JitterBuffer",
            "AudioFrameMixer",
            "AudioPacketEnvelope",
            "streamID",
            "AudioStreamFrame",
            "RTC.AudioFrame",
            "AudioFormatDescriptor",
            "PCMCodecFrame",
            "AudioCodecConfiguration",
            "packetAudioCodecRegistry"
        ]
        for sourcePath in try AppTestSupport.appSwiftSourcePaths() {
            let source = try AppTestSupport.source(sourcePath)
            for term in obsoleteTerms {
                #expect(source.contains(term) == false, "\(sourcePath) contains \(term)")
            }
        }
    }

    @Test func uiSourcesAreSplitByScreenResponsibility() throws {
        let contentView = try AppTestSupport.source("RideIntercom/UI/ContentView.swift")
        let callView = try AppTestSupport.source("RideIntercom/UI/Call/Advanced/CallView.swift")
        let settingsView = try AppTestSupport.source("RideIntercom/UI/Settings/Common/SettingsView.swift")
        let settingsPanels = try AppTestSupport.source("RideIntercom/UI/Settings/Common/SettingsPanels.swift")
        let diagnosticsView = try AppTestSupport.source("RideIntercom/UI/Diagnostics/DiagnosticsView.swift")
        let transmitPipelineView = try ["LiveTransmitPipelineView", "TransmitPipelinePresentation", "PipelineComponents"].map {
            try AppTestSupport.source("RideIntercom/UI/Diagnostics/" + $0 + ".swift")
        }.joined(separator: "\n")
        let receivePipelineView = try ["LiveReceivePipelineView", "ReceivePipelinePresentation", "ReceiveMixViews", "DiagnosticsPipelineDetails"].map {
            try AppTestSupport.source("RideIntercom/UI/Diagnostics/" + $0 + ".swift")
        }.joined(separator: "\n")
        let receiveDetails = try AppTestSupport.source("RideIntercom/UI/Diagnostics/DiagnosticsPipelineDetails.swift")
        let receivePresentation = try AppTestSupport.source("RideIntercom/UI/Diagnostics/ReceivePipelinePresentation.swift")
        let diagnosticsInput = try AppTestSupport.source("RideIntercom/UI/Diagnostics/DiagnosticsInput.swift")
        let effectChainSource = try AppTestSupport.source("RideIntercom/Intercom/ViewModel/IntercomViewModel+EffectChains.swift")
        let callSessionAdapter = try ["CallSessionAdapter", "CallSessionContracts"].map {
            try AppTestSupport.source("RideIntercom/Intercom/Transport/" + $0 + ".swift")
        }.joined(separator: "\n")
        let diagnosticsSpec = try AppTestSupport.source("docs/spec/App/UI/Diagnostics.md")

        #expect(contentView.contains("struct ContentView"))
        #expect(contentView.components(separatedBy: .newlines).count < 80)
        #expect(callView.contains("struct CallView"))
        #expect(settingsView.contains("struct SettingsView"))
        #expect(settingsPanels.contains("struct CommunicationPanel"))
        #expect(settingsPanels.contains("localNetworkRouteToggle"))
        #expect(settingsPanels.contains("internetRouteToggle"))
        #expect(settingsPanels.contains("internetRouteToggle"))
        #expect(diagnosticsView.contains("struct DiagnosticsView"))
        #expect(callView.contains("masterVoiceIsolationToggle"))
        #expect(callView.contains("RemoteParticipantRowView"))
        let participantViews = try AppTestSupport.source("RideIntercom/UI/Call/Advanced/ParticipantViews.swift")
        #expect(participantViews.contains("participantOutputSlider"))
        #expect(participantViews.contains("participantVoiceIsolationToggle"))
        #expect(transmitPipelineView.contains("CompactEffectChainGroup"))
        #expect(transmitPipelineView.contains("ViewThatFits(in: .horizontal)"))
        #expect(transmitPipelineView.contains("minHeight: 104") == false)
        #expect(receivePipelineView.contains("DiagnosticsReceiveDetails(presentation: presentation, expandedStage: $expandedStage)"))
        let outputGroupPattern = #"ReceiveOutputMixGroup\(\s*step:\s*presentation\.outputBusStep\b"#
        #expect(receivePipelineView.range(of: outputGroupPattern, options: .regularExpression) != nil)
        #expect(receivePipelineView.contains("ReceivePeerBusCard") == false)
        #expect(receivePipelineView.contains("receiveCodecSummary") == false)
        #expect(transmitPipelineView.contains("input.transmitEffectChainSnapshot"))
        #expect(receivePipelineView.contains("stageIdentifierPrefix: \"receive-master-effect-stage\""))
        #expect(receivePresentation.contains("input.receivePeerEffectChainSnapshot(peerID: peerID)"))
        #expect(diagnosticsInput.contains("effects: mixerBusSnapshot(id: id)?.effectChain ?? []"))
        #expect(receiveDetails.contains("@Bindable var viewModel") == false)
        #expect(receiveDetails.contains("viewModel.") == false)
        #expect(receivePipelineView.contains("input.receiveOutputEffectChainSnapshot"))
        #expect(receiveDetails.contains("member.connectionState.rawValue"))
        #expect(receiveDetails.contains("member.authenticationState.rawValue"))
        #expect(receiveDetails.contains("member.activeCodec?.rawValue"))
        #expect(transmitPipelineView.contains("input.mixerBusSnapshot(id: \"tx-bus\")"))
        #expect(receivePresentation.contains("for route in input.audioMixerSnapshot.routes"))
        #expect(receivePresentation.contains("route.destinationBusID == \"rx-master\""))
        #expect(receivePresentation.contains("route.sourceBusID.hasPrefix(Self.peerBusPrefix)"))
        #expect(receivePipelineView.contains("RTC \\(peerBus.connectionLabel)") == false)
        #expect(receivePipelineView.contains("DEC \\(codecLabel(peerBus.activeCodec))") == false)
        #expect(receivePipelineView.contains("defaultReceiveSoundIsolationEnabled") == false)
        #expect(effectChainSource.contains("var transmitEffectChainSnapshot"))
        #expect(effectChainSource.contains("func receivePeerEffectChainSnapshot"))
        #expect(effectChainSource.contains("var receiveMasterEffectChainSnapshot"))
        #expect(effectChainSource.contains("effects: mixerBusSnapshot(id: \"tx-bus\")?.effectChain ?? []"))
        #expect(effectChainSource.contains("peakLimiterStageSnapshot") == false)
        #expect(callSessionAdapter.contains("case remotePeerMetadata(peerID: String, activeCodec: AudioCodecIdentifier?)"))
        #expect(callSessionAdapter.contains("case remoteRuntimeStatus(peerID: String, status: RTCRuntimeStatus)"))
        #expect(callSessionAdapter.contains("updateRuntimePackageReports"))
        #expect(callSessionAdapter.contains("setEnabledRoutes"))
        #expect(callSessionAdapter.contains("RTC.CallSessionFactory.makeSession"))
        #expect(callSessionAdapter.contains("Set(RTC.RouteKind.allCases)"))
        #expect(callSessionAdapter.contains("import RTCNativeWebRTC"))
        #expect(callSessionAdapter.contains("WebRTCNativeEngine"))
        #expect(callSessionAdapter.contains("selectionMode: .singleRoute") == false)
        #expect(callSessionAdapter.contains("handleRTCError"))
        #expect(callSessionAdapter.contains("case .noEnabledRoute"))
        #expect(callSessionAdapter.contains("makeRouteConfiguration"))
        #expect(callSessionAdapter.contains("RTCRuntimeStatusTransport.decode(message)"))
        #expect(callSessionAdapter.contains("PeerMetadataApplicationPayload(activeCodec: activeAudioCodec())"))
        #expect(callSessionAdapter.contains("return .remotePeerMetadata(peerID: peerID, activeCodec: payload.activeCodec)"))
        #expect(diagnosticsSpec.contains("receive-master-effect-stage-peak-limiter"))
    }

    @Test func appRootKeepsPlatformSpecificWindowPolicyAtMacBoundary() throws {
        let appSource = try AppTestSupport.source("RideIntercom/App/RideIntercomApp.swift")
        let windowPolicySource = try AppTestSupport.source("RideIntercom/App/SingleWindowPolicy.swift")

        #expect(appSource.contains("WindowGroup(id: SingleWindowPolicy.mainWindowID)"))
        #expect(appSource.contains("WindowGroup {"))
        #expect(appSource.contains("#if os(macOS)"))
        #expect(windowPolicySource.contains("#if os(macOS)"))
        #expect(windowPolicySource.contains("applicationShouldTerminateAfterLastWindowClosed"))
        #expect(windowPolicySource.contains("applicationShouldSaveApplicationState"))
        #expect(windowPolicySource.contains("applicationShouldRestoreApplicationState"))
    }

    @Test func appInfoPlistEnablesBackgroundAudioMode() throws {
        let plistURL = AppTestSupport.workspaceRoot().appendingPathComponent("RideIntercom/Info.plist")
        let plistData = try Data(contentsOf: plistURL)
        let plist = try #require(
            PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any]
        )
        let backgroundModes = try #require(plist["UIBackgroundModes"] as? [String])
        let bonjourServices = try #require(plist["NSBonjourServices"] as? [String])
        // Xcode generates this value from INFOPLIST_KEY_NSLocalNetworkUsageDescription.
        let localNetworkUsage = try #require(Bundle.main.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription") as? String)

        #expect(backgroundModes.contains("audio"))
        let control = try Self.serviceType(in: "RideIntercom/packages/RTC/Sources/RTC/Local/LocalControlTransport.swift")
        let datagram = try Self.serviceType(in: "RideIntercom/packages/RTC/Sources/RTC/Local/LocalDatagramTransport.swift")
        #expect(Set(bonjourServices) == [control, datagram])
        #expect(!localNetworkUsage.isEmpty)
    }

    private static func serviceType(in path: String) throws -> String {
        let source = try AppTestSupport.source(path)
        let match = try #require(source.firstMatch(of: /static let serviceType = "([^"]+)"/))
        return String(match.1)
    }

}
}

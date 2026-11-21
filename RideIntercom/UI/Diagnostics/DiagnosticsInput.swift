import AudioMixer
import Foundation
import RTC
import SessionManager
import VADGate

struct DiagnosticsInput {
    var audioErrorMessage: String?
    var audioSessionProfile: AudioSessionProfile
    var audioSessionSnapshot: SessionManager.AudioSessionSnapshot
    var isAudioReady: Bool
    var isMicrophoneCaptureRunning: Bool
    var isMuted: Bool
    var isVoiceActive: Bool
    var vadSensitivity: VoiceActivitySensitivity
    var vadGateRuntimeSnapshot: VADGateRuntimeSnapshot
    var lastAudioSessionConfigurationReport: SessionManager.AudioSessionConfigurationReport?
    var lastInputStreamOperationReport: SessionManager.AudioStreamOperationReport?
    var lastVoiceProcessingOperationReport: SessionManager.AudioStreamOperationReport?
    var preferredTransmitCodec: AudioCodecIdentifier
    var routeLabel: String
    var networkDiagnostics: RTCNetworkDiagnostics?
    var selectedGroupConnectionState: CallConnectionState
    var selectedTransmitCodec: AudioCodecIdentifier
    var encodedAudioPacketCount: Int
    var transmitEffectChainSnapshot: AudioEffectChainSnapshot
    var audioMixerSnapshot: AudioMixerSnapshot
    var authenticatedPeerCount: Int
    var authenticatedPeerIDs: [String]
    var connectedPeerCount: Int
    var diagnosticsOutputLevel: Float
    var diagnosticsOutputPeakLevel: Float
    var droppedAudioPacketCount: Int
    var isOutputMuted: Bool
    var lastOutputStreamOperationReport: SessionManager.AudioStreamOperationReport?
    var outputVolume: Float
    var usesNativeOutput: Bool
    var lastNativeRenderAt: TimeInterval?
    var lastNativeAudibleOutputAt: TimeInterval?
    var lastPlaybackScheduledAt: TimeInterval?
    let capturedAt: TimeInterval
    var receiveOutputEffectChainSnapshot: AudioEffectChainSnapshot
    var receiveDecodeCounts: ReceiveDecodeCounts
    var lastReceivedAudioAt: TimeInterval?
    var receivedVoicePacketCount: Int
    var selectedGroup: IntercomGroup?
    var receivePeerRuntimeStatuses: [String: RTCRuntimeStatus]
    var receiveNetworkDiagnostics: RTCNetworkDiagnostics?
    var receivePeerVolumes: [String: Float]

    init(_ viewModel: IntercomViewModel, now: TimeInterval = Date().timeIntervalSince1970) {
        capturedAt = now
        audioErrorMessage = viewModel.audioErrorMessage
        audioSessionProfile = viewModel.audioSessionProfile
        audioSessionSnapshot = viewModel.audioSessionSnapshot
        isAudioReady = viewModel.isAudioReady
        isMicrophoneCaptureRunning = viewModel.isMicrophoneCaptureRunning
        isMuted = viewModel.isMuted
        isVoiceActive = viewModel.isVoiceActive
        vadSensitivity = viewModel.vadSensitivity
        vadGateRuntimeSnapshot = viewModel.vadGateRuntimeSnapshot
        lastAudioSessionConfigurationReport = viewModel.lastAudioSessionConfigurationReport
        lastInputStreamOperationReport = viewModel.lastInputStreamOperationReport
        lastVoiceProcessingOperationReport = viewModel.lastVoiceProcessingOperationReport
        preferredTransmitCodec = viewModel.preferredTransmitCodec
        routeLabel = viewModel.routeLabel
        if let activeGroupID = viewModel.activeGroupID, activeGroupID == viewModel.selectedGroup?.id {
            networkDiagnostics = viewModel.networkDiagnostics
        } else {
            networkDiagnostics = nil
        }
        selectedGroupConnectionState = viewModel.selectedGroupConnectionState
        selectedTransmitCodec = viewModel.selectedTransmitCodec
        // The transmitter increments this count as it collects encoded frames for delivery.
        encodedAudioPacketCount = viewModel.sentVoicePacketCount
        transmitEffectChainSnapshot = viewModel.transmitEffectChainSnapshot
        audioMixerSnapshot = viewModel.audioMixerSnapshot
        authenticatedPeerCount = viewModel.authenticatedPeerCount
        authenticatedPeerIDs = viewModel.authenticatedPeerIDs
        connectedPeerCount = viewModel.connectedPeerCount
        diagnosticsOutputLevel = viewModel.diagnosticsOutputLevel
        diagnosticsOutputPeakLevel = viewModel.diagnosticsOutputPeakLevel
        droppedAudioPacketCount = viewModel.droppedAudioPacketCount
        isOutputMuted = viewModel.isOutputMuted
        lastOutputStreamOperationReport = viewModel.lastOutputStreamOperationReport
        outputVolume = viewModel.overallOutputVolume
        usesNativeOutput = viewModel.audioPipeline.rendersToHardware
        lastNativeAudibleOutputAt = viewModel.audioPipeline.lastNativeAudibleOutputAt
        lastNativeRenderAt = viewModel.audioPipeline.lastNativeRenderAt
        lastPlaybackScheduledAt = viewModel.lastPlaybackScheduledAt
        receiveOutputEffectChainSnapshot = viewModel.receiveMixEffectChainSnapshot
        receiveDecodeCounts = viewModel.audioPipeline.receiveDecodeCounts
        lastReceivedAudioAt = viewModel.lastReceivedAudioAt
        receivedVoicePacketCount = viewModel.receivedVoicePacketCount
        selectedGroup = viewModel.selectedGroup
        receivePeerRuntimeStatuses = viewModel.remoteRuntimeStatuses
        receiveNetworkDiagnostics = viewModel.networkDiagnostics
        receivePeerVolumes = viewModel.remoteOutputVolumes
    }
    func receivePeerEffectChainSnapshot(peerID: String) -> AudioEffectChainSnapshot {
        let id = "rx-peer-" + peerID
        return AudioEffectChainSnapshot(id: id, effects: mixerBusSnapshot(id: id)?.effectChain ?? [])
    }
    func mixerBusSnapshot(id: String) -> MixerBusSnapshot? { audioMixerSnapshot.buses.first { $0.id == id } }
}

import AudioMixer
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
    var masterOutputVolume: Float
    var playedAudioFrameCount: Int
    var receiveMasterEffectChainSnapshot: AudioEffectChainSnapshot
    var receiveDecodeCounts: ReceiveDecodeCounts
    var receivedVoicePacketCount: Int
    var selectedGroup: IntercomGroup?
    var peerEffectChains: [String: AudioEffectChainSnapshot]
    var peerVolumes: [String: Float]

    init(_ viewModel: IntercomViewModel) {
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
        masterOutputVolume = viewModel.masterOutputVolume
        playedAudioFrameCount = viewModel.playedAudioFrameCount
        receiveMasterEffectChainSnapshot = viewModel.receiveMasterEffectChainSnapshot
        receiveDecodeCounts = viewModel.audioPipeline.receiveDecodeCounts
        receivedVoicePacketCount = viewModel.receivedVoicePacketCount
        selectedGroup = viewModel.selectedGroup
        let ids = Set((viewModel.selectedGroup?.members.map(\.id) ?? []) + viewModel.authenticatedPeerIDs)
        peerEffectChains = Dictionary(uniqueKeysWithValues: ids.map { ($0, viewModel.receivePeerEffectChainSnapshot(peerID: $0)) })
        peerVolumes = Dictionary(uniqueKeysWithValues: ids.map { ($0, viewModel.remoteOutputVolume(for: $0)) })
    }
    func mixerBusSnapshot(id: String) -> MixerBusSnapshot? { audioMixerSnapshot.buses.first { $0.id == id } }
    func receivePeerEffectChainSnapshot(peerID: String) -> AudioEffectChainSnapshot { peerEffectChains[peerID] ?? .init(id: "rx-peer-\(peerID)", effects: []) }
    func remoteOutputVolume(for peerID: String) -> Float { peerVolumes[peerID] ?? 1 }
}

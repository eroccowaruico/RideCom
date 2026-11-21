import AudioCore
import Codec
import Foundation
import RTC

nonisolated struct AppAudioPipelineConfiguration: Equatable, Sendable {
    /// Receive playout for calls: a 2 ms start on a calm link. The window also
    /// rebuilds audio queued before the output clock runs, so it stays 120 ms;
    /// AudioMixer learns Wi-Fi jitter up to half of it.
    static let callReceivePlayoutDelay: TimeInterval = 0.002
    static let callReceiveMaximumBufferedDuration: TimeInterval = 0.12
    var mixerFormat: AudioFormat
    var rtcSendFormat: AudioFormat
    var outputHardwareFormat: AudioFormat
    var preferredCodec: AudioCodecIdentifier
    var aacELDv2BitRate: Int
    var opusBitRate: Int
    var overallOutputVolume: Float
    var isOutputMuted: Bool
    var peerOutputVolumes: [String: Float]
    var transmitSoundIsolationEnabled: Bool
    var receiveMixSoundIsolationEnabled: Bool
    var peerSoundIsolationEnabled: [String: Bool]
    var maximumBufferedDuration: TimeInterval?
    var receiveMaximumBufferedDuration: TimeInterval?
    var receivePlayoutDelay: TimeInterval?
    var finitePlaybackDuration: TimeInterval?

    init(
        mixerFormat: AudioFormat = .intercomMixer,
        rtcSendFormat: AudioFormat = .intercomPacketAudio,
        outputHardwareFormat: AudioFormat = .intercomHardwarePreferred,
        preferredCodec: AudioCodecIdentifier = .pcm16,
        aacELDv2BitRate: Int = 48_000,
        opusBitRate: Int = Codec.OpusOptions().bitRate,
        overallOutputVolume: Float = 1,
        isOutputMuted: Bool = false,
        peerOutputVolumes: [String: Float] = [:],
        transmitSoundIsolationEnabled: Bool = true,
        receiveMixSoundIsolationEnabled: Bool = false,
        peerSoundIsolationEnabled: [String: Bool] = [:],
        maximumBufferedDuration: TimeInterval? = nil,
        receiveMaximumBufferedDuration: TimeInterval? = nil,
        receivePlayoutDelay: TimeInterval? = nil,
        finitePlaybackDuration: TimeInterval? = nil
    ) {
        self.mixerFormat = mixerFormat
        self.rtcSendFormat = rtcSendFormat
        self.outputHardwareFormat = outputHardwareFormat
        self.preferredCodec = preferredCodec
        self.aacELDv2BitRate = Codec.AACELDv2Options(bitRate: aacELDv2BitRate).bitRate
        self.opusBitRate = Codec.OpusOptions(bitRate: opusBitRate).bitRate
        self.overallOutputVolume = min(2, max(0, overallOutputVolume))
        self.isOutputMuted = isOutputMuted
        self.peerOutputVolumes = peerOutputVolumes.mapValues { min(1, max(0, $0)) }
        self.transmitSoundIsolationEnabled = transmitSoundIsolationEnabled
        self.receiveMixSoundIsolationEnabled = receiveMixSoundIsolationEnabled
        self.peerSoundIsolationEnabled = peerSoundIsolationEnabled
        self.maximumBufferedDuration = maximumBufferedDuration
        self.receiveMaximumBufferedDuration = receiveMaximumBufferedDuration
        self.receivePlayoutDelay = receivePlayoutDelay
        self.finitePlaybackDuration = finitePlaybackDuration
    }

    @MainActor var codecOptions: AppAudioCodecOptions {
        AppAudioCodecOptions(aacELDv2BitRate: aacELDv2BitRate, opusBitRate: opusBitRate)
    }

    @MainActor var audioPolicy: RTC.RTCAudioPolicy {
        AppAudioCodecBridge.makeRTCAudioPolicy(
            preferred: preferredCodec,
            format: rtcSendFormat,
            options: codecOptions
        )
    }

    @MainActor var codecRuntimeReport: CodecRuntimeReport {
        AppAudioCodecBridge.runtimeReport(
            for: preferredCodec,
            format: rtcSendFormat,
            options: codecOptions
        )
    }
}

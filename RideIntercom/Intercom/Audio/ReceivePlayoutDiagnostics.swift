import AudioMixer
import Foundation

nonisolated struct ReceiveDecodeCounts: Equatable, Sendable {
    var pcmPackets = 0
    var failures = 0
    var lastPCM: CodecOutputObservation?
    var lastFailureAt: TimeInterval?

    var lastPCMAt: TimeInterval? { lastPCM?.observedAt }
}

nonisolated struct ReceiveDecodeDiagnostics: Sendable {
    let counts: ReceiveDecodeCounts
    let peerPCM: [String: CodecOutputObservation]
}

nonisolated struct ReceiveProcessingTiming: Encodable, Sendable {
    let lockRequestedAt: TimeInterval
    var lockAcquiredAt: TimeInterval?
    var decodedAt: TimeInterval?
    var reservedAt: TimeInterval?
}

nonisolated struct ReceivePlayoutDiagnostics: Sendable {
    let bufferedDuration: Double
    let adjustments: Int
    let resets: Int
    let adjustment: MixerPlayoutAdjustment?
    let processingTiming: ReceiveProcessingTiming?
    let reservation: MixerPlayoutReservation?

    init(source: MixerPCMSource, previousAdjustmentCount: Int? = nil, processingTiming: ReceiveProcessingTiming? = nil,
         reservation: MixerPlayoutReservation? = nil) {
        bufferedDuration = source.bufferedDuration
        adjustments = source.playoutAdjustmentCount
        resets = source.playbackResetCount
        self.processingTiming = processingTiming
        self.reservation = reservation
        if let previousAdjustmentCount, previousAdjustmentCount != adjustments {
            adjustment = source.lastPlayoutAdjustment
        } else {
            adjustment = nil
        }
    }
}

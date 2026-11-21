import AudioCore
import Foundation

	func makeSourceSnapshots(
    sourceNodeOrder: [ObjectIdentifier], sourceMetadataByNodeID: [ObjectIdentifier: MixerSourceMetadata],
    pcmSourceByNodeID: [ObjectIdentifier: MixerPCMSource]
) -> [MixerSourceSnapshot] {
		return sourceNodeOrder.enumerated().compactMap { index, nodeID in
			sourceMetadataByNodeID[nodeID].map {
				let pcmSource = pcmSourceByNodeID[nodeID]
				return MixerSourceSnapshot(
					id: $0.id,
					typeName: $0.typeName,
					index: index,
					inputBusIndex: $0.inputBusIndex,
					originalFormat: $0.originalFormat,
					mixerFormat: $0.mixerFormat,
					scheduledFrameCount: $0.scheduledFrameCount,
					normalizationReport: $0.normalizationReport,
					lastFailure: $0.lastFailure,
					bufferedDuration: pcmSource?.bufferedDuration,
					playbackResetCount: pcmSource?.playbackResetCount ?? 0,
					lastScheduledAt: $0.lastScheduledAt,
					playoutAdjustmentCount: pcmSource?.playoutAdjustmentCount,
					lastPlayoutAdjustment: pcmSource?.lastPlayoutAdjustment
				)
			}
		}
	}

struct MixerSourceMetadata {
	var id: String
	var typeName: String
	var inputBusIndex: Int
	var originalFormat: AudioFormat?
	var mixerFormat: AudioFormat?
	var scheduledFrameCount = 0
	var lastScheduledAt: TimeInterval?
	var normalizationReport: AudioProcessingReport?
	var lastFailure: String?
}

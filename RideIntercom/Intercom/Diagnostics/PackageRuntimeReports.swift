import AVFAudio
import AudioCore
import AudioMixer
import Codec
import DynamicsProcessor
import Foundation
import PeakLimiter
import RTC
import SessionManager
import SoundIsolation
import VADGate

extension IntercomViewModel {
    static func emptyAudioMixerSnapshot() -> AudioMixerSnapshot {
        AudioMixerSnapshot(busIDs: [], buses: [], routes: [], outputBusID: nil)
    }

    static func makeCodecRuntimeReport(
        preferredCodec: AudioCodecIdentifier,
        rtcSendFormat: AudioFormat = .intercomPacketAudio,
        aacELDv2BitRate: Int,
        opusBitRate: Int
    ) -> CodecRuntimeReport {
        AppAudioCodecBridge.runtimeReport(
            for: preferredCodec,
            format: rtcSendFormat,
            options: AppAudioCodecOptions(
                aacELDv2BitRate: aacELDv2BitRate,
                opusBitRate: opusBitRate
            )
        )
    }

    func refreshPackageRuntimeSnapshots(now: TimeInterval = Date().timeIntervalSince1970) {
        codecRuntimeReport = Self.makeCodecRuntimeReport(
            preferredCodec: preferredTransmitCodec,
            rtcSendFormat: rtcAudioFormatPreset.audioFormat,
            aacELDv2BitRate: aacELDv2BitRate,
            opusBitRate: opusBitRate
        )
        vadGateRuntimeSnapshot = audioPipeline.vadRuntimeSnapshot
        audioMixerSnapshot = audioPipeline.snapshot
        lastRuntimePackageReports = makeRuntimePackageReports(generatedAt: now)
    }

    func publishRuntimePackageReports(
        force: Bool = false,
        now: TimeInterval = Date().timeIntervalSince1970
    ) {
        let interval = isDiagnosticsVisible ? Self.runtimePackageReportPublishInterval : 5
        if !force,
           let lastRuntimePackageReportPublishedAt,
           now - lastRuntimePackageReportPublishedAt < interval {
            return
        }
        refreshPackageRuntimeSnapshots(now: now)
        lastRuntimePackageReportPublishedAt = now
        callSession.updateRuntimePackageReports(lastRuntimePackageReports)
    }

    func mixerBusSnapshot(id: String) -> MixerBusSnapshot? {
        audioMixerSnapshot.buses.first { $0.id == id }
    }

    func makeRuntimePackageReports(generatedAt: TimeInterval) -> [RTCRuntimePackageReport] {
        var reports: [RTCRuntimePackageReport] = []
        func append<Payload: Encodable>(_ package: String, _ kind: String, _ payload: Payload) {
            if let report = try? RTCRuntimePackageReport.json(
                package: package, kind: kind, generatedAt: generatedAt, payload: payload
            ) {
                reports.append(report)
            }
        }

        append("AudioMixer", "snapshot", audioMixerSnapshot)
        append("Codec", "runtimeReport", codecRuntimeReport)
        append("VADGate", "runtimeSnapshot", vadGateRuntimeSnapshot)
        append("SoundIsolation", "transmitConfiguration", AppAudioPipeline.transmitIsolationConfiguration)
        append("SoundIsolation", "receiveMasterConfiguration", AppAudioPipeline.receiveIsolationConfiguration)
        append("DynamicsProcessor", "transmitConfiguration", DynamicsProcessorConfiguration())
        append("PeakLimiter", "transmitConfiguration", PeakLimiterConfiguration())
        append("PeakLimiter", "receiveMasterConfiguration", PeakLimiterConfiguration())
        append("SoundIsolation", "support", VoiceIsolationSupport.snapshot)
        for (busID, snapshot) in audioPipeline.isolationRuntimeSnapshots.sorted(by: { $0.key < $1.key }) {
            append("SoundIsolation", Self.isolationReportKind(for: busID), snapshot)
        }
        if let snapshot = audioPipeline.dynamicsRuntimeSnapshot {
            append("DynamicsProcessor", "transmitRuntimeSnapshot", snapshot)
        }
        if let snapshot = audioPipeline.transmitLimiterRuntimeSnapshot {
            append("PeakLimiter", "transmitRuntimeSnapshot", snapshot)
        }
        if let snapshot = audioPipeline.outputLimiterRuntimeSnapshot {
            append("PeakLimiter", "receiveMasterRuntimeSnapshot", snapshot)
        }
        append("SessionManager", "audioSessionConfigurationRequest", makeAudioSessionConfiguration())
        if let lastAudioSessionConfigurationReport {
            append("SessionManager", "audioSessionConfigurationReport", lastAudioSessionConfigurationReport)
        }
        if let lastInputStreamOperationReport {
            append("SessionManager", "inputStreamOperationReport", lastInputStreamOperationReport)
        }
        if let lastOutputStreamOperationReport {
            append("SessionManager", "outputStreamOperationReport", lastOutputStreamOperationReport)
        }
        if let lastVoiceProcessingOperationReport {
            append("SessionManager", "voiceProcessingOperationReport", lastVoiceProcessingOperationReport)
        }
        return reports
    }

    private static func isolationReportKind(for busID: String) -> String {
        switch busID {
        case "tx-bus": "transmitRuntimeSnapshot"
        case "rx-master": "receiveMasterRuntimeSnapshot"
        default: "receivePeerRuntimeSnapshot:\(busID.dropFirst("rx-peer-".count))"
        }
    }
}

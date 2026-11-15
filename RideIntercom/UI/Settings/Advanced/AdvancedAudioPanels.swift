import SwiftUI
import RTC
import Codec

/// Audio session and codec choices are expert settings: only Advanced shows them.
struct AdvancedAudioSessionPanel: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        Section {
            Picker("Mode", selection: Binding(
                get: { viewModel.audioSessionModeProfile },
                set: { viewModel.setAudioSessionModeProfile($0) }
            )) {
                ForEach(AudioSessionProfile.settingsModeCases) { profile in
                    settingsOption(profile.label, isDefault: profile == IntercomViewModel.defaultAudioSessionProfile).tag(profile)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("audioSessionProfilePicker")

            Toggle(
                "Use Speaker",
                isOn: Binding(
                    get: { viewModel.isSpeakerOutputEnabled },
                    set: { viewModel.setSpeakerOutputEnabled($0) }
                )
            )
            .accessibilityIdentifier("speakerOutputToggle")

            if viewModel.audioSessionModeProfile == .standard {
                Toggle(
                    "Echo Cancellation",
                    isOn: Binding(
                        get: { viewModel.isSessionEchoCancellationEnabled },
                        set: { viewModel.setSessionEchoCancellationEnabled($0) }
                    )
                )
                .disabled(!viewModel.canToggleSessionEchoCancellation)
                .accessibilityIdentifier("echoCancellationToggle")
            }

            if viewModel.supportsAdvancedMixingOptions {
                Toggle(
                    "Duck Other Audio",
                    isOn: Binding(
                        get: { viewModel.isDuckOthersEnabled },
                        set: { viewModel.setDuckOthersEnabled($0) }
                    )
                )
                .accessibilityIdentifier("duckOthersToggle")
            }

        } header: {
            Text("Audio Session")
        } footer: {
            Text("Burst mode uses the default session for intercom-style audio and explicit echo cancellation. Stream mode uses voice-chat routing for continuous conversation.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("audioSessionModeDescription")
        }
        .accessibilityIdentifier("audioSessionPanel")
    }
}

struct AdvancedTransmitCodecPanel: View {
    @Bindable var viewModel: IntercomViewModel

    var body: some View {
        Section {
            VStack(alignment: .leading) {
                Text("Codec")
                    .accessibilityIdentifier("transmitCodecLabel")
                Picker("Codec", selection: Binding(
                    get: { viewModel.preferredTransmitCodec },
                    set: { viewModel.setPreferredTransmitCodec($0) }
                )) {
                    ForEach([(AudioCodecIdentifier.pcm16, "PCM 16-bit"), (.mpeg4AACELD, "AAC-ELD"), (.opus, "Opus")], id: \.0) { codec, name in
                        settingsOption(name, isDefault: codec == IntercomViewModel.defaultTransmitCodec).tag(codec)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("transmitCodecPicker")
            }

            VStack(alignment: .leading) {
                Text("Sample Rate")
                    .accessibilityIdentifier("rtcAudioSampleRateLabel")
                Picker("Sample Rate", selection: Binding(
                    get: { viewModel.rtcAudioFormatPreset },
                    set: { viewModel.setRTCAudioFormatPreset($0) }
                )) {
                    ForEach(RTCAudioFormatPreset.allCases) { preset in
                        settingsOption(preset.label, isDefault: preset == IntercomViewModel.defaultRTCAudioFormatPreset).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("rtcAudioFormatPicker")
            }

            if viewModel.preferredTransmitCodec == .mpeg4AACELD {
                Picker("AAC-ELD Bitrate", selection: Binding(
                        get: { viewModel.aacELDv2BitRate },
                        set: { viewModel.setAACELDv2BitRate($0) }
                    )) {
                    ForEach(viewModel.availableAACBitRates, id: \.self) { bitRate in
                        let low = AppAudioCodecBridge.isLowBandwidthAACBitRate(bitRate, format: viewModel.rtcAudioFormatPreset.audioFormat)
                        settingsOption("\(bitRate / 1_000) kbps\(low ? " (Lower Quality)" : "")",
                                       isDefault: bitRate == IntercomViewModel.defaultAACELDv2BitRate).tag(bitRate)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("aacELDBitRatePicker")
            }

            if viewModel.preferredTransmitCodec == .opus {
                BitRateStepper(
                    title: "Opus Bitrate",
                    value: Binding(
                        get: { viewModel.opusBitRate },
                        set: { viewModel.setOpusBitRate($0) }
                    ),
                    choices: viewModel.availableOpusBitRates,
                    accessibilityIdentifier: "opusBitRateStepper"
                )
            }
        } header: {
            Text("Transmit Codec")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if viewModel.preferredTransmitCodec == .opus {
                    Text("Opus 24 and 32 kbps are lower-quality options. The default remains 48 kbps. Encoding bitrate is not total network usage.")
                        .accessibilityIdentifier("opusLowBandwidthExplanation")
                }
                Text("AAC-ELD choices depend on the sample rate. Unsupported values are adjusted to the nearest quality-preserving choice.")
                if viewModel.preferredTransmitCodec == .mpeg4AACELD,
                   viewModel.availableAACBitRates.contains(where: { AppAudioCodecBridge.isLowBandwidthAACBitRate($0, format: viewModel.rtcAudioFormatPreset.audioFormat) }) {
                    Text("48 kHz / 32 kbps and 24 kHz / 16 kbps are lower-quality options. They do not change the default. Encoding bitrate is not total network usage.")
                        .accessibilityIdentifier("aacLowBandwidthExplanation")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transmitCodecPanel")
    }
}

private struct BitRateStepper: View {
    let title: LocalizedStringKey
    @Binding var value: Int
    let choices: [Int]
    let accessibilityIdentifier: String

    var body: some View {
        let increment: (() -> Void)? = choices.first(where: { $0 > value }).map { next in { value = next } }
        let decrement: (() -> Void)? = choices.last(where: { $0 < value }).map { previous in { value = previous } }
        Stepper(onIncrement: increment, onDecrement: decrement) {
            LabeledContent(title) {
                if value < 48_000 {
                    Text("\(value / 1_000) kbps (Lower Quality)")
                } else {
                    Text("\(value / 1_000) kbps")
                }
            }
        }
        .accessibilityValue(value < 48_000
            ? Text("\(value / 1_000) kbps (Lower Quality)")
            : Text("\(value / 1_000) kbps"))
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

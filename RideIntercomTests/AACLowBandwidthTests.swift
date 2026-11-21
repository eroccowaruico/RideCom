import AudioCore
import Codec
import Foundation
import RTC
import Testing
@testable import RideIntercom

@MainActor
struct AACLowBandwidthTests {
    @Test func onlyMeasuredMonoCandidatesAreAddedAndEveryChoiceIsNativeSupported() {
        for (preset, candidate) in [(RTCAudioFormatPreset.mono48k, 32_000), (.mono24k, 16_000)] {
            let format = preset.audioFormat
            let native = CodecSupport.availableEncodingBitRates(codec: .mpeg4AACELD, format: format)
            let choices = AppAudioCodecBridge.availableAACBitRates(format: format)
            #expect(native.contains(candidate))
            #expect(choices.contains(candidate))
            #expect(choices.allSatisfy { native.contains($0) })
            #expect(choices.filter { $0 < AppAudioCodecBridge.minimumAACBitRate(format: format) } == [candidate])
        }
        let sixteen = RTCAudioFormatPreset.mono16k.audioFormat
        #expect(AppAudioCodecBridge.availableAACBitRates(format: sixteen).allSatisfy { $0 >= 48_000 })
    }

    @Test func defaultsAndInvalidValueRecoveryDoNotOptIntoLowerQuality() {
        let settings = AppSettings()
        #expect(settings.preferredTransmitCodec == .mpeg4AACELD)
        #expect(settings.rtcAudioFormatPreset == .mono48k && settings.aacELDv2BitRate == 48_000)
        #expect(settings.opusBitRate == 48_000)
        #expect(
            AppAudioCodecBridge.normalizedAACBitRate(11_000, format: RTCAudioFormatPreset.mono48k.audioFormat)
                == 48_000)
        #expect(
            AppAudioCodecBridge.normalizedAACBitRate(24_000, format: RTCAudioFormatPreset.mono48k.audioFormat)
                == 48_000)
        #expect(
            AppAudioCodecBridge.normalizedAACBitRate(20_000, format: RTCAudioFormatPreset.mono24k.audioFormat)
                == 32_000)
    }

    @Test func explicitCandidatesSurviveSavingCodecSwitchesAndRestoration() {
        for (preset, rate) in [(RTCAudioFormatPreset.mono48k, 32_000), (.mono24k, 16_000)] {
            let store = InMemoryAppSettingsStore()
            let harness = AppTestSupport.makeHarness(appSettingsStore: store); let viewModel = harness.viewModel
            defer { viewModel.disconnect() }
            viewModel.setRTCAudioFormatPreset(preset); viewModel.setAACELDv2BitRate(rate)
            #expect(viewModel.aacELDv2BitRate == rate)
            #expect(harness.callSession.audioPolicies.last?.maximumBitRate == rate)
            viewModel.setPreferredTransmitCodec(.pcm16); viewModel.setPreferredTransmitCodec(.mpeg4AACELD)
            #expect(viewModel.aacELDv2BitRate == rate && store.load().aacELDv2BitRate == rate)
            let restored = AppTestSupport.makeHarness(appSettingsStore: store)
            defer { restored.viewModel.disconnect() }
            #expect(restored.viewModel.rtcAudioFormatPreset == preset)
            #expect(restored.viewModel.aacELDv2BitRate == rate)
            #expect(restored.callSession.audioPolicies.last?.maximumBitRate == rate)
        }
    }

    @Test func sampleRateChangesPreserveSupportedMeaningAndDoNotChooseALowerQualityReplacement() {
        let harness = AppTestSupport.makeHarness(); let viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        viewModel.setAACELDv2BitRate(32_000)
        #expect(viewModel.aacELDv2BitRate == 32_000)
        viewModel.setRTCAudioFormatPreset(.mono24k)
        #expect(viewModel.aacELDv2BitRate == 32_000)
        viewModel.setAACELDv2BitRate(16_000)
        #expect(viewModel.aacELDv2BitRate == 16_000)
        viewModel.setRTCAudioFormatPreset(.mono48k)
        #expect(viewModel.aacELDv2BitRate == 48_000)
        viewModel.setRTCAudioFormatPreset(.mono16k); viewModel.setAACELDv2BitRate(16_000)
        #expect(viewModel.aacELDv2BitRate == 48_000)
        viewModel.setOpusBitRate(16_000)
        #expect(viewModel.opusBitRate == 48_000)
    }
    @Test func lowQualityChoiceAndNormalizationExplanationHaveJapaneseResources() throws {
        let path = try #require(Bundle.main.path(forResource: "ja", ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        #expect(
            bundle.localizedString(forKey: "%lld kbps (Lower Quality)", value: nil, table: nil)
                == "%lld kbps（音質低下）")
        #expect(
            bundle.localizedString(
                forKey:
                    """
                    AAC-ELD choices depend on the sample rate. Unsupported values are adjusted to the nearest \
                    quality-preserving choice.
                    """,
                value: nil, table: nil)
            == "AAC-ELDの選択肢はサンプルレートによって変わります。非対応の値は、音質を保つ選択肢の中で最も近い値へ補正します。")
    }

}

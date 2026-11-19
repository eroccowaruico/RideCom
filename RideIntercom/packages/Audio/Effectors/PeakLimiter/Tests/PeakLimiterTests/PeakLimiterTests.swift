import Testing
@testable import PeakLimiter
import AudioToolbox
import AVFAudio
import Foundation

@Test func componentDescriptionTargetsApplePeakLimiterEffect() {
    let description = PeakLimiterSupport.componentDescription

    #expect(description.componentType == kAudioUnitType_Effect)
    #expect(description.componentSubType == kAudioUnitSubType_PeakLimiter)
    #expect(description.componentManufacturer == kAudioUnitManufacturer_Apple)
    #expect(description.componentFlags == 0)
    #expect(description.componentFlagsMask == 0)
}

@Test func defaultConfigurationUsesRideIntercomVoicePreset() {
    let configuration = PeakLimiterConfiguration()

    #expect(configuration.attackTime == 0.012)
    #expect(configuration.decayTime == 0.024)
    #expect(configuration.preGain == 0)
}

@Test func configurationClampsParametersToSupportedRanges() {
    let low = PeakLimiterConfiguration(attackTime: 0, decayTime: 0, preGain: -100)
    let high = PeakLimiterConfiguration(attackTime: 1, decayTime: 1, preGain: 100)

    #expect(low.attackTime == 0.001)
    #expect(low.decayTime == 0.001)
    #expect(low.preGain == -40)
    #expect(high.attackTime == 0.03)
    #expect(high.decayTime == 0.06)
    #expect(high.preGain == 40)
}

@Test func runtimeSnapshotIsCodableAndIndependentFromMixer() throws {
    let snapshot = PeakLimiterRuntimeSnapshot(
        configuration: PeakLimiterConfiguration(attackTime: 0.01, decayTime: 0.02, preGain: 3),
        support: PeakLimiterSupportSnapshot(isAvailable: true),
        state: .active
    )

    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(PeakLimiterRuntimeSnapshot.self, from: data)

    #expect(decoded == snapshot)
}

@Test func realAudioUnitAcceptsConfigurationAndReportsIt() throws {
    #expect(PeakLimiterSupport.isAvailable)
    let effect = try PeakLimiterEffect.make()
    let configuration = PeakLimiterConfiguration(preGain: -6)
    try effect.apply(configuration)
    #expect(effect.configuration == configuration)
    #expect(effect.runtimeSnapshot.configuration == configuration)
    #expect(effect.node.numberOfInputs > 0)
    #expect(effect.node.numberOfOutputs > 0)
}

@MainActor
@Test func repeatedGraphStartupAndTeardownKeepsTheNativeParametersUsable() throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    for iteration in 0..<64 {
        try autoreleasepool {
            let engine = AVAudioEngine()
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 480)
            let source = AVAudioPlayerNode()
            let limiter = try PeakLimiterEffect.make()
            engine.attach(source)
            engine.attach(limiter.node)
            try engine.connectNode(source, to: limiter.node, format: format)
            try engine.connectNode(limiter.node, to: engine.mainMixerNode, format: format)
            // Include graphs discarded during preparation, before a render can start.
            if iteration.isMultiple(of: 2) { try engine.start() }
            defer {
                engine.stop()
                engine.detach(limiter.node)
                engine.detach(source)
            }
            let configuration = PeakLimiterConfiguration(attackTime: 0.015, decayTime: 0.03, preGain: -6)
            try limiter.apply(configuration)
            for (id, expected) in [(kLimiterParam_AttackTime, configuration.attackTime),
                                   (kLimiterParam_DecayTime, configuration.decayTime),
                                   (kLimiterParam_PreGain, configuration.preGain)] {
                var value: AudioUnitParameterValue = 0
                let status = limiter.avAudioUnitEffect.withAudioUnit {
                    AudioUnitGetParameter($0, id, kAudioUnitScope_Global, 0, &value)
                }
                #expect(status == noErr)
                #expect(abs(value - expected) < 0.000001)
            }
        }
    }
}

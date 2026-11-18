#if os(iOS)
import AVFAudio
import Testing
@testable import SessionManager

@MainActor @Suite(.serialized) struct NativeVoiceProcessingTests {
    @Test func disabledNativeInputFailsBeforeVoiceProcessingCanRaiseAnException() throws {
        let session = AVAudioSession.sharedInstance()
        let category = session.category, mode = session.mode, options = session.categoryOptions
        defer {
            try? session.setActive(false)
            try? session.setCategory(category, mode: mode, options: options)
        }
        // Playback deliberately has no recording input. No microphone permission or fake native node.
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
        let engine = AVAudioEngine()
        defer { engine.stop() }
        // Match a caller with a prepared receive graph before opening its input.
        let source = AVAudioMixerNode()
        engine.attach(source)
        try engine.connectNode(source, to: engine.mainMixerNode,
            format: try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)))
        let format = engine.inputNode.inputFormat(forBus: 0)
        try #require(format.sampleRate == 0 || format.channelCount == 0)
        let capture = AudioInputStreamCapture(configuration: .init(voiceProcessing:
            .init(soundIsolationEnabled: false, otherAudioDuckingEnabled: true)),
            backend: SystemAudioInputStreamBackend(engine: engine))
        let report = capture.start()
        #expect(report.result == .failed(.invalidFrame("Voice processing requires enabled input hardware")))
        #expect(!report.snapshot.isRunning && !engine.isRunning)
        #expect(!engine.inputNode.isVoiceProcessingEnabled, "Unavailable input must not change the native I/O mode")
        #expect(capture.stop().result == .ignored(.alreadyStopped))
    }
}
#endif

import AudioCore
import Testing
@testable import SessionManager

@Test func inputCaptureReportsHardwareFramesWithoutFormatConversion() {
    let hardwareFormat = AudioFormat(sampleRate: 24_000, channelCount: 2)
    let preferredFormat = AudioFormat(sampleRate: 48_000, channelCount: 1)
    let backend = FakeInputStreamBackend(actualHardwareFormat: hardwareFormat)
    let configuration = AudioInputStreamConfiguration(
        preferredFormat: preferredFormat,
        bufferFrameCount: 0
    )
    let capture = AudioInputStreamCapture(configuration: configuration, backend: backend)
    var events: [AudioStreamRuntimeEvent] = []
    capture.setRuntimeEventHandler { events.append($0) }

    let start = capture.start()
    backend.emit(PCMFrame(
        sequenceNumber: 1,
        format: hardwareFormat,
        capturedAt: 10,
        samples: [0.1, -0.1]
    ))
    let stop = capture.stop()
    let secondStop = capture.stop()

    #expect(configuration.bufferFrameCount == 1)
    #expect(start.result == .applied)
    #expect(start.snapshot.preferredFormat == preferredFormat)
    #expect(start.snapshot.actualHardwareFormat == hardwareFormat)
    #expect(stop.result == .applied)
    #expect(secondStop.result == .ignored(.alreadyStopped))
    #expect(secondStop.snapshot.processedFrameCount == 1)
    #expect(backend.startCount == 1)
    #expect(backend.stopCount == 1)
    #expect(events.contains(.inputFrame(PCMFrame(
        sequenceNumber: 1,
        format: hardwareFormat,
        capturedAt: 10,
        samples: [0.1, -0.1]
    ))))
}

@Test func stoppedInputStoresVoiceProcessingWithoutOpeningBackend() {
    let backend = FakeInputStreamBackend()
    let capture = AudioInputStreamCapture(backend: backend)
    let updated = AudioInputVoiceProcessingConfiguration(
        soundIsolationEnabled: false,
        otherAudioDuckingEnabled: true,
        duckingLevel: .maximum,
        inputMuted: true
    )
    var events: [AudioStreamRuntimeEvent] = []
    capture.setRuntimeEventHandler { events.append($0) }

    let report = capture.updateVoiceProcessing(updated)

    #expect(capture.configuration.voiceProcessing == updated)
    #expect(report.operation == .updateInputVoiceProcessing(updated))
    #expect(report.result == .ignored(.alreadyStopped))
    #expect(report.snapshot.isRunning == false)
    #expect(report.snapshot.inputVoiceProcessing == updated)
    #expect(backend.events.isEmpty)
    #expect(events == [.operation(report)])
}

@Test func stoppedInputAppliesLatestConfigurationOnlyOnRestart() {
    let backend = FakeInputStreamBackend()
    let capture = AudioInputStreamCapture(backend: backend)
    _ = capture.start()
    _ = capture.stop()
    let previousEvents = backend.events
    let updated = AudioInputVoiceProcessingConfiguration(inputMuted: true)
    let report = capture.updateVoiceProcessing(updated)
    #expect(report.result == .ignored(.alreadyStopped))
    #expect(backend.events == previousEvents)
    #expect(capture.start().result == .applied)
    #expect(Array(backend.events.suffix(2)) == [.updateVoiceProcessing(updated), .startCapture])
}

@Test func inputCaptureAppliesInitialVoiceProcessingBeforeStarting() {
    let backend = FakeInputStreamBackend()
    let voiceProcessing = AudioInputVoiceProcessingConfiguration(
        soundIsolationEnabled: true,
        otherAudioDuckingEnabled: true,
        duckingLevel: .medium,
        inputMuted: false
    )
    let configuration = AudioInputStreamConfiguration(voiceProcessing: voiceProcessing)
    let capture = AudioInputStreamCapture(configuration: configuration, backend: backend)
    var reports: [AudioStreamOperationReport] = []
    capture.setRuntimeEventHandler { event in
        if case .operation(let report) = event {
            reports.append(report)
        }
    }

    let start = capture.start()

    #expect(start.result == .applied)
    #expect(backend.events == [
        .updateVoiceProcessing(voiceProcessing),
        .startCapture
    ])
    #expect(reports.map(\.operation) == [
        .updateInputVoiceProcessing(voiceProcessing),
        .startInputCapture
    ])
    #expect(reports.first?.snapshot.inputVoiceProcessing == voiceProcessing)
}

@Test(arguments: [false, true])
func inputCaptureRestartsWhenVoiceProcessingIOModeChanges(_ initiallyEnabled: Bool) {
    let backend = FakeInputStreamBackend()
    let initial = AudioInputVoiceProcessingConfiguration(soundIsolationEnabled: false,
        otherAudioDuckingEnabled: initiallyEnabled)
    let updated = AudioInputVoiceProcessingConfiguration(soundIsolationEnabled: false,
        otherAudioDuckingEnabled: !initiallyEnabled)
    let capture = AudioInputStreamCapture(configuration: .init(voiceProcessing: initial), backend: backend)
    #expect(capture.start().result == .applied)
    let report = capture.updateVoiceProcessing(updated)
    #expect(report.result == .applied)
    #expect(report.operation == .updateInputVoiceProcessing(updated))
    #expect(report.snapshot.isRunning)
    #expect(backend.events == [.updateVoiceProcessing(initial), .startCapture, .stopCapture,
        .updateVoiceProcessing(updated), .startCapture])
}

@Test func inputCaptureUpdatesVoiceProcessingWhileRunningWithoutRestarting() {
    let backend = FakeInputStreamBackend()
    let initial = AudioInputVoiceProcessingConfiguration(soundIsolationEnabled: true)
    let updated = AudioInputVoiceProcessingConfiguration(
        soundIsolationEnabled: false,
        otherAudioDuckingEnabled: true,
        duckingLevel: .maximum,
        inputMuted: true
    )
    let capture = AudioInputStreamCapture(
        configuration: AudioInputStreamConfiguration(voiceProcessing: initial),
        backend: backend
    )

    _ = capture.start()
    let report = capture.updateVoiceProcessing(updated)

    #expect(report.result == .applied)
    #expect(report.snapshot.isRunning)
    #expect(report.snapshot.inputVoiceProcessing == updated)
    #expect(backend.startCount == 1)
    #expect(backend.stopCount == 0)
    #expect(backend.events == [
        .updateVoiceProcessing(initial),
        .startCapture,
        .updateVoiceProcessing(updated)
    ])
}

@Test func inputCaptureContinuesStartingWhenVoiceProcessingIsUnsupported() {
    let backend = FakeInputStreamBackend()
    let voiceProcessing = AudioInputVoiceProcessingConfiguration(inputMuted: true)
    backend.updateVoiceProcessingError = AudioStreamError.unsupportedOnCurrentPlatform
    let capture = AudioInputStreamCapture(
        configuration: AudioInputStreamConfiguration(voiceProcessing: voiceProcessing),
        backend: backend
    )
    var reports: [AudioStreamOperationReport] = []
    capture.setRuntimeEventHandler { event in
        if case .operation(let report) = event {
            reports.append(report)
        }
    }

    let start = capture.start()

    #expect(start.result == .applied)
    #expect(backend.startCount == 1)
    #expect(reports.first?.operation == .updateInputVoiceProcessing(voiceProcessing))
    #expect(reports.first?.result == .ignored(.unsupportedOnCurrentPlatform))
}

@Test func inputCaptureMapsUnsupportedBackendToIgnoredReport() {
    let backend = FakeInputStreamBackend()
    backend.startError = AudioStreamError.unsupportedOnCurrentPlatform
    let capture = AudioInputStreamCapture(backend: backend)

    let report = capture.start()

    #expect(report.result == .ignored(.unsupportedOnCurrentPlatform))
    #expect(report.snapshot.isRunning == false)
}

@Test func outputRendererConvertsFramesToHardwareFormat() {
    let hardwareFormat = AudioFormat(sampleRate: 48_000, channelCount: 2)
    let backend = FakeOutputStreamBackend(actualHardwareFormat: hardwareFormat)
    let configuration = AudioOutputStreamConfiguration(
        preferredFormat: AudioFormat(sampleRate: 16_000, channelCount: 1)
    )
    let renderer = AudioOutputStreamRenderer(configuration: configuration, backend: backend)
    var events: [AudioStreamRuntimeEvent] = []
    renderer.setRuntimeEventHandler { events.append($0) }

    let start = renderer.start()
    let scheduled = renderer.schedule(PCMFrame(
        sequenceNumber: 1,
        format: hardwareFormat,
        capturedAt: 10,
        samples: [0.2, -0.2]
    ))
    let converted = renderer.schedule(PCMFrame(
        sequenceNumber: 2,
        format: AudioFormat(sampleRate: 48_000, channelCount: 1),
        capturedAt: 10,
        samples: [0.4]
    ))

    #expect(start.result == .applied)
    #expect(start.snapshot.preferredFormat == configuration.preferredFormat)
    #expect(start.snapshot.actualHardwareFormat == hardwareFormat)
    #expect(scheduled.result == .applied)
    #expect(scheduled.snapshot.processedFrameCount == 1)
    #expect(converted.result == .applied)
    #expect(backend.scheduledFrames.map(\.sequenceNumber) == [1, 2])
    #expect(backend.scheduledFrames.last?.format == hardwareFormat)
    #expect(backend.scheduledFrames.last?.samples == [0.4, 0.4])
    #expect(events.contains(.outputFrameScheduled(PCMFrame(
        sequenceNumber: 1,
        format: hardwareFormat,
        capturedAt: 10,
        samples: [0.2, -0.2]
    ))))
}

@Test func failedInputStartCleansUpAndRetryRejectsOldCallbacks() throws {
    let backend = FakeInputStreamBackend()
    backend.startError = AudioStreamError.engineOperationFailed("partial input start")
    let capture = AudioInputStreamCapture(backend: backend)
    var frames: [PCMFrame] = []
    capture.setRuntimeEventHandler { if case .inputFrame(let frame) = $0 { frames.append(frame) } }
    let failed = capture.start()
    #expect(failed.result == .failed(.engineOperationFailed("partial input start")))
    #expect(!failed.snapshot.isRunning)
    #expect(backend.stopCount == 1)
    let stale = try #require(backend.callbacks.first)
    backend.startError = nil
    #expect(capture.start().result == .applied)
    let frame = PCMFrame(sequenceNumber: 1, format: AudioFormat(), capturedAt: 1, samples: [0.2])
    stale(frame)
    #expect(frames.isEmpty)
    backend.emit(frame)
    #expect(frames == [frame])
    let current = try #require(backend.onFrame)
    #expect(capture.stop().result == .applied)
    current(frame)
    #expect(frames == [frame])
    #expect(capture.stop().result == .ignored(.alreadyStopped))
    #expect(backend.stopCount == 2)
}

@Test func failedOutputStartCleansUpAndRetryDoesNotQueueAfterStop() {
    let backend = FakeOutputStreamBackend()
    backend.startError = AudioStreamError.engineOperationFailed("partial output start")
    let renderer = AudioOutputStreamRenderer(backend: backend)
    #expect(renderer.start().result == .failed(.engineOperationFailed("partial output start")))
    #expect(backend.stopCount == 1)
    backend.startError = nil
    #expect(renderer.start().result == .applied)
    let frame = PCMFrame(sequenceNumber: 1, format: AudioFormat(), capturedAt: 1, samples: [0.2])
    #expect(renderer.schedule(frame).result == .applied)
    #expect(renderer.stop().result == .applied)
    #expect(renderer.schedule(frame).result == .ignored(.alreadyStopped))
    #expect(backend.scheduledFrames == [frame])
    #expect(renderer.stop().result == .ignored(.alreadyStopped))
}

@Test func voiceProcessingFailureDoesNotStartCapture() {
    let backend = FakeInputStreamBackend()
    backend.updateVoiceProcessingError = AudioStreamError.engineOperationFailed("injected")
    let capture = AudioInputStreamCapture(backend: backend)
    let report = capture.start()
    #expect(report.result == .failed(.engineOperationFailed("injected")))
    #expect(!report.snapshot.isRunning)
    #expect(backend.startCount == 0)
    #expect(backend.stopCount == 1)
}

@Test func outputConfigurationAppliesAtStartAndRemainsStableWhileRunning() throws {
    let backend = FakeOutputStreamBackend()
    let original = AudioOutputStreamConfiguration(maximumBufferedDuration: 0.1)
    let call = AudioOutputStreamConfiguration(maximumBufferedDuration: 0.2)
    let renderer = AudioOutputStreamRenderer(configuration: original, backend: backend)
    #expect(renderer.start(configuration: call).result == .applied)
    #expect(renderer.configuration == call)
    #expect(backend.configurations == [call])
    #expect(renderer.start(configuration: original).result == .ignored(.alreadyRunning))
    #expect(renderer.configuration == call)
    #expect(backend.configurations == [call])
    #expect(renderer.stop().result == .applied)
    #expect(renderer.start(configuration: original).result == .applied)
    #expect(renderer.configuration == original)
    #expect(backend.configurations == [call, original])
    _ = renderer.stop()
}

import VADGate

nonisolated struct AudioLevelMeter {
    static func rmsLevel(samples: [Float]) -> Float {
        VADGate.rms(samples: samples)
    }
}

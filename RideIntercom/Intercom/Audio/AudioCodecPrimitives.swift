import VADGate

nonisolated struct AudioLevelMeter {
    static let audibleOutputThreshold: Float = 0.00025

    static func rmsLevel(samples: [Float]) -> Float {
        VADGate.rms(samples: samples)
    }
}

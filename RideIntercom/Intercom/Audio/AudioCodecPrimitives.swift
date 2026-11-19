import VADGate

nonisolated struct AudioLevelMeter {
    static let audibleOutputThreshold: Float = 0.00025

    static func rmsLevel(samples: [Float]) -> Float {
        VADGate.rms(samples: samples)
    }
}

nonisolated struct VoicePeakWindow: Equatable, Sendable {
    private let frameLimit: Int
    private var levels: [Float]

    init(frameLimit: Int = 100, levels: [Float] = []) {
        self.frameLimit = frameLimit
        self.levels = levels
    }

    mutating func record(_ level: Float) -> Float {
        let clampedLevel = min(1, max(0, level))
        levels.append(clampedLevel)
        if levels.count > frameLimit {
            levels.removeFirst(levels.count - frameLimit)
        }
        return levels.max() ?? 0
    }
}

struct ReceiveMasterMixSnapshot: Equatable {
    let sourceBusCount: Int
    let receivedFrameCount: Int
    let outputLevel: Float
    let outputPeakLevel: Float
    let masterVolume: Float
    let effectSummary: String
    let isMuted: Bool
    let state: PipelineStepState
}


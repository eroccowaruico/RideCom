struct ReceiveOutputMixSnapshot: Equatable {
    let sourceBusCount: Int
    let receivedFrameCount: Int
    let outputLevel: Float
    let outputPeakLevel: Float
    let outputVolume: Float
    let effectSummary: String
    let isMuted: Bool
    let state: PipelineStepState
}

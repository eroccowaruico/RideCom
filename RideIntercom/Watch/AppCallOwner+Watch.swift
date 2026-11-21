import CallControl
import Foundation

extension AppCallOwner {
    /// Watch starts calls to saved people; Widget and Siri keep their broader directory.
    private var watchCallTargets: [(entity: CallTargetEntity, destination: CallDestination)] {
        callTargets.filter { if case .user = $0.destination { true } else { false } }
    }

    func watchSnapshot(now: Date = Date()) -> WatchCallSnapshot {
        guard let viewModel = try? callModel(), viewModel.hasCurrentAccountAccess else {
            return .init(reference: nil, generatedAt: now, validUntil: now.addingTimeInterval(120),
                         targets: [], title: nil, hasCall: false, isMuted: true, state: .signedOut)
        }
        let hasCall = viewModel.hasAnyActiveGroupConnection
        let state: WatchCallState = switch viewModel.callStatus(for: viewModel.activeGroupID) {
        case .chooseDestination, .ready: .idle
        case .connecting: .connecting
        case .inCall: .inCall
        case .audioPaused: .audioPaused
        case .audioUnavailable: .audioUnavailable
        }
        return .init(reference: viewModel.currentCallReference.encoded, generatedAt: now,
                     validUntil: now.addingTimeInterval(120),
                     targets: watchCallTargets.map { .init(id: $0.entity.id, name: $0.entity.name) },
                     title: viewModel.groups.first { $0.id == viewModel.activeGroupID }.map(viewModel.callTitle),
                     hasCall: hasCall, isMuted: viewModel.isMuted, state: state,
                     audioCheck: viewModel.audioCheckWatchSessionID.map { sessionID in
                         let phase = viewModel.audioCheckPhase
                         if phase == .recording {
                             return .init(sessionID: sessionID, phase: phase, recordedFrames: 0, nonzeroSamples: 0)
                         }
                         return .init(sessionID: sessionID, phase: phase,
                             recordedFrames: viewModel.audioCheckRecordedFrameCount,
                             nonzeroSamples: viewModel.audioCheckRecordedNonzeroSamples)
                     }, supportsRemoteStart: true)
    }

    func handleWatchRequest(_ request: WatchControlRequest, now: Date = Date()) async -> WatchControlReply {
        func reply(_ problem: WatchControlProblem? = nil) -> WatchControlReply {
            .init(snapshot: watchSnapshot(now: now), problem: problem)
        }
        if request.action == .refresh { return reply() }
        guard let viewModel = try? callModel(), viewModel.hasCurrentAccountAccess else { return reply(.noAccount) }
        guard request.reference == viewModel.currentCallReference.encoded, request.validUntil > now,
              request.validUntil <= now.addingTimeInterval(120) else { return reply(.stale) }
        let succeeded: Bool
        switch request.action {
        case .refresh: return reply()
        case .startAudio(let id, let offer):
            guard offer.key.count == 32,
                  let target = watchCallTargets.first(where: { $0.entity.id == id }) else {
                return reply(.missingDestination)
            }
            guard viewModel.startCall(to: target.destination, accountAccessID: viewModel.accountAccessID,
                               allowSwitchingCall: false, source: .watchAudio) else { return reply(.denied) }
            do {
                let endpoint = try await viewModel.attachWatchAudio(offer)
                guard let current = try? callModel(), current === viewModel, viewModel.hasCurrentAccountAccess else {
                    return reply(.noAccount)
                }
                return .init(snapshot: watchSnapshot(), problem: nil, audioEndpoint: endpoint)
            } catch { return reply(.unavailable) }
        case .start(let id), .startRemote(let id):
            guard let target = watchCallTargets.first(where: { $0.entity.id == id }) else {
                return reply(.missingDestination)
            }
            let source: CallStartSource = request.action == .startRemote(id) ? .watchRemote : .watchAudio
            succeeded = viewModel.startCall(to: target.destination, accountAccessID: viewModel.accountAccessID,
                                     allowSwitchingCall: false, source: source)
        #if DEBUG
        case .startAudioCheck(let offer):
            guard offer.key.count == 32, viewModel.canStartAudioCheck else { return reply(.denied) }
            do {
                let endpoint = try await viewModel.attachWatchAudio(offer, audioCheck: true)
                return .init(snapshot: watchSnapshot(), problem: nil, audioEndpoint: endpoint)
            } catch { return reply(.unavailable) }
        case .playAudioCheck(let id):
            return reply(viewModel.playWatchAudioCheck(sessionID: id) ? nil : .stale)
        case .stopAudioCheck(let id):
            guard viewModel.audioCheckWatchSessionID == id else { return reply(.stale) }
            viewModel.cancelAudioCheck()
            return reply()
        #endif
        case .end: succeeded = viewModel.endCall(viewModel.currentCallReference)
        case .setMuted(let value): succeeded = viewModel.setCallMuted(value, for: viewModel.currentCallReference)
        }
        guard let current = try? callModel(), current === viewModel, viewModel.hasCurrentAccountAccess else {
            return reply(.noAccount)
        }
        return reply(succeeded ? nil : .denied)
    }
}

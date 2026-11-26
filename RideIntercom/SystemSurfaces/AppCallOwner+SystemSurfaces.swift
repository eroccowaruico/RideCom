import CallControl
import Foundation
import Observation

extension AppCallOwner {
    var isMenuBarInserted: Bool { viewModel?.canStartCalls == true && viewModel?.menuBarEnabled == true }

    @discardableResult
    func setCallSurfaceMuted(_ muted: Bool, reference: CallSurfaceReference) -> Bool {
        viewModel?.setCallMuted(muted, for: reference.callReference) == true
    }

    var currentLivePresentation: CallLivePresentation? {
        guard let model = viewModel, model.canStartCalls, model.hasAnyActiveGroupConnection,
              let reference = model.currentCallReference.displayedCall else { return nil }
        return .init(reference: reference, status: model.callStatus(for: reference.groupID),
                     isMuted: model.effectiveInputMuted, canControlMicrophone: model.canControlMicrophone)
    }
    func observeSystemSurfaces() {
        let input = withObservationTracking {
            (currentLivePresentation, viewModel?.liveActivityEnabled == true, systemSurfaceIsForeground)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeSystemSurfaces() }
        }
        liveActivities.setPresentation(input.0, enabled: input.1, isForeground: input.2)
    }
    func performCallSurfaceAction(
        _ action: CallSurfaceAction, reference: CallSurfaceReference? = nil, destinationID: String? = nil,
        allowsMicrophonePrompt: Bool = true
    ) async throws {
        switch action {
        case .calls:
            _ = try callModel()
        case .saved:
            return try await startSavedCall(id: destinationID, allowsMicrophonePrompt: allowsMicrophonePrompt)
        case .recent:
            return try await startRecentExternalCall()
        case .end:
            let model = try callModel()
            guard let reference, model.endCall(reference.callReference) else {
                throw CallIntentError.unavailable(
                    "The displayed call has ended or changed. Open RideCom to check your current call.")
            }
        }
        callPresentationID = UUID()
    }

    func startSavedCall(
        id: String?, allowsMicrophonePrompt: Bool = true,
        missingDestinationMessage: String =
            "This call destination is no longer available. Choose a saved user or group in RideCom."
    ) async throws {
        let model = try callModel()
        let destination = id.flatMap { id in callTargets.first { $0.entity.id == id }?.destination }
        try await startExternalCall(to: destination, using: model, allowsMicrophonePrompt: allowsMicrophonePrompt,
                                    missingDestinationMessage: missingDestinationMessage)
    }

    func startRecentExternalCall() async throws {
        let model = try callModel()
        try await startExternalCall(to: model.recentCallDestination, using: model, allowsMicrophonePrompt: true,
            missingDestinationMessage: "No recent call is available. Choose a saved user or group in RideCom.")
    }

    private func startExternalCall(
        to destination: CallDestination?, using model: IntercomViewModel,
        allowsMicrophonePrompt: Bool, missingDestinationMessage: String
    ) async throws {
        guard let destination else { throw CallIntentError.unavailable(missingDestinationMessage) }
        try Task.checkCancellation()
        let pending = model.accountCallWaitingForEnrollment
        if let pending, destination != .user(pending.id) {
            throw CallIntentError.unavailable("End the current call before starting a different call.")
        }
        let hasMicrophoneAccess = model.callMicrophonePermission() == .granted
        if pending != nil, !hasMicrophoneAccess {
            throw CallIntentError.unavailable(IntercomViewModel.microphoneAccessRequiredMessage)
        }
        if hasMicrophoneAccess, pending != nil || (model.hasAutomaticInternetEnrollmentProof
            && model.waitForAccountCallEnrollment(destination, allowsMicrophonePrompt: allowsMicrophonePrompt)) {
            callPresentationID = UUID()
            return
        }
        let start = model.requestCallStart(to: destination, accountAccessID: model.accountAccessID,
            allowSwitchingCall: false, allowsMicrophonePrompt: allowsMicrophonePrompt)
        guard await presentStartedCall(start, in: model) else {
            let message = model.callMicrophonePermission() == .granted
                ? model.groupErrorMessage : IntercomViewModel.microphoneAccessRequiredMessage
            throw CallIntentError.unavailable(message ?? "The call could not be started.")
        }
    }

    @discardableResult
    func presentStartedCall(_ start: CallStartOutcome, in model: IntercomViewModel) async -> Bool {
        guard let reference = await start.startedCall(), !Task.isCancelled,
              viewModel === model, model.matchesCurrentCall(reference) else { return false }
        callPresentationID = UUID()
        return true
    }
}

extension IntercomViewModel {
    func setMenuBarEnabled(_ enabled: Bool) {
        guard canStartCalls else { return }
        menuBarEnabled = enabled
        saveAppSettings()
    }

    func setLiveActivityEnabled(_ enabled: Bool) {
        guard canStartCalls else { return }
        liveActivityEnabled = enabled
        saveAppSettings()
    }
}

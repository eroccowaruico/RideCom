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
        _ action: CallSurfaceAction, reference: CallSurfaceReference? = nil, destinationID: String? = nil
    ) throws {
        switch action {
        case .calls:
            _ = try callModel()
        case .saved:
            return try startSavedCall(id: destinationID)
        case .recent:
            return try startRecentExternalCall()
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
        id: String?,
        missingDestinationMessage: String =
            "This call destination is no longer available. Choose a saved user or group in RideCom."
    ) throws {
        let model = try callModel()
        let destination = id.flatMap { id in callTargets.first { $0.entity.id == id }?.destination }
        try startExternalCall(to: destination, using: model, missingDestinationMessage: missingDestinationMessage)
    }

    func startRecentExternalCall() throws {
        let model = try callModel()
        try startExternalCall(to: model.recentCallDestination, using: model,
            missingDestinationMessage: "No recent call is available. Choose a saved user or group in RideCom.")
    }

    private func startExternalCall(
        to destination: CallDestination?, using model: IntercomViewModel, missingDestinationMessage: String
    ) throws {
        guard let destination else { throw CallIntentError.unavailable(missingDestinationMessage) }
        guard model.startCall(to: destination, accountAccessID: model.accountAccessID, allowSwitchingCall: false) else {
            throw CallIntentError.unavailable(model.groupErrorMessage ?? "The call could not be started.")
        }
        callPresentationID = UUID()
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

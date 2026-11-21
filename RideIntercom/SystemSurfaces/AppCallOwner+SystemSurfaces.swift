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
        guard let vm = viewModel, vm.canStartCalls, vm.hasAnyActiveGroupConnection,
              let reference = vm.currentCallReference.displayedCall else { return nil }
        return .init(reference: reference, status: vm.callStatus(for: reference.groupID),
                     isMuted: vm.effectiveInputMuted, canControlMicrophone: vm.canControlMicrophone)
    }
    func observeSystemSurfaces() {
        let input = withObservationTracking {
            (currentLivePresentation, viewModel?.liveActivityEnabled == true, systemSurfaceIsForeground)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeSystemSurfaces() }
        }
        liveActivities.setPresentation(input.0, enabled: input.1, isForeground: input.2)
    }
    func performCallSurfaceAction(_ action: CallSurfaceAction, reference: CallSurfaceReference?) throws {
        switch action {
        case .calls:
            _ = try callModel()
        case .saved:
            return try startWidgetCall(id: "")
        case .recent:
            return try startRecentExternalCall()
        case .end:
            let vm = try callModel()
            guard let reference, vm.endCall(reference.callReference) else {
                throw CallIntentError.unavailable("The displayed call has ended or changed. Open RideCom to check your current call.")
            }
        }
        callPresentationID = UUID()
    }

    func startWidgetCall(id: String) throws {
        try startSavedCall(id: id, missingDestinationMessage: "This call destination is no longer available. Choose a saved user or group in RideCom.")
    }

    func startSavedCall(id: String, missingDestinationMessage: String) throws {
        let vm = try callModel()
        let destination = callTargets.first { $0.entity.id == id }?.destination
        try startExternalCall(to: destination, using: vm, missingDestinationMessage: missingDestinationMessage)
    }

    func startRecentExternalCall() throws {
        let vm = try callModel()
        try startExternalCall(to: vm.recentCallDestination, using: vm,
                              missingDestinationMessage: "No recent call is available. Choose a saved user or group in RideCom.")
    }

    private func startExternalCall(to destination: CallDestination?, using vm: IntercomViewModel, missingDestinationMessage: String) throws {
        guard let destination else { throw CallIntentError.unavailable(missingDestinationMessage) }
        guard vm.startCall(to: destination, accountAccessID: vm.accountAccessID, allowSwitchingCall: false) else {
            throw CallIntentError.unavailable(vm.groupErrorMessage ?? "The call could not be started.")
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

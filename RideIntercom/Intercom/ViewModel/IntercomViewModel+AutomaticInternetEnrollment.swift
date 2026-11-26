import AuthenticationServices
import CallControl
import CryptoKit
import Foundation
import Observation
import RTC

@Observable final class AutomaticInternetEnrollment {
    @ObservationIgnored var client = InternetAccountClient()
    @ObservationIgnored var beginBackgroundTime: AppBackgroundTime.Request = {
        AppBackgroundTime.begin(name: "Finish Internet Device Registration", expiration: $0)
    }
    @ObservationIgnored var task: Task<Void, Never>?
    var waitingCall: CallAwaitingInternetEnrollment?
    @ObservationIgnored var startedCall: CallAwaitingInternetEnrollment?
    @ObservationIgnored var retryAt: Date?
    @ObservationIgnored var retryDelay = 5
    @ObservationIgnored var waitsForExecutionOpportunity = false
    @ObservationIgnored var isSubmittingProof = false
}

struct CallAwaitingInternetEnrollment {
    let destination: CallDestination
    let reference: CallReference
    let startsNearby: Bool
    let isStillAllowed: @MainActor () -> Bool
    var needsAppleConfirmation: Bool
    var accountRecipient: AccountPrincipal?
    var replacesRejectedCredential = false
}

extension IntercomViewModel {
    var needsInternetEnrollment: Bool {
        internetCredentialState == .missing && canPrepareInternetCredential
    }

    var canWaitForSavedInternetCredential: Bool {
        internetCredentialState == .unreadable && canPrepareInternetCredential
    }

    var canPrepareInternetCredential: Bool {
        internetSettingsStore.permitsServiceAccess && internetSettingsStore.fixedWorkerOrigin != nil
            && enabledRTCTransportRoutes.contains(.webRTC)
    }

    var hasAutomaticInternetEnrollmentProof: Bool {
        needsInternetEnrollment && accountSession.enrollmentProof(for: accountAccessID) != nil
    }

    var callForAppleEnrollmentConfirmation: CallReference? {
        guard needsInternetEnrollment, canStartCalls, !accountSession.isSigningIn,
              let pending = automaticInternetEnrollment.waitingCall, pending.needsAppleConfirmation,
              isCurrentEnrollmentCall(pending)
        else { return nil }
        return pending.reference
    }

    var accountCallWaitingForEnrollment: SavedUser? {
        guard let pending = automaticInternetEnrollment.waitingCall, pending.accountRecipient != nil,
              isCurrentEnrollmentCall(pending) else { return nil }
        return enrolledCallRecipient(pending)
    }

    func waitForAccountCallEnrollment(_ destination: CallDestination) -> Bool {
        guard case .user(let id) = destination, !hasAnyActiveGroupConnection, callMicrophonePermissionRequest == nil,
              canStartCalls, canEditSavedGroups,
              localAccountPrincipal == nil, needsInternetEnrollment || canWaitForSavedInternetCredential,
              let origin = internetSettingsStore.fixedWorkerOrigin,
              let user = savedRemoteUsers.first(where: { $0.id == id }),
              let recipient = user.principal, recipient.issuer == IdentityEncoding.origin(origin)
        else { return false }
        if accountCallWaitingForEnrollment?.id == id { return true }
        selectedGroup = nil
        groupErrorMessage = nil
        connectionGeneration = UUID()
        callDisconnectDeadline = callAccessNow().addingTimeInterval(callDisconnectInterval.seconds)
        automaticInternetEnrollment.waitingCall = .init(
            destination: destination, reference: currentCallReference, startsNearby: false,
            isStillAllowed: { true }, needsAppleConfirmation: !hasAutomaticInternetEnrollmentProof,
            accountRecipient: recipient)
        callTicker.start()
        reconcileAutomaticInternetEnrollment()
        return true
    }

    func cancelPendingAccountCallEnrollment() {
        if automaticInternetEnrollment.waitingCall?.accountRecipient != nil { disconnect() }
    }

    private func enrolledCallRecipient(_ pending: CallAwaitingInternetEnrollment) -> SavedUser? {
        guard case .user(let id) = pending.destination, let recipient = pending.accountRecipient else { return nil }
        return savedRemoteUsers.first { $0.id == id && $0.principal == recipient }
    }

    private func isCurrentEnrollmentCall(_ pending: CallAwaitingInternetEnrollment) -> Bool {
        guard matchesCurrentCall(pending.reference), pending.isStillAllowed(),
              let deadline = callDisconnectDeadline, callAccessNow() < deadline else { return false }
        if pending.accountRecipient != nil { return enrolledCallRecipient(pending) != nil }
        return selectedGroup?.id == pending.reference.groupID && isActiveCall(pending.destination)
    }

    func prepareCallEnrollmentConfirmation(
        _ request: ASAuthorizationAppleIDRequest, for call: CallReference
    ) -> AppleEnrollmentConfirmation? {
        guard networkPathIsAvailable == true, callForAppleEnrollmentConfirmation == call,
              let accountUserID else { return nil }
        return AppleEnrollmentConfirmation(request: request, userID: accountUserID)
    }

    func completeCallEnrollmentConfirmation(
        _ confirmation: AppleEnrollmentConfirmation, for call: CallReference,
        userID: String, state: String?, identityToken: Data?
    ) {
        guard callForAppleEnrollmentConfirmation == call else { return }
        guard let proof = confirmation.proof(userID: userID, state: state, identityToken: identityToken),
              accountSession.acceptEnrollmentConfirmation(proof, userID: userID, access: call.accountAccessID)
        else {
            reportCallEnrollmentConfirmationFailure(for: call)
            return
        }
        groupErrorMessage = nil
        automaticInternetEnrollment.waitingCall?.needsAppleConfirmation = false
        automaticInternetEnrollment.retryAt = nil
        automaticInternetEnrollment.retryDelay = 5
        reconcileAutomaticInternetEnrollment()
    }

    func reportCallEnrollmentConfirmationFailure(for call: CallReference) {
        guard callForAppleEnrollmentConfirmation == call else { return }
        groupErrorMessage = String(localized: "Could not prepare Internet calling for this device.")
    }

    private var canContinueInternetEnrollment: Bool {
        canStartCalls && needsInternetEnrollment && networkPathIsAvailable == true
            && !automaticInternetEnrollment.waitsForExecutionOpportunity
            && (!hasAnyActiveGroupConnection || automaticInternetEnrollment.waitingCall != nil)
            && contactInvitationSession == nil
    }

    var keepsCallDuringCredentialRecovery: Bool {
        guard let call = automaticInternetEnrollment.startedCall, call.replacesRejectedCredential else { return false }
        return isCurrentEnrollmentCall(call)
    }

    func handleInternetRouteBlock(_ reason: RTC.ConnectionBlockReason) {
        internetTransportFailure = .blocked(reason)
        guard reason == .deviceCredentialRejected, hasInternetCredentials, internetSettingsStore.permitsServiceAccess,
              internetSettingsStore.fixedWorkerOrigin != nil else { return }
        internetSettingsStore.rejectCurrentCredential()
        internetCredentialState = .missing
        internetCheckGeneration = UUID()
        isCheckingInternet = false
        internetCheckMessage = InternetTransportFailure.blocked(.deviceCredentialRejected).detail
        callSession.updateInternetConfiguration(nil, preservingCall: true)
        if var call = automaticInternetEnrollment.startedCall, isCurrentEnrollmentCall(call) {
            call.replacesRejectedCredential = true
            call.needsAppleConfirmation = !hasAutomaticInternetEnrollmentProof
            automaticInternetEnrollment.startedCall = call
            automaticInternetEnrollment.waitingCall = call
        }
        reconcileAutomaticInternetEnrollment()
    }

    func reconcileAutomaticInternetEnrollment(executionOpportunity: Bool = false) {
        if executionOpportunity {
            automaticInternetEnrollment.waitsForExecutionOpportunity = false
            reloadUnreadableInternetCredentials()
        }
        if hasInternetCredentials {
            reconcileInternetCredentialRenewal()
            return
        }
        let proof = accountSession.enrollmentProof(for: accountAccessID)
        let needsAppleConfirmation = proof == nil && !automaticInternetEnrollment.isSubmittingProof
        if needsInternetEnrollment, let pending = automaticInternetEnrollment.waitingCall,
           pending.needsAppleConfirmation != needsAppleConfirmation {
            automaticInternetEnrollment.waitingCall?.needsAppleConfirmation = needsAppleConfirmation
        }
        guard canContinueInternetEnrollment, !needsAppleConfirmation else {
            automaticInternetEnrollment.task?.cancel()
            return
        }
        guard automaticInternetEnrollment.task == nil,
              let proof,
              let origin = internetSettingsStore.fixedWorkerOrigin else { return }
        automaticInternetEnrollment.task = Task { [weak self] in
            await self?.runAutomaticInternetEnrollment(proof, at: origin)
        }
    }

    private func runAutomaticInternetEnrollment(_ proof: InternetSignInProof, at origin: URL) async {
        defer {
            automaticInternetEnrollment.task = nil
            reconcileAutomaticInternetEnrollment()
        }
        while canUseEnrollmentProof(proof) {
            if let retryAt = automaticInternetEnrollment.retryAt, retryAt > Date() {
                let remaining = min(retryAt, proof.expiresAt).timeIntervalSinceNow
                do { try await Task.sleep(for: .seconds(max(0, remaining))) } catch { return }
                continue
            }
            do {
                try await withInternetEnrollmentTime {
                    try await finishAutomaticInternetEnrollment(proof, at: origin)
                }
                accountSession.discardEnrollmentProof(proof.id)
                return
            } catch is CancellationError {
                return
            } catch InternetAccountClient.Failure.appleEnrollmentRejected {
                accountSession.discardEnrollmentProof(proof.id)
                return
            } catch {
                guard canUseEnrollmentProof(proof) else { return }
                guard let delay = enrollmentRetryDelay(for: error) else {
                    accountSession.discardEnrollmentProof(proof.id)
                    failCallAwaitingInternetEnrollment()
                    return
                }
                automaticInternetEnrollment.retryAt = Date().addingTimeInterval(Double(delay))
            }
        }
    }

    func applyInternetConfigurationAfterEnrollment(_ configuration: RTC.CloudflareRealtimeConfiguration) {
        guard let pending = automaticInternetEnrollment.waitingCall else {
            disconnect()
            callSession.updateInternetConfiguration(configuration)
            return
        }
        automaticInternetEnrollment.waitingCall = nil
        if pending.accountRecipient != nil {
            let deadline = callDisconnectDeadline
            let mayConnect = canStartCalls && enabledRTCTransportRoutes.contains(.webRTC)
                && isCurrentEnrollmentCall(pending)
                && localAccountPrincipal?.issuer == pending.accountRecipient?.issuer
            // The intent has no live session. End only its timer before starting the resolved call.
            callDisconnectDeadline = nil
            callTicker.stop()
            callSession.updateInternetConfiguration(configuration)
            if mayConnect {
                _ = requestCallStart(to: pending.destination, accountAccessID: pending.reference.accountAccessID,
                                     allowSwitchingCall: false, presentsAfterPermission: true,
                                     disconnectDeadline: deadline, isStillAllowed: pending.isStillAllowed)
            }
            return
        }
        let expired = disconnectIfTimerExpired(now: callAccessNow().timeIntervalSince1970)
        guard matchesCurrentCall(pending.reference), canStartCalls, enabledRTCTransportRoutes.contains(.webRTC),
              !expired, pending.isStillAllowed(), isActiveCall(pending.destination),
              let group = groups.first(where: { $0.id == activeGroupID }), callDestination(of: group) != nil,
              let credential = try? credential(for: group)
        else {
            if !expired { disconnect() }
            callSession.updateInternetConfiguration(configuration)
            return
        }
        let preservesCall = pending.replacesRejectedCredential || pending.startsNearby
        if pending.replacesRejectedCredential { internetTransportFailure = nil }
        callSession.updateInternetConfiguration(configuration, preservingCall: preservesCall)
        if pending.replacesRejectedCredential {
            callSession.retryInternetRouteAfterCredentialChange()
            return
        }
        if !preservesCall {
            prepareInvitationsForCall(to: group)
            startPreparedCall(group: group, credential: credential)
        }
        if case .user(let id) = pending.destination { noticeNewDirectCall(to: id) }
    }

    private func failCallAwaitingInternetEnrollment() {
        guard let pending = automaticInternetEnrollment.waitingCall else { return }
        if pending.replacesRejectedCredential {
            groupErrorMessage = String(localized: "Could not prepare Internet calling for this device.")
            return
        }
        automaticInternetEnrollment.waitingCall = nil
        guard !pending.startsNearby else { return }
        disconnect()
        groupErrorMessage = String(localized: "Could not prepare Internet calling for this device.")
    }

    private func canUseEnrollmentProof(_ proof: InternetSignInProof) -> Bool {
        !Task.isCancelled && canContinueInternetEnrollment
            && accountSession.enrollmentProof(for: accountAccessID)?.id == proof.id
    }

    private func canUseIssuedEnrollmentCredential(_ proof: InternetSignInProof) -> Bool {
        guard !Task.isCancelled, canContinueInternetEnrollment else { return false }
        return accountSession.enrollmentProof(for: accountAccessID).map { $0.id == proof.id } ?? true
    }

    func withInternetEnrollmentTime(_ run: () async throws -> Void) async throws {
        var endBackgroundTime: (@MainActor () -> Void)?
        endBackgroundTime = automaticInternetEnrollment.beginBackgroundTime { [weak self] in
            guard let end = endBackgroundTime else { return }
            endBackgroundTime = nil
            self?.automaticInternetEnrollment.waitsForExecutionOpportunity = true
            self?.automaticInternetEnrollment.task?.cancel()
            end()
        }
        defer {
            let end = endBackgroundTime
            endBackgroundTime = nil
            end?()
        }
        try await run()
    }

    private func finishAutomaticInternetEnrollment(_ proof: InternetSignInProof, at origin: URL) async throws {
        let client = automaticInternetEnrollment.client
        let deviceID = try internetSettingsStore.accountDeviceID()
        let memberID = localMemberIdentity.memberID
        let deviceKey = IdentityEncoding.encode(
            try internetSettingsStore.deviceSigningKey().publicKey.x963Representation)
        let challenge = try await client.challenge(origin: origin, deviceID: deviceID)
        guard canUseEnrollmentProof(proof) else { throw CancellationError() }
        automaticInternetEnrollment.isSubmittingProof = true
        defer { automaticInternetEnrollment.isSubmittingProof = false }
        let credential = try await client.exchange(
            origin: origin, challenge: challenge, token: proof.identityToken,
            signInProof: proof.sign(challenge, deviceKey: deviceKey))
        do {
            guard canUseIssuedEnrollmentCredential(proof) else { throw CancellationError() }
            let identity = try await client.certify(
                origin: origin, credential: credential, memberID: memberID, deviceKey: deviceKey)
            guard canUseIssuedEnrollmentCredential(proof) else { throw CancellationError() }
            try saveInternetConnection(url: origin.absoluteString, token: credential.accessToken, identity: identity)
        } catch {
            if canUseIssuedEnrollmentCredential(proof), !internetSettingsStore.requiresAccountDataReset {
                try? await client.revoke(.init(workerURL: origin, accessToken: credential.accessToken))
            }
            throw error
        }
    }

    func enrollmentRetryDelay(for error: any Error) -> Int? {
        switch error {
        case InternetAccountClient.Failure.rateLimited(let seconds): return seconds
        case InternetAccountClient.Failure.serviceUnavailable, is URLError:
            let delay = automaticInternetEnrollment.retryDelay
            automaticInternetEnrollment.retryDelay = min(delay * 2, 60)
            return delay
        default: return nil
        }
    }
}

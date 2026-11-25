import AuthenticationServices
import CallControl
import CryptoKit
import Foundation
import Observation
import RTC

@Observable final class AutomaticInternetEnrollment {
    @ObservationIgnored var client = InternetAccountClient()
    @ObservationIgnored var task: Task<Void, Never>?
    var waitingCall: CallAwaitingInternetEnrollment?
    @ObservationIgnored var retryAt: Date?
    @ObservationIgnored var retryDelay = 5
}

struct CallAwaitingInternetEnrollment {
    let destination: CallDestination
    let reference: CallReference
    let startsNearby: Bool
    let isStillAllowed: @MainActor () -> Bool
    var needsAppleConfirmation: Bool
}

extension IntercomViewModel {
    var needsInternetEnrollment: Bool {
        internetCredentialState == .missing && internetSettingsStore.permitsServiceAccess
            && internetSettingsStore.fixedWorkerOrigin != nil && enabledRTCTransportRoutes.contains(.webRTC)
    }

    var hasAutomaticInternetEnrollmentProof: Bool {
        needsInternetEnrollment && accountSession.enrollmentProof(for: accountAccessID) != nil
    }

    var callForAppleEnrollmentConfirmation: CallReference? {
        guard needsInternetEnrollment, canStartCalls, !accountSession.isSigningIn,
              let pending = automaticInternetEnrollment.waitingCall, pending.needsAppleConfirmation,
              selectedGroup?.id == pending.reference.groupID, matchesCurrentCall(pending.reference),
              pending.isStillAllowed(), isActiveCall(pending.destination),
              let deadline = callDisconnectDeadline, callAccessNow() < deadline
        else { return nil }
        return pending.reference
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

    private var canEnrollInternetAutomatically: Bool {
        canStartCalls && hasAutomaticInternetEnrollmentProof && networkPathIsAvailable == true
            && (!hasAnyActiveGroupConnection || automaticInternetEnrollment.waitingCall != nil)
            && contactInvitationSession == nil
    }

    func reconcileAutomaticInternetEnrollment() {
        let proof = accountSession.enrollmentProof(for: accountAccessID)
        if needsInternetEnrollment, let pending = automaticInternetEnrollment.waitingCall,
           pending.needsAppleConfirmation != (proof == nil) {
            automaticInternetEnrollment.waitingCall?.needsAppleConfirmation = proof == nil
        }
        if hasInternetCredentials, let proof { accountSession.discardEnrollmentProof(proof.id) }
        guard canEnrollInternetAutomatically else {
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
                try await finishAutomaticInternetEnrollment(proof, at: origin)
                accountSession.discardEnrollmentProof(proof.id)
                return
            } catch is CancellationError {
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
        if pending.startsNearby {
            callSession.updateInternetConfiguration(configuration, preservingCall: true)
        } else {
            callSession.updateInternetConfiguration(configuration)
            prepareInvitationsForCall(to: group)
            startPreparedCall(group: group, credential: credential)
        }
        if case .user(let id) = pending.destination { noticeNewDirectCall(to: id) }
    }

    private func failCallAwaitingInternetEnrollment() {
        guard let pending = automaticInternetEnrollment.waitingCall else { return }
        automaticInternetEnrollment.waitingCall = nil
        guard !pending.startsNearby else { return }
        disconnect()
        groupErrorMessage = String(localized: "Could not prepare Internet calling for this device.")
    }

    private func canUseEnrollmentProof(_ proof: InternetSignInProof) -> Bool {
        !Task.isCancelled && canEnrollInternetAutomatically
            && accountSession.enrollmentProof(for: accountAccessID)?.id == proof.id
    }

    private func finishAutomaticInternetEnrollment(_ proof: InternetSignInProof, at origin: URL) async throws {
        let client = automaticInternetEnrollment.client
        let deviceID = try internetSettingsStore.accountDeviceID()
        let memberID = localMemberIdentity.memberID
        let deviceKey = IdentityEncoding.encode(
            try internetSettingsStore.deviceSigningKey().publicKey.x963Representation)
        let challenge = try await client.challenge(origin: origin, deviceID: deviceID)
        guard canUseEnrollmentProof(proof) else { throw CancellationError() }
        let credential = try await client.exchange(origin: origin, challenge: challenge, token: proof.identityToken,
                                                   signInProof: proof.sign(challenge))
        do {
            guard canUseEnrollmentProof(proof) else { throw CancellationError() }
            let identity = try await client.certify(
                origin: origin, credential: credential, memberID: memberID, deviceKey: deviceKey)
            guard canUseEnrollmentProof(proof) else { throw CancellationError() }
            try saveInternetConnection(url: origin.absoluteString, token: credential.accessToken, identity: identity)
        } catch {
            if !Task.isCancelled, canUseEnrollmentProof(proof), !internetSettingsStore.requiresAccountDataReset {
                try? await client.revoke(.init(workerURL: origin, accessToken: credential.accessToken))
            }
            throw error
        }
    }

    private func enrollmentRetryDelay(for error: any Error) -> Int? {
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

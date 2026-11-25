import Foundation
import CryptoKit
import RTC

enum InternetCredentialState {
    case missing, unreadable, configured
}

extension IntercomViewModel {
    var fixedInternetWorkerOrigin: String? { internetSettingsStore.fixedWorkerOrigin?.absoluteString }

    var connectivityNotice: String? {
        if let internetTransportFailure { return internetTransportFailure.notice }
        guard hasAnyActiveGroupConnection, automaticInternetEnrollment.waitingCall == nil,
              networkPathIsAvailable == true else { return nil }
        return internetCallSetupNotice
    }

    var internetCallSetupNotice: String? {
        guard internetSettingsStore.permitsServiceAccess, enabledRTCTransportRoutes.contains(.webRTC) else {
            return nil
        }
        switch internetCredentialState {
        case .missing:
            return String(localized: "Could not prepare Internet calling for this device.")
        case .unreadable:
            return String(localized: "Could not read saved Internet calling settings. Reopen RideCom and try again.")
        case .configured:
            return nil
        }
    }

    func makeInternetAccountAuthorization() throws -> InternetAccountAuthorization {
        guard canStartCalls, let accountUserID else { throw InternetAccountClient.Failure.rejected }
        #if DEBUG && RIDEINTERCOM_VALIDATION
        if let fixture = AppleAccountFixture.makeInternetAuthorization(viewModel: self) { return fixture }
        #endif
        guard internetSettingsStore.permitsServiceAccess else {
            throw InternetConnectionSettingsStore.ValidationError.disabledDuringLocalTests
        }
        guard automaticInternetEnrollment.task == nil else { throw InternetAccountClient.Failure.rejected }
        if let proof = accountSession.enrollmentProof(for: accountAccessID) {
            accountSession.discardEnrollmentProof(proof.id)
        }
        return InternetAccountAuthorization(
            expectedUserID: accountUserID, deviceID: try internetSettingsStore.accountDeviceID(),
            memberID: localMemberIdentity.memberID,
            deviceKey: IdentityEncoding.encode(
                try internetSettingsStore.deviceSigningKey().publicKey.x963Representation),
            resolveOrigin: internetSettingsStore.workerOrigin,
            currentUser: { [weak self] in
                guard let self, self.canStartCalls else { return nil }
                return self.accountUserID
            }, save: { [weak self] origin, credential, identity in
                guard let self, self.canStartCalls else { throw InternetAccountClient.Failure.rejected }
                try self.saveInternetConnection(
                    url: origin.absoluteString, token: credential.accessToken, identity: identity)
            })
    }
    func endAccountAccess() {
        automaticInternetEnrollment.task?.cancel()
        stopCallRelationshipBackup()
        stopDirectRestoreDeviceSync()
        notifications.stop()
        stopGroupDeliverySync()
        stopCallAccessObservation()
        storeAccess.stop()
        stopContactInvitationSession()
        disconnect()
        internetCheckGeneration = UUID()
        isCheckingInternet = false
        if accountSession.deletion.blocksSignIn {
            internetCredentialState = .missing
            localAccountPrincipal = nil
            return
        }
        // Disable saved Internet access before the asynchronous server request.
        do { _ = try internetSettingsStore.retireAppleCredential() } catch {
            internetCheckMessage = "Could not read Internet access for sign-out. Saved data has been preserved."
        }
        internetCredentialState = .missing
        localAccountPrincipal = nil
        Task { await retryInternetAccountRevocation() }
    }
    func retryInternetAccountRevocation(client: InternetAccountClient = .init()) async {
        let generation = internetCheckGeneration
        do {
            guard let pending = try internetSettingsStore.pendingRevocation() else { return }
            try await client.revoke(pending)
            try internetSettingsStore.finishRevocation(pending)
        } catch {
            guard generation == internetCheckGeneration else { return }
            internetCheckMessage =
                "Internet access is disabled on this device. Server sign-out is pending; retry when online."
        }
    }
    func saveInternetConnection(url: String, token: String, identity: VerifiedDeviceIdentity? = nil) throws {
        guard canStartCalls else { throw InternetAccountClient.Failure.rejected }
        do { try internetSettingsStore.save(url: url, token: token, identity: identity) } catch {
            if internetSettingsStore.requiresAccountDataReset {
                requiresAccountDataReset = true
                invitationBackgroundTransfer?.reconcile(keeping: [])
                internetCheckGeneration = UUID()
                isCheckingInternet = false
                stopContactInvitationSession()
                disconnect()
                localAccountPrincipal = nil
                internetCredentialState = .missing
            }
            throw error
        }
        if let transfer = invitationBackgroundTransfer { transfer.reconcile(keeping: backgroundInvitationUploadIDs()) }
        localAccountPrincipal = try internetSettingsStore.loadPrincipal(memberID: localMemberIdentity.memberID)
        guard let configuration = try internetSettingsStore.load() else {
            throw InternetConnectionSettingsStore.ValidationError.missingToken
        }
        internetCheckGeneration = UUID()
        isCheckingInternet = false
        stopContactInvitationSession()
        internetWorkerURL = configuration.workerURL.absoluteString
        internetCredentialState = .configured
        internetCheckMessage = "Device token saved. Service not checked."
        applyInternetConfigurationAfterEnrollment(configuration)
        callRelationshipBackupSync?.request()
        requestDirectRestoreDeviceSync()
        callRelationshipSync.resumeDirectRestore?()
        Task { await startNotifications() }
    }

    func beginAccountDataReset() throws {
        guard hasCurrentAccountAccess, requiresAccountDataReset,
              internetSettingsStore.requiresAccountDataReset, let accountUserID else {
            throw InternetAccountClient.Failure.rejected
        }
        try accountSession.deletion.beginLocalReset(
            userID: accountUserID, deviceID: internetSettingsStore.existingAccountDeviceID())
        accountSession.signOut()
    }

    func checkInternetService(session: URLSession = .shared) async {
        guard canStartCalls, !isCheckingInternet else { return }
        let stored: CloudflareRealtimeConfiguration?
        do { stored = try internetSettingsStore.load() } catch {
            internetCheckMessage = "Could not read saved Internet credentials. Try again."; return
        }
        guard let configuration = stored else {
            internetCheckMessage = "Configure Internet Connection in Settings first."
            return
        }
        let generation = internetCheckGeneration
        isCheckingInternet = true
        internetCheckMessage = "Checking device authorization and service configuration…"
        do {
            let status = try await CloudflareRealtimeSignalingClient.checkService(configuration, session: session)
            guard generation == internetCheckGeneration else { return }
            internetCheckMessage =
                """
                Authorized. \(status.activeSessions) active sessions. \
                Reserved \(status.reservedParticipantSeconds) / \(status.monthlyParticipantSeconds) \
                participant-seconds (\(status.month)). \
                Media and audio have not been tested.
                """
        } catch {
            guard generation == internetCheckGeneration else { return }
            internetCheckMessage = "Service check failed: \(error.localizedDescription)"
        }
        isCheckingInternet = false
    }
}

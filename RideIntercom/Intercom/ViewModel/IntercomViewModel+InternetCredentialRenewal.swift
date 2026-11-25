import Foundation
import RTC

extension IntercomViewModel {
    private var canRenewInternetCredential: Bool {
        canStartCalls && hasInternetCredentials && canPrepareInternetCredential
            && networkPathIsAvailable == true && !automaticInternetEnrollment.waitsForExecutionOpportunity
    }

    func reconcileInternetCredentialRenewal() {
        guard canRenewInternetCredential else {
            automaticInternetEnrollment.task?.cancel()
            return
        }
        guard automaticInternetEnrollment.task == nil, let principal = localAccountPrincipal,
              let configuration = try? internetSettingsStore.load(),
              let deviceID = try? internetSettingsStore.existingAccountDeviceID(),
              let signer = try? internetSettingsStore.credentialRenewalSigner(memberID: localMemberIdentity.memberID)
        else { return }
        if let identity = signer.identity, identity.expiresAt - callAccessNow().timeIntervalSince1970 > 48 * 3600 {
            return
        }
        automaticInternetEnrollment.retryDelay = 5
        automaticInternetEnrollment.task = Task { [weak self] in
            await self?.renewInternetCredential(configuration, principal: principal, deviceID: deviceID, signer: signer)
        }
    }

    private func renewInternetCredential(
        _ configuration: CloudflareRealtimeConfiguration, principal: AccountPrincipal,
        deviceID: String, signer: DeviceIdentitySigner
    ) async {
        defer {
            automaticInternetEnrollment.task = nil
            if Task.isCancelled || !hasInternetCredentials { reconcileAutomaticInternetEnrollment() }
        }
        while canRenewInternetCredential && !Task.isCancelled {
            do {
                try await withInternetEnrollmentTime {
                    guard try internetSettingsStore.load() == configuration else { throw CancellationError() }
                    guard let identity = try await automaticInternetEnrollment.client.renewDeviceIdentity(
                        configuration, userID: principal.userID, deviceID: deviceID, signer: signer
                    ) else { return }
                    try Task.checkCancellation()
                    guard canRenewInternetCredential, localAccountPrincipal == principal,
                          try internetSettingsStore.load() == configuration else { throw CancellationError() }
                    if let current = try? internetSettingsStore.loadIdentity(memberID: signer.memberID),
                       current.expiresAt >= identity.expiresAt { return }
                    try internetSettingsStore.save(
                        url: configuration.workerURL.absoluteString,
                        token: configuration.accessToken, identity: identity
                    )
                    synchronizeInternetServices()
                }
                return
            } catch {
                guard !Task.isCancelled, canRenewInternetCredential,
                      let delay = enrollmentRetryDelay(for: error) else { return }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
    }
}

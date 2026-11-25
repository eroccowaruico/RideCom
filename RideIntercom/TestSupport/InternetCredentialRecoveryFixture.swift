#if os(iOS) && DEBUG && RIDEINTERCOM_VALIDATION
import CallControl
import Foundation
import RTC
import UIKit

/// The UI suite controls the transport event and the result of registration.
/// The app still owns the saved credential, call generation, and notice.
@MainActor
final class InternetCredentialRecoveryFixture: CallSession {
    let settings: InternetConnectionSettingsStore
    private let origin: URL
    private weak var model: IntercomViewModel?
    private var rejectedCall: CallReference?
    private var retried = false
    private var foreground: Task<Void, Never>?

    var onEvent: ((TransportEvent) -> Void)?
    var processReceivedAudio: (@Sendable (RTC.ReceivedAudioPacket) -> AudioPacketReception)?
    let activeRouteDebugTypeName = "Validation transport"

    static func make(namespace: String, userID: String) -> InternetCredentialRecoveryFixture? {
        let environment = ProcessInfo.processInfo.environment
        guard namespace.hasPrefix("RideIntercom.Validation."), userID == AppleAccountFixture.userID,
              environment["RIDEINTERCOM_LOCAL_TESTING"] == "1",
              environment["RIDEINTERCOM_INTERNET_ACCOUNT_FIXTURE"] == "credential-recovery",
              let origin = URL(string: "https://127.0.0.1:9") else { return nil }
        return InternetCredentialRecoveryFixture(namespace: namespace + ".CredentialRecovery", origin: origin)
    }

    private init(namespace: String, origin: URL) {
        self.origin = origin
        settings = .init(keychain: MemoryKeychain(), namespace: namespace, fixedWorkerOrigin: origin)
        do {
            try settings.save(url: origin.absoluteString, token: "validation-previous")
        } catch { preconditionFailure("Could not prepare the validation credential") }
    }

    deinit { foreground?.cancel() }

    func bind(_ model: IntercomViewModel) {
        self.model = model
        foreground = Task { @MainActor [weak self] in
            let entries = NotificationCenter.default.notifications(named: UIApplication.willEnterForegroundNotification)
                .map { _ in () }
            for await _ in entries {
                guard let self else { return }
                if recover() { return }
            }
        }
    }

    func connect(group: IntercomGroup) {
        guard let model, rejectedCall == nil else { return }
        rejectedCall = model.currentCallReference
        model.groupDeliveryNetworkPathChanged(isAvailable: true)
        onEvent?(.serviceBlocked(.deviceCredentialRejected))
    }

    private func recover() -> Bool {
        guard let model, let rejectedCall else { return false }
        precondition(model.currentCallReference == rejectedCall)
        do {
            try model.saveInternetConnection(url: origin.absoluteString, token: "validation-replacement")
        } catch { preconditionFailure("Could not save the replacement validation credential") }
        precondition(model.currentCallReference == rejectedCall && retried)
        return true
    }

    func retryInternetRouteAfterCredentialChange() {
        precondition(!retried)
        retried = true
    }
    func makeAudioPacketSink(whileSourceIsActive: @escaping @Sendable () -> Bool)
        -> @Sendable (RTCAudioPacket) -> Void { { _ in } }
    func startMedia() {}
    func stopMedia() {}
    func disconnect() {}
    func setAudioPolicy(_ policy: RTCAudioPolicy) {}
    func setEnabledRoutes(_ routes: Set<RouteKind>) {}
    func setLocalMute(_ muted: Bool) {}
    func setOutputMute(_ muted: Bool) {}
    func updateRuntimePackageReports(_ reports: [RTCRuntimePackageReport]) {}
    func sendControl(_ message: ControlMessage) {}
    func sendApplicationData(_ message: ApplicationDataMessage) {}

    private final class MemoryKeychain: KeychainSecretStoring {
        private var values: [String: [String: String]] = [:]
        func accounts(service: String) -> [String] { Array((values[service] ?? [:]).keys) }
        func secret(service: String, account: String) -> String? { values[service]?[account] }
        func saveSecret(_ secret: String, service: String, account: String) {
            values[service, default: [:]][account] = secret
        }
        func createSecretIfAbsent(_ secret: String, service: String, account: String) -> String {
            if let existing = values[service]?[account] { return existing }
            saveSecret(secret, service: service, account: account)
            return secret
        }
        func deleteSecret(service: String, account: String) { values[service]?[account] = nil }
    }
}
#endif

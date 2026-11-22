import CloudKit
import Foundation
@testable import RideIntercom

@MainActor
final class CloudAccountFixture {
    let center = NotificationCenter()
    var account: String?
    var accountAfterRead: String?
    var afterRead: (() throws -> Void)?
    var pauseNextLookup = false
    var pausedLookup: CheckedContinuation<Void, Never>?
    var records: [String: CKRecord] = [:]
    var writtenAccounts: [String] = []

    init(account: String?) { self.account = account }

    var store: CloudKitCallRelationshipBackupStore {
        .init(fetch: { id in
            guard let active = self.account else { throw CKError(.notAuthenticated) }
            let record = self.records[active]
            if let next = self.accountAfterRead {
                self.account = next
                self.accountAfterRead = nil
            }
            guard let record, record.recordID == id else { throw CKError(.unknownItem) }
            let afterRead = self.afterRead
            self.afterRead = nil
            try afterRead?()
            return record
        }, write: { record, _ in
            guard let active = self.account else { throw CKError(.notAuthenticated) }
            self.records[active] = record
            self.writtenAccounts.append(active)
            return record
        })
    }

    func session(keychain: KeychainSecretStoring = DictionaryKeychain(),
                 directRestoreClient: InternetAccountClient? = nil) -> CloudKitCallRelationshipBackupSession {
        .init(store: store, keychain: keychain, namespace: "CloudFixture", center: center,
              directRestoreClient: directRestoreClient) {
            let found = self.account
            if self.pauseNextLookup {
                self.pauseNextLookup = false
                await withCheckedContinuation { self.pausedLookup = $0 }
            }
            return found.map { .init(container: "fixture", environment: .development, account: $0) }
        }
    }

    func finishPausedLookup() {
        pausedLookup?.resume()
        pausedLookup = nil
    }
}

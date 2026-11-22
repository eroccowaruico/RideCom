import CloudKit
import Foundation
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized)
struct CloudKitBackupSessionTests {
    @Test func lateAccountLookupCannotReplaceTheAccountFromTheChangeNotification() async throws {
        let accounts = AccountCallFixture(); defer { accounts.disconnect() }
        let model = try accounts.peer("rider", account: "a").viewModel
        _ = try addGroup(to: model)
        let cloud = CloudAccountFixture(account: "first")
        cloud.pauseNextLookup = true
        defer { cloud.finishPausedLookup() }
        let session = cloud.session()
        let app = AppCallOwner(account: model.accountSession, viewModel: model,
                               widgetDestinationStore: .init(fileURL: nil), backupSession: session)
        let earlier = try #require(session.task)
        await AppTestSupport.waitUntil { cloud.pausedLookup != nil }
        try #require(cloud.pausedLookup != nil)

        cloud.account = "second"
        cloud.center.post(name: .CKAccountChanged, object: nil)
        await session.task?.value
        let active = try #require(model.callRelationshipBackupSync)
        await active.task?.value
        cloud.finishPausedLookup()
        await earlier.value

        #expect(app.viewModel?.callRelationshipBackupSync === active)
        #expect(cloud.writtenAccounts == ["second"])
        #expect(cloud.records["first"] == nil)
    }

    @Test func accountChangingDuringReadIsCheckedAgainBeforeWriting() async throws {
        let accounts = AccountCallFixture(); defer { accounts.disconnect() }
        let model = try accounts.peer("rider", account: "a").viewModel
        let id = try addGroup(to: model)
        let cloud = CloudAccountFixture(account: "first")
        let session = cloud.session()
        let app = AppCallOwner(account: model.accountSession, viewModel: model,
                               widgetDestinationStore: .init(fileURL: nil), backupSession: session)
        await session.task?.value
        let original = try #require(model.callRelationshipBackupSync)
        await original.task?.value
        #expect(cloud.writtenAccounts == ["first"])

        cloud.accountAfterRead = "second"
        #expect(model.renameGroup(id, to: "Latest name"))
        await original.task?.value
        #expect(model.callRelationshipBackupSync == nil)
        #expect(cloud.writtenAccounts == ["first"])
        #expect(cloud.records["second"] == nil)

        app.systemSurfaceIsForeground = true
        await session.task?.value
        await model.callRelationshipBackupSync?.task?.value
        #expect(model.callRelationshipBackupSync?.status == .saved)
        #expect(cloud.writtenAccounts == ["first", "second"])
    }

    @Test func foregroundRetriesAnUnavailableICloudAccountWithoutChangingLocalData() async throws {
        let accounts = AccountCallFixture(); defer { accounts.disconnect() }
        let model = try accounts.peer("rider", account: "a").viewModel
        let id = try addGroup(to: model)
        let cloud = CloudAccountFixture(account: nil)
        let session = cloud.session()
        let app = AppCallOwner(account: model.accountSession, viewModel: model,
                               widgetDestinationStore: .init(fileURL: nil), backupSession: session)
        await session.task?.value
        #expect(model.callRelationshipBackupSync == nil)
        #expect(cloud.writtenAccounts.isEmpty)
        #expect(model.groups.map(\.id) == [id])

        cloud.account = "available"
        app.systemSurfaceIsForeground = true
        await session.task?.value
        await model.callRelationshipBackupSync?.task?.value
        #expect(cloud.writtenAccounts == ["available"])
        #expect(model.groups.map(\.id) == [id])
    }

    private func addGroup(to model: IntercomViewModel) throws -> UUID {
        let id = UUID()
        let member = model.localMemberIdentity.memberID
        let signer = try model.internetSettingsStore.invitationSigner(memberID: member)
        let binding = AccountDeviceBinding(principal: try #require(signer.principal), publicKey: signer.publicKey)
        let group = try IntercomGroup(id: id, name: "Riders", members: [.init(id: member, displayName: "Rider")],
                                      accountDevices: [member: binding])
        try #require(model.commitGroups([group]))
        return id
    }
}

@MainActor
private final class CloudAccountFixture {
    let center = NotificationCenter()
    var account: String?
    var accountAfterRead: String?
    var pauseNextLookup = false
    var pausedLookup: CheckedContinuation<Void, Never>?
    var records: [String: CKRecord] = [:]
    var writtenAccounts: [String] = []

    init(account: String?) { self.account = account }

    func session() -> CloudKitCallRelationshipBackupSession {
        let store = CloudKitCallRelationshipBackupStore(fetch: { id in
            guard let active = self.account else { throw CKError(.notAuthenticated) }
            let record = self.records[active]
            if let next = self.accountAfterRead {
                self.account = next
                self.accountAfterRead = nil
            }
            guard let record, record.recordID == id else { throw CKError(.unknownItem) }
            return record
        }, write: { record, _ in
            guard let active = self.account else { throw CKError(.notAuthenticated) }
            self.records[active] = record
            self.writtenAccounts.append(active)
            return record
        })
        return .init(store: store, keychain: DictionaryKeychain(), namespace: "CloudFixture", center: center) {
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

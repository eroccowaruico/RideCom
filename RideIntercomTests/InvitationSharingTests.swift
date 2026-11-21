import CoreTransferable
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import RideIntercom

@MainActor
struct InvitationSharingTests {
    @Test func diagnosticsNeverReadsOrCreatesInvitationKeys() throws {
        let keychain = DictionaryKeychain()
        let harness = AppTestSupport.makeHarness(
            internetSettingsStore: InternetConnectionSettingsStore(keychain: keychain, namespace: "lazy-share"),
            invitationAuthority: DirectInvitationAuthority(keychain: keychain, namespace: "lazy-share"))
        defer { harness.viewModel.disconnect() }
        let group = try #require(harness.viewModel.groups.first)
        harness.viewModel.selectedGroup = group
        let reads = keychain.readCount
        let snapshot = harness.groupStore.snapshot
        for _ in 0..<20 { _ = harness.viewModel.diagnosticsAppliedRows }
        #expect(keychain.readCount == reads)
        #expect(keychain.accounts(service: "lazy-share.DirectInvitations").isEmpty)
        #expect(keychain.accounts(service: "lazy-share.InternetConnection").isEmpty)
        #expect(harness.groupStore.snapshot == snapshot)
    }
    @Test func shareExportsNativeURLOnlyOnDemandAndUsesCurrentName() async throws {
        let keychain = DictionaryKeychain()
        let harness = AppTestSupport.makeHarness(
            internetSettingsStore: InternetConnectionSettingsStore(keychain: keychain, namespace: "share-export"),
            invitationAuthority: DirectInvitationAuthority(keychain: keychain, namespace: "share-export"))
        let viewModel = harness.viewModel; defer { viewModel.disconnect() }
        let group = try #require(viewModel.groups.first); viewModel.selectedGroup = group
        let reads = keychain.readCount
        let share = InvitationShare(viewModel: viewModel, groupID: group.id)
        #expect(viewModel.canShareSelectedGroup)
        #expect(InvitationShare.exportedContentTypes().contains(.url))
        #expect(keychain.readCount == reads)
        #expect(viewModel.setLocalDisplayName("Updated Rider"))
        let bytes = try await share.exported(as: .url)
        let url = try await URL(importing: bytes, contentType: .url)
        let token = try GroupInviteTokenCodec.decodeJoinURL(url)
        #expect(token.groupID == group.id && token.inviterDisplayName == "Updated Rider")
        #expect(keychain.readCount > reads)
        let another = try GroupInviteTokenCodec.decodeJoinURL(#require(viewModel.makeSelectedGroupInviteURL()))
        #expect(token.directInvitation?.context.id != another.directInvitation?.context.id)
    }

    @Test(arguments: ["selection", "deleted", "storage", "relogin"])
    func deferredShareRejectsChangedTargetOrAuthorization(change: String) async throws {
        let account = AccountFixture(); defer { account.remove() }; account.signIn()
        let harness = AppTestSupport.makeHarness(accountSession: account.session)
        let viewModel = harness.viewModel; defer { viewModel.disconnect() }
        let group = try #require(viewModel.groups.first); viewModel.selectedGroup = group
        let share = InvitationShare(viewModel: viewModel, groupID: group.id)
        switch change {
        case "selection":
            let other = try #require(viewModel.groups.last)
            viewModel.selectedGroup = other
            #expect(viewModel.selectedGroup?.id != group.id)
        case "deleted": viewModel.deleteGroup(group.id)
        case "storage": viewModel.groupStorageIssue = .unavailable
        default: account.session.signOut(); account.signIn()
        }
        await #expect(throws: (any Error).self) { try await share.exported(as: .url) }
    }

    @Test func storageChangedAfterPresentationCannotIssueKeysOrShare() async throws {
        let keychain = DictionaryKeychain()
        let harness = AppTestSupport.makeHarness(
            internetSettingsStore: InternetConnectionSettingsStore(keychain: keychain, namespace: "stale-share"),
            invitationAuthority: DirectInvitationAuthority(keychain: keychain, namespace: "stale-share"))
        let viewModel = harness.viewModel; defer { viewModel.disconnect() }
        let group = try #require(viewModel.groups.first); viewModel.selectedGroup = group
        let share = InvitationShare(viewModel: viewModel, groupID: group.id)
        #expect(viewModel.canShareSelectedGroup)
        harness.groupStore.snapshot.generation = UUID()
        await #expect(throws: (any Error).self) { try await share.exported(as: .url) }
        #expect(viewModel.groupStorageIssue != nil)
        #expect(keychain.accounts(service: "stale-share.DirectInvitations").isEmpty)
        #expect(keychain.accounts(service: "stale-share.InternetConnection").isEmpty)
    }

    /// Group Settings opened from a list row shares that group without changing which call is shown.
    @Test func settingsShareIsBoundToItsGroupNotTheSelection() async throws {
        let account = AccountFixture(); defer { account.remove() }; account.signIn()
        let harness = AppTestSupport.makeHarness(accountSession: account.session)
        let viewModel = harness.viewModel; defer { viewModel.disconnect() }
        let group = try #require(viewModel.groups.first(where: { $0.kind == .group }))
        let other = try #require(viewModel.groups.last(where: { $0.id != group.id }))
        viewModel.selectedGroup = other
        #expect(viewModel.canShareGroup(group.id))
        let share = InvitationShare(viewModel: viewModel, settingsGroupID: group.id)
        let url = try await URL(importing: share.exported(as: .url), contentType: .url)
        #expect(try GroupInviteTokenCodec.decodeJoinURL(url).groupID == group.id)
        #expect(viewModel.selectedGroup?.id == other.id, "Sharing from settings does not change the shown call")
        viewModel.deleteGroup(group.id)
        #expect(!viewModel.canShareGroup(group.id))
        await #expect(throws: (any Error).self) { try await share.exported(as: .url) }
    }
}

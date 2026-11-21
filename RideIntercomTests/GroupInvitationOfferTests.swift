import Foundation
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized) struct GroupInvitationOfferTests {
    @Test func aNewlyDeliveredGroupPersistsAnUnansweredTabOffer() throws {
        let authorDevice = GroupDeliveryTestIdentity("offer-author"),
            recipientDevice = GroupDeliveryTestIdentity("offer-recipient")
        defer { authorDevice.remove(); recipientDevice.remove() }
        try authorDevice.authorizeFixture(userID: String(repeating: "a", count: 64))
        try recipientDevice.authorizeFixture(userID: String(repeating: "b", count: 64))
        let harness = try recipientDevice.harness(knowing: [authorDevice]); defer { harness.viewModel.disconnect() }
        let now = Date(), id = UUID()
        let token = try GroupInviteToken.make(
            authority: testInvitationAuthority(), signer: authorDevice.signer, groupID: id,
            groupName: "Delivered group", groupSecret: "shared-key", inviterMemberID: authorDevice.memberID,
            issuedAt: now.timeIntervalSince1970,
            expiresAt: now.addingTimeInterval(3600).timeIntervalSince1970)
        let envelope = try GroupInvitationEnvelope.seal(
            token, sender: authorDevice.principal,
            recipient: .init(
                principal: recipientDevice.principal, memberID: recipientDevice.memberID,
                encryptionKey: recipientDevice.signer.publicKey),
            signer: authorDevice.signer, now: now)
        #expect(
            try harness.viewModel.groupRepository.stageGroupDelivery(
                envelope, token: token, now: now.timeIntervalSince1970) == .pending)
        #expect(harness.viewModel.groupTabInvitationOffer == nil)
        try harness.viewModel.groupRepository.receiveGroupDelivery(
            envelope, token: token, localDisplayName: "Me", now: now.timeIntervalSince1970)
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(harness.groupStore.snapshot)) as? [String: Any])
        let record = try #require((object["groups"] as? [[String: Any]])?.first)
        #expect(record["groupTabOfferAcknowledged"] as? Bool == false)
    }
    @Test func decliningCoversTheArrivedBatchAndSurvivesReload() throws {
        let groups = try [
            IntercomGroup(name: "First", members: [.init(id: "local", displayName: "Me")]),
            IntercomGroup(name: "Second", members: [.init(id: "local", displayName: "Me")])
        ]
        let store = InMemoryGroupStore(groups: groups)
        for index in store.snapshot.groups.indices {
            store.snapshot.groups[index].joinedByInvitation = true
            store.snapshot.groups[index].groupTabOfferAcknowledged = false
        }
        let harness = AppTestSupport.makeHarness(groups: groups, groupStore: store, localMemberID: "local")
        defer { harness.viewModel.disconnect() }
        let reference = harness.viewModel.currentCallReference
        let offer = try #require(harness.viewModel.groupTabInvitationOffer)
        #expect(harness.viewModel.renameGroup(offer.id, to: "Renamed invitation"))
        #expect(harness.viewModel.groupTabInvitationOffer?.name == "Renamed invitation")
        #expect(harness.viewModel.acknowledgeGroupTabInvitationOffer(offer.id))
        #expect(harness.viewModel.groupTabInvitationOffer == nil)
        #expect(store.snapshot.groups.allSatisfy { $0.groupTabOfferAcknowledged == true })
        harness.viewModel.reloadSavedGroups()
        #expect(harness.viewModel.groupTabInvitationOffer == nil && !harness.viewModel.showsGroupsTab)
        #expect(harness.viewModel.groups.count == 2 && harness.viewModel.currentCallReference == reference)
    }

    @Test func aFailedAcknowledgementKeepsTheOfferForReloadRecovery() throws {
        let group = try IntercomGroup(name: "Not lost", members: [.init(id: "local", displayName: "Me")])
        let store = InMemoryGroupStore(groups: [group]); store.snapshot.groups[0].joinedByInvitation = true
        store.snapshot.groups[0].groupTabOfferAcknowledged = false
        let harness = AppTestSupport.makeHarness(groups: [group], groupStore: store, localMemberID: "local")
        defer { harness.viewModel.disconnect() }
        store.failSaving = true
        #expect(!harness.viewModel.acknowledgeGroupTabInvitationOffer(group.id))
        #expect(
            harness.viewModel.groupStorageIssue != nil
                && store.snapshot.groups[0].groupTabOfferAcknowledged == false)
        store.failSaving = false; harness.viewModel.reloadSavedGroups()
        #expect(harness.viewModel.groupTabInvitationOffer?.id == group.id)
        #expect(harness.viewModel.acknowledgeGroupTabInvitationOffer(group.id))
    }

    @Test func legacyAndOwnedGroupsDoNotOfferAndAnActiveCallOrAdvancedModeDefersTheChoice() throws {
        let old = try IntercomGroup(name: "Legacy joined", members: [.init(id: "local", displayName: "Me")]),
            own = try IntercomGroup(name: "Owned", members: [.init(id: "local", displayName: "Me")])
        let store = InMemoryGroupStore(groups: [old, own]); store.snapshot.groups[0].joinedByInvitation = true
        let harness = AppTestSupport.makeHarness(groups: [old, own], groupStore: store, localMemberID: "local")
        defer { harness.viewModel.disconnect() }
        #expect(harness.viewModel.groupTabInvitationOffer == nil)
        store.snapshot.groups[0].groupTabOfferAcknowledged = false; harness.viewModel.reloadSavedGroups()
        #expect(harness.viewModel.groupTabInvitationOffer?.id == old.id)
        harness.viewModel.interfaceMode = .advanced
        #expect(
            harness.viewModel.groupTabInvitationOffer == nil
                && !harness.viewModel.acknowledgeGroupTabInvitationOffer(old.id))
        harness.viewModel.interfaceMode = .standard; harness.viewModel.showsGroupsTab = true
        #expect(harness.viewModel.groupTabInvitationOffer == nil)
        harness.viewModel.showsGroupsTab = false
        #expect(harness.viewModel.createTalkGroup(name: "Current conversation"))
        #expect(harness.viewModel.hasAnyActiveGroupConnection && harness.viewModel.groupTabInvitationOffer == nil)
        #expect(!harness.viewModel.acknowledgeGroupTabInvitationOffer(old.id))
        harness.viewModel.disconnect()
        #expect(harness.viewModel.groupTabInvitationOffer?.id == old.id)
    }

    @Test func explicitlyHidingTheVisibleGroupTabDoesNotOfferTheArrivedGroupsAgain() throws {
        let group = try IntercomGroup(name: "Already visible", members: [.init(id: "local", displayName: "Me")])
        let store = InMemoryGroupStore(groups: [group]); store.snapshot.groups[0].joinedByInvitation = true
        store.snapshot.groups[0].groupTabOfferAcknowledged = false
        let harness = AppTestSupport.makeHarness(groups: [group], groupStore: store, localMemberID: "local")
        defer { harness.viewModel.disconnect() }
        harness.viewModel.showsGroupsTab = true
        harness.viewModel.setShowsGroupsTab(false)
        #expect(harness.viewModel.groupTabInvitationOffer == nil)
        #expect(store.snapshot.groups[0].groupTabOfferAcknowledged == true)
    }

}

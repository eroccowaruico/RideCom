import Foundation
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized) struct GroupInvitationOfferTests {
    @Test func aNewlyDeliveredGroupPersistsAnUnansweredTabOffer() throws {
        let a = GroupDeliveryTestIdentity("offer-author"), b = GroupDeliveryTestIdentity("offer-recipient")
        defer { a.remove(); b.remove() }
        try a.authorizeFixture(userID: String(repeating: "a", count: 64)); try b.authorizeFixture(userID: String(repeating: "b", count: 64))
        let h = try b.harness(knowing: [a]); defer { h.viewModel.disconnect() }
        let now = Date(), id = UUID()
        let token = try GroupInviteToken.make(authority: testInvitationAuthority(), signer: a.signer, groupID: id,
            groupName: "Delivered group", groupSecret: "shared-key", inviterMemberID: a.memberID, issuedAt: now.timeIntervalSince1970,
            expiresAt: now.addingTimeInterval(3600).timeIntervalSince1970)
        let envelope = try GroupInvitationEnvelope.seal(token, sender: a.principal, recipient: b.principal,
            recipientMemberID: b.memberID, recipientKey: b.signer.publicKey, signer: a.signer, now: now)
        #expect(try h.viewModel.groupRepository.stageGroupDelivery(envelope, token: token, now: now.timeIntervalSince1970) == .pending)
        #expect(h.viewModel.groupTabInvitationOffer == nil)
        try h.viewModel.groupRepository.receiveGroupDelivery(envelope, token: token, localDisplayName: "Me", now: now.timeIntervalSince1970)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(h.groupStore.snapshot)) as? [String: Any])
        let record = try #require((object["groups"] as? [[String: Any]])?.first)
        #expect(record["groupTabOfferAcknowledged"] as? Bool == false)
    }
    @Test func decliningCoversTheArrivedBatchAndSurvivesReload() throws {
        let groups = try [IntercomGroup(name: "First", members: [.init(id: "local", displayName: "Me")]), IntercomGroup(name: "Second", members: [.init(id: "local", displayName: "Me")])]
        let store = InMemoryGroupStore(groups: groups)
        for index in store.snapshot.groups.indices { store.snapshot.groups[index].joinedByInvitation = true; store.snapshot.groups[index].groupTabOfferAcknowledged = false }
        let h = AppTestSupport.makeHarness(groups: groups, groupStore: store, localMemberID: "local")
        defer { h.viewModel.disconnect() }
        let reference = h.viewModel.currentCallReference
        let offer = try #require(h.viewModel.groupTabInvitationOffer)
        #expect(h.viewModel.renameGroup(offer.id, to: "Renamed invitation"))
        #expect(h.viewModel.groupTabInvitationOffer?.name == "Renamed invitation")
        #expect(h.viewModel.acknowledgeGroupTabInvitationOffer(offer.id))
        #expect(h.viewModel.groupTabInvitationOffer == nil)
        #expect(store.snapshot.groups.allSatisfy { $0.groupTabOfferAcknowledged == true })
        h.viewModel.reloadSavedGroups()
        #expect(h.viewModel.groupTabInvitationOffer == nil && !h.viewModel.showsGroupsTab)
        #expect(h.viewModel.groups.count == 2 && h.viewModel.currentCallReference == reference)
    }

    @Test func aFailedAcknowledgementKeepsTheOfferForReloadRecovery() throws {
        let group = try IntercomGroup(name: "Not lost", members: [.init(id: "local", displayName: "Me")])
        let store = InMemoryGroupStore(groups: [group]); store.snapshot.groups[0].joinedByInvitation = true; store.snapshot.groups[0].groupTabOfferAcknowledged = false
        let h = AppTestSupport.makeHarness(groups: [group], groupStore: store, localMemberID: "local")
        defer { h.viewModel.disconnect() }
        store.failSaving = true
        #expect(!h.viewModel.acknowledgeGroupTabInvitationOffer(group.id))
        #expect(h.viewModel.groupStorageIssue != nil && store.snapshot.groups[0].groupTabOfferAcknowledged == false)
        store.failSaving = false; h.viewModel.reloadSavedGroups()
        #expect(h.viewModel.groupTabInvitationOffer?.id == group.id)
        #expect(h.viewModel.acknowledgeGroupTabInvitationOffer(group.id))
    }

    @Test func legacyAndOwnedGroupsDoNotOfferAndAnActiveCallOrAdvancedModeDefersTheChoice() throws {
        let old = try IntercomGroup(name: "Legacy joined", members: [.init(id: "local", displayName: "Me")]), own = try IntercomGroup(name: "Owned", members: [.init(id: "local", displayName: "Me")])
        let store = InMemoryGroupStore(groups: [old, own]); store.snapshot.groups[0].joinedByInvitation = true
        let h = AppTestSupport.makeHarness(groups: [old, own], groupStore: store, localMemberID: "local")
        defer { h.viewModel.disconnect() }
        #expect(h.viewModel.groupTabInvitationOffer == nil)
        store.snapshot.groups[0].groupTabOfferAcknowledged = false; h.viewModel.reloadSavedGroups()
        #expect(h.viewModel.groupTabInvitationOffer?.id == old.id)
        h.viewModel.interfaceMode = .advanced
        #expect(h.viewModel.groupTabInvitationOffer == nil && !h.viewModel.acknowledgeGroupTabInvitationOffer(old.id))
        h.viewModel.interfaceMode = .standard; h.viewModel.showsGroupsTab = true
        #expect(h.viewModel.groupTabInvitationOffer == nil)
        h.viewModel.showsGroupsTab = false
        #expect(h.viewModel.createTalkGroup(name: "Current conversation"))
        #expect(h.viewModel.hasAnyActiveGroupConnection && h.viewModel.groupTabInvitationOffer == nil)
        #expect(!h.viewModel.acknowledgeGroupTabInvitationOffer(old.id))
        h.viewModel.disconnect()
        #expect(h.viewModel.groupTabInvitationOffer?.id == old.id)
    }

    @Test func explicitlyHidingTheVisibleGroupTabDoesNotOfferTheArrivedGroupsAgain() throws {
        let group = try IntercomGroup(name: "Already visible", members: [.init(id: "local", displayName: "Me")])
        let store = InMemoryGroupStore(groups: [group]); store.snapshot.groups[0].joinedByInvitation = true; store.snapshot.groups[0].groupTabOfferAcknowledged = false
        let h = AppTestSupport.makeHarness(groups: [group], groupStore: store, localMemberID: "local")
        defer { h.viewModel.disconnect() }
        h.viewModel.showsGroupsTab = true
        h.viewModel.setShowsGroupsTab(false)
        #expect(h.viewModel.groupTabInvitationOffer == nil)
        #expect(store.snapshot.groups[0].groupTabOfferAcknowledged == true)
    }

}

import CallControl
import CryptoKit
import Foundation
import Testing
import UserNotifications
@testable import RideIntercom

@MainActor
@Suite(.serialized)
struct GroupDeliveryFlowTests {
    @Test func selectingAKnownAccountQueuesEveryKnownDeviceInTheSameSave() throws {
        let peer = AccountPrincipal(issuer: "https://delivery.test", userID: String(repeating: "b", count: 64))
        let user = SavedUser(displayName: "Registered friend", memberIDs: ["friend-one", "friend-two"],
            deviceKeys: [
                "friend-one": testIdentitySigner("friend-one").publicKey,
                "friend-two": testIdentitySigner("friend-two").publicKey
            ], principal: peer)
        let store = InMemoryGroupStore(groups: []); store.snapshot.users = [user]
        let harness = AppTestSupport.makeHarness(groups: [], groupStore: store, localMemberID: "sender")
        defer { harness.viewModel.disconnect() }
        #expect(harness.viewModel.createTalkGroup(name: "Selected riders", userIDs: [user.id]))
        let group = try #require(harness.viewModel.groups.first)
        #expect(group.members.count == 2, "The same account still occupies one participant slot")
        #expect(harness.viewModel.groupRepository.groupDeliveries.count == 2)
        #expect(Set(harness.viewModel.groupRepository.groupDeliveries.map(\.noticeID)).count == 1)
        #expect(
            harness.viewModel.groupRepository.groupDeliveries.allSatisfy {
                $0.groupID == group.id && $0.state == .pending
            })
    }
    @Test func differentRecipientAccountsDoNotShareANotificationIdentifier() throws {
        let users = ["b", "c"].map { character in
            let member = "friend-" + character
            return SavedUser(
                displayName: member, memberIDs: [member], deviceKeys: [member: testIdentitySigner(member).publicKey],
                principal: AccountPrincipal(
                    issuer: "https://delivery.test", userID: String(repeating: character, count: 64)))
        }
        let store = InMemoryGroupStore(groups: []); store.snapshot.users = users
        let harness = AppTestSupport.makeHarness(groups: [], groupStore: store, localMemberID: "sender")
        defer { harness.viewModel.disconnect() }
        let records = harness.viewModel.groupDeliveryRecords(for: Set(users.map(\.id)), groupID: UUID())
        #expect(records.count == 2)
        #expect(
            Set(records.map(\.noticeID)).count == 2,
            "A recipient must not see a shared identifier linking other recipients")
    }

    @Test func aGroupMembersStateUsesTheirAccountAndKeepsOtherGroupsSeparate() throws {
        let peer = AccountPrincipal(issuer: "https://delivery.test", userID: String(repeating: "b", count: 64))
        let user = SavedUser(displayName: "Two devices", memberIDs: ["state-one", "state-two"],
            deviceKeys: [
                "state-one": testIdentitySigner("state-one").publicKey,
                "state-two": testIdentitySigner("state-two").publicKey
            ], principal: peer)
        let store = InMemoryGroupStore(groups: []); store.snapshot.users = [user]
        let harness = AppTestSupport.makeHarness(groups: [], groupStore: store, localMemberID: "state-sender")
        defer { harness.viewModel.disconnect() }
        #expect(harness.viewModel.createTalkGroup(name: "State after closing the sheet", userIDs: [user.id]))
        let group = try #require(harness.viewModel.groups.first)
        #expect(harness.viewModel.groupInvitationDeliveryState(forMember: "state-one", in: group.id) == .pending)
        #expect(harness.viewModel.groupInvitationDeliveries(in: group.id).count == 2)
        let record = try #require(harness.viewModel.groupRepository.groupDeliveries.first)
        try harness.viewModel.groupRepository.setGroupDeliveryState(record.id, state: .received)
        #expect(
            harness.viewModel.groupInvitationDeliveryState(forMember: "state-two", in: group.id) == .received,
            "One known device's receipt confirms the same person")
        #expect(harness.viewModel.groupInvitationDeliveryState(forMember: "unknown", in: group.id) == nil)
        let other = UUID()
        #expect(harness.viewModel.groupInvitationDeliveryState(forMember: "state-one", in: other) == nil)
        #expect(harness.viewModel.groupInvitationDeliveries(in: other).isEmpty)
    }

    @Test func aGroupInvitationNoticeIsNeverDecodedAsACallRequest() {
        let payload: [AnyHashable: Any] = ["version": 1, "kind": "groupInvitation", "requestID": UUID().uuidString,
            "recipientID": String(repeating: "a", count: 64)]
        #expect(CallNotificationTap(payload: payload) == nil)
        #expect(GroupInvitationTap(payload: payload) != nil)
        #expect(
            GroupInvitationTap(payload: [
                "version": 1, "requestID": UUID().uuidString, "recipientID": String(repeating: "a", count: 64)
            ]) == nil)
    }

    @Test func foregroundGroupInvitationOnlyAppearsInNotificationCenter() throws {
        let identity = GroupDeliveryTestIdentity("quiet-group-invitation")
        defer { identity.remove() }
        try identity.authorizeFixture(userID: String(repeating: "a", count: 64))
        let model = try identity.harness(knowing: []).viewModel
        defer { model.stopGroupDeliverySync(); model.disconnect() }
        let owner = AppCallOwner(account: model.accountSession, viewModel: model)
        owner.notificationBridge.bind(to: owner)
        let notice = try #require(GroupInvitationTap(payload: [
            "version": 1, "kind": "groupInvitation", "requestID": UUID().uuidString,
            "recipientID": try identity.principal.userID
        ]))
        let wrongRecipient = try #require(GroupInvitationTap(payload: [
            "version": 1, "kind": "groupInvitation", "requestID": UUID().uuidString,
            "recipientID": String(repeating: "b", count: 64)
        ]))

        #expect(owner.notificationBridge.groupPresentationOptions(for: notice) == [.list])
        #expect(model.activeGroupID == nil)
        #expect(model.createTalkGroup(name: "Keep this call"))
        let call = model.currentCallReference
        #expect(owner.notificationBridge.groupPresentationOptions(for: notice) == [.list])
        #expect(owner.notificationBridge.groupPresentationOptions(for: wrongRecipient).isEmpty)
        #expect(model.currentCallReference == call)
        #expect(owner.callPresentationID == nil && owner.groupsPresentationID == nil)
    }

    func grantGroupInvitationPermission(
        on model: IntercomViewModel,
        recipient: GroupDeliveryTestIdentity,
        sender: GroupDeliveryTestIdentity
    ) throws {
        let permission = try CallNotificationPermissionMessage.make(
            owner: recipient.principal,
            allowedSender: sender.principal,
            revision: 1,
            grant: nil,
            signer: recipient.signer,
            groupGrant: testCallNotificationGrant(
                owner: recipient.principal,
                allowedSender: sender.principal,
                audience: "rideintercom-group-invitation"
            ),
            groupInvitationsSupported: true
        )
        try model.notifications.receivePermission(permission, peerID: recipient.memberID)
    }

    func allowGroupDeliveryRequests(from devices: GroupDeliveryTestIdentity...) throws {
        var users: [String: String] = [:]
        for device in devices {
            let access = try #require(try device.store.notificationAccess(memberID: device.memberID))
            users[access.accessToken] = try device.principal.userID
        }
        GroupDeliveryHTTPStub.users = users
    }
}

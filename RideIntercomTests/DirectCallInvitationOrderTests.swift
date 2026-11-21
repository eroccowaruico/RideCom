import Foundation
import RTC
import Testing
@testable import RideIntercom

extension DirectCallTests {
    enum GroupInviteOrder: CaseIterable {
        case afterAcknowledgement, beforeAcknowledgement, beforeAcknowledgementWithSavedGroup
    }

    @Test(arguments: GroupInviteOrder.allCases)
    func signedGroupInvitationAndReplyPrepareSameSeparateDeviceCall(order: GroupInviteOrder) async throws {
        let group = try IntercomGroup(name: "Riders", members: [.init(id: "alice", displayName: "Alice")],
                                      accessSecret: "ordinary-group-key")
        let firstPeer = AppTestSupport.makeHarness(groups: [group], localMemberID: "alice")
        var savedGroup = group
        savedGroup.members.append(.init(id: "bob", displayName: "Bob"))
        let secondPeer = AppTestSupport.makeHarness(
            groups: order == .beforeAcknowledgementWithSavedGroup ? [savedGroup] : [], localMemberID: "bob")
        defer { firstPeer.viewModel.disconnect(); secondPeer.viewModel.disconnect() }
        firstPeer.viewModel.selectGroup(group)
        let url = try #require(firstPeer.viewModel.makeSelectedGroupInviteURL())
        try secondPeer.viewModel.acceptInviteURL(url)
        let alice = try #require(secondPeer.viewModel.savedRemoteUsers.first)
        #expect(secondPeer.viewModel.existingDirectCall(for: alice.id) == nil)
        var earlyCredential: GroupAccessCredential?
        if order != .afterAcknowledgement {
            #expect(secondPeer.viewModel.groupRepository.pendingInvitation(for: group.id) != nil)
            #expect(secondPeer.viewModel.selectUser(alice.id))
            let earlyCall = try #require(secondPeer.viewModel.selectedGroup)
            earlyCredential = try secondPeer.viewModel.groupRepository.credential(for: earlyCall.id)
            #expect(earlyCredential != nil)
            #expect(secondPeer.viewModel.activeGroupID == group.id)
        }
        firstPeer.callSession.authenticate(["bob"])
        secondPeer.callSession.authenticate(["alice"])
        secondPeer.viewModel.sendPendingInvitationReceipt()
        let message = try #require(secondPeer.callSession.sentApplicationDataMessages.last {
            $0.namespace == DirectInvitationReceipt.namespace
        })
        firstPeer.viewModel.receiveInvitationReceipt(peerID: "bob", message: message)
        let acknowledgement = try #require(firstPeer.callSession.sentApplicationDataMessages.last {
            $0.namespace == DirectInvitationReceipt.namespace
        })
        let bob = try #require(firstPeer.viewModel.savedRemoteUsers.first)
        let directID = try #require(firstPeer.viewModel.existingDirectCall(for: bob.id)?.id)
        let aliceKey = try #require(firstPeer.viewModel.groupRepository.credential(for: directID)?.secret)
        try await verifyEarlyCall(earlyCredential, call: (directID, aliceKey), order: order,
                                  peers: (firstPeer, secondPeer), group: group)
        secondPeer.viewModel.receiveInvitationReceipt(peerID: "alice", message: acknowledgement)
        #expect(secondPeer.viewModel.groupRepository.pendingInvitation(for: group.id) == nil)
        #expect(firstPeer.viewModel.activeGroupID == group.id)
        #expect(secondPeer.viewModel.activeGroupID == group.id)
        #expect(secondPeer.viewModel.existingDirectCall(for: alice.id)?.id == directID)
        #expect(directID != group.id)
        firstPeer.viewModel.receiveInvitationReceipt(peerID: "bob", message: message)
        secondPeer.viewModel.receiveInvitationReceipt(peerID: "alice", message: acknowledgement)

        try verifyReloadedCall(firstPeer: firstPeer, secondPeer: secondPeer, group: group,
                               directID: directID, aliceKey: aliceKey)
    }

    private func verifyEarlyCall(
        _ earlyCredential: GroupAccessCredential?, call: (UUID, String), order: GroupInviteOrder,
        peers: (AppTestSupport.Harness, AppTestSupport.Harness), group: IntercomGroup
    ) async throws {
        let (directID, aliceKey) = call
        let (firstPeer, secondPeer) = peers
        let alice = try #require(secondPeer.viewModel.savedRemoteUsers.first)
        let bob = try #require(firstPeer.viewModel.savedRemoteUsers.first)
        if let earlyCredential {
            let matchesBeforeAcknowledgement = earlyCredential.groupID == directID && earlyCredential.secret == aliceKey
            try #require(matchesBeforeAcknowledgement)
            if order == .beforeAcknowledgement {
                try #require(
                    firstPeer.viewModel.startCall(
                        to: .user(bob.id), accountAccessID: firstPeer.viewModel.accountAccessID))
                try #require(
                    secondPeer.viewModel.startCall(
                        to: .user(alice.id), accountAccessID: secondPeer.viewModel.accountAccessID))
                #expect(secondPeer.viewModel.groupRepository.pendingInvitation(for: group.id) != nil)
                #if os(iOS)
                try await Self.assertLocalCall(aliceGroup: try #require(firstPeer.callSession.connectedGroup),
                                          bobGroup: try #require(secondPeer.callSession.connectedGroup))
                #endif
                try #require(
                    firstPeer.viewModel.startCall(
                        to: .group(group.id), accountAccessID: firstPeer.viewModel.accountAccessID))
                try #require(
                    secondPeer.viewModel.startCall(
                        to: .group(group.id), accountAccessID: secondPeer.viewModel.accountAccessID))
                firstPeer.callSession.authenticate(["bob"])
                secondPeer.callSession.authenticate(["alice"])
            }
        }
    }

    private func verifyReloadedCall(
        firstPeer: AppTestSupport.Harness, secondPeer: AppTestSupport.Harness, group: IntercomGroup,
        directID: UUID, aliceKey: String
    ) throws {
        let alice = try #require(secondPeer.viewModel.savedRemoteUsers.first)
        let bob = try #require(firstPeer.viewModel.savedRemoteUsers.first)
        firstPeer.viewModel.disconnect()
        secondPeer.viewModel.disconnect()
        firstPeer.viewModel.reloadSavedGroups()
        secondPeer.viewModel.reloadSavedGroups()
        #expect(firstPeer.viewModel.selectUser(bob.id))
        #expect(secondPeer.viewModel.selectUser(alice.id))
        #expect(firstPeer.viewModel.selectedGroup?.id == directID)
        #expect(secondPeer.viewModel.selectedGroup?.id == directID)
        let matchingCredential = try secondPeer.viewModel.groupRepository.credential(for: directID)?.secret == aliceKey
        try #require(matchingCredential)
        let matchedAtCallStart = firstPeer.callSession.connectedGroup?.accessSecret == aliceKey
            && secondPeer.callSession.connectedGroup?.accessSecret == aliceKey
        #expect(matchedAtCallStart)
        let separateCredential = aliceKey != group.accessSecret
        #expect(separateCredential)
        #expect(firstPeer.viewModel.regularGroups.map(\.id) == [group.id])
        #expect(secondPeer.viewModel.regularGroups.map(\.id) == [group.id])
    }

}

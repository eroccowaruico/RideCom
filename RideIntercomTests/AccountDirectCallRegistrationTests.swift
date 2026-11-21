import CryptoKit
import Foundation
import RTC
import Testing
@testable import RideIntercom

extension AccountDirectCallTests {
    @Test func sharingThePreferredAccountCallKeyKeepsVerifiedDevicesFromOrdinaryInvitations() async throws {
        let fixture = AccountCallFixture(); defer { fixture.disconnect() }
        let author = try fixture.peer("alice", account: "a")
        let recipient = try fixture.peer("bob", account: "b")
        let authorTablet = try fixture.peer("alice-tablet", account: "a")
        let recipientTablet = try fixture.peer("bob-tablet", account: "b")
        for peer in [author, recipient, authorTablet, recipientTablet] {
            peer.viewModel.allowsNearbyGroupDelivery = false
        }
        try fixture.introduce(authorTablet, to: recipient)
        try fixture.introduce(author, to: recipient)
        try fixture.introduce(recipientTablet, to: author)
        try fixture.introduce(recipient, to: author)
        let firstPeer = author.viewModel, secondPeer = recipient.viewModel
        for viewModel in [firstPeer, secondPeer] {
            viewModel.disconnect()
            viewModel.setRTCTransportRoutes([.multipeer])
            let person = try #require(viewModel.savedRemoteUsers.first)
            try #require(viewModel.startCall(to: .user(person.id), accountAccessID: viewModel.accountAccessID))
        }
        let callID = try #require(firstPeer.activeGroupID)
        let recipientCall = try #require(secondPeer.activeDirectCall)
        try #require(recipientCall.id == callID)
        try #require(Set(recipientCall.accountDevices.keys) == ["alice", "alice-tablet", "bob"])
        let authorKey = try #require(try firstPeer.groupRepository.credential(for: callID))
        let recipientKey = try #require(try secondPeer.groupRepository.credential(for: callID))
        let conflictingKeys = authorKey != recipientKey
        try #require(conflictingKeys)
        let link = try #require(firstPeer.makeGroupInviteURL(for: callID))
        #expect(throws: GroupInviteTokenError.activeGroupKeyChanged) { try secondPeer.acceptInviteURL(link) }
        let preservesActiveKey = try secondPeer.groupRepository.credential(for: callID) == recipientKey
        #expect(preservesActiveKey)

        secondPeer.disconnect()
        try secondPeer.acceptInviteURL(link)
        let repaired = try #require(secondPeer.groupRepository.storedGroup(callID))
        let matchesSharedKey = try secondPeer.groupRepository.credential(for: callID) == authorKey
        try #require(matchesSharedKey)
        let keepsVerifiedDevices = repaired.accountDevices == recipientCall.accountDevices
        try #require(keepsVerifiedDevices)
        #expect(Set(repaired.members.map(\.id)) == Set(recipientCall.members.map(\.id)))
        #if os(iOS)
        try await DirectCallTests.assertLocalCall(aliceGroup: try #require(author.callSession.connectedGroup),
                                                   bobGroup: try #require(recipient.callSession.connectedGroup))
        #endif
    }

    @Test(arguments: [false, true])
    func accountCallSurvivesRegistrationThroughAnotherInvitation(creatorIsAuthor: Bool) async throws {
        let fixture = AccountCallFixture(); defer { fixture.disconnect() }
        let author = try fixture.peer("alice", account: "a")
        let recipient = try fixture.peer("bob", account: "b")
        let firstPeer = author.viewModel, secondPeer = recipient.viewModel
        firstPeer.allowsNearbyGroupDelivery = false
        secondPeer.allowsNearbyGroupDelivery = false
        try fixture.introduce(author, to: recipient)
        let ordinaryGroupID = try #require(firstPeer.selectedGroup?.id)
        let acceptance = try #require(secondPeer.signedPendingInvitationReceipt(for: ordinaryGroupID))
        let acknowledgement = try #require(firstPeer.applyInvitationReceipt(acceptance, from: "bob", standalone: true))
        _ = secondPeer.applyInvitationReceipt(acknowledgement, from: "alice", standalone: true)
        try #require(secondPeer.groupRepository.pendingInvitation(for: ordinaryGroupID) == nil)
        firstPeer.disconnect(); secondPeer.disconnect()

        let creator = creatorIsAuthor ? firstPeer : secondPeer
        let other = creatorIsAuthor ? secondPeer : firstPeer
        let creatorContact = try #require(creator.savedRemoteUsers.first)
        try #require(creator.selectUser(creatorContact.id, connectIfIdle: false))
        let id = try #require(creator.selectedGroup?.id)
        let initialKey = try #require(try creator.groupRepository.credential(for: id)).secret

        let newGroupID = try fixture.completeGroupContactRegistration(from: author, to: recipient)
        #expect(other.groups.contains { $0.id == newGroupID })
        for viewModel in [firstPeer, secondPeer] {
            viewModel.setRTCTransportRoutes([.multipeer])
            let person = try #require(viewModel.savedRemoteUsers.first)
            try #require(viewModel.startCall(to: .user(person.id), accountAccessID: viewModel.accountAccessID))
            try #require(viewModel.activeGroupID == id)
        }
        let creatorKeepsKey = try creator.groupRepository.credential(for: id)?.secret == initialKey
        let otherUsesSameKey = try other.groupRepository.credential(for: id)?.secret == initialKey
        #expect(creatorKeepsKey)
        try #require(otherUsesSameKey)
        #if os(iOS)
        try await DirectCallTests.assertLocalCall(aliceGroup: try #require(author.callSession.connectedGroup),
                                                   bobGroup: try #require(recipient.callSession.connectedGroup))
        #endif
    }

    @Test(arguments: [1, 7]) func groupContactRegistrationKeepsItsCallKeyWhenOnlyOneSideKnowsMoreDevices(
        otherDevices: Int
    ) async throws {
        let fixture = AccountCallFixture(); defer { fixture.disconnect() }
        let author = try fixture.peer("alice", account: "a")
        let recipient = try fixture.peer("bob", account: "b")
        let otherIDs = (0..<otherDevices).map { "another-bob-device-\($0)" }
        for id in otherIDs { try fixture.introduce(fixture.peer(id, account: "b"), to: author) }
        let groupID = try fixture.completeGroupContactRegistration(from: author, to: recipient)

        // Start at the regular Users entry point, after reloading both saved directories.
        let firstPeer = try fixture.restart(author), secondPeer = try fixture.restart(recipient)
        let authorContact = try #require(firstPeer.viewModel.savedRemoteUsers.first)
        let recipientContact = try #require(secondPeer.viewModel.savedRemoteUsers.first)
        try #require(Set(authorContact.memberIDs) == Set(otherIDs + ["bob"]))
        try #require(recipientContact.memberIDs == ["alice"])
        let deviceID = IntercomGroup.directCallID(memberIDs: ["alice", "bob"])
        let deviceKey = try #require(try firstPeer.viewModel.groupRepository.credential(for: deviceID)).secret
        try #require(try secondPeer.viewModel.groupRepository.credential(for: deviceID)?.secret == deviceKey)
        for (peer, person) in [(firstPeer, authorContact), (secondPeer, recipientContact)] {
            #expect(peer.viewModel.existingDirectCall(for: person.id) == nil)
            peer.viewModel.setRTCTransportRoutes([.multipeer])
            try #require(
                peer.viewModel.startCall(to: .user(person.id), accountAccessID: peer.viewModel.accountAccessID))
        }
        let callID = try #require(firstPeer.viewModel.activeGroupID)
        let accountCall = try #require(firstPeer.viewModel.activeDirectCall)
        #expect(accountCall.accountPair != nil)
        #expect(accountCall.accountDevices["bob"] != nil)
        #expect(accountCall.members.count == min(otherDevices + 2, IntercomGroup.maximumMemberCount))
        #expect(secondPeer.viewModel.activeGroupID == callID)
        let accountKey = try #require(try firstPeer.viewModel.groupRepository.credential(for: callID)).secret
        let usesMatchingAccountKey =
            try secondPeer.viewModel.groupRepository.credential(for: callID)?.secret == accountKey
        try #require(usesMatchingAccountKey)
        let keepsContactDeviceKeySeparate = accountKey != deviceKey
        #expect(keepsContactDeviceKeySeparate)
        let matchesGroupKey = try firstPeer.viewModel.groupRepository.credential(for: groupID)?.secret == deviceKey
        #expect(!matchesGroupKey)
        #if os(iOS)
        try await DirectCallTests.assertLocalCall(aliceGroup: try #require(firstPeer.callSession.connectedGroup),
                                                   bobGroup: try #require(secondPeer.callSession.connectedGroup))
        #endif
    }

    @Test(arguments: [false, true])
    func ordinaryGroupRegistrationKeepsItsCallKeyWhenOnlyOneSideKnowsMoreDevices(authorKnowsMore: Bool) async throws {
        let fixture = AccountCallFixture(); defer { fixture.disconnect() }
        let author = try fixture.peer("alice", account: "a")
        let recipient = try fixture.peer("bob", account: "b")
        let extra = try fixture.peer("other-device", account: authorKnowsMore ? "b" : "a")
        let firstPeer = author.viewModel, secondPeer = recipient.viewModel
        firstPeer.allowsNearbyGroupDelivery = false
        secondPeer.allowsNearbyGroupDelivery = false
        extra.viewModel.allowsNearbyGroupDelivery = false
        try fixture.introduce(extra, to: authorKnowsMore ? author : recipient)
        try fixture.introduce(author, to: recipient)
        let groupID = try #require(firstPeer.selectedGroup?.id)
        let acceptance = try #require(secondPeer.signedPendingInvitationReceipt(for: groupID))
        let activeCalls = (firstPeer.activeGroupID, secondPeer.activeGroupID)
        let acknowledgement = try #require(firstPeer.applyInvitationReceipt(acceptance, from: "bob", standalone: true))
        _ = secondPeer.applyInvitationReceipt(acknowledgement, from: "alice", standalone: true)
        try #require(secondPeer.groupRepository.pendingInvitation(for: groupID) == nil)
        #expect((firstPeer.activeGroupID, secondPeer.activeGroupID) == activeCalls)
        let authorSnapshot = author.groupStore.snapshot, recipientSnapshot = recipient.groupStore.snapshot
        #expect(firstPeer.applyInvitationReceipt(acceptance, from: "bob", standalone: true) != nil)
        _ = secondPeer.applyInvitationReceipt(acknowledgement, from: "alice", standalone: true)
        #expect(author.groupStore.snapshot == authorSnapshot && recipient.groupStore.snapshot == recipientSnapshot)

        let reloadedAuthor = try fixture.restart(author), reloadedRecipient = try fixture.restart(recipient)
        let authorContact = try #require(reloadedAuthor.viewModel.savedRemoteUsers.first)
        let recipientContact = try #require(reloadedRecipient.viewModel.savedRemoteUsers.first)
        try #require(Set(authorContact.memberIDs) == (authorKnowsMore ? ["bob", "other-device"] : ["bob"]))
        try #require(Set(recipientContact.memberIDs) == (authorKnowsMore ? ["alice"] : ["alice", "other-device"]))
        for (peer, person) in [(reloadedAuthor, authorContact), (reloadedRecipient, recipientContact)] {
            peer.viewModel.setRTCTransportRoutes([.multipeer])
            try #require(
                peer.viewModel.startCall(to: .user(person.id), accountAccessID: peer.viewModel.accountAccessID))
        }
        let callID = try #require(reloadedAuthor.viewModel.activeGroupID)
        try #require(reloadedRecipient.viewModel.activeGroupID == callID)
        let leftKey = try #require(try reloadedAuthor.viewModel.groupRepository.credential(for: callID)).secret
        let rightKey = try #require(try reloadedRecipient.viewModel.groupRepository.credential(for: callID)).secret
        let bothUseSameKey = leftKey == rightKey
        try #require(bothUseSameKey)
        let groupKey = try #require(try reloadedAuthor.viewModel.groupRepository.credential(for: groupID)).secret
        let keepsGroupKeySeparate = groupKey != leftKey
        #expect(keepsGroupKeySeparate)
        #if os(iOS)
        try await DirectCallTests.assertLocalCall(aliceGroup: try #require(reloadedAuthor.callSession.connectedGroup),
                                                   bobGroup: try #require(reloadedRecipient.callSession.connectedGroup))
        #endif
    }

    @Test func recipientWithSeveralKnownDevicesCanStartAnOrdinaryInvitationCallBeforeAcknowledgement() async throws {
        let fixture = AccountCallFixture(); defer { fixture.disconnect() }
        let author = try fixture.peer("alice", account: "a")
        let recipient = try fixture.peer("bob", account: "b")
        let extra = try fixture.peer("other-device", account: "a")
        for peer in [author, recipient, extra] { peer.viewModel.allowsNearbyGroupDelivery = false }
        let firstPeer = author.viewModel, secondPeer = recipient.viewModel
        try fixture.introduce(extra, to: recipient)
        let otherGroupID = try #require(secondPeer.selectedGroup?.id)
        try fixture.introduce(author, to: recipient)
        let groupID = try #require(firstPeer.selectedGroup?.id)
        let acceptance = try #require(secondPeer.signedPendingInvitationReceipt(for: groupID))
        let inviter = try #require(secondPeer.savedRemoteUsers.first)
        try #require(Set(inviter.memberIDs) == ["alice", "other-device"])
        #expect(
            secondPeer.groupRepository.pendingOrdinaryGroupDeviceCallKeys(
                for: inviter, localPrincipal: secondPeer.localAccountPrincipal,
                                                                    now: Date().timeIntervalSince1970) == nil)
        try #require(secondPeer.deleteGroup(otherGroupID))
        secondPeer.setRTCTransportRoutes([.multipeer])
        try #require(secondPeer.startCall(to: .user(inviter.id), accountAccessID: secondPeer.accountAccessID))
        let callID = try #require(secondPeer.activeGroupID)

        let acknowledgement = try #require(firstPeer.applyInvitationReceipt(acceptance, from: "bob", standalone: true))
        let invitee = try #require(firstPeer.savedRemoteUsers.first)
        firstPeer.setRTCTransportRoutes([.multipeer])
        try #require(firstPeer.startCall(to: .user(invitee.id), accountAccessID: firstPeer.accountAccessID))
        try #require(firstPeer.activeGroupID == callID)
        let authorKey = try #require(try firstPeer.groupRepository.credential(for: callID)).secret
        let recipientKey = try #require(try secondPeer.groupRepository.credential(for: callID)).secret
        let bothUseSameKey = authorKey == recipientKey
        try #require(bothUseSameKey)
        try #require(secondPeer.groupRepository.pendingInvitation(for: groupID) != nil)
        #if os(iOS)
        try await DirectCallTests.assertLocalCall(aliceGroup: try #require(author.callSession.connectedGroup),
                                                   bobGroup: try #require(recipient.callSession.connectedGroup))
        #endif

        _ = secondPeer.applyInvitationReceipt(acknowledgement, from: "alice", standalone: true)
        #expect(secondPeer.groupRepository.pendingInvitation(for: groupID) == nil)
        #expect(firstPeer.activeGroupID == callID && secondPeer.activeGroupID == callID)
        let keepsCallKey = try secondPeer.groupRepository.credential(for: callID)?.secret == recipientKey
        #expect(keepsCallKey)
    }

    @Test func twoSavedDeviceCallKeysAreNotChosenByDirectoryOrder() throws {
        let fixture = AccountCallFixture(); defer { fixture.disconnect() }
        let author = try fixture.peer("alice", account: "a")
        let phone = try fixture.peer("bob-phone", account: "b")
        let tablet = try fixture.peer("bob-tablet", account: "b")
        _ = try fixture.completeGroupContactRegistration(from: author, to: phone)
        _ = try fixture.completeGroupContactRegistration(from: author, to: tablet)
        let viewModel = try fixture.restart(author).viewModel
        let contact = try #require(viewModel.savedRemoteUsers.first)
        try #require(Set(contact.memberIDs) == ["bob-phone", "bob-tablet"])
        let deviceKeys = try contact.memberIDs.map { peerID in
            try #require(
                try viewModel.groupRepository.credential(for: IntercomGroup.directCallID(memberIDs: ["alice", peerID]))
            ).secret
        }
        let hasDistinctKeys = Set(deviceKeys).count == 2
        try #require(hasDistinctKeys)

        try #require(viewModel.selectUser(contact.id, connectIfIdle: false))
        let callID = try #require(viewModel.selectedGroup?.id)
        let accountKey = try #require(try viewModel.groupRepository.credential(for: callID)).secret
        let signer = try viewModel.internetSettingsStore.invitationSigner(memberID: "alice")
        let possibleAccountKeys = try contact.memberIDs.map { peerID in
            let publicKey = try #require(contact.deviceKeys?[peerID])
            return try signer.accountDirectCallSecret(peerMemberID: peerID, peerPublicKey: publicKey, callID: callID)
        }
        let selectedAnAmbiguousDevice = possibleAccountKeys.contains(accountKey) || deviceKeys.contains(accountKey)
        #expect(!selectedAnAmbiguousDevice)
    }

}

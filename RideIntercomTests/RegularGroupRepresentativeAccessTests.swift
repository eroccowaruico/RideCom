import CryptoKit
import Foundation
import RTC
import Testing
@testable import RideIntercom

extension RegularGroupRepresentativeTests {
    @Test(arguments: [false, true])
    func removingAMemberKeepsThatPersonOutWhenTheCallRestarts(internet: Bool) throws {
        let fixture = try RegularRepresentativeFixture(); defer { fixture.stop() }
        let viewModel = fixture.harness.viewModel
        let removed = try fixture.signer("phone")
        let secondDevice = try fixture.signer("tablet")
        let remaining = try fixture.signer("remaining", account: "c")
        fixture.harness.callSession.authenticate(["phone", "remaining"])
        try fixture.deliver(removed); try fixture.deliver(remaining)
        #expect(Set(viewModel.callAccessAdmittedMemberships.keys.map(\.rawValue)) == ["phone", "remaining"])
        let call = viewModel.currentCallReference
        #expect(viewModel.removeMember("phone", from: fixture.groupID))
        #expect(viewModel.currentCallReference == call)
        #expect(Set(viewModel.callAccessAdmittedMemberships.keys.map(\.rawValue)) == ["remaining"])
        viewModel.disconnect()
        viewModel.reloadSavedGroups()
        viewModel.selectGroup(try #require(viewModel.groups.first { $0.id == fixture.groupID }))
        viewModel.handleTransportEvent(.authenticated(members: ["phone", "tablet", "remaining"].map {
            .init(peer: .init(id: .init(rawValue: $0), displayName: $0),
                  route: internet ? .webRTC : .multipeer, isConnected: true, membershipID: UUID())
        }))
        try fixture.deliver(removed); try fixture.deliver(secondDevice); try fixture.deliver(remaining)
        #expect(Set(viewModel.groups[0].members.map(\.id)) == ["local", "remaining"])
        #expect(Set(viewModel.callAccessAdmittedMemberships.keys.map(\.rawValue)) == ["remaining"])
    }

    @Test func onlyExplicitlyAddingTheSavedPersonRestoresTheirGroupAccess() throws {
        let fixture = try RegularRepresentativeFixture(); defer { fixture.stop() }
        let viewModel = fixture.harness.viewModel, signer = try fixture.signer("phone")
        let secret = try #require(viewModel.groupRepository.credential(for: fixture.groupID)?.secret)
        let token = try GroupInviteToken.make(authority: testInvitationAuthority(), signer: signer,
            groupID: fixture.groupID, groupName: "Friends", groupSecret: secret, inviterMemberID: "phone")
        let link = try GroupInviteTokenCodec.joinURL(for: token)
        try viewModel.acceptInviteURL(link)
        let person = try #require(viewModel.savedRemoteUsers.first)
        #expect(viewModel.removeMember("phone", from: fixture.groupID))
        #expect(viewModel.savedRemoteUsers.first?.id == person.id)
        let excluded = try GroupSnapshot.decode(fixture.harness.groupStore.snapshot.encoded())
        #expect(excluded.groups.first?.removedMembers?.first?.principal == signer.principal)
        #expect(throws: (any Error).self) { try viewModel.acceptInviteURL(link) }
        #expect(viewModel.addSavedUsers([person.id], to: fixture.groupID))
        fixture.harness.callSession.authenticate(["phone"])
        try fixture.deliver(signer)
        #expect(viewModel.callAccessAdmittedMemberships.keys.map(\.rawValue) == ["phone"])
        #expect(fixture.harness.groupStore.snapshot.groups.first?.removedMembers == nil)
    }

    @Test func replacementCannotUseCopiedKeyDifferentAccountOrOldConnectionProof() throws {
        let fixture = try RegularRepresentativeFixture(); defer { fixture.stop() }
        let viewModel = fixture.harness.viewModel, first = try fixture.signer("phone")
        fixture.harness.callSession.authenticate(["phone"]); let old = try fixture.profile(first)
        try fixture.deliver(old)
        fixture.harness.callSession.authenticate([]); fixture.harness.callSession.authenticate(["phone"])
        try fixture.deliver(old)
        #expect(viewModel.peerProfiles["phone"]?.verified == nil)
        let forged = try fixture.signer("phone", key: P256.Signing.PrivateKey())
        try fixture.deliver(forged)
        #expect(viewModel.peerProfiles["phone"]?.verified == nil)
        try fixture.deliver(fixture.signer("phone", account: "c"))
        #expect(viewModel.peerProfiles["phone"]?.verified == nil)
        try fixture.deliver(first)
        #expect(viewModel.peerProfiles["phone"]?.verified != nil)
        #expect(viewModel.groups[0].accountDevices["phone"]?.principal == first.principal)
    }

    @Test func localOnlyPeersRemainDistinctAndUnauthenticatedDiscoveryCannotEvictAnyone() throws {
        let members =
            [GroupMember(id: "local", displayName: "You")]
            + (1...7).map { GroupMember(id: "peer-\($0)", displayName: "Rider \($0)") }
        let group = try IntercomGroup(name: "Full", members: members, accessSecret: "key")
        let harness = AppTestSupport.makeHarness(groups: [group]), viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        viewModel.selectGroup(group); harness.callSession.authenticate(["unknown"])
        #expect(viewModel.groups[0].members.map(\.id) == members.map(\.id))
        let fixture = try RegularRepresentativeFixture(); defer { fixture.stop() }
        fixture.harness.callSession.authenticate(["local-one", "local-two"])
        try fixture.deliver(testIdentitySigner("local-one")); try fixture.deliver(testIdentitySigner("local-two"))
        #expect(fixture.harness.viewModel.groups[0].members.count == 3)
        #expect(fixture.harness.viewModel.groups[0].accountDevices.count == 1) // Only our own certified binding.
        #expect(fixture.harness.viewModel.savedUsers.isEmpty)
    }

    @Test func deletingDirectContactPreservesGroupBindingNamesAndCallWithoutRestoringContact() throws {
        let fixture = try RegularRepresentativeFixture(); defer { fixture.stop() }
        let viewModel = fixture.harness.viewModel, first = try fixture.signer("phone"),
            second = try fixture.signer("tablet")
        let token = try GroupInviteToken.make(
            authority: testInvitationAuthority(), signer: first, groupID: fixture.groupID,
            groupName: "Friends", groupSecret: "replacement-key", inviterMemberID: "phone",
            inviterDisplayName: "Person")
        viewModel.disconnect(); try viewModel.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: token))
        let user = try #require(viewModel.savedRemoteUsers.first)
        #expect(fixture.harness.groupStore.snapshot.groups.first?.invitationDeviceKeys == ["phone": first.publicKey])
        #expect(viewModel.renameSavedUser(user.id, displayName: "Friend"))
        fixture.harness.callSession.authenticate(["phone"]); try fixture.deliver(first)
        fixture.harness.callSession.authenticate(["tablet"]); try fixture.deliver(second)
        #expect(fixture.harness.groupStore.snapshot.groups.first?.invitationDeviceKeys == nil)
        #expect(viewModel.groups[0].members.first { $0.id == "tablet" }?.resolvedDisplayName == "Friend")
        #expect(viewModel.availableUsers(for: fixture.groupID).isEmpty)
        #expect(viewModel.renameSavedUser(user.id, displayName: "Nickname"))
        #expect(viewModel.groups[0].members.first { $0.id == "tablet" }?.resolvedDisplayName == "Nickname")
        let reference = viewModel.currentCallReference
        #expect(viewModel.removeSavedUser(user.id))
        #expect(viewModel.savedUsers.isEmpty)
        try fixture.deliver(second, name: "Updated", revision: 2)
        #expect(viewModel.savedUsers.isEmpty)
        #expect(viewModel.currentCallReference == reference)
        #expect(viewModel.groups[0].members.first { $0.id == "tablet" }?.localName == "Nickname")
        #expect(!viewModel.startCall(to: .user(user.id), accountAccessID: viewModel.accountAccessID))
        #expect(viewModel.endCall(reference))
    }

    enum InvitationKeySource: String, CaseIterable { case groupLink, namedLink, namedReply }

    @Test(arguments: InvitationKeySource.allCases, [RouteKind.multipeer, .webRTC])
    func acceptedInvitationProtectsTheGroupMemberKeyAfterContactDeletion(
        source: InvitationKeySource, route: RouteKind
    ) throws {
        let author = AppTestSupport.makeHarness(groups: [], localMemberID: "inviter")
        let recipient = AppTestSupport.makeHarness(groups: [], localMemberID: "invitee")
        let authorModel = author.viewModel, recipientModel = recipient.viewModel
        authorModel.contactSessionFactory = { RecordingCallSession() }
        recipientModel.contactSessionFactory = { RecordingCallSession() }
        defer {
            authorModel.stopContactInvitationSession(); recipientModel.stopContactInvitationSession()
            authorModel.disconnect(); recipientModel.disconnect()
        }
        #expect(authorModel.createTalkGroup(name: "Friends"))
        let groupID = try #require(authorModel.selectedGroup?.id)
        try acceptRepresentativeInvitation(from: authorModel, to: recipientModel, groupID: groupID, source: source)

        let viewModel = source == .namedReply ? authorModel : recipientModel
        let peer = source == .namedReply ? recipientModel : authorModel
        let peerID = peer.localMemberIdentity.memberID
        let signer = try peer.internetSettingsStore.invitationSigner(memberID: peerID)
        #expect(signer.principal == nil)
        let replacement = try DeviceIdentitySigner(memberID: peerID, key: P256.Signing.PrivateKey())
        let contact = try #require(viewModel.savedRemoteUsers.first { $0.memberIDs.contains(peerID) })
        let credential = try viewModel.groupRepository.credential(for: groupID)
        #expect(viewModel.removeSavedUser(contact.id))
        viewModel.stopContactInvitationSession()
        viewModel.disconnect()
        viewModel.reloadSavedGroups()
        viewModel.selectGroup(try #require(viewModel.groups.first { $0.id == groupID }))

        try connectRepresentative(replacement, name: "Other identity", peerID: peerID, route: route, in: viewModel)
        #expect(viewModel.peerProfiles[peerID]?.verified == nil)
        #expect(!viewModel.callAccessAdmittedMemberships.keys.contains(.init(rawValue: peerID)))
        try connectRepresentative(signer, name: "Original identity", peerID: peerID, route: route, in: viewModel)
        #expect(viewModel.peerProfiles[peerID]?.verified?.identity.publicKey == signer.publicKey)
        #expect(viewModel.callAccessAdmittedMemberships.keys.contains(.init(rawValue: peerID)))
        #expect(
            viewModel.groupRepository.storedGroup(groupID)?.members.contains {
                $0.id == peerID && $0.displayName == "Original identity"
            } == true)
        #expect(try viewModel.groupRepository.credential(for: groupID) == credential)
        #expect(viewModel.savedRemoteUsers.isEmpty)
    }

    private func acceptRepresentativeInvitation(
        from authorModel: IntercomViewModel, to recipientModel: IntercomViewModel, groupID: UUID,
        source: InvitationKeySource
    ) throws {
        if source == .groupLink {
            try recipientModel.acceptInviteURL(try #require(authorModel.makeSelectedGroupInviteURL()))
        } else {
            let draft = GroupInvitationDraft(name: "Friend", suggestedName: "Friend")
            #expect(
                authorModel.saveGroupInvitations(
                    groupID: groupID, creating: false, name: "", selected: [], newPeople: [draft]) == groupID)
            let share = try authorModel.prepareContactPersonShare(
                draft.id, expectedAccountAccessID: authorModel.accountAccessID)
            try recipientModel.acceptContactInviteURL(share.url)
            recipientModel.stopContactInvitationSession()
            if source == .namedReply {
                try authorModel.receiveContactReplyURL(
                    recipientModel.contactReplyURLForSharing(
                        share.id, expectedAccountAccessID: recipientModel.accountAccessID))
            }
        }
    }

    private func connectRepresentative(
        _ signer: DeviceIdentitySigner, name: String, peerID: String, route: RouteKind, in viewModel: IntercomViewModel
    ) throws {
        viewModel.handleTransportEvent(.authenticated(members: [
            .init(peer: .init(id: .init(rawValue: peerID), displayName: "Rider"),
                  route: route, isConnected: true, membershipID: UUID())
        ]))
        let profile = try testPeerProfile(viewModel, peerID: peerID, displayName: name, revision: 1, signer: signer)
        viewModel.handleTransportEvent(.receivedApplicationData(peerID: peerID,
            message: .init(namespace: SharedDisplayName.namespace, payload: try JSONEncoder().encode(profile))))
    }

    @Test func failedReplacementSaveKeepsOldBindingAndDoesNotAdmitNewAudio() throws {
        let fixture = try RegularRepresentativeFixture(); defer { fixture.stop() }
        let viewModel = fixture.harness.viewModel
        fixture.harness.callSession.authenticate(["phone"]); try fixture.deliver(fixture.signer("phone"))
        let group = try #require(viewModel.groupRepository.storedGroup(fixture.groupID))
        fixture.harness.callSession.authenticate(["tablet"])
        fixture.harness.groupStore.failSaving = true
        try fixture.deliver(fixture.signer("tablet"))
        #expect(viewModel.groupRepository.storedGroup(fixture.groupID) == group)
        #expect(viewModel.peerProfiles["tablet"]?.verified == nil)
        #expect(viewModel.callAccessAdmittedMemberships.isEmpty)
        #expect(viewModel.hasAnyActiveGroupConnection)
        #expect(viewModel.groupStorageIssue != nil)
    }

    @Test func pendingSecondDeviceCannotSponsorOrKeepEstablishedConversationAlive() throws {
        let fixture = try RegularRepresentativeFixture(enforce: true); defer { fixture.stop() }
        let viewModel = fixture.harness.viewModel
        fixture.harness.callSession.authenticate(["phone"]); try fixture.deliver(fixture.signer("phone"))
        fixture.harness.callSession.authenticate(["phone", "tablet"]); try fixture.deliver(fixture.signer("tablet"))
        #expect(viewModel.peerProfiles["tablet"]?.verified == nil)
        let status = SharedCallAccess(groupID: fixture.groupID, recipientMemberID: "local",
            challenge: try #require(viewModel.peerProfiles["tablet"]?.challenge), revision: 1, hasActiveRight: true,
            activeUntil: nil, mediaReady: true, isEstablished: true, lastSponsoredStart: nil)
        let signed = try status.signed(by: fixture.signer("tablet"))
        viewModel.receiveCallAccess(
            peerID: "tablet",
            message: .init(namespace: SharedCallAccess.namespace, payload: try JSONEncoder().encode(signed)))
        #expect(viewModel.peerProfiles["tablet"]?.callAccess == nil)
        #expect(!viewModel.canPrepareCallMedia)
        _ = viewModel.callAccessState.establish(now: 100, sponsored: true, remoteEstablished: false, mediaReady: true)
        #expect(viewModel.callAccessState.isEstablished)
        fixture.harness.callSession.authenticate(["tablet"])
        #expect(!viewModel.callAccessState.isEstablished)
        #expect(viewModel.callAccessAdmittedMemberships.isEmpty)
    }

    @Test(arguments: [RouteKind.multipeer, .webRTC], [false, true])
    func verifiedCallStatusDoesNotGrantGroupManagement(route: RouteKind, certified: Bool) throws {
        let fixture = try RegularRepresentativeFixture(enforce: true)
        defer { fixture.stop() }
        let viewModel = fixture.harness.viewModel
        let peer = try certified ? fixture.signer("rider") : testIdentitySigner("rider")
        let peerID = peer.memberID
        func authenticateTransport() {
            viewModel.handleTransportEvent(.authenticated(members: [
                .init(peer: .init(id: .init(rawValue: peerID), displayName: "Rider"),
                      route: route, isConnected: true, membershipID: UUID())
            ]))
        }
        func receiveStatus(_ signed: SharedCallAccess) throws {
            viewModel.handleTransportEvent(.receivedApplicationData(peerID: peerID,
                message: .init(namespace: SharedCallAccess.namespace, payload: try JSONEncoder().encode(signed))))
        }

        authenticateTransport()
        let challenge = try #require(viewModel.peerProfiles[peerID]?.challenge)
        let status = try SharedCallAccess(groupID: fixture.groupID, recipientMemberID: "local",
            challenge: challenge, revision: 1, hasActiveRight: true, activeUntil: nil,
            mediaReady: false, isEstablished: false, lastSponsoredStart: nil).signed(by: peer)
        #expect(viewModel.groups.first?.members.map(\.id) == ["local"])
        try receiveStatus(status)
        #expect(viewModel.peerProfiles[peerID]?.callAccess == nil)
        #expect(!viewModel.canPrepareCallMedia)

        // This fixture has a device identity but no StoreKit evidence for the peer.
        try fixture.deliver(peer)
        let stored = try #require(viewModel.groupRepository.storedGroup(fixture.groupID))
        #expect(stored.members.map(\.id) == ["local", peerID])
        #expect(stored.accountDevices[peerID]?.principal == peer.principal)
        #expect(stored.accountDevices[peerID]?.publicKey == (certified ? peer.publicKey : nil))
        #expect(viewModel.savedUsers.isEmpty)
        try receiveStatus(status)
        #expect(viewModel.peerProfiles[peerID]?.callAccess == status)
        #expect(viewModel.canPrepareCallMedia)
        #expect(!viewModel.canManageRegularGroups)
        #expect(!viewModel.removeMember(peerID, from: fixture.groupID))
        #expect(viewModel.groupRepository.storedGroup(fixture.groupID) == stored)

        viewModel.disconnect()
        viewModel.reloadSavedGroups()
        viewModel.selectGroup(try #require(viewModel.groups.first { $0.id == fixture.groupID }))
        authenticateTransport()
        try fixture.deliver(peer)
        #expect(viewModel.peerProfiles[peerID]?.verified != nil)
        #expect(viewModel.peerProfiles[peerID]?.challenge != challenge)
        try receiveStatus(status)
        #expect(viewModel.peerProfiles[peerID]?.callAccess == nil)
        #expect(!viewModel.canPrepareCallMedia)
        #expect(!viewModel.canManageRegularGroups)
    }

    @Test func ownOtherDeviceDoesNotReplaceLocalRoleAndNormalSnapshotReloads() throws {
        let fixture = try RegularRepresentativeFixture(); defer { fixture.stop() }
        let viewModel = fixture.harness.viewModel
        fixture.harness.callSession.authenticate(["own-tablet"])
        try fixture.deliver(fixture.signer("own-tablet", account: "a"))
        #expect(viewModel.groups[0].members.map(\.id) == ["local"])
        #expect(viewModel.peerProfiles["own-tablet"]?.verified == nil)
        fixture.harness.callSession.authenticate(["phone"]); try fixture.deliver(fixture.signer("phone"))
        let bytes = try fixture.harness.groupStore.snapshot.encoded()
        let decoded = try GroupSnapshot.decode(bytes)
        #expect(decoded.groups[0].accountDevices.count == 2)
        #expect(try decoded.groups[0].group().members.first?.id == "local")
        #expect(decoded.users.isEmpty)
    }
}

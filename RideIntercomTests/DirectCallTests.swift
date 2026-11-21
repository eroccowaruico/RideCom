import Foundation
import RTC
import Testing
@testable import RideIntercom

@MainActor
struct DirectCallTests {
    @Test func issuedOrdinaryGroupInvitationSurvivesReloadOnlyWithItsOriginalGroupKey() throws {
        let storage = try GroupStorageFixture()
        defer { storage.remove() }
        let group = try storage.group()
        try storage.repository.save([group], credential: .init(groupID: group.id, secret: "original-fixture"))
        let app = AppTestSupport.makeHarness(groups: [], groupRepository: storage.repository, localMemberID: "local")
        defer { app.viewModel.disconnect() }
        let firstURL = try #require(app.viewModel.makeGroupInviteURL(for: group.id))
        let firstToken = try GroupInviteTokenCodec.decodeJoinURL(firstURL)
        let first = try #require(firstToken.directInvitation).context
        let secondURL = try #require(app.viewModel.makeGroupInviteURL(for: group.id))
        let secondToken = try GroupInviteTokenCodec.decodeJoinURL(secondURL)
        let second = try #require(secondToken.directInvitation).context
        #expect(first.id != second.id)
        let reopened = storage.restart()
        _ = try reopened.load(localMemberID: "local")
        let now = Date().timeIntervalSince1970
        #expect(reopened.issuedOrdinaryGroupInvitation(now: now)?.id == second.id)
        #expect(reopened.issuedOrdinaryGroupInvitation(now: second.expiresAt)?.id == nil)
        let retained = try storage.file.read()
        let saved = try #require(retained)
        #expect(saved.lastIssuedOrdinaryGroupInvitation?.credentialReference == saved.groups.first?.credentialReference)

        try reopened.save([group], credential: .init(groupID: group.id, secret: "replacement-fixture"))
        #expect(try storage.file.read()?.lastIssuedOrdinaryGroupInvitation == nil)
        let updated = AppTestSupport.makeHarness(groups: [], groupRepository: reopened, localMemberID: "local")
        defer { updated.viewModel.disconnect() }
        _ = try #require(updated.viewModel.makeGroupInviteURL(for: group.id))
        try reopened.delete(group.id, remaining: [])
        #expect(try storage.file.read()?.lastIssuedOrdinaryGroupInvitation == nil)
    }

    @Test func ordinaryTwoMemberGroupRemainsAGroup() throws {
        let group = try IntercomGroup(name: "Two Riders", members: [
            .init(id: "alice", displayName: "Alice"),
            .init(id: "bob", displayName: "Bob")
        ], accessSecret: "group-key")
        let h = AppTestSupport.makeHarness(groups: [group], localMemberID: "alice")
        defer { h.viewModel.disconnect() }
        #expect(group.kind == .group)
        #expect(h.viewModel.regularGroups.map(\.id) == [group.id])
        #expect(h.viewModel.activeDirectCall == nil)
    }

    enum GroupInviteOrder: CaseIterable {
        case afterAcknowledgement, beforeAcknowledgement, beforeAcknowledgementWithSavedGroup
    }

    @Test(arguments: GroupInviteOrder.allCases)
    func signedGroupInvitationAndReplyPrepareSameSeparateDeviceCall(order: GroupInviteOrder) async throws {
        let group = try IntercomGroup(name: "Riders", members: [.init(id: "alice", displayName: "Alice")],
                                      accessSecret: "ordinary-group-key")
        let a = AppTestSupport.makeHarness(groups: [group], localMemberID: "alice")
        var savedGroup = group
        savedGroup.members.append(.init(id: "bob", displayName: "Bob"))
        let b = AppTestSupport.makeHarness(groups: order == .beforeAcknowledgementWithSavedGroup ? [savedGroup] : [], localMemberID: "bob")
        defer { a.viewModel.disconnect(); b.viewModel.disconnect() }
        a.viewModel.selectGroup(group)
        let url = try #require(a.viewModel.makeSelectedGroupInviteURL())
        try b.viewModel.acceptInviteURL(url)
        let alice = try #require(b.viewModel.savedRemoteUsers.first)
        #expect(b.viewModel.existingDirectCall(for: alice.id) == nil)
        var earlyCredential: GroupAccessCredential?
        if order != .afterAcknowledgement {
            #expect(b.viewModel.groupRepository.pendingInvitation(for: group.id) != nil)
            #expect(b.viewModel.selectUser(alice.id))
            let earlyCall = try #require(b.viewModel.selectedGroup)
            let savedCredential = try b.viewModel.groupRepository.credential(for: earlyCall.id)
            earlyCredential = try #require(savedCredential)
            #expect(b.viewModel.activeGroupID == group.id)
        }
        a.callSession.authenticate(["bob"])
        b.callSession.authenticate(["alice"])
        b.viewModel.sendPendingInvitationReceipt()
        let message = try #require(b.callSession.sentApplicationDataMessages.last {
            $0.namespace == DirectInvitationReceipt.namespace
        })
        a.viewModel.receiveInvitationReceipt(peerID: "bob", message: message)
        let acknowledgement = try #require(a.callSession.sentApplicationDataMessages.last {
            $0.namespace == DirectInvitationReceipt.namespace
        })
        let bob = try #require(a.viewModel.savedRemoteUsers.first)
        let directID = try #require(a.viewModel.existingDirectCall(for: bob.id)?.id)
        let aliceKey = try #require(a.viewModel.groupRepository.credential(for: directID)?.secret)
        if let earlyCredential {
            let matchesBeforeAcknowledgement = earlyCredential.groupID == directID && earlyCredential.secret == aliceKey
            try #require(matchesBeforeAcknowledgement)
            if order == .beforeAcknowledgement {
                try #require(a.viewModel.startCall(to: .user(bob.id), accountAccessID: a.viewModel.accountAccessID))
                try #require(b.viewModel.startCall(to: .user(alice.id), accountAccessID: b.viewModel.accountAccessID))
                #expect(b.viewModel.groupRepository.pendingInvitation(for: group.id) != nil)
                #if os(iOS)
                try await Self.assertLocalCall(aliceGroup: try #require(a.callSession.connectedGroup),
                                          bobGroup: try #require(b.callSession.connectedGroup))
                #endif
                try #require(a.viewModel.startCall(to: .group(group.id), accountAccessID: a.viewModel.accountAccessID))
                try #require(b.viewModel.startCall(to: .group(group.id), accountAccessID: b.viewModel.accountAccessID))
                a.callSession.authenticate(["bob"])
                b.callSession.authenticate(["alice"])
            }
        }
        b.viewModel.receiveInvitationReceipt(peerID: "alice", message: acknowledgement)
        #expect(b.viewModel.groupRepository.pendingInvitation(for: group.id) == nil)
        #expect(a.viewModel.activeGroupID == group.id)
        #expect(b.viewModel.activeGroupID == group.id)
        #expect(b.viewModel.existingDirectCall(for: alice.id)?.id == directID)
        #expect(directID != group.id)
        a.viewModel.receiveInvitationReceipt(peerID: "bob", message: message)
        b.viewModel.receiveInvitationReceipt(peerID: "alice", message: acknowledgement)

        a.viewModel.disconnect()
        b.viewModel.disconnect()
        a.viewModel.reloadSavedGroups()
        b.viewModel.reloadSavedGroups()
        #expect(a.viewModel.selectUser(bob.id))
        #expect(b.viewModel.selectUser(alice.id))
        #expect(a.viewModel.selectedGroup?.id == directID)
        #expect(b.viewModel.selectedGroup?.id == directID)
        let matchingCredential = try b.viewModel.groupRepository.credential(for: directID)?.secret == aliceKey
        try #require(matchingCredential)
        let matchedAtCallStart = a.callSession.connectedGroup?.accessSecret == aliceKey
            && b.callSession.connectedGroup?.accessSecret == aliceKey
        #expect(matchedAtCallStart)
        let separateCredential = aliceKey != group.accessSecret
        #expect(separateCredential)
        #expect(a.viewModel.regularGroups.map(\.id) == [group.id])
        #expect(b.viewModel.regularGroups.map(\.id) == [group.id])
    }

    @Test func multiplePendingOrdinaryInvitationsDoNotChooseAReceiptForAnIndividualCall() throws {
        let member = GroupMember(id: "alice", displayName: "Alice")
        let first = try IntercomGroup(name: "First", members: [member], accessSecret: "first-fixture")
        let second = try IntercomGroup(name: "Second", members: [member], accessSecret: "second-fixture")
        let a = AppTestSupport.makeHarness(groups: [first, second], localMemberID: "alice")
        let b = AppTestSupport.makeHarness(groups: [], localMemberID: "bob")
        defer { a.viewModel.disconnect(); b.viewModel.disconnect() }
        a.viewModel.selectGroup(first)
        try b.viewModel.acceptInviteURL(try #require(a.viewModel.makeSelectedGroupInviteURL()))
        let alice = try #require(b.viewModel.savedRemoteUsers.first)
        let now = Date().timeIntervalSince1970
        #expect(b.viewModel.groupRepository.pendingOrdinaryGroupReceipt(for: alice, now: now)?.groupID == first.id)
        a.viewModel.selectGroup(second)
        try b.viewModel.acceptInviteURL(try #require(a.viewModel.makeSelectedGroupInviteURL()))
        #expect(b.viewModel.groupRepository.pendingInvitation(for: first.id) != nil)
        #expect(b.viewModel.groupRepository.pendingInvitation(for: second.id) != nil)
        #expect(b.viewModel.groupRepository.pendingOrdinaryGroupReceipt(for: alice, now: now) == nil)
        #expect(b.viewModel.existingDirectCall(for: alice.id) == nil)
    }

    #if os(iOS)
    fileprivate static func assertLocalCall(aliceGroup: IntercomGroup, bobGroup: IntercomGroup) async throws {
        let aliceRTC = RouteManager(routes: [LocalCallRoute()])
        let bobRTC = RouteManager(routes: [LocalCallRoute()])
        let alice = RideIntercomCallSessionAdapter(memberID: "alice", rtcSession: aliceRTC)
        let bob = RideIntercomCallSessionAdapter(memberID: "bob", rtcSession: bobRTC)
        let payload = Data(repeating: 42, count: 160)
        var alicePeers: [String] = [], bobPeers: [String] = []
        var receivedAudio = false
        alice.onEvent = { event in
            if case .authenticated(let members) = event { alicePeers = members.map(\.peer.id.rawValue) }
        }
        bob.processReceivedAudio = { _ in .processed(level: 0.1) }
        bob.onEvent = { event in
            if case .authenticated(let members) = event { bobPeers = members.map(\.peer.id.rawValue) }
            if case .receivedAudioPacket(let received, _) = event, received.packet.payload == payload {
                receivedAudio = true
            }
        }
        alice.setAudioPolicy(.init()); bob.setAudioPolicy(.init())
        alice.connect(group: aliceGroup); bob.connect(group: bobGroup)
        alice.startMedia(); bob.startMedia()
        await AppTestSupport.waitUntil(timeout: .seconds(12)) { alicePeers == ["bob"] && bobPeers == ["alice"] }
        let authenticated = alicePeers == ["bob"] && bobPeers == ["alice"]
        if authenticated {
            for sequence: UInt64 in 0..<40 {
                alice.sendAudioPacket(.init(sequenceNumber: sequence, codec: .pcm16, payload: payload))
                try? await Task.sleep(for: .milliseconds(50))
                if receivedAudio { break }
            }
        }
        await aliceRTC.stopConnection(); await bobRTC.stopConnection()
        #expect(authenticated)
        #expect(receivedAudio)
    }
    #endif

    @Test func selectingSavedUserCreatesAndReusesSeparateCallWithoutSwitchingActiveGroup() throws {
        let h = try harness(local: "alice", remote: "bob")
        let vm = h.viewModel
        defer { vm.disconnect() }
        let original = try #require(vm.groups.first)
        let user = try #require(vm.savedRemoteUsers.first)
        let active = vm.activeGroupID
        let disconnects = h.callSession.disconnectCallCount
        #expect(vm.selectUser(user.id))
        let direct = try #require(vm.selectedGroup)
        #expect(direct.kind == .direct)
        #expect(direct.id != original.id)
        #expect(vm.regularGroups.map(\.id) == [original.id])
        #expect(vm.activeGroupID == active)
        #expect(h.callSession.disconnectCallCount == disconnects)
        let credential = try #require(try vm.groupRepository.credential(for: direct.id))
        vm.showGroupSelection()
        #expect(vm.selectUser(user.id))
        #expect(vm.selectedGroup?.id == direct.id)
        #expect(try vm.groupRepository.credential(for: direct.id) == credential)
        #expect(vm.groups.count == 2)
        vm.connectLocal()
        #expect(vm.activeGroupID == direct.id)
    }

    @Test func onlySavedDirectContactsCanResolveCallsAndDeletionEndsTheirCall() throws {
        let h = try harness(local: "alice", remote: "bob")
        let vm = h.viewModel
        defer { vm.disconnect() }
        #expect(!vm.selectUser(UUID()))
        let user = try #require(vm.savedRemoteUsers.first)
        #expect(vm.selectUser(user.id))
        let direct = try #require(vm.selectedGroup)
        vm.connectLocal()
        #expect(vm.removeSavedUser(user.id))
        #expect(vm.activeGroupID == nil)
        #expect(!vm.groups.contains { $0.id == direct.id })
        #expect(!vm.selectUser(user.id))
        #expect(vm.makeSelectedGroupInviteURL() == nil)
    }

    /// The call's More menu finds User Settings through the direct call; removing the
    /// saved user removes the direct call with them.
    @Test func directCallMoreMenuFollowsTheSavedUser() throws {
        let h = try harness(local: "alice", remote: "bob")
        let vm = h.viewModel
        defer { vm.disconnect() }
        let user = try #require(vm.savedRemoteUsers.first)
        #expect(vm.selectUser(user.id))
        let direct = try #require(vm.selectedGroup)
        #expect(vm.savedUserID(forDirectCall: direct) == user.id)
        #expect(vm.existingDirectCall(for: user.id)?.id == direct.id)
        vm.connectLocal()
        #expect(vm.isInCall(with: .user(user.id)))
        #expect(vm.removeSavedUser(user.id))
        #expect(vm.savedUserID(forDirectCall: direct) == nil)
        #expect(vm.existingDirectCall(for: user.id) == nil)
    }

    @Test func recipientBoundInviteIsSharedAndReusesSameCallOnBothSides() throws {
        let a = try harness(local: "alice", remote: "bob")
        let b = try harness(local: "bob", remote: "alice")
        defer { a.viewModel.disconnect(); b.viewModel.disconnect() }
        #expect(a.viewModel.selectUser(try #require(a.viewModel.savedRemoteUsers.first).id))
        let invite = try #require(a.viewModel.makeSelectedGroupInviteURL())
        let token = try GroupInviteTokenCodec.decodeJoinURL(invite)
        #expect(token.recipientMemberID == "bob")
        #expect(token.version == 6)
        try b.viewModel.acceptInviteURL(invite)
        #expect(b.viewModel.selectedGroup?.kind == .direct)
        let id = try #require(a.viewModel.selectedGroup?.id)
        #expect(b.viewModel.selectedGroup?.id == id)
        #expect(try a.viewModel.groupRepository.credential(for: id) == b.viewModel.groupRepository.credential(for: id))
        b.viewModel.showGroupSelection()
        #expect(b.viewModel.selectUser(try #require(b.viewModel.savedRemoteUsers.first).id))
        #expect(b.viewModel.selectedGroup?.id == id)
        #expect(b.viewModel.groups.count == 2)
    }

    @Test func forwardedInviteCannotCreateContactOrCallForThirdPerson() throws {
        let a = try harness(local: "alice", remote: "bob")
        let c = try harness(local: "charlie", remote: "dana")
        defer { a.viewModel.disconnect(); c.viewModel.disconnect() }
        #expect(a.viewModel.selectUser(try #require(a.viewModel.savedRemoteUsers.first).id))
        let before = c.groupStore.snapshot
        let invite = try #require(a.viewModel.makeSelectedGroupInviteURL())
        #expect(throws: GroupInviteTokenError.wrongRecipient) { try c.viewModel.acceptInviteURL(invite) }
        #expect(c.groupStore.snapshot == before)
    }

    @Test func directCallCannotGrowIntoGroup() throws {
        let h = try harness(local: "alice", remote: "bob")
        let vm = h.viewModel
        defer { vm.disconnect() }
        let user = try #require(vm.savedRemoteUsers.first)
        #expect(vm.selectUser(user.id))
        let group = try #require(vm.selectedGroup)
        vm.reserveInviteMemberSlot()
        vm.removeMember("bob", from: group.id)
        #expect(!vm.addSavedUsers([user.id], to: group.id))
        #expect(vm.selectedGroup?.members.map(\.id) == ["alice", "bob"])
    }

    @Test func simultaneousInvitationsConvergeWithoutCreatingAnotherCall() throws {
        let a = try harness(local: "alice", remote: "bob")
        let b = try harness(local: "bob", remote: "alice")
        defer { a.viewModel.disconnect(); b.viewModel.disconnect() }
        #expect(a.viewModel.selectUser(try #require(a.viewModel.savedRemoteUsers.first).id))
        #expect(b.viewModel.selectUser(try #require(b.viewModel.savedRemoteUsers.first).id))
        let left = try #require(a.viewModel.makeSelectedGroupInviteURL())
        let right = try #require(b.viewModel.makeSelectedGroupInviteURL())
        try a.viewModel.acceptInviteURL(right)
        #expect(a.viewModel.crossedDirectCallToShare?.id == a.viewModel.selectedGroup?.id)
        try b.viewModel.acceptInviteURL(left)
        #expect(b.viewModel.crossedDirectCallToShare == nil)
        let id = try #require(a.viewModel.selectedGroup?.id)
        #expect(try a.viewModel.groupRepository.credential(for: id) == b.viewModel.groupRepository.credential(for: id))
        #expect(a.viewModel.groups.count == 2)
        #expect(b.viewModel.groups.count == 2)
        a.viewModel.showGroupSelection()
        #expect(a.viewModel.crossedDirectCallToShare == nil)
    }

    @Test func directCallSurvivesRestartAndRenamingWithoutChangingKey() throws {
        let h = try harness(local: "alice", remote: "bob")
        let vm = h.viewModel
        defer { vm.disconnect() }
        let user = try #require(vm.savedRemoteUsers.first)
        #expect(vm.selectUser(user.id))
        let id = try #require(vm.selectedGroup?.id)
        let key = try vm.groupRepository.credential(for: id)
        #expect(vm.renameSavedUser(user.id, displayName: "Bobby"))
        #expect(vm.selectedCallTitle == "Bobby")
        vm.disconnect()
        vm.reloadSavedGroups()
        #expect(vm.selectUser(user.id))
        #expect(vm.selectedGroup?.id == id)
        #expect(vm.selectedGroup?.kind == .direct)
        #expect(vm.selectedCallTitle == "Bobby")
        #expect(try vm.groupRepository.credential(for: id) == key)
        #expect(vm.regularGroups.count == 1)
    }

    @Test func failedPersistenceDoesNotSelectOrConnectAnotherCall() throws {
        let h = try harness(local: "alice", remote: "bob")
        let vm = h.viewModel
        defer { vm.disconnect() }
        let before = h.groupStore.snapshot
        let selected = vm.selectedGroup?.id
        h.groupStore.failSaving = true
        #expect(!vm.selectUser(try #require(vm.savedRemoteUsers.first).id))
        #expect(h.groupStore.snapshot == before)
        #expect(vm.selectedGroup?.id == selected)
        #expect(vm.activeGroupID == selected)
    }

    @Test func unexpectedAuthenticatedParticipantStopsDirectCall() throws {
        let h = try harness(local: "alice", remote: "bob")
        let vm = h.viewModel
        defer { vm.disconnect() }
        #expect(vm.selectUser(try #require(vm.savedRemoteUsers.first).id))
        vm.connectLocal()
        h.callSession.authenticate(["stranger"])
        #expect(vm.activeGroupID == nil)
        #expect(vm.authenticatedPeerIDs.isEmpty)
        #expect(vm.selectedGroup?.members.map(\.id) == ["alice", "bob"])
        #expect(vm.groupErrorMessage != nil)
    }

    @Test func versionTwoMigrationPreservesUsersAndKeysAndRejectsMissingCurrentKind() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        let group = try IntercomGroup(name: "Riders", members: [.init(id: "local", displayName: "You"), .init(id: "rider", displayName: "Rider")])
        try f.repository.save([group], credential: .init(groupID: group.id, secret: "key"), acceptedInvitation: testAcceptedInvitation(groupID: group.id, inviter: group.members[1]))
        let users = f.repository.users
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.file.url)) as? [String: Any])
        var records = try #require(json["groups"] as? [[String: Any]])
        records[0].removeValue(forKey: "kind")
        json["groups"] = records
        // Missing kind in schema 3 must not silently turn a direct call into a group.
        try JSONSerialization.data(withJSONObject: json).write(to: f.file.url)
        #expect(throws: (any Error).self) { try f.restart().load(localMemberID: "local") }
        json["version"] = 2
        records[0].removeValue(forKey: "invitationDeviceKeys")
        json["groups"] = records
        let old = try JSONSerialization.data(withJSONObject: json)
        try old.write(to: f.file.url)
        f.store.failCommit = true
        #expect(throws: (any Error).self) { try f.restart().load(localMemberID: "local") }
        #expect(try Data(contentsOf: f.file.url) == old)
        f.store.failCommit = false
        let restarted = f.restart()
        #expect(try restarted.load(localMemberID: "local").first?.kind == .group)
        #expect(restarted.users == users)
        #expect(try restarted.credential(for: group.id)?.secret == "key")
        #expect(try f.file.read()?.version == GroupSnapshot.currentVersion)
    }

    @Test func tamperedRecipientOrGroupKindCannotReinterpretExistingCall() throws {
        let h = try harness(local: "alice", remote: "bob")
        let vm = h.viewModel
        defer { vm.disconnect() }
        #expect(vm.selectUser(try #require(vm.savedRemoteUsers.first).id))
        let id = try #require(vm.selectedGroup?.id)
        let key = try #require(try vm.groupRepository.credential(for: id)).secret
        let groupInvite = try GroupInviteToken.make(authority: testInvitationAuthority(), signer: testIdentitySigner("bob"), groupID: id, groupName: "Direct Call", groupSecret: key, inviterMemberID: "bob")
        #expect(throws: GroupInviteTokenError.incompatibleCall) { try vm.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: groupInvite)) }
        let token = try GroupInviteTokenCodec.decodeJoinURL(#require(vm.makeSelectedGroupInviteURL()))
        let tampered = try GroupInviteToken(version: 6,
            groupID: IntercomGroup.directCallID(memberIDs: ["alice", "charlie"]), groupName: token.groupName,
            groupSecret: token.groupSecret, inviterMemberID: "alice", recipientMemberID: "charlie",
            issuedAt: token.issuedAt, expiresAt: token.expiresAt,
            directInvitation: testInvitationAuthority().issue(.init(groupID: IntercomGroup.directCallID(memberIDs: ["alice", "charlie"]), inviterMemberID: "alice", inviterDeviceKey: testIdentitySigner("alice").publicKey, recipientMemberID: "charlie", expiresAt: token.expiresAt!)), signature: token.signature, identityProof: token.identityProof)
        #expect(throws: GroupInviteTokenError.invalidSignature) { try GroupInviteTokenCodec.decodeJoinURL(GroupInviteTokenCodec.joinURL(for: tampered)) }
        #expect(vm.selectedGroup?.kind == .direct)
    }

    private func harness(local: String, remote: String) throws -> AppTestSupport.Harness {
        let group = try IntercomGroup(name: "Riders", members: [.init(id: local, displayName: "You")], accessSecret: "original-key")
        let h = AppTestSupport.makeHarness(groups: [group])
        let token = try GroupInviteToken.make(authority: testInvitationAuthority(), signer: testIdentitySigner(remote), groupID: group.id, groupName: group.name, groupSecret: "original-key", inviterMemberID: remote)
        try h.viewModel.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: token))
        return h
    }
}

@MainActor
struct OrdinaryGroupReplyTransportTests {
    @Test func reopenedInviterReceivesAnAcceptanceForTheOriginalLink() async throws {
        let storage = try GroupStorageFixture()
        defer { storage.remove() }
        let group = try storage.group()
        try storage.repository.save([group], credential: .init(groupID: group.id, secret: "original-link-fixture"))
        let issuer = AppTestSupport.makeHarness(groups: [], groupRepository: storage.repository, localMemberID: "local")
        let url = try #require(issuer.viewModel.makeGroupInviteURL(for: group.id))
        issuer.viewModel.stopOrdinaryGroupReplyExchanges()

        let author = AppTestSupport.makeHarness(accountSession: issuer.viewModel.accountSession, groups: [],
            groupRepository: storage.restart(), internetSettingsStore: issuer.viewModel.internetSettingsStore,
            invitationAuthority: issuer.viewModel.invitationAuthority, localMemberID: "local")
        let recipient = AppTestSupport.makeHarness(groups: [], localMemberID: "bob")
        defer {
            author.viewModel.stopOrdinaryGroupReplyExchanges(); recipient.viewModel.stopOrdinaryGroupReplyExchanges()
            author.viewModel.disconnect(); recipient.viewModel.disconnect()
        }
        author.viewModel.allowsNearbyGroupDelivery = true
        recipient.viewModel.allowsNearbyGroupDelivery = true
        let owner = AppCallOwner(account: author.viewModel.accountSession, viewModel: author.viewModel)
        owner.systemSurfaceIsForeground = true
        try recipient.viewModel.acceptInviteURL(url)
        #expect(author.viewModel.savedRemoteUsers.isEmpty)
        await AppTestSupport.waitUntil(timeout: .seconds(12)) {
            recipient.viewModel.groupRepository.pendingInvitation(for: group.id) == nil
        }
        let acknowledged = recipient.viewModel.groupRepository.pendingInvitation(for: group.id) == nil
        #expect(acknowledged)
        #expect(author.viewModel.savedRemoteUsers.first?.memberIDs == ["bob"])
        #expect(author.viewModel.activeGroupID == nil)
        #expect(owner.viewModel === author.viewModel)
    }

    @Test func ordinaryInvitationReplyReachesTheInviterAfterSwitchingToAnIndividualCall() async throws {
        let group = try IntercomGroup(name: "Riders", members: [.init(id: "alice", displayName: "Alice")],
                                      accessSecret: "ordinary-group-reply-fixture")
        let a = AppTestSupport.makeHarness(groups: [group], localMemberID: "alice")
        let b = AppTestSupport.makeHarness(groups: [], localMemberID: "bob")
        defer {
            a.viewModel.stopOrdinaryGroupReplyExchanges(); b.viewModel.stopOrdinaryGroupReplyExchanges()
            a.viewModel.disconnect(); b.viewModel.disconnect()
        }
        a.viewModel.allowsNearbyGroupDelivery = true
        b.viewModel.allowsNearbyGroupDelivery = true
        var requests = 0, releases = 0
        var expire: (@MainActor () -> Void)?
        b.viewModel.beginOrdinaryGroupReplyBackgroundTime = { callback in
            requests += 1
            expire = callback
            return { releases += 1 }
        }
        let url = try #require(a.viewModel.makeGroupInviteURL(for: group.id))
        try b.viewModel.acceptInviteURL(url)
        let alice = try #require(b.viewModel.savedRemoteUsers.first)
        #expect(b.viewModel.groupRepository.pendingInvitation(for: group.id) != nil)
        #expect(a.viewModel.savedRemoteUsers.isEmpty)
        let firstExpiration = try #require(expire)
        firstExpiration()
        #expect(b.viewModel.ordinaryGroupReplyExchanges.isEmpty)
        #expect(b.viewModel.groupRepository.pendingInvitation(for: group.id) != nil)
        try #require(b.viewModel.startCall(to: .user(alice.id), accountAccessID: b.viewModel.accountAccessID))
        let current = try #require(b.viewModel.activeDirectCall)
        firstExpiration()
        #expect(releases == 1)

        await AppTestSupport.waitUntil(timeout: .seconds(10)) {
            b.viewModel.groupRepository.pendingInvitation(for: group.id) == nil && !a.viewModel.savedRemoteUsers.isEmpty
        }
        #expect(a.viewModel.activeGroupID == nil)
        #expect(b.viewModel.activeGroupID == current.id)
        #expect(b.viewModel.groupRepository.pendingInvitation(for: group.id) == nil)
        let bob = try #require(a.viewModel.savedRemoteUsers.first)
        #expect(a.viewModel.existingDirectCall(for: bob.id)?.id == current.id)
        let source = try #require(a.viewModel.groupRepository.credential(for: current.id)?.secret)
        let matches = try b.viewModel.groupRepository.credential(for: current.id)?.secret == source
        #expect(matches)
        #expect(requests == 2)
        #expect(releases == 2)
        #expect(b.viewModel.ordinaryGroupReplyExchanges.isEmpty)
        #if os(iOS)
        try #require(a.viewModel.startCall(to: .user(bob.id), accountAccessID: a.viewModel.accountAccessID))
        try await DirectCallTests.assertLocalCall(aliceGroup: try #require(a.callSession.connectedGroup),
                                  bobGroup: try #require(b.callSession.connectedGroup))
        #endif
    }
}

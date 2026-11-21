import Foundation
import RTC
import Testing
@testable import RideIntercom

extension DirectCallTests {
    @Test func crossedOrdinaryGroupInvitationsPrepareOneMatchingDeviceCall() async throws {
        let left = try IntercomGroup(name: "Left riders", members: [.init(id: "alice", displayName: "Alice")],
                                     accessSecret: "left-crossed-group-fixture")
        let right = try IntercomGroup(name: "Right riders", members: [.init(id: "bob", displayName: "Bob")],
                                      accessSecret: "right-crossed-group-fixture")
        let author = AppTestSupport.makeHarness(groups: [left], localMemberID: "alice")
        let recipient = AppTestSupport.makeHarness(groups: [right], localMemberID: "bob")
        let firstPeer = author.viewModel, secondPeer = recipient.viewModel
        defer { firstPeer.disconnect(); secondPeer.disconnect() }
        firstPeer.allowsNearbyGroupDelivery = false
        secondPeer.allowsNearbyGroupDelivery = false
        let leftURL = try #require(firstPeer.makeGroupInviteURL(for: left.id))
        let rightURL = try #require(secondPeer.makeGroupInviteURL(for: right.id))
        try firstPeer.acceptInviteURL(rightURL)
        try secondPeer.acceptInviteURL(leftURL)
        let acceptedLeft = try #require(secondPeer.signedPendingInvitationReceipt(for: left.id))
        let acceptedRight = try #require(firstPeer.signedPendingInvitationReceipt(for: right.id))
        #expect(acceptedLeft.id != acceptedRight.id)
        let aliceCall = firstPeer.activeGroupID, bobCall = secondPeer.activeGroupID

        let acknowledgedRight = try #require(
            secondPeer.applyInvitationReceipt(acceptedRight, from: "alice", standalone: true))
        let acknowledgedLeft = try #require(
            firstPeer.applyInvitationReceipt(acceptedLeft, from: "bob", standalone: true))
        _ = firstPeer.applyInvitationReceipt(acknowledgedRight, from: "bob", standalone: true)
        _ = secondPeer.applyInvitationReceipt(acknowledgedLeft, from: "alice", standalone: true)
        #expect(firstPeer.groupRepository.pendingInvitation(for: right.id) == nil)
        #expect(secondPeer.groupRepository.pendingInvitation(for: left.id) == nil)
        #expect(firstPeer.activeGroupID == aliceCall && secondPeer.activeGroupID == bobCall)

        firstPeer.disconnect()
        secondPeer.disconnect()
        firstPeer.reloadSavedGroups()
        secondPeer.reloadSavedGroups()
        #expect(firstPeer.savedRemoteUsers.map(\.memberIDs) == [["bob"]])
        #expect(secondPeer.savedRemoteUsers.map(\.memberIDs) == [["alice"]])
        let bob = try #require(firstPeer.savedRemoteUsers.first)
        let alice = try #require(secondPeer.savedRemoteUsers.first)
        let directID = try #require(firstPeer.existingDirectCall(for: bob.id)?.id)
        #expect(secondPeer.existingDirectCall(for: alice.id)?.id == directID)
        #expect(firstPeer.groups.filter { $0.kind == .direct }.count == 1)
        #expect(secondPeer.groups.filter { $0.kind == .direct }.count == 1)
        let leftSecret = try firstPeer.groupRepository.credential(for: directID)?.secret
        let sameCredential =
            try leftSecret != nil && secondPeer.groupRepository.credential(for: directID)?.secret == leftSecret
        try #require(sameCredential)
        try #require(firstPeer.startCall(to: .user(bob.id), accountAccessID: firstPeer.accountAccessID))
        try #require(secondPeer.startCall(to: .user(alice.id), accountAccessID: secondPeer.accountAccessID))
        #if os(iOS)
        try await Self.assertLocalCall(aliceGroup: try #require(author.callSession.connectedGroup),
                                      bobGroup: try #require(recipient.callSession.connectedGroup))
        #endif
    }

    @Test func multiplePendingOrdinaryInvitationsPrepareTheSameCallWithoutChoosingAReply() async throws {
        let member = GroupMember(id: "alice", displayName: "Alice")
        let first = try IntercomGroup(name: "First", members: [member], accessSecret: "first-fixture")
        let second = try IntercomGroup(name: "Second", members: [member], accessSecret: "second-fixture")
        let firstPeer = AppTestSupport.makeHarness(groups: [first, second], localMemberID: "alice")
        let secondPeer = AppTestSupport.makeHarness(groups: [], localMemberID: "bob")
        defer { firstPeer.viewModel.disconnect(); secondPeer.viewModel.disconnect() }
        firstPeer.viewModel.allowsNearbyGroupDelivery = false
        secondPeer.viewModel.allowsNearbyGroupDelivery = false
        firstPeer.viewModel.selectGroup(first)
        try secondPeer.viewModel.acceptInviteURL(try #require(firstPeer.viewModel.makeSelectedGroupInviteURL()))
        let alice = try #require(secondPeer.viewModel.savedRemoteUsers.first)
        let now = Date().timeIntervalSince1970
        #expect(
            secondPeer.viewModel.groupRepository.pendingOrdinaryGroupReceipt(for: alice, now: now)?.groupID
                == first.id)
        firstPeer.viewModel.selectGroup(second)
        try secondPeer.viewModel.acceptInviteURL(try #require(firstPeer.viewModel.makeSelectedGroupInviteURL()))
        #expect(secondPeer.viewModel.groupRepository.pendingInvitation(for: first.id) != nil)
        #expect(secondPeer.viewModel.groupRepository.pendingInvitation(for: second.id) != nil)
        #expect(secondPeer.viewModel.groupRepository.pendingOrdinaryGroupReceipt(for: alice, now: now) == nil)
        #expect(secondPeer.viewModel.existingDirectCall(for: alice.id) == nil)
        let activeGroupID = secondPeer.viewModel.activeGroupID
        try #require(secondPeer.viewModel.selectUser(alice.id, connectIfIdle: false))
        #expect(secondPeer.viewModel.activeGroupID == activeGroupID)
        let directID = try #require(secondPeer.viewModel.existingDirectCall(for: alice.id)?.id)
        let earlySecret = try secondPeer.viewModel.groupRepository.credential(for: directID)?.secret

        let reply = try #require(secondPeer.viewModel.signedPendingInvitationReceipt(for: second.id))
        let acknowledgement = try #require(
            firstPeer.viewModel.applyInvitationReceipt(reply, from: "bob", standalone: true))
        let matchingCredential =
            try earlySecret != nil
            && firstPeer.viewModel.groupRepository.credential(for: directID)?.secret == earlySecret
        try #require(matchingCredential)
        #expect(secondPeer.viewModel.groupRepository.pendingInvitation(for: first.id) != nil)
        #expect(secondPeer.viewModel.groupRepository.pendingInvitation(for: second.id) != nil)

        let bob = try #require(firstPeer.viewModel.savedRemoteUsers.first)
        try #require(
            firstPeer.viewModel.startCall(to: .user(bob.id), accountAccessID: firstPeer.viewModel.accountAccessID))
        try #require(
            secondPeer.viewModel.startCall(
                to: .user(alice.id), accountAccessID: secondPeer.viewModel.accountAccessID))
        #if os(iOS)
        try await Self.assertLocalCall(aliceGroup: try #require(firstPeer.callSession.connectedGroup),
                                      bobGroup: try #require(secondPeer.callSession.connectedGroup))
        #endif

        _ = secondPeer.viewModel.applyInvitationReceipt(acknowledgement, from: "alice", standalone: true)
        #expect(secondPeer.viewModel.groupRepository.pendingInvitation(for: first.id) != nil)
        #expect(secondPeer.viewModel.groupRepository.pendingInvitation(for: second.id) == nil)
        #expect(secondPeer.viewModel.activeGroupID == directID)
    }

    #if os(iOS)
    static func assertLocalCall(aliceGroup: IntercomGroup, bobGroup: IntercomGroup) async throws {
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
        let testHarness = try harness(local: "alice", remote: "bob")
        let viewModel = testHarness.viewModel
        defer { viewModel.disconnect() }
        let original = try #require(viewModel.groups.first)
        let user = try #require(viewModel.savedRemoteUsers.first)
        let active = viewModel.activeGroupID
        let disconnects = testHarness.callSession.disconnectCallCount
        #expect(viewModel.selectUser(user.id))
        let direct = try #require(viewModel.selectedGroup)
        #expect(direct.kind == .direct)
        #expect(direct.id != original.id)
        #expect(viewModel.regularGroups.map(\.id) == [original.id])
        #expect(viewModel.activeGroupID == active)
        #expect(testHarness.callSession.disconnectCallCount == disconnects)
        let credential = try #require(try viewModel.groupRepository.credential(for: direct.id))
        viewModel.showGroupSelection()
        #expect(viewModel.selectUser(user.id))
        #expect(viewModel.selectedGroup?.id == direct.id)
        #expect(try viewModel.groupRepository.credential(for: direct.id) == credential)
        #expect(viewModel.groups.count == 2)
        viewModel.connectLocal()
        #expect(viewModel.activeGroupID == direct.id)
    }

    @Test func onlySavedDirectContactsCanResolveCallsAndDeletionEndsTheirCall() throws {
        let testHarness = try harness(local: "alice", remote: "bob")
        let viewModel = testHarness.viewModel
        defer { viewModel.disconnect() }
        #expect(!viewModel.selectUser(UUID()))
        let user = try #require(viewModel.savedRemoteUsers.first)
        #expect(viewModel.selectUser(user.id))
        let direct = try #require(viewModel.selectedGroup)
        viewModel.connectLocal()
        #expect(viewModel.removeSavedUser(user.id))
        #expect(viewModel.activeGroupID == nil)
        #expect(!viewModel.groups.contains { $0.id == direct.id })
        #expect(!viewModel.selectUser(user.id))
        #expect(viewModel.makeSelectedGroupInviteURL() == nil)
    }

    /// The call's More menu finds User Settings through the direct call; removing the
    /// saved user removes the direct call with them.
}

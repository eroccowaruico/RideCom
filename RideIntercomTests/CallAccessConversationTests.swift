import Foundation
import Observation
import SessionManager
import RTC
import Testing
@testable import RideIntercom

extension CallAccessTests {
    @Test func unpaidCallerCanConnectControlToPaidLocalPeerAndEstablishExactlyOnce() async throws {
        let fixture = try CallAccessPair(); defer { fixture.close() }
        fixture.sourceA.value = .init(status: .notPurchased)
        await fixture.connect()
        #expect(
            fixture.alice.viewModel.callAccessState.isEstablished
                && fixture.bob.viewModel.callAccessState.isEstablished)
        #expect(fixture.alice.viewModel.isAudioReady && fixture.bob.viewModel.isAudioReady)
        let start = try #require(fixture.alice.viewModel.callAccessState.lastSponsoredStart)
        #expect(fixture.bob.viewModel.callAccessState.lastSponsoredStart == start)
        #expect(
            fixture.alice.viewModel.groupRepository.lastSponsoredStart(
                for: try #require(fixture.alice.viewModel.activeGroupID)) == start)
        fixture.sourceB.value = .init(status: .revoked)
        fixture.alice.viewModel.refreshCallAccess(); fixture.bob.viewModel.refreshCallAccess(); await fixture.pump()
        #expect(
            fixture.alice.viewModel.callAccessState.isEstablished
                && fixture.bob.viewModel.callAccessState.isEstablished)
        #expect(fixture.alice.viewModel.callAccessState.lastSponsoredStart == start)
        let messages =
            fixture.alice.callSession.sentApplicationDataMessages.count
            + fixture.bob.callSession.sentApplicationDataMessages.count
        fixture.alice.viewModel.refreshCallAccess(); fixture.bob.viewModel.refreshCallAccess(); await fixture.pump()
        #expect(
            fixture.alice.callSession.sentApplicationDataMessages.count
                + fixture.bob.callSession.sentApplicationDataMessages.count == messages)
    }

    @Test func unpaidPeersKeepControlButNoAudioOrInventedWindowThenRestoreAutomaticallyResumes() async throws {
        let fixture = try CallAccessPair(); defer { fixture.close() }
        fixture.sourceA.value = .init(status: .notPurchased); fixture.sourceB.value = .init(status: .notPurchased)
        await fixture.connect()
        #expect(fixture.alice.viewModel.peerProfiles["bob"]?.verified != nil)
        #expect(fixture.bob.viewModel.peerProfiles["alice"]?.verified != nil)
        #expect(!fixture.alice.viewModel.isCallMediaStarted && !fixture.bob.viewModel.isCallMediaStarted)
        #expect(fixture.alice.viewModel.callAccessState.lastSponsoredStart == nil)
        fixture.sourceB.value = .init(status: .active, activeUntil: .distantFuture)
        await AppTestSupport.waitUntil { fixture.bob.viewModel.isCallMediaStarted }
        await fixture.pump()
        #expect(
            fixture.alice.viewModel.callAccessState.isEstablished
                && fixture.bob.viewModel.callAccessState.isEstablished)
    }

    @Test func failedRemoteMediaDoesNotGrantWindowAndRetryCanEstablish() async throws {
        let fixture = try CallAccessPair(); defer { fixture.close() }
        fixture.bob.outputBackend.startError = AudioStreamError.engineOperationFailed("unavailable")
        await fixture.connect()
        #expect(
            !fixture.alice.viewModel.callAccessState.isEstablished
                && !fixture.bob.viewModel.callAccessState.isEstablished)
        #expect(
            fixture.alice.viewModel.callAccessState.lastSponsoredStart == nil
                && fixture.bob.viewModel.callAccessState.lastSponsoredStart == nil)
        #expect(fixture.alice.callSession.audioPolicies.last?.peerPolicy == .admittedMemberships([:]))
        #expect(fixture.alice.viewModel.standardCallStatus == .connecting)
        fixture.bob.outputBackend.startError = nil
        fixture.bob.viewModel.refreshCallAccess(); await fixture.pump()
        #expect(
            fixture.alice.viewModel.callAccessState.isEstablished
                && fixture.bob.viewModel.callAccessState.isEstablished)
    }

    @Test func creationNeedsOwnRightButAcceptingAndEndingDoNot() async throws {
        let fixture = try CallAccessPair(); defer { fixture.close() }
        fixture.sourceA.value = .init(status: .notPurchased)
        #expect(!fixture.alice.viewModel.createTalkGroup(name: "Blocked"))
        #expect(!fixture.alice.viewModel.canShareSelectedGroup)
        #expect(fixture.alice.viewModel.makeSelectedGroupInviteURL() == nil)
        let group = try #require(fixture.alice.viewModel.selectedGroup)
        let snapshot = fixture.alice.groupStore.snapshot
        let draft = GroupInvitationDraft(name: "Rider", suggestedName: "New person")
        #expect(fixture.alice.viewModel.saveGroupInvitations(groupID: group.id, creating: false, name: group.name,
                                                  selected: [], newPeople: [draft]) == nil)
        #expect(fixture.alice.groupStore.snapshot == snapshot)
        await fixture.connect()
        fixture.alice.viewModel.disconnect()
        #expect(fixture.alice.viewModel.activeGroupID == nil)
    }

    @Test func emptyCatalogKeepsTrialWithoutClaimingPurchaseOrRecordingSponsor() async throws {
        let harness = AppTestSupport.makeHarness(); defer { harness.viewModel.disconnect() }
        #expect(harness.viewModel.storeAccess.evaluation(at: Date()).status == .unconfigured)
        harness.viewModel.selectGroup(try #require(harness.viewModel.groups.first))
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
        #expect(harness.viewModel.isAudioReady)
        #expect(harness.viewModel.callAccessState.lastSponsoredStart == nil)
        #expect(
            harness.callSession.sentApplicationDataMessages.allSatisfy {
                $0.namespace != SharedCallAccess.namespace
            })
    }
}

extension CallAccessTests {
    @Test func devicePauseAndPartialRoutesKeepConversationPastWindowButLastPeerLossRequiresSponsor() async throws {
        let fixture = try CallAccessPair(); defer { fixture.close() }; await fixture.connect()
        let original = try #require(fixture.alice.viewModel.callAccessState.lastSponsoredStart)
        fixture.sourceA.value = .init(status: .notPurchased); fixture.sourceB.value = .init(status: .revoked)
        // Resume near the end of the access window. The new call's timer still has time
        // left when the older sponsored window ends, so only access policy is exercised.
        fixture.close()
        fixture.sourceA.now = Date(timeIntervalSince1970: original + 86_340); fixture.sourceB.now = fixture.sourceA.now
        await fixture.connect()
        #expect(
            fixture.alice.viewModel.callAccessState.isEstablished
                && fixture.bob.viewModel.callAccessState.isEstablished)
        #expect(fixture.alice.viewModel.callAccessState.lastSponsoredStart == original)
        fixture.sourceA.now = Date(timeIntervalSince1970: original + 86_401); fixture.sourceB.now = fixture.sourceA.now
        #expect(try #require(fixture.alice.viewModel.callDisconnectDeadline) > fixture.sourceA.now)
        fixture.alice.viewModel.stopAudioPipeline(); fixture.alice.viewModel.refreshCallAccess()
        fixture.bob.viewModel.refreshCallAccess(); await fixture.pump()
        #expect(fixture.alice.viewModel.callAccessState.isEstablished && fixture.alice.viewModel.isAudioReady)
        #expect(fixture.alice.viewModel.callAccessState.lastSponsoredStart == original)
        fixture.alice.viewModel.handleTransportEvent(.serviceError("Internet unavailable; Local remains"))
        #expect(fixture.alice.viewModel.callAccessState.isEstablished)
        fixture.alice.callSession.authenticate([]); fixture.bob.callSession.authenticate([])
        #expect(
            !fixture.alice.viewModel.callAccessState.isEstablished
                && !fixture.bob.viewModel.callAccessState.isEstablished)
        await fixture.connect()
        #expect(
            !fixture.alice.viewModel.callAccessState.isEstablished
                && !fixture.bob.viewModel.callAccessState.isEstablished)
        #expect(!fixture.alice.viewModel.isCallMediaStarted && !fixture.bob.viewModel.isCallMediaStarted)
        #expect(fixture.alice.viewModel.callAccessState.lastSponsoredStart == original)
    }

    @Test func paidLateJoinerAndRepeatedProofDoNotRenewExistingConversation() async throws {
        let fixture = try CallAccessPair(); defer { fixture.close() }; await fixture.connect()
        let original = try #require(fixture.alice.viewModel.callAccessState.lastSponsoredStart)
        fixture.sourceA.now = fixture.sourceA.now.addingTimeInterval(200); fixture.sourceB.now = fixture.sourceA.now
        fixture.alice.callSession.authenticate(["bob", "carol"])
        let viewModel = fixture.alice.viewModel
        let profile = try testPeerProfile(viewModel, peerID: "carol", displayName: "Group only")
        viewModel.handleTransportEvent(
            .receivedApplicationData(
                peerID: "carol",
                message: .init(namespace: SharedDisplayName.namespace, payload: try JSONEncoder().encode(profile)))
        )
        let state = try #require(viewModel.peerProfiles["carol"])
        let value = SharedCallAccess(
            groupID: try #require(viewModel.activeGroupID),
            recipientMemberID: viewModel.localMemberIdentity.memberID,
            challenge: state.challenge, revision: 1, hasActiveRight: true,
            activeUntil: Date.distantFuture.timeIntervalSince1970,
            mediaReady: true, isEstablished: false, lastSponsoredStart: nil)
        let data = try JSONEncoder().encode(value.signed(by: testIdentitySigner("carol")))
        viewModel.handleTransportEvent(
            .receivedApplicationData(
                peerID: "carol", message: .init(namespace: SharedCallAccess.namespace, payload: data)))
        #expect(viewModel.callAccessState.lastSponsoredStart == original)
        #expect(!viewModel.savedUsers.contains { $0.memberIDs.contains("carol") })
        if case .admittedMemberships(let admitted) = fixture.alice.callSession.audioPolicies.last?.peerPolicy {
            #expect(admitted[.init(rawValue: "carol")] == state.membershipID)
        } else { Issue.record("Missing audio admission") }
        fixture.alice.callSession.authenticate(["carol"])
        #expect(viewModel.callAccessState.isEstablished)
        fixture.alice.callSession.authenticate(["unverified"])
        #expect(!viewModel.callAccessState.isEstablished)
        #expect(viewModel.callAccessState.lastSponsoredStart == original)
    }

    @Test func replayWrongSignatureAndFutureTimestampCannotAuthorizeNewMembership() async throws {
        let fixture = try CallAccessPair(); defer { fixture.close() }; await fixture.connect()
        let viewModel = fixture.alice.viewModel
        let previous = try #require(viewModel.peerProfiles["bob"]?.callAccess)
        fixture.sourceA.value = .init(status: .notPurchased); fixture.sourceB.value = .init(status: .notPurchased)
        fixture.sourceA.now = fixture.sourceA.now.addingTimeInterval(86_401); fixture.sourceB.now = fixture.sourceA.now
        fixture.alice.callSession.authenticate([]); fixture.bob.callSession.authenticate([])
        await fixture.connect()
        viewModel.handleTransportEvent(
            .receivedApplicationData(
                peerID: "bob",
                message: .init(namespace: SharedCallAccess.namespace, payload: try JSONEncoder().encode(previous)))
        )
        #expect(!viewModel.callAccessState.isEstablished)
        let peer = try #require(viewModel.peerProfiles["bob"])
        let future = SharedCallAccess(
            groupID: try #require(viewModel.activeGroupID),
            recipientMemberID: viewModel.localMemberIdentity.memberID,
            challenge: peer.challenge, revision: 1000, activeUntil: nil,
            mediaReady: true, isEstablished: false, lastSponsoredStart: fixture.sourceA.now.timeIntervalSince1970 + 1)
        for signer in [testIdentitySigner("bob"), testIdentitySigner("impostor")] {
            let bytes = try JSONEncoder().encode(future.signed(by: signer))
            viewModel.handleTransportEvent(
                .receivedApplicationData(
                    peerID: "bob", message: .init(namespace: SharedCallAccess.namespace, payload: bytes)))
        }
        #expect(!viewModel.callAccessState.isEstablished)
        #expect(viewModel.callAccessState.lastSponsoredStart != future.lastSponsoredStart)
    }

    @Test func stoppedObservationCannotResumeAndOldAccountCannotShareOrReceiveAccess() async throws {
        let fixture = try CallAccessPair(); defer { fixture.close() }
        fixture.sourceA.value = .init(status: .notPurchased); fixture.sourceB.value = .init(status: .notPurchased)
        await fixture.connect()
        fixture.alice.viewModel.stopCallAccessObservation()
        fixture.sourceA.value = .init(status: .active, activeUntil: .distantFuture)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!fixture.alice.viewModel.isCallMediaStarted)
        fixture.alice.viewModel.accountSession.signOut()
        let count = fixture.alice.callSession.sentApplicationDataMessages.count
        fixture.alice.viewModel.refreshCallAccess(); fixture.alice.viewModel.sendCallAccess(force: true)
        #expect(!fixture.alice.viewModel.canStartCalls)
        #expect(fixture.alice.callSession.sentApplicationDataMessages.count == count)
    }
}

extension CallAccessTests {
    @Test func verifiedDistributionAccessWithoutAnExpirationCanSponsor() async throws {
        let fixture = try CallAccessPair(); defer { fixture.close() }
        fixture.sourceA.value = .init(status: .notPurchased); fixture.sourceB.value = .init(status: .active)
        await fixture.connect()
        #expect(
            fixture.alice.viewModel.callAccessState.isEstablished
                && fixture.bob.viewModel.callAccessState.isEstablished)
        #expect(fixture.alice.viewModel.callAccessState.lastSponsoredStart != nil)
    }

    @Test func failedHistorySaveDoesNotStopEstablishedMedia() async throws {
        let fixture = try CallAccessPair(); defer { fixture.close() }
        fixture.bob.outputBackend.startError = AudioStreamError.engineOperationFailed("paused")
        await fixture.connect()
        // Both identities are now verified; fail only the subsequent start write.
        fixture.alice.groupStore.failSaving = true
        fixture.bob.outputBackend.startError = nil
        fixture.bob.viewModel.refreshCallAccess(); await fixture.pump()
        #expect(fixture.alice.viewModel.callAccessState.isEstablished && fixture.alice.viewModel.isAudioReady)
        #expect(fixture.alice.viewModel.groupStorageIssue != nil)
        #expect(fixture.alice.groupStore.snapshot.groups.first?.lastSponsoredStart == nil)
        fixture.alice.viewModel.refreshCallAccess(); await fixture.pump()
        #expect(fixture.alice.viewModel.isAudioReady)
    }

    @Test func directInvitationAndRestartRemainAvailableToUnpaidContact() async throws {
        let fixture = try CallAccessPair(); defer { fixture.close() }; await fixture.connect()
        fixture.sourceA.value = .init(status: .notPurchased)
        let user = try #require(fixture.alice.viewModel.savedRemoteUsers.first)
        fixture.alice.viewModel.disconnect(); fixture.bob.viewModel.disconnect()
        #expect(fixture.alice.viewModel.selectUser(user.id))
        let id = try #require(fixture.alice.viewModel.selectedGroup?.id)
        let invite = try #require(fixture.alice.viewModel.makeSelectedGroupInviteURL())
        try fixture.bob.viewModel.acceptInviteURL(invite)
        fixture.aliceMessageIndex = fixture.alice.callSession.sentApplicationDataMessages.count
        fixture.bobMessageIndex = fixture.bob.callSession.sentApplicationDataMessages.count
        await fixture.connect()
        let original = try #require(fixture.alice.viewModel.callAccessState.lastSponsoredStart)
        #expect(fixture.alice.viewModel.groupRepository.lastSponsoredStart(for: id) == original)
        #expect(fixture.alice.viewModel.removeSavedUser(user.id))
        #expect(fixture.alice.viewModel.activeGroupID == nil)
        #expect(
            !fixture.alice.viewModel.startCall(
                to: .user(user.id), accountAccessID: fixture.alice.viewModel.accountAccessID))
        #expect(fixture.alice.viewModel.groupRepository.lastSponsoredStart(for: id) == nil)
    }
}

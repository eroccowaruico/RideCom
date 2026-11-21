import Foundation
import Observation
import SessionManager
import RTC
import Testing
@testable import RideIntercom

extension CallAccessTests {
    @Test func smallClockDifferenceDoesNotDiscardReadyStateOrInventFutureWindow() async throws {
        let fixture = try CallAccessPair(); defer { fixture.close() }
        fixture.sourceB.now = fixture.sourceA.now.addingTimeInterval(0.1)
        fixture.sourceA.value = .init(status: .notPurchased)
        await fixture.connect()
        #expect(
            fixture.alice.viewModel.callAccessState.isEstablished
                && fixture.bob.viewModel.callAccessState.isEstablished)
        if let aStart = fixture.alice.viewModel.callAccessState.lastSponsoredStart {
            #expect(aStart <= fixture.sourceA.now.timeIntervalSince1970)
        }
        fixture.sourceA.now = fixture.sourceA.now.addingTimeInterval(0.2)
        fixture.alice.viewModel.refreshCallAccess()
        #expect(
            fixture.alice.viewModel.callAccessState.lastSponsoredStart
                == fixture.bob.viewModel.callAccessState.lastSponsoredStart)
    }

    @Test func unreadySponsorDoesNotLetTwoUnpaidParticipantsEstablish() async throws {
        let source = CallAccessSourceFixture(); source.value = .init(status: .notPurchased)
        let harness = AppTestSupport.makeHarness(enforceCallAccess: true, callAccessEvaluation: { _ in source.value })
        defer { harness.viewModel.disconnect() }; let viewModel = harness.viewModel
        viewModel.selectGroup(try #require(viewModel.groups.first))
        harness.callSession.authenticate(["member-108", "member-215"])
        for (peerID, paid) in [("member-108", true), ("member-215", false)] {
            let profile = try testPeerProfile(viewModel, peerID: peerID, displayName: "Rider")
            viewModel.handleTransportEvent(
                .receivedApplicationData(
                    peerID: peerID,
                    message: .init(
                        namespace: SharedDisplayName.namespace, payload: try JSONEncoder().encode(profile))))
            let peer = try #require(viewModel.peerProfiles[peerID])
            let status = SharedCallAccess(
                groupID: try #require(viewModel.activeGroupID),
                recipientMemberID: viewModel.localMemberIdentity.memberID,
                challenge: peer.challenge, revision: 1, hasActiveRight: paid, activeUntil: nil,
                mediaReady: !paid, isEstablished: false, lastSponsoredStart: nil)
            viewModel.handleTransportEvent(
                .receivedApplicationData(
                    peerID: peerID,
                    message: .init(
                        namespace: SharedCallAccess.namespace,
                payload: try JSONEncoder().encode(status.signed(by: testIdentitySigner(peerID))))))
        }
        await AppTestSupport.waitUntil { viewModel.isAudioReady }
        #expect(viewModel.isAudioReady)
        #expect(!viewModel.callAccessState.isEstablished)
        #expect(viewModel.callAccessState.lastSponsoredStart == nil)
        #expect(harness.callSession.audioPolicies.last?.peerPolicy == .admittedMemberships([:]))
    }
}

extension CallAccessTests {
    @Test func unpaidLocalReconnectAtExactly24HoursKeepsOriginalStart() async throws {
        let fixture = try CallAccessPair(); defer { fixture.close() }; await fixture.connect()
        let original = try #require(fixture.alice.viewModel.callAccessState.lastSponsoredStart)
        fixture.close()
        fixture.sourceA.value = .init(status: .notPurchased); fixture.sourceB.value = .init(status: .notPurchased)
        fixture.sourceA.now = Date(timeIntervalSince1970: original + 86_400); fixture.sourceB.now = fixture.sourceA.now
        await fixture.connect()
        #expect(
            fixture.alice.viewModel.callAccessState.isEstablished
                && fixture.bob.viewModel.callAccessState.isEstablished)
        #expect(
            fixture.alice.viewModel.callAccessState.lastSponsoredStart == original
                && fixture.bob.viewModel.callAccessState.lastSponsoredStart == original)
        #expect(!fixture.alice.viewModel.createTalkGroup(name: "Window is not a pass"))
    }

    @Test func sameVersionSnapshotPreservesFutureTimeButDoesNotGrantAccessAndResetClearsIt() throws {
        let fixture = try GroupStorageFixture(); defer { fixture.remove() }
        let group = try fixture.group()
        var snapshot = GroupSnapshot(groups: [.init(group)])
        snapshot.groups[0].lastSponsoredStart = Date.distantFuture.timeIntervalSince1970
        try fixture.store.commit(snapshot)
        let repository = fixture.restart(); _ = try repository.load(localMemberID: "local")
        #expect(
            !CallAccessState.permitsResume(
                since: repository.lastSponsoredStart(for: group.id), now: Date().timeIntervalSince1970))
        let now = Date().timeIntervalSince1970
        try repository.recordSponsoredStart(now, for: group.id, now: now)
        #expect(repository.lastSponsoredStart(for: group.id) == now)
        try repository.reset()
        #expect(repository.lastSponsoredStart(for: group.id) == nil)
        var corrupt = snapshot; corrupt.groups[0].lastSponsoredStart = -1
        #expect(throws: (any Error).self) { try corrupt.encoded() }
    }

    @Test func distributionSourceDoesNotEnableCommercialRulesWhileCatalogIsEmpty() async throws {
        let harness = AppTestSupport.makeHarness(
            enforceCallAccess: false, callAccessEvaluation: { _ in .init(status: .active) })
        defer { harness.viewModel.disconnect() }
        #expect(harness.viewModel.createTalkGroup(name: "Trial"))
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
        #expect(harness.viewModel.isAudioReady)
        #expect(harness.viewModel.callAccessState.lastSponsoredStart == nil)
    }
}

extension CallAccessTests {
    @Test func forgedOrAlteredSignedStatusCannotGrantAccessEvenWithNewRevision() async throws {
        let fixture = try CallAccessPair(); defer { fixture.close() }
        fixture.sourceA.value = .init(status: .notPurchased); fixture.sourceB.value = .init(status: .notPurchased)
        await fixture.connect()
        let viewModel = fixture.alice.viewModel, peer = try #require(fixture.alice.viewModel.peerProfiles["bob"])
        let value = SharedCallAccess(
            groupID: try #require(viewModel.activeGroupID),
            recipientMemberID: viewModel.localMemberIdentity.memberID,
            challenge: peer.challenge, revision: 10_000, activeUntil: nil,
            mediaReady: true, isEstablished: false, lastSponsoredStart: nil)
        var tampered = try value.signed(by: testIdentitySigner("bob"))
        tampered.hasActiveRight = true
        var foreign = value; foreign.hasActiveRight = true
        foreign = try foreign.signed(by: testIdentitySigner("impostor"))
        for invalid in [tampered, foreign] {
            viewModel.handleTransportEvent(
                .receivedApplicationData(
                    peerID: "bob",
                    message: .init(
                        namespace: SharedCallAccess.namespace,
                payload: try JSONEncoder().encode(invalid))))
            #expect(viewModel.peerProfiles["bob"]?.callAccess?.revision != 10_000)
            #expect(!viewModel.isCallMediaStarted && !viewModel.callAccessState.isEstablished)
            #expect(viewModel.callAccessState.lastSponsoredStart == nil)
        }
    }
}

extension CallAccessTests {
    @Test func controlTickerSurvivesRetryButStopsAtTerminalFailureAndRestartsOnConnect() async throws {
        let fixture = try CallAccessPair(); defer { fixture.close() }
        fixture.sourceA.value = .init(status: .notPurchased); fixture.sourceB.value = .init(status: .notPurchased)
        await fixture.connect()
        let viewModel = fixture.alice.viewModel,
            ticker = try #require(fixture.alice.viewModel.callTicker as? NoOpCallTicker)
        #expect(ticker.isRunning)
        viewModel.handleTransportEvent(.linkFailed(willRetry: true))
        #expect(ticker.isRunning)
        viewModel.handleTransportEvent(.linkFailed(willRetry: false))
        #expect(!ticker.isRunning)
        viewModel.connectLocal()
        #expect(ticker.isRunning)
        viewModel.disconnect()
        #expect(!ticker.isRunning)
    }
}

extension CallAccessTests {
    @Test func rightExpiringDuringActivationCannotOpenMedia() async throws {
        let fixture = try CallAccessPair(), gate = ManualAsyncGate()
        defer { fixture.close() }
        fixture.alice.viewModel.setSoundIsolationEnabled(false); fixture.bob.viewModel.setSoundIsolationEnabled(false)
        fixture.alice.audioSessionBackend.activationGate = gate
        fixture.sourceA.value = .init(status: .active, activeUntil: fixture.sourceA.now.addingTimeInterval(1))
        fixture.sourceB.value = .init(status: .notPurchased)
        let connecting = Task { await fixture.connect() }
        await gate.waitForEntry()
        fixture.sourceA.now = fixture.sourceA.now.addingTimeInterval(2)
        fixture.sourceB.now = fixture.sourceA.now
        await gate.release()
        await connecting.value
        #expect(!fixture.alice.viewModel.isCallMediaStarted)
        #expect(fixture.alice.inputBackend.startCount == 1 && fixture.alice.callSession.startMediaCallCount == 0)
        #expect(!fixture.alice.viewModel.callAccessState.isEstablished)
        _ = await fixture.alice.viewModel.audioSessionManager.requestActive(false).value
    }
}

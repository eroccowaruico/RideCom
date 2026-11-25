#if os(macOS)
import Foundation
import RTC
import Testing
@testable import RideIntercom

extension GroupDeliveryWorkerTests {
    enum CredentialRenewalTrigger: CaseIterable { case outgoingCall, authenticatedPeer, restoredNetwork }

    @Test(.timeLimit(.minutes(1)), arguments: CredentialRenewalTrigger.allCases)
    func appRenewsTheCredentialForAnExistingWorkerCall(trigger: CredentialRenewalTrigger) async throws {
        try await withWorker(credentialRenewal: true) {
            let group = try #require(IntercomSeedData.recentGroups.first)
            let member = try #require(group.members.first)
            let otherMember = try #require(group.members.first { $0.id != member.id })
            let caller = GroupDeliveryTestIdentity(member.id, fixedWorkerOrigin: URL(string: "https://delivery.test"))
            let listener = GroupDeliveryTestIdentity(otherMember.id)
            let account = AccountFixture()
            defer { caller.remove(); listener.remove(); account.remove() }
            account.signIn(member.id)
            try await register(caller)
            try await register(listener)
            var callTime = Date().addingTimeInterval(-120)
            let harness = AppTestSupport.makeHarness(
                accountSession: account.session, groups: [group], internetSettingsStore: caller.store,
                localMemberID: member.id, callAccessNow: { callTime })
            let model = harness.viewModel
            let client = InternetAccountClient(session: workerSession())
            model.automaticInternetEnrollment.client = client
            defer { model.disconnect() }
            let credential = try #require(try caller.store.load())
            let receiver = try #require(try listener.store.load())
            let before = try #require(try caller.store.loadIdentity(memberID: member.id))
            let session = try await publishWorkerCall(client, peerID: member.id, credential: credential)
            let peerSession = try await publishWorkerCall(client, peerID: otherMember.id, credential: receiver)

            let renewalBoundary = Date(timeIntervalSince1970: before.expiresAt - 48 * 3600)
            callTime = renewalBoundary.addingTimeInterval(trigger == .authenticatedPeer ? -1800 : -1)
            model.setRTCTransportRoutes([.webRTC])
            model.groupDeliveryNetworkPathChanged(isAvailable: trigger != .restoredNetwork)
            #expect(model.automaticInternetEnrollment.task == nil)
            if trigger == .outgoingCall { callTime = renewalBoundary }
            try #require(model.startCall(to: .group(group.id), accountAccessID: model.accountAccessID))
            let call = model.currentCallReference
            let deadline = try #require(model.callDisconnectDeadline)
            try #require(model.setCallMuted(true, for: call))

            if trigger == .authenticatedPeer { callTime = renewalBoundary }
            harness.callSession.authenticate([otherMember.id], route: .webRTC)
            if trigger == .restoredNetwork {
                callTime = renewalBoundary
                model.groupDeliveryNetworkPathChanged(isAvailable: true)
            }
            let renewal = try #require(model.automaticInternetEnrollment.task)
            await renewal.value

            try verifyRenewedCredential(caller.store, before: before, credential: credential)
            #expect(model.currentCallReference == call && model.isMuted && model.callDisconnectDeadline == deadline)
            #expect(model.authenticatedPeerIDs == [otherMember.id])
            #expect(harness.callSession.connectCallCount == 1 && harness.callSession.retriedInternetRouteCount == 0)
            try await verifyWorkerCall(client, session: session, peerID: otherMember.id, credential: credential)
            let _: WorkerCallReply = try await client.send(
                origin: receiver.workerURL, path: peerSession, method: "DELETE", token: receiver.accessToken)
        }
    }

    private func verifyRenewedCredential(
        _ store: InternetConnectionSettingsStore, before: VerifiedDeviceIdentity,
        credential: CloudflareRealtimeConfiguration
    ) throws {
        let after = try #require(try store.loadIdentity(memberID: before.memberID))
        #expect(after.expiresAt == before.expiresAt + 28 * 86_400)
        #expect(after.sessionBinding == before.sessionBinding && after.deviceKey == before.deviceKey)
        let keptCredential = try store.load() == credential
        #expect(keptCredential)
    }

    private struct WorkerCallReply: Decodable, Sendable {
        let sessionId: String?
    }

    private func publishWorkerCall(
        _ client: InternetAccountClient, peerID: String, credential: CloudflareRealtimeConfiguration
    ) async throws -> String {
        let room = "api/rooms/" + String(repeating: "c", count: 64)
        let offer = "v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=mid:0\r\na=sctp-port:5000\r\n"
        let body = try JSONSerialization.data(withJSONObject: [
            "participantId": peerID, "offer": ["type": "offer", "sdp": offer]
        ])
        let joined: WorkerCallReply = try await client.sendJSON(
            origin: credential.workerURL, path: room + "/join", body: body, token: credential.accessToken)
        let path = room + "/sessions/" + (try #require(joined.sessionId))
        let _: WorkerCallReply = try await client.send(
            origin: credential.workerURL, path: path + "/publish", body: [:], token: credential.accessToken)
        return path
    }

    private func verifyWorkerCall(
        _ client: InternetAccountClient, session: String, peerID: String, credential: CloudflareRealtimeConfiguration
    ) async throws {
        let origin = credential.workerURL, token = credential.accessToken
        let pull = try JSONSerialization.data(withJSONObject: ["peerIds": [peerID]])
        let _: WorkerCallReply = try await client.sendJSON(
            origin: origin, path: session + "/pull", body: pull, token: token)
        let lease: WorkerCallReply = try await client.send(
            origin: origin, path: session + "/renew", body: [:], token: token)
        #expect(lease.sessionId == session.split(separator: "/").last.map(String.init))
        let _: WorkerCallReply = try await client.send(origin: origin, path: session, method: "DELETE", token: token)
    }
}
#endif

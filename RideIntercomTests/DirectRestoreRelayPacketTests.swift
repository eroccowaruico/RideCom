import Foundation
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized)
struct DirectRestoreRelayPacketTests {
    @Test func exchangesTheRequestAndResponseAndRestoresTheOriginalCallKey() throws {
        let scenario = try ReplacementScenario()
        defer { scenario.fixture.disconnect() }
        let exchange = try Exchange(scenario)
        let submission = exchange.submission
        #expect(submission.recipient == exchange.target.userID)
        #expect(submission.id == submission.id.lowercased())
        #expect(submission.sessionBinding == exchange.target.sessionBinding)
        let signingInput = try JSONSerialization.data(
            withJSONObject: [submission.recipient, submission.deviceID, submission.sessionBinding,
                             submission.id, submission.expiresAt, submission.packet],
            options: [.withoutEscapingSlashes])
        let proof = try submission.proof.verify(signingInput, purpose: .submitDirectCallRestoreRelay,
            memberID: exchange.requester.memberID, trust: scenario.trust, now: exchange.now)
        #expect(proof.principal == exchange.requester.principal)

        let reply = try exchange.reply()
        let delivered = try reply.openResponse(for: exchange.request, as: exchange.requester,
                                              trust: scenario.trust, now: exchange.now)
        let contact = try #require(exchange.backup.contacts.first)
        let batch = try delivered.restoreBatch(for: exchange.request, contact: contact, localDisplayName: "Rider",
            as: exchange.requester, verifying: (scenario.trust, exchange.now))
        let destination = scenario.replacement.viewModel.groupRepository
        try destination.restoreCallRelationships(batch, as: exchange.requester, trust: scenario.trust,
                                                 now: exchange.now.timeIntervalSince1970)
        let key = try #require(try scenario.other.viewModel.groupRepository.credential(for: scenario.directID)).secret
        #expect(try destination.credential(for: scenario.directID)?.secret == key)
        #expect(scenario.replacement.groupStore.snapshot.users.first?.id == contact.id)

        let otherRequest = try exchange.freshRequest()
        #expect(throws: DeviceIdentityProof.Failure.invalid) {
            try reply.openResponse(for: otherRequest, as: exchange.requester, trust: scenario.trust, now: exchange.now)
        }
    }

    @Test func rejectsDifferentSessionsAlteredPacketsAndUnrelatedSenders() throws {
        let scenario = try ReplacementScenario()
        defer { scenario.fixture.disconnect() }
        let exchange = try Exchange(scenario)
        let submission = exchange.submission
        let incoming = try Exchange.delivery(of: submission, from: exchange.source)
        let renewed = try Exchange.signer(for: scenario.other, in: scenario, binding: "c", now: exchange.now)
        let sibling = try scenario.fixture.peer("sibling", account: "b", at: exchange.now)
        let otherDevice = try Exchange.signer(for: sibling, in: scenario, binding: "f", now: exchange.now)
        for signer in [renewed, otherDevice] {
            #expect(throws: (any Error).self) {
                try incoming.openRequest(as: signer, trust: scenario.trust, now: exchange.now)
            }
        }
        var changed = try #require(Data(base64Encoded: submission.packet))
        changed[changed.index(before: changed.endIndex)] ^= 1
        let alteredFields: [[String: Any]] = [
            ["id": UUID().uuidString.lowercased()], ["expiresAt": submission.expiresAt - 1],
            ["packet": changed.base64EncodedString()], ["senderUserID": String(repeating: "c", count: 64)]
        ]
        for fields in alteredFields {
            let altered = try Exchange.delivery(of: submission, from: exchange.source, changes: fields)
            #expect(throws: (any Error).self) {
                try altered.openRequest(as: exchange.responder, trust: scenario.trust, now: exchange.now)
            }
        }
        let third = try scenario.fixture.peer("another-sender", account: "c", at: exchange.now)
        let thirdSigner = try Exchange.signer(for: third, in: scenario, binding: "d", now: exchange.now)
        let forwarded = try DirectCallRestoreRelayPacket.seal(
            .request(value: exchange.request), to: exchange.target, as: thirdSigner, now: exchange.now)
        let thirdIdentity = try #require(thirdSigner.identity)
        #expect(throws: DeviceIdentityProof.Failure.invalid) {
            try Exchange.delivery(of: forwarded, from: thirdIdentity).openRequest(
                as: exchange.responder, trust: scenario.trust, now: exchange.now)
        }
        #expect(throws: DeviceIdentityProof.Failure.invalid) {
            try incoming.openRequest(as: exchange.responder, trust: scenario.trust, now: exchange.now + 300)
        }
    }

    @MainActor private struct Exchange {
        let scenario: ReplacementScenario
        let now = Date()
        let requester: DeviceIdentitySigner
        let responder: DeviceIdentitySigner
        let source: VerifiedDeviceIdentity
        let target: VerifiedDeviceIdentity
        let backup: CallRelationshipBackup
        let request: CallRelationshipRestoreRequest
        let submission: DirectCallRestoreRelayPacket.Submission

        init(_ scenario: ReplacementScenario) throws {
            self.scenario = scenario
            requester = try Self.signer(for: scenario.replacement, in: scenario, binding: "e", now: now)
            responder = try Self.signer(for: scenario.other, in: scenario, binding: "f", now: now)
            source = try #require(requester.identity)
            target = try #require(responder.identity)
            backup = try scenario.old.viewModel.groupRepository.callRelationshipBackup(
                as: scenario.oldSigner, now: now.timeIntervalSince1970)
            request = try #require(try backup.directRestoreRequest(
                for: scenario.savedPersonID, to: target, as: requester, now: now))
            submission = try DirectCallRestoreRelayPacket.seal(
                .request(value: request), to: target, as: requester, now: now)
        }

        func freshRequest() throws -> CallRelationshipRestoreRequest {
            try #require(try backup.directRestoreRequest(
                for: scenario.savedPersonID, to: target, as: requester, now: now))
        }

        func reply() throws -> DirectCallRestoreRelayPacket.Delivery {
            let incoming = try Self.delivery(of: submission, from: source)
            let opened = try incoming.openRequest(as: responder, trust: scenario.trust, now: now)
            #expect(opened.replyTo.deviceID == source.deviceID)
            #expect(opened.replyTo.sessionBinding == source.sessionBinding)
            let holder = scenario.other.viewModel.groupRepository
            let matching = try holder.callRelationshipBackup(as: responder, now: now.timeIntervalSince1970)
            let response = try #require(try holder.sealDirectRestore(
                opened.request, as: responder, trust: scenario.trust, now: now, matching: matching))
            let reply = try DirectCallRestoreRelayPacket.seal(
                .response(value: response), to: opened.replyTo, as: responder, now: now)
            return try Self.delivery(of: reply, from: target)
        }

        static func signer(
            for peer: AppTestSupport.Harness, in scenario: ReplacementScenario, binding: String, now: Date
        ) throws -> DeviceIdentitySigner {
            let model = peer.viewModel
            let signer = try model.internetSettingsStore.invitationSigner(memberID: model.localMemberIdentity.memberID)
            let identity = try #require(signer.identity)
            let certificate = try testIdentityCertificate(signer: scenario.fixture.issuer, userID: identity.userID,
                deviceID: identity.deviceID, memberID: identity.memberID, deviceKey: identity.deviceKey,
                origin: identity.issuer, now: now, changes: ["sessionBinding": String(repeating: binding, count: 64)])
            let verified = try certificate.verify(origin: scenario.trust.origin,
                                                  trustedIssuerKey: scenario.trust.issuerKey, now: now)
            return try .init(memberID: identity.memberID, key: model.internetSettingsStore.deviceSigningKey(),
                             identity: verified)
        }

        static func delivery(
            of submission: DirectCallRestoreRelayPacket.Submission, from sender: VerifiedDeviceIdentity,
            changes: [String: Any] = [:]
        ) throws -> DirectCallRestoreRelayPacket.Delivery {
            let fields: [String: Any] = ["id": submission.id, "senderUserID": sender.userID,
                "expiresAt": submission.expiresAt, "packet": submission.packet]
            let data = try JSONSerialization.data(withJSONObject: fields.merging(changes) { _, new in new })
            return try JSONDecoder().decode(DirectCallRestoreRelayPacket.Delivery.self, from: data)
        }
    }
}

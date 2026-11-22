import Foundation
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized)
struct DirectRestoreDevicePublicationTests {
    @Test func replacementOpensThePublicationUsingTheConfirmedBackup() throws {
        let setup = try Setup()
        defer { setup.scenario.fixture.disconnect() }
        let address = try #require(try setup.backup.directRestoreDeviceAddress(
            for: setup.scenario.savedPersonID, as: setup.replacement, now: setup.now))
        let publication = try #require(try setup.publication())
        #expect(address.slot == publication.slot)
        let delivery = try packet(from: publication)
        let certificate = try delivery.open(at: address, as: setup.replacement, trust: setup.scenario.trust,
                                            now: setup.now)
        let selected = try #require(try setup.backup.directRestoreRecipient(
            for: setup.scenario.savedPersonID, from: [certificate], trust: setup.scenario.trust, now: setup.now))
        #expect(selected.deviceID == setup.holder.identity?.deviceID)
        #expect(try setup.backup.directRestoreRequest(
            for: setup.scenario.savedPersonID, to: selected, as: setup.replacement, now: setup.now) != nil)

        let fields: [Any] = [publication.slot, publication.reader, publication.issuedAt, publication.expiresAt,
                             publication.packet]
        let signed = try JSONSerialization.data(withJSONObject: fields, options: [.withoutEscapingSlashes])
        let signer = try publication.proof.verify(signed, purpose: .publishDirectRestoreDevice,
            memberID: setup.holder.memberID, trust: setup.scenario.trust, now: setup.now)
        #expect(signer.principal == setup.holder.principal)

        #expect(throws: GroupStorageError.identityConflict) {
            try delivery.open(at: address, as: setup.holder, trust: setup.scenario.trust, now: setup.now)
        }
        let modified = try packet(from: publication, expiresAt: publication.expiresAt - 1)
        #expect(throws: (any Error).self) {
            try modified.open(at: address, as: setup.replacement, trust: setup.scenario.trust, now: setup.now)
        }
        let time = Date(timeIntervalSince1970: Double(publication.expiresAt) / 1000 + 1)
        #expect(throws: (any Error).self) {
            try delivery.open(at: address, as: setup.replacement, trust: setup.scenario.trust, now: time)
        }
    }

    @Test func deletionStopsPublicationAndReregistrationChangesTheAddress() throws {
        let setup = try Setup()
        let scenario = setup.scenario
        defer { scenario.fixture.disconnect() }
        let original = try #require(try setup.publication())
        let originalAddr = try #require(try setup.backup.directRestoreDeviceAddress(
            for: scenario.savedPersonID, as: setup.replacement, now: setup.now))
        for model in [scenario.old.viewModel, scenario.other.viewModel] {
            model.groupDeliveryClient = nil
            let user = try #require(model.savedRemoteUsers.first?.id)
            try #require(model.removeSavedUser(user))
        }
        #expect(try setup.publication() == nil)
        _ = try scenario.fixture.completeGroupContactRegistration(from: scenario.other, to: scenario.old)
        for model in [scenario.old.viewModel, scenario.other.viewModel] {
            let user = try #require(model.savedRemoteUsers.first?.id)
            try #require(model.selectUser(user, connectIfIdle: false))
        }
        let currentContact = try #require(scenario.other.viewModel.savedRemoteUsers.first?.id)
        let renewed = try #require(try scenario.other.viewModel.groupRepository.directRestoreDevicePublication(
            for: currentContact, as: setup.holder, now: setup.now))
        #expect(renewed.slot != original.slot)
        let newlyRegistered = try packet(from: renewed)
        #expect(throws: (any Error).self) {
            try newlyRegistered.open(at: originalAddr, as: setup.replacement, trust: scenario.trust, now: setup.now)
        }
    }

    @Test func confirmedInvitationMetadataCannotReplaceTheDiscoverySeed() throws {
        let setup = try Setup()
        defer { setup.scenario.fixture.disconnect() }
        let pairID = IntercomGroup.directCallID(memberIDs: [setup.scenario.oldSigner.memberID, setup.holder.memberID])
        let pair = try #require(try setup.scenario.old.viewModel.groupRepository.credential(for: pairID))
        let data = try JSONEncoder().encode(setup.backup)
        let encoded = try #require(String(bytes: data, encoding: .utf8))
        #expect(!encoded.contains(pair.secret))
        var payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var contacts = try #require(payload["contacts"] as? [[String: Any]])
        let saved = try #require(contacts[0].removeValue(forKey: "restoreDiscoverySeed") as? String)
        #expect(saved != pair.secret)
        let contactID = setup.scenario.savedPersonID
        payload["contacts"] = contacts
        let missing = try CallRelationshipBackup.read(JSONSerialization.data(withJSONObject: payload),
            as: setup.replacement, now: setup.now.timeIntervalSince1970)
        #expect(try missing.directRestoreDeviceAddress(for: contactID, as: setup.replacement, now: setup.now) == nil)

        let fakeSeed = Data(repeating: 0, count: 32)
        contacts[0]["restoreDiscoverySeed"] = IdentityEncoding.encode(fakeSeed)
        payload["contacts"] = contacts
        let changed = try CallRelationshipBackup.read(JSONSerialization.data(withJSONObject: payload),
            as: setup.replacement, now: setup.now.timeIntervalSince1970)
        let address = try #require(try changed.directRestoreDeviceAddress(
            for: contactID, as: setup.replacement, now: setup.now))
        let publication = try #require(try setup.publication())
        #expect(address.slot != publication.slot)
        let delivery = try packet(from: publication)
        #expect(throws: (any Error).self) {
            try delivery.open(at: address, as: setup.replacement, trust: setup.scenario.trust, now: setup.now)
        }
    }

    private func packet(from publication: DirectRestoreDevicePublication, expiresAt: Int64? = nil) throws
        -> DirectRestoreDevicePublication.Delivery {
        let fields: [String: Any] = ["expiresAt": expiresAt ?? publication.expiresAt, "packet": publication.packet]
        let data = try JSONSerialization.data(withJSONObject: fields)
        return try JSONDecoder().decode(DirectRestoreDevicePublication.Delivery.self, from: data)
    }

    @MainActor private struct Setup {
        let now: Date
        let scenario: ReplacementScenario
        let backup: CallRelationshipBackup
        let holder: DeviceIdentitySigner
        let replacement: DeviceIdentitySigner
        let holderContact: UUID

        init() throws {
            scenario = try ReplacementScenario()
            now = Date()
            holder = try Self.signer(for: scenario.other, in: scenario, now: now)
            replacement = try Self.signer(for: scenario.replacement, in: scenario, now: now)
            let saved = try scenario.old.viewModel.groupRepository.callRelationshipBackup(
                as: scenario.oldSigner, now: now.timeIntervalSince1970)
            backup = try CallRelationshipBackup.read(JSONEncoder().encode(saved), as: replacement,
                                                     now: now.timeIntervalSince1970)
            holderContact = try #require(scenario.other.viewModel.savedRemoteUsers.first?.id)
        }

        func publication() throws -> DirectRestoreDevicePublication? {
            try scenario.other.viewModel.groupRepository.directRestoreDevicePublication(
                for: holderContact, as: holder, now: now)
        }

        static func signer(for peer: AppTestSupport.Harness, in scenario: ReplacementScenario,
                           now: Date) throws -> DeviceIdentitySigner {
            let model = peer.viewModel
            let memberID = model.localMemberIdentity.memberID
            let original = try model.internetSettingsStore.invitationSigner(memberID: memberID)
            let identity = try #require(original.identity)
            let certificate = try testIdentityCertificate(signer: scenario.fixture.issuer, userID: identity.userID,
                deviceID: identity.deviceID, memberID: identity.memberID, deviceKey: identity.deviceKey,
                origin: identity.issuer, now: now, changes: ["sessionBinding": String(repeating: "e", count: 64)])
            let verified = try certificate.verify(origin: scenario.trust.origin,
                                                  trustedIssuerKey: scenario.trust.issuerKey, now: now)
            return try .init(memberID: identity.memberID, key: model.internetSettingsStore.deviceSigningKey(),
                             identity: verified)
        }
    }
}

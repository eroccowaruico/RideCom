import Foundation
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized)
struct DirectRestoreRegistrationTests {
    @Test func aReregistrationRequiresTheNewAcceptanceInBothStores() throws {
        let scenario = try ReplacementScenario(); defer { scenario.fixture.disconnect() }
        let old = scenario.old.viewModel, holder = scenario.other.viewModel
        let responder = try holder.internetSettingsStore.invitationSigner(memberID: "bob")
        let requester = try scenario.replacement.viewModel.internetSettingsStore.invitationSigner(memberID: "alice")
        let identity = try #require(responder.identity)
        let trust = try #require(try holder.internetSettingsStore.identityTrust())
        let now = Date()
        let time = now.timeIntervalSince1970
        let oldBackup = try old.groupRepository.callRelationshipBackup(as: scenario.oldSigner, now: time)
        let oldContact = try #require(oldBackup.contacts.first)
        let oldRequest = try #require(try oldBackup.directRestoreRequest(
            for: oldContact.id, to: identity, as: requester, now: now))
        let prior = try holder.groupRepository.callRelationshipBackup(as: responder, now: time)
        _ = try #require(try holder.groupRepository.confirmRestore(
            oldRequest, as: responder, trust: trust, now: now, matchingDirectBackup: prior))

        for model in [old, holder] {
            model.groupDeliveryClient = nil
            let id = try #require(model.savedRemoteUsers.first?.id)
            try #require(model.removeSavedUser(id))
        }
        _ = try scenario.fixture.completeGroupContactRegistration(from: scenario.other, to: scenario.old)
        for model in [old, holder] {
            let id = try #require(model.savedRemoteUsers.first?.id)
            try #require(model.selectUser(id, connectIfIdle: false))
            #expect(model.selectedGroup?.id == scenario.directID)
        }
        let latest = try holder.groupRepository.callRelationshipBackup(as: responder, now: time)
        let newBackup = try old.groupRepository.callRelationshipBackup(as: scenario.oldSigner, now: time)
        let newContact = try #require(newBackup.contacts.first)
        #expect(newContact.restoreRecipientFingerprint == oldContact.restoreRecipientFingerprint)
        #expect(newContact.confirmedRegistrationID != oldContact.confirmedRegistrationID)
        let newRequest = try #require(try newBackup.directRestoreRequest(
            for: newContact.id, to: identity, as: requester, now: now))
        let delivered = try JSONDecoder().decode(CallRelationshipRestoreRequest.self,
                                                 from: JSONEncoder().encode(newRequest))

        for (request, backup) in [(oldRequest, latest), (oldRequest, prior), (newRequest, prior)] {
            #expect(try holder.groupRepository.confirmRestore(
                request, as: responder, trust: trust, now: now, matchingDirectBackup: backup) == nil)
        }
        let confirmation = try #require(try holder.groupRepository.confirmRestore(
            delivered, as: responder, trust: trust, now: now, matchingDirectBackup: latest))
        #expect(try confirmation.verify(for: newRequest, as: requester, trust: trust, now: now).callID
            == scenario.directID)
        let record = try #require(scenario.other.groupStore.snapshot.groups.first { $0.id == scenario.directID })
        let context = CallRelationshipRestoreContext(request: delivered, confirmation: confirmation, record: record)
        #expect(try newBackup.matchesDirectRestoreRequest(context, contactID: newContact.id))
        #expect(try !oldBackup.matchesDirectRestoreRequest(context, contactID: oldContact.id))
    }

    @Test func changingTheAcceptanceInTransitInvalidatesTheRequestSignature() throws {
        let scenario = try ReplacementScenario(); defer { scenario.fixture.disconnect() }
        let responder = try scenario.other.viewModel.internetSettingsStore.invitationSigner(memberID: "bob")
        let requester = try scenario.replacement.viewModel.internetSettingsStore.invitationSigner(memberID: "alice")
        let now = Date()
        let candidate = try scenario.old.viewModel.groupRepository.callRelationshipBackup(
            as: scenario.oldSigner, now: now.timeIntervalSince1970)
        let identity = try #require(responder.identity)
        let request = try #require(try candidate.directRestoreRequest(
            for: scenario.savedPersonID, to: identity, as: requester, now: now))
        let json = try JSONEncoder().encode(request)
        var object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        var challenge = try #require(object["challenge"] as? [String: Any])
        let expected = try #require(candidate.contacts.first?.confirmedRegistrationID)
        #expect(challenge["confirmedRegistrationID"] as? String == expected.uuidString)
        challenge["confirmedRegistrationID"] = UUID().uuidString
        object["challenge"] = challenge
        let changed = try JSONDecoder().decode(CallRelationshipRestoreRequest.self,
                                               from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: DeviceIdentityProof.Failure.invalid) {
            try changed.verifiedDirectRequester(addressedTo: responder, trust: scenario.trust, now: now)
        }
    }
}

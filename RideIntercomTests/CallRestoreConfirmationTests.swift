import Foundation
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized)
struct CallRestoreConfirmationTests {
    @Test(arguments: [false, true])
    func aSavedRelationshipCanConfirmRestoreOnlyWhileItStillExists(directCall: Bool) throws {
        let scenario = try RestoreProofFixture(); defer { scenario.fixture.disconnect() }
        let holder = scenario.other.viewModel
        let replacement = scenario.replacement.viewModel
        let responder = try holder.internetSettingsStore.invitationSigner(memberID: "bob")
        let requester = try replacement.internetSettingsStore.invitationSigner(memberID: "alice")
        let trust = try #require(try holder.internetSettingsStore.identityTrust())
        let now = Date()
        let callID = directCall ? scenario.directID : scenario.groupID
        let request = try restoreRequest(callID, to: responder, from: requester, now: now)
        let delivered = try JSONDecoder().decode(CallRelationshipRestoreRequest.self,
                                                 from: JSONEncoder().encode(request))
        let repository = holder.groupRepository
        let before = scenario.other.groupStore.snapshot
        let confirmation = try #require(try repository.confirmRestore(delivered, as: responder, trust: trust, now: now))
        let reply = try JSONDecoder().decode(CallRelationshipRestoreConfirmation.self,
                                             from: JSONEncoder().encode(confirmation))
        let verified = try reply.verify(for: request, as: requester, trust: trust, now: now)
        let requesterPrincipal = try #require(requester.principal)
        let responderPrincipal = try #require(responder.principal)
        #expect(verified.callID == callID)
        #expect(verified.previousMemberID == "alice-old")
        #expect(verified.requesterMemberID == requester.memberID)
        #expect(verified.requester == .init(principal: requesterPrincipal, publicKey: requester.publicKey))
        #expect(verified.responderMemberID == responder.memberID)
        #expect(verified.responder == .init(principal: responderPrincipal, publicKey: responder.publicKey))
        #expect(scenario.other.groupStore.snapshot == before)

        let nextRequest = try restoreRequest(callID, to: responder, from: requester, now: now)
        #expect(throws: DeviceIdentityProof.Failure.invalid) {
            try confirmation.verify(for: nextRequest, as: requester, trust: trust, now: now)
        }
        #expect(throws: DeviceIdentityProof.Failure.invalid) {
            try confirmation.verify(for: request, as: requester, trust: trust, now: now.addingTimeInterval(300))
        }

        if directCall {
            let savedPerson = try #require(holder.savedRemoteUsers.first?.id)
            try repository.removeUser(savedPerson)
        } else {
            try #require(holder.removeMember("alice-old", from: callID))
        }
        #expect(try repository.confirmRestore(nextRequest, as: responder, trust: trust, now: now) == nil)
    }

    @Test func aStaleRepositoryCannotConfirmAfterDeletionByAnotherProcess() throws {
        let scenario = try RestoreProofFixture(); defer { scenario.fixture.disconnect() }
        let holder = scenario.other.viewModel
        let responder = try holder.internetSettingsStore.invitationSigner(memberID: "bob")
        let requester = try scenario.replacement.viewModel.internetSettingsStore.invitationSigner(memberID: "alice")
        let trust = try #require(try holder.internetSettingsStore.identityTrust())
        let credentials = try #require(scenario.fixture.credentialStores["bob"])
        let stale = GroupRepository(store: scenario.other.groupStore, credentials: credentials)
        _ = try stale.load(localMemberID: responder.memberID)
        let person = try #require(holder.savedRemoteUsers.first?.id)
        try holder.groupRepository.removeUser(person)
        let now = Date()
        let request = try restoreRequest(scenario.directID, to: responder, from: requester, now: now)

        #expect(throws: GroupStorageError.changedByAnotherProcess) {
            try stale.confirmRestore(request, as: responder, trust: trust, now: now)
        }
    }

    @Test func aConfirmationCannotBeAcceptedAfterChangingTheRequestersDeviceKey() throws {
        let scenario = try RestoreProofFixture(); defer { scenario.fixture.disconnect() }
        let holder = scenario.other.viewModel
        let responder = try holder.internetSettingsStore.invitationSigner(memberID: "bob")
        let requester = try scenario.replacement.viewModel.internetSettingsStore.invitationSigner(memberID: "alice")
        let trust = try #require(try holder.internetSettingsStore.identityTrust())
        let now = Date()
        let request = try restoreRequest(scenario.directID, to: responder, from: requester, now: now)
        let confirmation = try #require(try holder.groupRepository.confirmRestore(
            request, as: responder, trust: trust, now: now))
        let changed = try scenario.fixture.peer(requester.memberID, account: "a").viewModel.internetSettingsStore
        let differentKey = try changed.invitationSigner(memberID: requester.memberID)
        #expect(differentKey.principal == requester.principal)
        #expect(differentKey.publicKey != requester.publicKey)
        #expect(throws: DeviceIdentityProof.Failure.invalid) {
            try confirmation.verify(for: request, as: differentKey, trust: trust, now: now)
        }
    }

    @Test func restoreConfirmationRequiresAValidNewDeviceForTheSavedAccount() throws {
        let scenario = try RestoreProofFixture(); defer { scenario.fixture.disconnect() }
        let holder = scenario.other.viewModel
        let responder = try holder.internetSettingsStore.invitationSigner(memberID: "bob")
        let trust = try #require(try holder.internetSettingsStore.identityTrust())
        let now = Date()
        let outsiders = [
            scenario.oldSigner,
            try scenario.fixture.peer("outsider", account: "c")
                .viewModel.internetSettingsStore.invitationSigner(memberID: "outsider")
        ]
        for requester in outsiders {
            let request = try restoreRequest(scenario.groupID, to: responder, from: requester, now: now)
            #expect(try holder.groupRepository.confirmRestore(request, as: responder, trust: trust, now: now) == nil)
        }

        let requester = try scenario.replacement.viewModel.internetSettingsStore.invitationSigner(memberID: "alice")
        let request = try restoreRequest(scenario.groupID, to: responder, from: requester, now: now)
        #expect(throws: DeviceIdentityProof.Failure.invalid) {
            try holder.groupRepository.confirmRestore(request, as: responder, trust: trust,
                                                      now: now.addingTimeInterval(300))
        }
    }

    @Test func anotherDeviceOfTheResponderCannotSubstituteItsOlderRelationship() throws {
        let scenario = try RestoreProofFixture(); defer { scenario.fixture.disconnect() }
        let primary = scenario.other.viewModel
        let oldModel = scenario.old.viewModel
        let contactID = try #require(oldModel.savedRemoteUsers.first?.id)
        try #require(oldModel.selectUser(contactID, connectIfIdle: false))
        let originalBackup = try oldModel.groupRepository.callRelationshipBackup(
            as: scenario.oldSigner, now: Date().timeIntervalSince1970)
        let unsynced = try scenario.fixture.peer("bob-other", account: "b")
        unsynced.viewModel.allowsNearbyGroupDelivery = false
        _ = try scenario.fixture.completeGroupContactRegistration(from: unsynced, to: scenario.old)
        let saved = try #require(unsynced.viewModel.savedRemoteUsers.first?.id)
        try #require(unsynced.viewModel.selectUser(saved, connectIfIdle: false))
        try #require(unsynced.viewModel.selectedGroup?.id == scenario.directID)
        let addressed = try primary.internetSettingsStore.invitationSigner(memberID: "bob")
        let other = try unsynced.viewModel.internetSettingsStore.invitationSigner(memberID: "bob-other")
        let requester = try scenario.replacement.viewModel.internetSettingsStore.invitationSigner(memberID: "alice")
        let addressedIdentity = try #require(addressed.identity)
        let otherIdentity = try #require(other.identity)
        let trust = try #require(try primary.internetSettingsStore.identityTrust())

        let now = Date()
        let backup = try CallRelationshipBackup.read(JSONEncoder().encode(originalBackup), as: requester,
                                                    now: now.timeIntervalSince1970)
        let request = try #require(try backup.directRestoreRequest(
            for: contactID, to: addressedIdentity, as: requester, now: now))
        let beforeRemoval = try #require(try primary.groupRepository.confirmRestore(
            request, as: addressed, trust: trust, now: now))
        let verified = try beforeRemoval.verify(for: request, as: requester, trust: trust, now: now)
        #expect(verified.previousMemberID == "alice-old")
        let person = try #require(primary.savedRemoteUsers.first?.id)
        try primary.groupRepository.removeUser(person)

        // There is no delivery record after the retention period. The other device still holds its own older copy.
        #expect(try backup.directRestoreRequest(for: contactID, to: otherIdentity, as: requester, now: now) == nil)
        let multipleDevices = try oldModel.groupRepository.callRelationshipBackup(
            as: scenario.oldSigner, now: now.timeIntervalSince1970)
        let savedContact = try #require(multipleDevices.contacts.first(where: { $0.id == contactID }))
        #expect(savedContact.restoreRecipientFingerprint == nil)
        #expect(try multipleDevices.directRestoreRequest(
            for: contactID, to: addressedIdentity, as: requester, now: now) == nil)
        #expect(try primary.groupRepository.confirmRestore(request, as: addressed, trust: trust, now: now) == nil)
        #expect(throws: DeviceIdentityProof.Failure.invalid) {
            _ = try unsynced.viewModel.groupRepository.confirmRestore(request, as: other, trust: trust, now: now)
        }
        let otherRequest = try restoreRequest(scenario.directID, to: other, from: requester, now: now)
        let response = try #require(try unsynced.viewModel.groupRepository.confirmRestore(
            otherRequest, as: other, trust: trust, now: now))
        let staleConfirmation = try response.verify(for: otherRequest, as: requester, trust: trust, now: now)
        #expect(staleConfirmation.previousMemberID == "alice-old")
        #expect(throws: DeviceIdentityProof.Failure.invalid) {
            try response.verify(for: request, as: requester, trust: trust, now: now)
        }
    }

    @Test func aBackupWithoutARecipientKeepsTheContactButCannotAddressARequest() throws {
        let scenario = try RestoreProofFixture(); defer { scenario.fixture.disconnect() }
        let model = scenario.old.viewModel
        let contactID = try #require(model.savedRemoteUsers.first?.id)
        try #require(model.selectUser(contactID, connectIfIdle: false))
        let now = Date()
        let time = now.timeIntervalSince1970
        let backup = try model.groupRepository.callRelationshipBackup(as: scenario.oldSigner, now: time)
        let original = try JSONEncoder().encode(backup)
        var payload = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var contact = try #require((payload["contacts"] as? [[String: Any]])?.first)
        contact.removeValue(forKey: "restoreRecipientFingerprint")
        payload["contacts"] = [contact]
        let requester = try scenario.replacement.viewModel.internetSettingsStore.invitationSigner(memberID: "alice")
        let responder = try scenario.other.viewModel.internetSettingsStore.invitationSigner(memberID: "bob")
        let identity = try #require(responder.identity)
        let previous = try CallRelationshipBackup.read(JSONSerialization.data(withJSONObject: payload),
                                                      as: requester, now: time)
        #expect(previous.contacts.map(\.id) == [contactID])
        #expect(try previous.directRestoreRequest(for: contactID, to: identity, as: requester, now: now) == nil)
        contact["restoreRecipientFingerprint"] = "not-a-fingerprint"
        payload["contacts"] = [contact]
        #expect(throws: GroupStorageError.invalidUpdate) {
            try CallRelationshipBackup.read(JSONSerialization.data(withJSONObject: payload), as: requester, now: time)
        }
    }

    @Test(arguments: [false, true])
    func restoreRejectsAConfirmationForAnotherCallOrAnExpiredRequest(expired: Bool) throws {
        let scenario = try ReplacementScenario(); defer { scenario.fixture.disconnect() }
        let store = InMemoryGroupStore(), credentials = InMemoryGroupCredentialStore()
        let repository = GroupRepository(store: store, credentials: credentials)
        _ = try repository.load(localMemberID: "alice")
        let original = store.snapshot
        let signer = try scenario.replacement.viewModel.internetSettingsStore.invitationSigner(memberID: "alice")
        let batch = try scenario.confirmedRestore()
        let first = try #require(batch.calls.first)
        let second = try #require(batch.calls.last)
        try #require(first.record.id != second.record.id)
        if expired {
            let later = Date().addingTimeInterval(300).timeIntervalSince1970
            #expect(throws: DeviceIdentityProof.Failure.invalid) {
                try repository.restoreCallRelationships(batch, as: signer, trust: scenario.trust, now: later)
            }
        } else {
            let wrong = ConfirmedCallRestore.Call(record: second.record, credential: second.credential,
                                                  request: first.request, confirmation: first.confirmation)
            let combined = ConfirmedCallRestore(owner: batch.owner, previousMemberID: batch.previousMemberID,
                                                users: batch.users, calls: [first, wrong])
            #expect(throws: GroupStorageError.invalidUpdate) {
                try repository.restoreCallRelationships(combined, as: signer, trust: scenario.trust)
            }
        }
        #expect(store.snapshot == original)
        #expect(credentials.values.isEmpty)
    }

    private func restoreRequest(
        _ callID: UUID, to responder: DeviceIdentitySigner, from requester: DeviceIdentitySigner, now: Date
    ) throws -> CallRelationshipRestoreRequest {
        let principal = try #require(responder.principal)
        let recipient = AccountDeviceBinding(principal: principal, publicKey: responder.publicKey)
        return try .init(callID: callID, recipientMemberID: responder.memberID, recipient: recipient,
                         signer: requester, now: now)
    }
}

@MainActor
private struct RestoreProofFixture {
    let fixture = AccountCallFixture()
    let old: AppTestSupport.Harness
    let other: AppTestSupport.Harness
    let replacement: AppTestSupport.Harness
    let oldSigner: DeviceIdentitySigner
    let groupID: UUID
    let directID: UUID

    init() throws {
        old = try fixture.peer("alice-old", account: "a")
        other = try fixture.peer("bob", account: "b")
        replacement = try fixture.peer("alice", account: "a")
        for peer in [old, other, replacement] { peer.viewModel.allowsNearbyGroupDelivery = false }
        groupID = try fixture.completeGroupContactRegistration(from: other, to: old)
        oldSigner = try old.viewModel.internetSettingsStore.invitationSigner(memberID: "alice-old")
        let person = try #require(other.viewModel.savedRemoteUsers.first?.id)
        try #require(other.viewModel.selectUser(person, connectIfIdle: false))
        directID = try #require(other.viewModel.selectedGroup?.id)
    }
}

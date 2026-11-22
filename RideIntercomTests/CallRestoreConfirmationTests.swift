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
        let principal = try #require(responder.principal)
        let now = Date()
        let callID = directCall ? scenario.directID : scenario.groupID
        let request = try CallRelationshipRestoreRequest(callID: callID, recipient: principal, signer: requester,
                                                         now: now)
        let delivered = try JSONDecoder().decode(CallRelationshipRestoreRequest.self,
                                                 from: JSONEncoder().encode(request))
        let repository = holder.groupRepository
        let before = scenario.other.groupStore.snapshot
        let confirmation = try #require(try repository.confirmRestore(delivered, as: responder, trust: trust, now: now))
        let reply = try JSONDecoder().decode(CallRelationshipRestoreConfirmation.self,
                                             from: JSONEncoder().encode(confirmation))
        #expect(try reply.replacedMemberID(for: request, trust: trust, now: now) == "alice-old")
        #expect(scenario.other.groupStore.snapshot == before)

        let nextRequest = try CallRelationshipRestoreRequest(callID: callID, recipient: principal, signer: requester,
                                                             now: now)
        #expect(throws: DeviceIdentityProof.Failure.invalid) {
            try confirmation.replacedMemberID(for: nextRequest, trust: trust, now: now)
        }
        #expect(throws: DeviceIdentityProof.Failure.invalid) {
            try confirmation.replacedMemberID(for: request, trust: trust, now: now.addingTimeInterval(300))
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
        let request = try CallRelationshipRestoreRequest(callID: scenario.directID,
            recipient: try #require(responder.principal), signer: requester, now: now)

        #expect(throws: GroupStorageError.changedByAnotherProcess) {
            try stale.confirmRestore(request, as: responder, trust: trust, now: now)
        }
    }

    @Test func restoreConfirmationRequiresAValidNewDeviceForTheSavedAccount() throws {
        let scenario = try RestoreProofFixture(); defer { scenario.fixture.disconnect() }
        let holder = scenario.other.viewModel
        let responder = try holder.internetSettingsStore.invitationSigner(memberID: "bob")
        let trust = try #require(try holder.internetSettingsStore.identityTrust())
        let principal = try #require(responder.principal)
        let now = Date()
        let outsiders = [
            scenario.oldSigner,
            try scenario.fixture.peer("outsider", account: "c")
                .viewModel.internetSettingsStore.invitationSigner(memberID: "outsider")
        ]
        for requester in outsiders {
            let request = try CallRelationshipRestoreRequest(callID: scenario.groupID, recipient: principal,
                                                             signer: requester, now: now)
            #expect(try holder.groupRepository.confirmRestore(request, as: responder, trust: trust, now: now) == nil)
        }

        let requester = try scenario.replacement.viewModel.internetSettingsStore.invitationSigner(memberID: "alice")
        let request = try CallRelationshipRestoreRequest(callID: scenario.groupID, recipient: principal,
                                                         signer: requester, now: now)
        #expect(throws: DeviceIdentityProof.Failure.invalid) {
            try holder.groupRepository.confirmRestore(request, as: responder, trust: trust,
                                                      now: now.addingTimeInterval(300))
        }
    }
}

@MainActor
private struct RestoreProofFixture {
    let fixture = AccountCallFixture()
    let other: AppTestSupport.Harness
    let replacement: AppTestSupport.Harness
    let oldSigner: DeviceIdentitySigner
    let groupID: UUID
    let directID: UUID

    init() throws {
        let old = try fixture.peer("alice-old", account: "a")
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

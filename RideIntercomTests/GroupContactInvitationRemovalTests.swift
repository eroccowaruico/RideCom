import CallControl
import CryptoKit
import Foundation
import RTC
import Testing
@testable import RideIntercom

extension GroupContactInvitationTests {
    @Test(arguments: [RouteKind.multipeer, .webRTC], [false, true])
    func verifiedRemovalUsesRecipientAndRemainingRiderState(route: RouteKind, riderAlreadyKnown: Bool) async throws {
        let authorHarness = AppTestSupport.makeHarness(
            groups: [], localMemberID: "group-author", enforceCallAccess: true,
            callAccessEvaluation: { _ in .init(status: .active) })
        let targetStore = try GroupStorageFixture(), observerStore = try GroupStorageFixture()
        defer { targetStore.remove(); observerStore.remove() }
        let targetHarness = AppTestSupport.makeHarness(
            groups: [], groupRepository: targetStore.repository, credentialStore: targetStore.keys,
            localMemberID: "group-target")
        let observerHarness = AppTestSupport.makeHarness(
            groups: [], groupRepository: observerStore.repository, credentialStore: observerStore.keys,
            localMemberID: "group-observer", enforceCallAccess: true,
            callAccessEvaluation: { _ in .init(status: .notPurchased) })
        let author = authorHarness.viewModel, target = targetHarness.viewModel, observer = observerHarness.viewModel
        defer { for viewModel in [author, target, observer] { viewModel.disconnect() } }

        #expect(author.createTalkGroup(name: "Mountain riders"))
        let group = try #require(author.selectedGroup)
        let inviterID = author.localMemberIdentity.memberID, targetID = target.localMemberIdentity.memberID
        let observerID = observer.localMemberIdentity.memberID
        let signer = try author.internetSettingsStore.invitationSigner(memberID: inviterID)
        let targetSigner = try target.internetSettingsStore.invitationSigner(memberID: targetID)
        let observerSigner = try observer.internetSettingsStore.invitationSigner(memberID: observerID)
        let oldURL = try #require(author.makeSelectedGroupInviteURL())
        try target.acceptInviteURL(oldURL)
        try observer.acceptInviteURL(try #require(author.makeSelectedGroupInviteURL()))

        let scenario = GroupRemovalScenario(
            author: author, targetHarness: targetHarness, observerHarness: observerHarness,
            targetStore: targetStore, observerStore: observerStore,
            group: group, signer: signer, targetSigner: targetSigner, observerSigner: observerSigner, route: route)
        try await scenario.prepareObserver(riderAlreadyKnown: riderAlreadyKnown)
        let delivery = try scenario.verifyInitialRemoval()
        try scenario.verifyRemovalAfterRestart(delivery, oldURL: oldURL)
    }
}

@MainActor
private struct GroupRemovalScenario {
    let author: IntercomViewModel
    let targetHarness: AppTestSupport.Harness
    let observerHarness: AppTestSupport.Harness
    let targetStore: GroupStorageFixture
    let observerStore: GroupStorageFixture
    let group: IntercomGroup
    let signer: DeviceIdentitySigner
    let targetSigner: DeviceIdentitySigner
    let observerSigner: DeviceIdentitySigner
    let route: RouteKind

    private var target: IntercomViewModel { targetHarness.viewModel }
    private var observer: IntercomViewModel { observerHarness.viewModel }
    private var inviterID: String { signer.memberID }
    private var targetID: String { targetSigner.memberID }
    private var observerID: String { observerSigner.memberID }

    func prepareObserver(riderAlreadyKnown: Bool) async throws {
        try authenticate(author, peers: [targetSigner, observerSigner])
        try authenticate(target, peers: [signer, observerSigner])
        try authenticate(observer, peers: riderAlreadyKnown ? [signer, targetSigner] : [signer])
        for peer in riderAlreadyKnown ? [signer, targetSigner] : [signer] {
            let active = SharedCallAccess(groupID: group.id, recipientMemberID: observerID,
                challenge: try #require(observer.peerProfiles[peer.memberID]?.challenge), revision: 1,
                hasActiveRight: peer.memberID == inviterID, activeUntil: nil, mediaReady: true,
                isEstablished: true, lastSponsoredStart: nil)
            observer.handleTransportEvent(.receivedApplicationData(peerID: peer.memberID,
                    message: .init(
                        namespace: SharedCallAccess.namespace,
                        payload: try JSONEncoder().encode(active.signed(by: peer)))))
        }
        await AppTestSupport.waitUntil { observer.callAccessState.isEstablished }
        #expect(!observer.canManageRegularGroups)
        #expect(observer.callAccessAdmittedMemberships.keys.contains(.init(rawValue: inviterID)))
        #expect(observer.callAccessAdmittedMemberships.keys.contains(.init(rawValue: targetID)) == riderAlreadyKnown)
    }

    private func authenticate(_ viewModel: IntercomViewModel, peers: [DeviceIdentitySigner]) throws {
        viewModel.handleTransportEvent(.authenticated(members: peers.map {
            .init(peer: .init(id: .init(rawValue: $0.memberID), displayName: "Rider"),
                  route: route, isConnected: true, membershipID: UUID())
        }))
        for peer in peers {
            let name = String(peer.memberID.split(separator: "-").last ?? "Rider")
            let profile = try testPeerProfile(viewModel, peerID: peer.memberID, displayName: name, signer: peer)
            viewModel.handleTransportEvent(.receivedApplicationData(peerID: peer.memberID,
                message: .init(namespace: SharedDisplayName.namespace, payload: try JSONEncoder().encode(profile))))
        }
    }

    func verifyInitialRemoval() throws -> SignedGroupRemovalDelivery {
        let continuingCall = observer.currentCallReference, targetCall = target.currentCallReference
        let targetContact = try #require(target.savedRemoteUsers.first { $0.memberIDs.contains(inviterID) })
        let observerCredential = try observer.groupRepository.credential(for: group.id)
        #expect(author.removeMember(targetID, from: group.id))
        let event = MembershipStatement(groupID: group.id, introductionID: UUID(), introducerID: inviterID,
            memberID: targetID, memberKey: targetSigner.publicKey, kind: .removal)
        let signed = try MembershipEndorsement(event, signer: signer)
        let otherKey = try DeviceIdentitySigner(memberID: inviterID, key: P256.Signing.PrivateKey())
        let untrusted = try MembershipEndorsement(event, signer: otherKey)
        let delivery = SignedGroupRemovalDelivery(
            signed: signed, untrusted: untrusted, now: Date().timeIntervalSince1970)
        try verifyDelivery(
            delivery, targetCall: targetCall, continuingCall: continuingCall,
            targetContactID: targetContact.id, observerCredential: observerCredential)
        return delivery
    }

    private func verifyDelivery(
        _ delivery: SignedGroupRemovalDelivery, targetCall: CallReference, continuingCall: CallReference,
        targetContactID: UUID, observerCredential: GroupAccessCredential?
    ) throws {
        let rejected = try delivery.deliver(delivery.untrusted, to: observer, store: observerStore.file)
        #expect(!rejected)
        #expect(observer.currentCallReference == continuingCall)
        let beforeFailure = try targetStore.file.read()
        targetStore.store.failCommit = true
        let failed = try delivery.deliver(delivery.signed, to: target, store: targetStore.file)
        #expect(!failed)
        #expect(try targetStore.file.read() == beforeFailure)
        #expect(target.currentCallReference == targetCall)
        targetStore.store.failCommit = false
        target.disconnect()
        target.reloadSavedGroups()
        target.selectGroup(try #require(target.groups.first { $0.id == group.id }))

        let appliedToTarget = try delivery.deliver(delivery.signed, to: target, store: targetStore.file)
        let appliedToObserver = try delivery.deliver(delivery.signed, to: observer, store: observerStore.file)
        #expect(appliedToTarget && appliedToObserver)
        #expect(target.activeGroupID == nil && targetHarness.callSession.connectedGroup == nil)
        #expect(try target.groupRepository.credential(for: group.id) == nil)
        #expect(target.savedRemoteUsers.contains { $0.id == targetContactID })
        #expect(observer.groups.first { $0.id == group.id }?.members.map(\.id) == [observerID, inviterID])
        #expect(observer.currentCallReference == continuingCall)
        #expect(try observer.groupRepository.credential(for: group.id) == observerCredential)
        #expect(Set(observer.callAccessAdmittedMemberships.keys.map(\.rawValue)) == [inviterID])
        #expect(
            observerHarness.callSession.audioPolicies.last?.peerPolicy
                == .admittedMemberships(observer.callAccessAdmittedMemberships))
        #expect(observer.peerProfiles[targetID] == nil)
    }

    func verifyRemovalAfterRestart(_ delivery: SignedGroupRemovalDelivery, oldURL: URL) throws {
        // Lose the in-memory receive state after the commit, as after a restart
        // between saving and returning a delivery acknowledgement.
        observer.disconnect()
        let savedObserver = try observerStore.file.read(), savedTarget = try targetStore.file.read()
        let observerAfterRestart = AppTestSupport.makeHarness(groups: [], groupRepository: observerStore.restart(),
            credentialStore: observerStore.keys, localMemberID: observerID).viewModel
        let targetAfterRestart = AppTestSupport.makeHarness(groups: [], groupRepository: targetStore.restart(),
            credentialStore: targetStore.keys, localMemberID: targetID).viewModel
        defer { observerAfterRestart.disconnect(); targetAfterRestart.disconnect() }
        let targetRetry = try delivery.deliver(delivery.signed, to: targetAfterRestart, store: targetStore.file)
        let observerRetry = try delivery.deliver(delivery.signed, to: observerAfterRestart, store: observerStore.file)
        #expect(targetRetry && observerRetry)
        #expect(try observerStore.file.read() == savedObserver)
        #expect(try targetStore.file.read() == savedTarget)
        #expect(try !delivery.deliver(delivery.untrusted, to: targetAfterRestart, store: targetStore.file))
        #expect(try !delivery.deliver(delivery.untrusted, to: observerAfterRestart, store: observerStore.file))
        let changedTarget = try MembershipEndorsement(
            .init(
                groupID: group.id, introductionID: delivery.signed.statement.introductionID,
                introducerID: inviterID, memberID: observerID, memberKey: observerSigner.publicKey, kind: .removal),
            signer: signer)
        #expect(try !delivery.deliver(changedTarget, to: observerAfterRestart, store: observerStore.file))
        #expect(try observerStore.file.read() == savedObserver)
        #expect(throws: GroupInviteTokenError.retiredGroupLink) { try targetAfterRestart.acceptInviteURL(oldURL) }
        observerAfterRestart.selectGroup(try #require(observerAfterRestart.groups.first { $0.id == group.id }))
        try authenticate(observerAfterRestart, peers: [signer, targetSigner])
        #expect(observerAfterRestart.peerProfiles[targetID]?.verified == nil)
        #expect(observerAfterRestart.groups.first?.members.contains { $0.id == targetID } == false)
        try verifyInterruptedDelivery(observerAfterRestart, delivery: delivery)
    }

    private func verifyInterruptedDelivery(
        _ observerAfterRestart: IntercomViewModel, delivery: SignedGroupRemovalDelivery
    ) throws {
        let lateRemoval = try MembershipEndorsement(.init(groupID: group.id, introductionID: UUID(),
                introducerID: inviterID, memberID: targetID, memberKey: targetSigner.publicKey, kind: .removal),
            signer: signer)
        observerStore.store.failAfterCommit = true
        let lostResponse = try delivery.deliver(lateRemoval, to: observerAfterRestart, store: observerStore.file)
        #expect(!lostResponse)
        observerStore.store.failAfterCommit = false
        observerAfterRestart.disconnect()
        observerAfterRestart.reloadSavedGroups()
        let afterInterruptedSave = try #require(try observerStore.file.read())
        #expect(
            afterInterruptedSave.groupRemovalReceipts.map(\.eventID) == [
                delivery.signed.statement.introductionID, lateRemoval.statement.introductionID
            ])
        #expect(try delivery.deliver(lateRemoval, to: observerAfterRestart, store: observerStore.file))
        #expect(try observerStore.file.read() == afterInterruptedSave)
    }
}

@MainActor
private struct SignedGroupRemovalDelivery {
    let signed: MembershipEndorsement
    let untrusted: MembershipEndorsement
    let now: TimeInterval

    // A fixture supplies the author's authorization. The signed message and actual saved
    // introducer key still have to match before applying it to the recipient App.
    func deliver(_ removal: MembershipEndorsement, to viewModel: IntercomViewModel, store: FileGroupStore)
        throws -> Bool {
        let statement = removal.statement
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let receipt = GroupSnapshot.GroupRemovalReceipt(
            groupID: statement.groupID, eventID: statement.introductionID,
            signedDigest: Data(SHA256.hash(data: try encoder.encode(removal))), expiresAt: now + 3600)
        do {
            if try viewModel.groupRepository.hasAppliedGroupRemoval(receipt, now: now) { return true }
        } catch GroupStorageError.invalidUpdate { return false }
        guard statement.kind == .removal,
              !statement.memberID.hasPrefix(GroupMember.pendingInvitePrefix),
              !statement.introducerID.hasPrefix(GroupMember.pendingInvitePrefix),
              statement.introducerID != statement.memberID,
            let roster = try store.read()?.groups.first(where: { $0.id == statement.groupID })
        else { return false }
        return removal.hasKnownSignature(in: roster)
            && viewModel.applyGroupMemberRemoval(statement.memberID, from: statement.groupID, receipt: receipt)
    }
}

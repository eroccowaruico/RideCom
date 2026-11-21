import CryptoKit
import Foundation
import RTC
import Testing
@testable import RideIntercom

extension GroupContactInvitationTests {
    @Test func anotherGroupMemberCanVerifyTheIntroducerButNeedsCurrentMembershipState() throws {
        let now = Date()
        let fixture = try prepared(now: { now })
        let authorHarness = fixture.author, recipientHarness = fixture.recipient
        let token = fixture.token
        let observerHarness = AppTestSupport.makeHarness(
            groups: [], localMemberID: "group-observer", callAccessNow: { now })
        defer {
            for viewModel in [authorHarness.viewModel, recipientHarness.viewModel, observerHarness.viewModel] {
                viewModel.stopContactInvitationSession()
                viewModel.disconnect()
            }
        }
        let group = try #require(token.invitedGroup), invitation = try #require(token.directInvitation)
        let authorSigner = try authorHarness.viewModel.internetSettingsStore.invitationSigner(
            memberID: token.inviterMemberID)
        let observer = try prepareObserver(
            observerHarness, introducedBy: authorHarness.viewModel, signer: authorSigner, group: group)
        let acknowledgement = try exchangeInvitationReplies(
            from: authorHarness.viewModel, to: recipientHarness.viewModel, token: token, id: invitation.context.id)
        let memberKey = try #require(acknowledgement.inviteeDeviceKey)
        let memberID = acknowledgement.inviteeMemberID
        #expect(!observer.members.contains { $0.id == memberID })
        #expect(
            authorHarness.groupStore.snapshot.groups.first { $0.id == group.id }?.invitationDeviceKeys?[memberID]
                == memberKey)

        let accepted = try verifyThirdDeviceAcknowledgement(
            acknowledgement, observer: observer, authorID: authorSigner.memberID,
            group: group, times: (now.timeIntervalSince1970, invitation.context.expiresAt))
        let acknowledgementBytes = try JSONEncoder().encode(acknowledgement)

        // Compare a detached statement which has no group key, contact label, or grant data.
        let statement = MembershipStatement(groupID: group.id, introductionID: invitation.context.id,
            introducerID: authorSigner.memberID, memberID: memberID, memberKey: memberKey)
        let endorsement = try MembershipEndorsement(statement, signer: authorSigner)
        let bytes = try JSONEncoder().encode(endorsement)
        #expect(bytes.count < acknowledgementBytes.count)
        let text = try #require(String(bytes: bytes, encoding: .utf8))
        #expect(!text.contains(group.secret) && !text.contains(token.groupSecret) && !text.contains(invitation.secret))
        #expect(!text.contains("displayName") && !text.contains("invitedGroupDigest"))
        let decoded = try JSONDecoder().decode(MembershipEndorsement.self, from: bytes)
        let active: Set<UUID> = [statement.introductionID]
        let verifiedRecipient = try #require(acknowledgement.acceptanceProof).verify(
            acknowledgement.identityMessage(), purpose: .acceptInvitation, memberID: memberID)
        #expect(decoded.verifies(in: observer, peer: verifiedRecipient, activeIntroductions: active))
        #expect(!decoded.verifies(in: observer, peer: verifiedRecipient, activeIntroductions: []))
        #expect(!decoded.verifies(in: observer, peer: verifiedRecipient, activeIntroductions: [UUID()]))
        try verifyEndorsementRejectsUntrustedInputs(decoded, bytes: bytes, observer: observer, peer: verifiedRecipient)

        #expect(authorHarness.viewModel.removeMember(memberID, from: group.id))
        // Issuer-side removal does not invalidate already signed bytes at an uninformed observer.
        try acknowledgement.verifyAcknowledgement(of: accepted, trust: nil, now: now.timeIntervalSince1970)
        #expect(decoded.verifies(in: observer, peer: verifiedRecipient, activeIntroductions: active))
        #expect(!decoded.verifies(in: observer, peer: verifiedRecipient, activeIntroductions: []))
        print("Third-device membership: acknowledgement=\(acknowledgementBytes.count)B detached=\(bytes.count)B")
    }

    private func prepareObserver(
        _ observerHarness: AppTestSupport.Harness, introducedBy authorModel: IntercomViewModel,
        signer authorSigner: DeviceIdentitySigner, group: ContactGroupInvitation
    ) throws -> GroupSnapshot.Record {
        let observerModel = observerHarness.viewModel
        let linkForObserver = try GroupInviteToken.make(
            authority: authorModel.invitationAuthority, signer: authorSigner,
            groupID: group.id, groupName: group.name, groupSecret: group.secret, inviterMemberID: authorSigner.memberID)
        try observerModel.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: linkForObserver))
        let savedAuthor = try #require(observerModel.savedRemoteUsers.first)
        #expect(observerModel.removeSavedUser(savedAuthor.id))
        observerModel.disconnect()
        observerModel.reloadSavedGroups()
        let stored = try GroupSnapshot.decode(observerHarness.groupStore.snapshot.encoded())
        let observer = try #require(stored.groups.first { $0.id == group.id })
        #expect(observer.invitationDeviceKeys == [authorSigner.memberID: authorSigner.publicKey])
        #expect(observerModel.savedRemoteUsers.isEmpty)
        return observer
    }

    private func exchangeInvitationReplies(
        from authorModel: IntercomViewModel, to recipientModel: IntercomViewModel, token: GroupInviteToken, id: UUID
    ) throws -> DirectInvitationReceipt {
        try recipientModel.acceptContactInviteURL(GroupInviteTokenCodec.joinURL(for: token, contactBootstrap: true))
        let reply = try recipientModel.contactReplyURLForSharing(
            id, expectedAccountAccessID: recipientModel.accountAccessID)
        try authorModel.receiveContactReplyURL(reply)
        let confirmation = try authorModel.contactReplyURLForSharing(
            id, expectedAccountAccessID: authorModel.accountAccessID)
        let acknowledgement = try ContactReplyURL.decode(confirmation)
        try recipientModel.receiveContactReplyURL(confirmation)
        return acknowledgement
    }

    private func verifyThirdDeviceAcknowledgement(
        _ acknowledgement: DirectInvitationReceipt, observer: GroupSnapshot.Record, authorID: String,
        group: ContactGroupInvitation, times: (now: TimeInterval, expiresAt: TimeInterval)
    ) throws -> DirectInvitationReceipt {
        // A third device can verify the signed contact acknowledgement without the invitation capability.
        var accepted = acknowledgement
        accepted.kind = .accepted
        accepted.acknowledgementProof = nil
        #expect(acknowledgement.invitation?.invitedGroupID == observer.id)
        #expect(acknowledgement.acknowledgementProof?.publicKey == observer.invitationDeviceKeys?[authorID])
        try acknowledgement.verifyAcknowledgement(of: accepted, trust: nil, now: times.now)
        #expect(acknowledgement.invitation?.invitedGroupDigest == (try group.digest()))
        let afterExpiry = times.expiresAt + 1
        #expect(throws: DeviceIdentityProof.Failure.invalid) {
            try acknowledgement.verifyAcknowledgement(of: accepted, trust: nil, now: afterExpiry)
        }

        return accepted
    }

    private func verifyEndorsementRejectsUntrustedInputs(
        _ endorsement: MembershipEndorsement, bytes: Data, observer: GroupSnapshot.Record, peer: VerifiedDeviceProof
    ) throws {
        let statement = endorsement.statement
        var otherGroup = observer; otherGroup.id = UUID()
        #expect(!endorsement.verifies(in: otherGroup, peer: peer, activeIntroductions: [statement.introductionID]))
        let unsignedPeer = testIdentitySigner("other-rider")
        let unknownIdentity = try unsignedPeer.sign(Data(), purpose: .shareDisplayName).verify(
            Data(), purpose: .shareDisplayName, memberID: unsignedPeer.memberID)
        #expect(
            !endorsement.verifies(
                in: observer, peer: unknownIdentity, activeIntroductions: [statement.introductionID]))
        let otherKey = try DeviceIdentitySigner(memberID: statement.introducerID, key: P256.Signing.PrivateKey())
        let unpinned = try MembershipEndorsement(statement, signer: otherKey)
        #expect(!unpinned.verifies(in: observer, peer: peer, activeIntroductions: [statement.introductionID]))
        var changedBytes = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var changedStatement = try #require(changedBytes["statement"] as? [String: Any])
        changedStatement["groupID"] = otherGroup.id.uuidString
        changedBytes["statement"] = changedStatement
        let changed = try JSONDecoder().decode(
            MembershipEndorsement.self, from: JSONSerialization.data(withJSONObject: changedBytes))
        #expect(!changed.verifies(in: otherGroup, peer: peer, activeIntroductions: [statement.introductionID]))
    }

    @Test func reorderedMembershipChangesConvergeAfterReloadWithOnlyExplicitReadmission() throws {
        let now = Date()
        let fixture = try prepared(now: { now })
        let authorHarness = fixture.author, recipientHarness = fixture.recipient
        let token = fixture.token
        let observerHarness = AppTestSupport.makeHarness(
            groups: [], localMemberID: "group-observer", callAccessNow: { now })
        defer {
            for viewModel in [authorHarness.viewModel, recipientHarness.viewModel, observerHarness.viewModel] {
                viewModel.stopContactInvitationSession(); viewModel.disconnect()
            }
        }
        let inviter = try authorHarness.viewModel.internetSettingsStore.invitationSigner(
            memberID: token.inviterMemberID)
        let group = try #require(token.invitedGroup)
        let receiver = try currentObserverRoster(
            observerHarness, invitedBy: authorHarness.viewModel, signer: inviter, group: group)
        let original = try acceptMembership(
            GroupInviteTokenCodec.joinURL(for: token, contactBootstrap: true),
            id: #require(token.directInvitation).context.id,
            invitation: fixture, groupID: group.id, introducerID: inviter.memberID)
        #expect(authorHarness.viewModel.removeMember(original.memberID, from: group.id))
        let removal = MembershipStatement(groupID: group.id, introductionID: UUID(), introducerID: inviter.memberID,
            memberID: original.memberID, memberKey: original.memberKey, kind: .removal)
        let draft = GroupInvitationDraft(name: "Ride again", suggestedName: "Rider")
        #expect(
            authorHarness.viewModel.saveGroupInvitations(
                groupID: group.id, creating: false, name: "", selected: [], newPeople: [draft]) == group.id)
        let share = try authorHarness.viewModel.prepareContactPersonShare(
            draft.id, expectedAccountAccessID: authorHarness.viewModel.accountAccessID)
        var fresh = try acceptMembership(
            share.url, id: share.id, invitation: fixture, groupID: group.id, introducerID: inviter.memberID)
        fresh.observedRemovals = [removal.introductionID]
        let events = try [original, removal, fresh].map { try MembershipEndorsement($0, signer: inviter) }
        #expect(authorHarness.viewModel.removeMember(fresh.memberID, from: group.id))
        let laterRemoval = MembershipStatement(
            groupID: group.id, introductionID: UUID(), introducerID: inviter.memberID,
            memberID: original.memberID, memberKey: original.memberKey, kind: .removal)
        let signedLaterRemoval = try MembershipEndorsement(laterRemoval, signer: inviter)
        let otherKey = try DeviceIdentitySigner(memberID: inviter.memberID, key: P256.Signing.PrivateKey())
        let untrustedRemoval = try MembershipEndorsement(laterRemoval, signer: otherKey)
        try verifyReorderedEventsAfterReload(
            events, in: receiver, original: original, fresh: fresh,
            laterRemovals: (signed: signedLaterRemoval, untrusted: untrustedRemoval))
    }

    private func currentObserverRoster(
        _ observer: AppTestSupport.Harness, invitedBy authorModel: IntercomViewModel,
        signer: DeviceIdentitySigner, group: ContactGroupInvitation
    ) throws -> GroupSnapshot.Record {
        let observerInvite = try GroupInviteToken.make(authority: authorModel.invitationAuthority, signer: signer,
            groupID: group.id, groupName: group.name, groupSecret: group.secret, inviterMemberID: signer.memberID)
        try observer.viewModel.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: observerInvite))
        observer.viewModel.disconnect()
        observer.viewModel.reloadSavedGroups()
        return try #require(observer.groupStore.snapshot.groups.first { $0.id == group.id })
    }

    private func acceptMembership(
        _ url: URL, id: UUID, invitation: PreparedInvitation, groupID: UUID, introducerID: String
    ) throws -> MembershipStatement {
        let author = invitation.author
        let recipientModel = invitation.recipient.viewModel
        try recipientModel.acceptContactInviteURL(url)
        recipientModel.stopContactInvitationSession()
        try author.viewModel.receiveContactReplyURL(
            recipientModel.contactReplyURLForSharing(id, expectedAccountAccessID: recipientModel.accountAccessID))
        let memberID = recipientModel.localMemberIdentity.memberID
        let record = try #require(author.groupStore.snapshot.groups.first { $0.id == groupID })
        let memberKey = try #require(record.invitationDeviceKeys?[memberID])
        return MembershipStatement(groupID: groupID, introductionID: id, introducerID: introducerID,
            memberID: memberID, memberKey: memberKey)
    }

    private func verifyReorderedEventsAfterReload(
        _ events: [MembershipEndorsement], in receiver: GroupSnapshot.Record,
        original: MembershipStatement, fresh: MembershipStatement,
        laterRemovals: (signed: MembershipEndorsement, untrusted: MembershipEndorsement)
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RideIntercom-membership-order-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for sequence in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
            let file = directory.appendingPathComponent(sequence.map(String.init).joined() + ".json")
            var journal = MembershipJournal()
            var received = Set<Int>()
            for index in sequence {
                received.insert(index)
                let acceptedEvent = journal.receive(events[index], in: receiver)
                #expect(acceptedEvent)
                try JSONEncoder().encode(journal).write(to: file, options: .atomic)
                journal = try JSONDecoder().decode(MembershipJournal.self, from: Data(contentsOf: file))
                let expected = received.contains(1) ? (received.contains(2) ? fresh.introductionID : nil)
                    : (received.contains(0) ? original.introductionID : nil)
                #expect(journal.activeIntroductions(for: original.memberID) == Set([expected].compactMap { $0 }))
                let acceptedRetry = journal.receive(events[index], in: receiver)
                #expect(!acceptedRetry, "Retry has no additional write")
            }
            #expect(journal.activeIntroductions(for: original.memberID) == [fresh.introductionID])

            let acceptedUntrusted = journal.receive(laterRemovals.untrusted, in: receiver)
            #expect(!acceptedUntrusted)
            #expect(journal.activeIntroductions(for: original.memberID) == [fresh.introductionID])
            let acceptedRemoval = journal.receive(laterRemovals.signed, in: receiver)
            #expect(acceptedRemoval)
            try JSONEncoder().encode(journal).write(to: file, options: .atomic)
            journal = try JSONDecoder().decode(MembershipJournal.self, from: Data(contentsOf: file))
            let acceptedRestoreReplay = journal.receive(events[2], in: receiver)
            #expect(!acceptedRestoreReplay)
            #expect(journal.activeIntroductions(for: original.memberID).isEmpty)
        }
    }

    @Test func concurrentIntroducersKeepAllValidReadmissionsForTheSameDevice() throws {
        let firstAuthor = testIdentitySigner("parallel-author-a"),
            secondAuthor = testIdentitySigner("parallel-author-c")
        let rider = testIdentitySigner("parallel-rider")
        let secondDeviceUsingSameID = try DeviceIdentitySigner(memberID: rider.memberID, key: P256.Signing.PrivateKey())
        let group = try IntercomGroup(name: "Riders", members: [
            GroupMember(id: "parallel-observer", displayName: "Observer"),
                GroupMember(id: firstAuthor.memberID, displayName: "A"),
                GroupMember(id: secondAuthor.memberID, displayName: "C")
        ])
        var roster = GroupSnapshot.Record(group)
        roster.invitationDeviceKeys = [
            firstAuthor.memberID: firstAuthor.publicKey, secondAuthor.memberID: secondAuthor.publicKey
        ]
        func signed(by author: DeviceIdentitySigner, kind: MembershipStatementKind, observes: [UUID] = [],
                    member: DeviceIdentitySigner? = nil) throws -> MembershipEndorsement {
            let member = member ?? rider
            return try MembershipEndorsement(
                .init(
                    groupID: group.id, introductionID: UUID(), introducerID: author.memberID,
                    memberID: member.memberID, memberKey: member.publicKey, kind: kind, observedRemovals: observes),
                signer: author)
        }
        let first = try signed(by: firstAuthor, kind: .removal), second = try signed(by: secondAuthor, kind: .removal)
        let removals = [first.statement.introductionID, second.statement.introductionID]
        let onlyOne = try signed(by: firstAuthor, kind: .admission, observes: [removals[0]])
        let agreedA = try signed(by: firstAuthor, kind: .admission, observes: removals)
        let agreedC = try signed(by: secondAuthor, kind: .admission, observes: Array(removals.reversed()))
        let changedKey = try signed(
            by: secondAuthor, kind: .admission, observes: removals, member: secondDeviceUsingSameID)
        let laterRemoval = try signed(by: firstAuthor, kind: .removal)
        let explicitRestore = try signed(
            by: secondAuthor, kind: .admission, observes: removals + [laterRemoval.statement.introductionID])
        let events = [first, second, onlyOne, agreedA, agreedC]

        for order in [[0, 1, 2, 3, 4], [4, 3, 2, 1, 0], [3, 0, 2, 4, 1], [2, 0, 1, 4, 3]] {
            var journal = try replayMembershipEvents(events, in: roster, order: order)
            let active = journal.activeIntroductions(for: rider.memberID)
            #expect(active == [agreedA.statement.introductionID, agreedC.statement.introductionID])
            let peer = try rider.sign(Data(), purpose: .shareDisplayName).verify(
                Data(), purpose: .shareDisplayName, memberID: rider.memberID)
            #expect(agreedA.verifies(in: roster, peer: peer, activeIntroductions: active))
            #expect(agreedC.verifies(in: roster, peer: peer, activeIntroductions: active))
            #expect(!onlyOne.verifies(in: roster, peer: peer, activeIntroductions: active))
            let conflict = journal.receive(changedKey, in: roster)
            #expect(conflict && journal.activeIntroductions(for: rider.memberID).isEmpty)
            let removed = journal.receive(laterRemoval, in: roster)
            #expect(removed && journal.activeIntroductions(for: rider.memberID).isEmpty)
            let restored = journal.receive(explicitRestore, in: roster)
            let restoredIntroductions: Set<UUID> = [explicitRestore.statement.introductionID]
            #expect(restored && journal.activeIntroductions(for: rider.memberID) == restoredIntroductions)
        }
    }

    private func replayMembershipEvents(
        _ events: [MembershipEndorsement], in roster: GroupSnapshot.Record, order: [Int]
    ) throws -> MembershipJournal {
        var journal = MembershipJournal()
        for index in order {
            let applied = journal.receive(events[index], in: roster)
            #expect(applied)
            journal = try JSONDecoder().decode(MembershipJournal.self, from: JSONEncoder().encode(journal))
        }
        return journal
    }
}

enum MembershipStatementKind: String, Codable { case admission, removal }

struct MembershipStatement: Codable {
    let groupID: UUID
    let introductionID: UUID
    let introducerID: String
    let memberID: String
    let memberKey: String
    var kind = MembershipStatementKind.admission
    var observedRemovals: [UUID] = []

    func signingData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Data("rideintercom.membership-experiment.v2\0".utf8) + (try encoder.encode(self))
    }
}

struct MembershipEndorsement: Codable {
    let statement: MembershipStatement
    let proof: DeviceIdentityProof

    init(_ statement: MembershipStatement, signer: DeviceIdentitySigner) throws {
        self.statement = statement
        self.proof = try signer.sign(statement.signingData(), purpose: .acknowledgeInvitation)
    }

    @MainActor
    func verifies(in group: GroupSnapshot.Record, peer: VerifiedDeviceProof, activeIntroductions: Set<UUID>) -> Bool {
        guard statement.kind == .admission, activeIntroductions.contains(statement.introductionID),
              statement.memberID == peer.memberID, statement.memberKey == peer.publicKey else { return false }
        return hasKnownSignature(in: group)
    }

    @MainActor
    func hasKnownSignature(in group: GroupSnapshot.Record) -> Bool {
        guard statement.groupID == group.id,
              group.invitationDeviceKeys?[statement.introducerID] == proof.publicKey else { return false }
        return (try? proof.verify(statement.signingData(), purpose: .acknowledgeInvitation,
                                  memberID: statement.introducerID)) != nil
    }
}

private struct MembershipJournal: Codable {
    private(set) var events: [UUID: MembershipEndorsement] = [:]

    @MainActor
    mutating func receive(_ event: MembershipEndorsement, in group: GroupSnapshot.Record) -> Bool {
        let id = event.statement.introductionID
        guard events[id] == nil, event.hasKnownSignature(in: group) else { return false }
        events[id] = event
        return true
    }

    func activeIntroductions(for memberID: String) -> Set<UUID> {
        let statements = events.values.map(\.statement).filter { $0.memberID == memberID }
        let removals = Set(statements.filter { $0.kind == .removal }.map(\.introductionID))
        let admissions = statements.filter { $0.kind == .admission && Set($0.observedRemovals) == removals }
        // Several introducers can confirm the same member key. Competing keys
        // for one ID need a new removal and an explicit readmission.
        guard Set(admissions.map(\.memberKey)).count == 1 else { return [] }
        return Set(admissions.map(\.introductionID))
    }
}

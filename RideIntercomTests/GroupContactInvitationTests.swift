import CryptoKit
import Foundation
import RTC
import Testing
@testable import RideIntercom

@MainActor
struct GroupContactInvitationTests {
    @Test func anUnsignedGroupAttachmentCannotBeAddedToAContactInvitation() throws {
        let token = try ContactInvitationSession.makeToken(authority: testInvitationAuthority(), signer: testIdentitySigner("group-author"),
            displayName: "Author", now: Date().timeIntervalSince1970)
        var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(token)) as? [String: Any])
        fields["invitedGroup"] = ["id": UUID().uuidString, "name": "Forged group", "secret": "forged-secret"]
        let data = try JSONSerialization.data(withJSONObject: fields)
        let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let url = try #require(URL(string: "rideintercom://contact?token=" + encoded))
        #expect(throws: (any Error).self) { try GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true) }
    }
    @Test func aCombinedInvitationBindsTheGroupWithoutPuttingItsKeyInTheReceipt() throws {
        let author = testIdentitySigner("group-author"), recipient = testIdentitySigner("group-recipient")
        let authority = testInvitationAuthority(), now = Date().timeIntervalSince1970
        let group = ContactGroupInvitation(id: UUID(), name: "Mountain riders", secret: "group-only-key")
        let token = try ContactInvitationSession.makeToken(authority: authority, signer: author, displayName: "Author", now: now, invitedGroup: group)
        let url = try GroupInviteTokenCodec.joinURL(for: token, contactBootstrap: true)
        let decoded = try GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true)
        #expect(decoded.invitedGroup == group)
        #expect(decoded.groupID != group.id && decoded.groupSecret != group.secret)
        let accepted = try decoded.accept(signer: recipient, displayName: "Recipient", now: now, contactBootstrap: true)
        #expect(try authority.verify(accepted.receipt, now: now) != nil)
        #expect(accepted.receipt.invitation?.invitedGroupID == group.id)
        #expect(accepted.receipt.invitation?.invitedGroupDigest == (try group.digest()))
        #expect(!String(decoding: try JSONEncoder().encode(accepted.receipt), as: UTF8.self).contains(group.secret))
        var changed = accepted.receipt
        changed.invitation?.invitedGroupID = UUID()
        #expect(try authority.verify(changed, now: now) == nil)
        var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        fields["invitedGroup"] = ["id": group.id.uuidString, "name": group.name, "secret": "replaced-key"]
        let tampered = try JSONDecoder().decode(GroupInviteToken.self, from: JSONSerialization.data(withJSONObject: fields))
        #expect(throws: (any Error).self) { try tampered.validate(contactBootstrap: true) }
        #expect(!tampered.verifySignature())
    }

    private func prepared(recipientCredentials: GroupCredentialStoring? = nil, now: @escaping @MainActor () -> Date = Date.init) throws -> (AppTestSupport.Harness, AppTestSupport.Harness, GroupInviteToken, UUID) {
        let author = AppTestSupport.makeHarness(groups: [], localMemberID: "group-author", callAccessNow: now)
        let recipient = AppTestSupport.makeHarness(groups: [], credentialStore: recipientCredentials, localMemberID: "group-recipient", callAccessNow: now)
        author.viewModel.contactSessionFactory = { RecordingCallSession() }; recipient.viewModel.contactSessionFactory = { RecordingCallSession() }
        #expect(author.viewModel.createTalkGroup(name: "Mountain riders"))
        author.viewModel.disconnect()
        let group = try #require(author.viewModel.groups.first), person = UUID()
        try author.viewModel.groupRepository.saveContactPerson(person, name: "My new rider")
        author.viewModel.reloadSavedGroups()
        let credential = try #require(try author.viewModel.groupRepository.credential(for: group.id))
        let token = try ContactInvitationSession.makeToken(authority: author.viewModel.invitationAuthority,
            signer: author.viewModel.internetSettingsStore.invitationSigner(memberID: "group-author"), displayName: "Author", now: now().timeIntervalSince1970,
            invitedGroup: .init(id: group.id, name: group.name, secret: credential.secret))
        try author.viewModel.groupRepository.stageContactInvitation(token, now: now().timeIntervalSince1970, personID: person)
        author.viewModel.reloadSavedGroups()
        return (author, recipient, token, person)
    }

    @Test func registrationAndGroupJoinCompleteTogetherAndTheReplyFillsOnlyItsSlot() throws {
        let (a, b, token, person) = try prepared()
        defer { a.viewModel.disconnect(); b.viewModel.disconnect() }
        let target = try #require(token.invitedGroup), id = try #require(token.directInvitation?.context.id)
        #expect(a.viewModel.groups.first(where: { $0.id == target.id })?.members.count == 2)
        let url = try GroupInviteTokenCodec.joinURL(for: token, contactBootstrap: true)
        try b.viewModel.acceptContactInviteURL(url)
        #expect(b.viewModel.savedRemoteUsers.count == 1)
        #expect(b.viewModel.groups.contains { $0.id == target.id && $0.kind == .group })
        #expect(try b.viewModel.groupRepository.credential(for: target.id)?.secret == target.secret)
        let reply = try b.viewModel.contactReplyURLForSharing(id, expectedAccountAccessID: b.viewModel.accountAccessID)
        try a.viewModel.receiveContactReplyURL(reply)
        #expect(a.viewModel.savedRemoteUsers.first?.id == person)
        #expect(a.viewModel.savedRemoteUsers.first?.resolvedDisplayName == "My new rider")
        #expect(a.viewModel.groups.first(where: { $0.id == target.id })?.members.map(\.id) == ["group-author", "group-recipient"])
        let direct = try #require(b.viewModel.groups.first(where: { $0.kind == .direct }))
        #expect(try b.viewModel.groupRepository.credential(for: direct.id)?.secret != target.secret)
        #expect(try a.viewModel.groupRepository.credential(for: direct.id) == b.viewModel.groupRepository.credential(for: direct.id))
        let before = b.groupStore.snapshot
        try b.viewModel.acceptContactInviteURL(url)
        #expect(b.groupStore.snapshot == before)
        let ack = try a.viewModel.contactReplyURLForSharing(id, expectedAccountAccessID: a.viewModel.accountAccessID)
        try b.viewModel.receiveContactReplyURL(ack)
        #expect(b.viewModel.contactInvitationRecord(id)?.state == .delivered)
        #expect(b.viewModel.groups.contains { $0.id == target.id })
        #expect(a.viewModel.activeGroupID == nil && b.viewModel.activeGroupID == nil)
    }

    @Test func anotherGroupMemberCanVerifyTheIntroducerButNeedsCurrentMembershipState() throws {
        let now = Date()
        let (a, b, token, _) = try prepared(now: { now })
        let c = AppTestSupport.makeHarness(groups: [], localMemberID: "group-observer", callAccessNow: { now })
        defer {
            for vm in [a.viewModel, b.viewModel, c.viewModel] {
                vm.stopContactInvitationSession()
                vm.disconnect()
            }
        }
        let group = try #require(token.invitedGroup), invitation = try #require(token.directInvitation)
        let author = try a.viewModel.internetSettingsStore.invitationSigner(memberID: token.inviterMemberID)
        let linkForObserver = try GroupInviteToken.make(authority: a.viewModel.invitationAuthority, signer: author,
            groupID: group.id, groupName: group.name, groupSecret: group.secret, inviterMemberID: author.memberID)
        try c.viewModel.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: linkForObserver))
        let savedAuthor = try #require(c.viewModel.savedRemoteUsers.first)
        #expect(c.viewModel.removeSavedUser(savedAuthor.id))
        c.viewModel.disconnect()
        c.viewModel.reloadSavedGroups()
        let stored = try GroupSnapshot.decode(c.groupStore.snapshot.encoded())
        let observer = try #require(stored.groups.first { $0.id == group.id })
        #expect(observer.invitationDeviceKeys == [author.memberID: author.publicKey])
        #expect(c.viewModel.savedRemoteUsers.isEmpty)

        try b.viewModel.acceptContactInviteURL(GroupInviteTokenCodec.joinURL(for: token, contactBootstrap: true))
        let reply = try b.viewModel.contactReplyURLForSharing(invitation.context.id, expectedAccountAccessID: b.viewModel.accountAccessID)
        try a.viewModel.receiveContactReplyURL(reply)
        let confirmation = try a.viewModel.contactReplyURLForSharing(invitation.context.id, expectedAccountAccessID: a.viewModel.accountAccessID)
        let acknowledgement = try ContactReplyURL.decode(confirmation)
        try b.viewModel.receiveContactReplyURL(confirmation)
        let memberKey = try #require(acknowledgement.inviteeDeviceKey)
        let memberID = acknowledgement.inviteeMemberID
        #expect(!observer.members.contains { $0.id == memberID })
        #expect(a.groupStore.snapshot.groups.first { $0.id == group.id }?.invitationDeviceKeys?[memberID] == memberKey)

        // A third device can verify the signed contact acknowledgement without the invitation capability.
        var accepted = acknowledgement
        accepted.kind = .accepted
        accepted.acknowledgementProof = nil
        #expect(acknowledgement.invitation?.invitedGroupID == observer.id)
        #expect(acknowledgement.acknowledgementProof?.publicKey == observer.invitationDeviceKeys?[author.memberID])
        try acknowledgement.verifyAcknowledgement(of: accepted, trust: nil, now: now.timeIntervalSince1970)
        #expect(acknowledgement.invitation?.invitedGroupDigest == (try group.digest()))
        let afterExpiry = invitation.context.expiresAt + 1
        #expect(throws: DeviceIdentityProof.Failure.invalid) {
            try acknowledgement.verifyAcknowledgement(of: accepted, trust: nil, now: afterExpiry)
        }
        let acknowledgementBytes = try JSONEncoder().encode(acknowledgement)

        // Compare a detached statement which has no group key, contact label, or grant data.
        let statement = MembershipStatement(groupID: group.id, introductionID: invitation.context.id,
            introducerID: author.memberID, memberID: memberID, memberKey: memberKey)
        let endorsement = try MembershipEndorsement(statement, signer: author)
        let bytes = try JSONEncoder().encode(endorsement)
        #expect(bytes.count < acknowledgementBytes.count)
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(!text.contains(group.secret) && !text.contains(token.groupSecret) && !text.contains(invitation.secret))
        #expect(!text.contains("displayName") && !text.contains("invitedGroupDigest"))
        let decoded = try JSONDecoder().decode(MembershipEndorsement.self, from: bytes)
        let verifiedRecipient = try #require(acknowledgement.acceptanceProof).verify(
            acknowledgement.identityMessage(), purpose: .acceptInvitation, memberID: memberID)
        #expect(decoded.verifies(in: observer, peer: verifiedRecipient, activeIntroductions: [statement.introductionID]))
        #expect(!decoded.verifies(in: observer, peer: verifiedRecipient, activeIntroductions: []))
        #expect(!decoded.verifies(in: observer, peer: verifiedRecipient, activeIntroductions: [UUID()]))
        var otherGroup = observer; otherGroup.id = UUID()
        #expect(!decoded.verifies(in: otherGroup, peer: verifiedRecipient, activeIntroductions: [statement.introductionID]))
        let unsignedPeer = testIdentitySigner("other-rider")
        let unknownIdentity = try unsignedPeer.sign(Data(), purpose: .shareDisplayName).verify(
            Data(), purpose: .shareDisplayName, memberID: unsignedPeer.memberID)
        #expect(!decoded.verifies(in: observer, peer: unknownIdentity, activeIntroductions: [statement.introductionID]))
        let otherKey = try DeviceIdentitySigner(memberID: author.memberID, key: P256.Signing.PrivateKey())
        let unpinned = try MembershipEndorsement(statement, signer: otherKey)
        #expect(!unpinned.verifies(in: observer, peer: verifiedRecipient, activeIntroductions: [statement.introductionID]))
        var changedBytes = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var changedStatement = try #require(changedBytes["statement"] as? [String: Any])
        changedStatement["groupID"] = otherGroup.id.uuidString
        changedBytes["statement"] = changedStatement
        let changed = try JSONDecoder().decode(MembershipEndorsement.self, from: JSONSerialization.data(withJSONObject: changedBytes))
        #expect(!changed.verifies(in: otherGroup, peer: verifiedRecipient, activeIntroductions: [statement.introductionID]))

        #expect(a.viewModel.removeMember(memberID, from: group.id))
        // Issuer-side removal does not invalidate already signed bytes at an uninformed observer.
        try acknowledgement.verifyAcknowledgement(of: accepted, trust: nil, now: now.timeIntervalSince1970)
        #expect(decoded.verifies(in: observer, peer: verifiedRecipient, activeIntroductions: [statement.introductionID]))
        #expect(!decoded.verifies(in: observer, peer: verifiedRecipient, activeIntroductions: []))
        print("Third-device membership: acknowledgement=\(acknowledgementBytes.count)B detached=\(bytes.count)B")
    }

    private struct MembershipStatement: Codable {
        enum Kind: String, Codable { case admission, removal }

        let groupID: UUID
        let introductionID: UUID
        let introducerID: String
        let memberID: String
        let memberKey: String
        var kind = Kind.admission
        var observedRemovals: [UUID] = []

        func signingData() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return Data("rideintercom.membership-experiment.v2\0".utf8) + (try encoder.encode(self))
        }
    }

    private struct MembershipEndorsement: Codable {
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

    @Test func reorderedMembershipChangesConvergeAfterReloadWithOnlyExplicitReadmission() throws {
        let now = Date()
        let (a, b, token, _) = try prepared(now: { now })
        let c = AppTestSupport.makeHarness(groups: [], localMemberID: "group-observer", callAccessNow: { now })
        defer {
            for vm in [a.viewModel, b.viewModel, c.viewModel] { vm.stopContactInvitationSession(); vm.disconnect() }
        }
        let inviter = try a.viewModel.internetSettingsStore.invitationSigner(memberID: token.inviterMemberID)
        let group = try #require(token.invitedGroup)
        let observerInvite = try GroupInviteToken.make(authority: a.viewModel.invitationAuthority, signer: inviter,
            groupID: group.id, groupName: group.name, groupSecret: group.secret, inviterMemberID: inviter.memberID)
        try c.viewModel.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: observerInvite))
        c.viewModel.disconnect()
        c.viewModel.reloadSavedGroups()
        let receiver = try #require(c.groupStore.snapshot.groups.first { $0.id == group.id })

        func accept(_ url: URL, id: UUID) throws -> MembershipStatement {
            try b.viewModel.acceptContactInviteURL(url)
            b.viewModel.stopContactInvitationSession()
            try a.viewModel.receiveContactReplyURL(b.viewModel.contactReplyURLForSharing(id, expectedAccountAccessID: b.viewModel.accountAccessID))
            let memberID = b.viewModel.localMemberIdentity.memberID
            let record = try #require(a.groupStore.snapshot.groups.first { $0.id == group.id })
            let memberKey = try #require(record.invitationDeviceKeys?[memberID])
            return MembershipStatement(groupID: group.id, introductionID: id, introducerID: inviter.memberID,
                memberID: memberID, memberKey: memberKey)
        }
        let original = try accept(GroupInviteTokenCodec.joinURL(for: token, contactBootstrap: true),
                                  id: #require(token.directInvitation).context.id)
        #expect(a.viewModel.removeMember(original.memberID, from: group.id))
        let removal = MembershipStatement(groupID: group.id, introductionID: UUID(), introducerID: inviter.memberID,
            memberID: original.memberID, memberKey: original.memberKey, kind: .removal)
        let draft = GroupInvitationDraft(name: "Ride again", suggestedName: "Rider")
        #expect(a.viewModel.saveGroupInvitations(groupID: group.id, creating: false, name: "", selected: [], newPeople: [draft]) == group.id)
        let share = try a.viewModel.prepareContactPersonShare(draft.id, expectedAccountAccessID: a.viewModel.accountAccessID)
        var fresh = try accept(share.url, id: share.id)
        fresh.observedRemovals = [removal.introductionID]
        let events = try [original, removal, fresh].map { try MembershipEndorsement($0, signer: inviter) }
        #expect(a.viewModel.removeMember(fresh.memberID, from: group.id))
        let laterRemoval = MembershipStatement(groupID: group.id, introductionID: UUID(), introducerID: inviter.memberID,
            memberID: original.memberID, memberKey: original.memberKey, kind: .removal)
        let signedLaterRemoval = try MembershipEndorsement(laterRemoval, signer: inviter)
        let otherKey = try DeviceIdentitySigner(memberID: inviter.memberID, key: P256.Signing.PrivateKey())
        let untrustedRemoval = try MembershipEndorsement(laterRemoval, signer: otherKey)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RideIntercom-membership-order-" + UUID().uuidString)
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

            let acceptedUntrusted = journal.receive(untrustedRemoval, in: receiver)
            #expect(!acceptedUntrusted)
            #expect(journal.activeIntroductions(for: original.memberID) == [fresh.introductionID])
            let acceptedRemoval = journal.receive(signedLaterRemoval, in: receiver)
            #expect(acceptedRemoval)
            try JSONEncoder().encode(journal).write(to: file, options: .atomic)
            journal = try JSONDecoder().decode(MembershipJournal.self, from: Data(contentsOf: file))
            let acceptedRestoreReplay = journal.receive(events[2], in: receiver)
            #expect(!acceptedRestoreReplay)
            #expect(journal.activeIntroductions(for: original.memberID).isEmpty)
        }
    }

    @Test func concurrentIntroducersKeepAllValidReadmissionsForTheSameDevice() throws {
        let a = testIdentitySigner("parallel-author-a"), c = testIdentitySigner("parallel-author-c")
        let b = testIdentitySigner("parallel-rider")
        let secondDeviceUsingSameID = try DeviceIdentitySigner(memberID: b.memberID, key: P256.Signing.PrivateKey())
        let group = try IntercomGroup(name: "Riders", members: [
            GroupMember(id: "parallel-observer", displayName: "Observer"),
            GroupMember(id: a.memberID, displayName: "A"), GroupMember(id: c.memberID, displayName: "C"),
        ])
        var roster = GroupSnapshot.Record(group)
        roster.invitationDeviceKeys = [a.memberID: a.publicKey, c.memberID: c.publicKey]
        func signed(by author: DeviceIdentitySigner, kind: MembershipStatement.Kind, observes: [UUID] = [],
                    member: DeviceIdentitySigner? = nil) throws -> MembershipEndorsement {
            let member = member ?? b
            return try MembershipEndorsement(.init(groupID: group.id, introductionID: UUID(), introducerID: author.memberID,
                memberID: member.memberID, memberKey: member.publicKey, kind: kind, observedRemovals: observes), signer: author)
        }
        let first = try signed(by: a, kind: .removal), second = try signed(by: c, kind: .removal)
        let removals = [first.statement.introductionID, second.statement.introductionID]
        let onlyOne = try signed(by: a, kind: .admission, observes: [removals[0]])
        let agreedA = try signed(by: a, kind: .admission, observes: removals)
        let agreedC = try signed(by: c, kind: .admission, observes: Array(removals.reversed()))
        let changedKey = try signed(by: c, kind: .admission, observes: removals, member: secondDeviceUsingSameID)
        let laterRemoval = try signed(by: a, kind: .removal)
        let explicitRestore = try signed(by: c, kind: .admission, observes: removals + [laterRemoval.statement.introductionID])
        let events = [first, second, onlyOne, agreedA, agreedC]

        func reload(_ journal: MembershipJournal) throws -> MembershipJournal {
            try JSONDecoder().decode(MembershipJournal.self, from: JSONEncoder().encode(journal))
        }
        for order in [[0, 1, 2, 3, 4], [4, 3, 2, 1, 0], [3, 0, 2, 4, 1], [2, 0, 1, 4, 3]] {
            var journal = MembershipJournal()
            for index in order {
                let applied = journal.receive(events[index], in: roster)
                #expect(applied)
                journal = try reload(journal)
            }
            let active = journal.activeIntroductions(for: b.memberID)
            #expect(active == [agreedA.statement.introductionID, agreedC.statement.introductionID])
            let peer = try b.sign(Data(), purpose: .shareDisplayName).verify(Data(), purpose: .shareDisplayName, memberID: b.memberID)
            #expect(agreedA.verifies(in: roster, peer: peer, activeIntroductions: active))
            #expect(agreedC.verifies(in: roster, peer: peer, activeIntroductions: active))
            #expect(!onlyOne.verifies(in: roster, peer: peer, activeIntroductions: active))
            let conflict = journal.receive(changedKey, in: roster)
            #expect(conflict && journal.activeIntroductions(for: b.memberID).isEmpty)
            let removed = journal.receive(laterRemoval, in: roster)
            #expect(removed && journal.activeIntroductions(for: b.memberID).isEmpty)
            let restored = journal.receive(explicitRestore, in: roster)
            #expect(restored && journal.activeIntroductions(for: b.memberID) == [explicitRestore.statement.introductionID])
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

    @Test(arguments: [RouteKind.multipeer, .webRTC], [false, true])
    func verifiedRemovalUsesRecipientAndRemainingRiderState(route: RouteKind, riderAlreadyKnown: Bool) async throws {
        let a = AppTestSupport.makeHarness(groups: [], localMemberID: "group-author", enforceCallAccess: true,
            callAccessEvaluation: { _ in .init(status: .active) })
        let targetStore = try GroupStorageFixture(), observerStore = try GroupStorageFixture()
        defer { targetStore.remove(); observerStore.remove() }
        let b = AppTestSupport.makeHarness(groups: [], groupRepository: targetStore.repository, credentialStore: targetStore.keys,
            localMemberID: "group-target")
        let c = AppTestSupport.makeHarness(groups: [], groupRepository: observerStore.repository, credentialStore: observerStore.keys,
            localMemberID: "group-observer", enforceCallAccess: true, callAccessEvaluation: { _ in .init(status: .notPurchased) })
        let author = a.viewModel, target = b.viewModel, observer = c.viewModel
        defer { for vm in [author, target, observer] { vm.disconnect() } }

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

        func authenticate(_ vm: IntercomViewModel, peers: [DeviceIdentitySigner]) throws {
            vm.handleTransportEvent(.authenticated(members: peers.map {
                .init(peer: .init(id: .init(rawValue: $0.memberID), displayName: "Rider"),
                      route: route, isConnected: true, membershipID: UUID())
            }))
            for peer in peers {
                let name = String(peer.memberID.split(separator: "-").last ?? "Rider")
                let profile = try testPeerProfile(vm, peerID: peer.memberID, displayName: name, signer: peer)
                vm.handleTransportEvent(.receivedApplicationData(peerID: peer.memberID,
                    message: .init(namespace: SharedDisplayName.namespace, payload: try JSONEncoder().encode(profile))))
            }
        }

        try authenticate(author, peers: [targetSigner, observerSigner])
        try authenticate(target, peers: [signer, observerSigner])
        try authenticate(observer, peers: riderAlreadyKnown ? [signer, targetSigner] : [signer])
        for peer in riderAlreadyKnown ? [signer, targetSigner] : [signer] {
            let active = SharedCallAccess(groupID: group.id, recipientMemberID: observerID,
                challenge: try #require(observer.peerProfiles[peer.memberID]?.challenge), revision: 1,
                hasActiveRight: peer.memberID == inviterID, activeUntil: nil, mediaReady: true, isEstablished: true, lastSponsoredStart: nil)
            observer.handleTransportEvent(.receivedApplicationData(peerID: peer.memberID,
                message: .init(namespace: SharedCallAccess.namespace, payload: try JSONEncoder().encode(active.signed(by: peer)))))
        }
        await AppTestSupport.waitUntil { observer.callAccessState.isEstablished }
        #expect(!observer.canManageRegularGroups)
        #expect(observer.callAccessAdmittedMemberships.keys.contains(.init(rawValue: inviterID)))
        #expect(observer.callAccessAdmittedMemberships.keys.contains(.init(rawValue: targetID)) == riderAlreadyKnown)
        let continuingCall = observer.currentCallReference, targetCall = target.currentCallReference
        let targetContact = try #require(target.savedRemoteUsers.first { $0.memberIDs.contains(inviterID) })
        let observerCredential = try observer.groupRepository.credential(for: group.id)

        #expect(author.removeMember(targetID, from: group.id))
        let event = MembershipStatement(groupID: group.id, introductionID: UUID(), introducerID: inviterID,
            memberID: targetID, memberKey: targetSigner.publicKey, kind: .removal)
        let signed = try MembershipEndorsement(event, signer: signer)
        let otherKey = try DeviceIdentitySigner(memberID: inviterID, key: P256.Signing.PrivateKey())
        let untrusted = try MembershipEndorsement(event, signer: otherKey)
        let now = Date().timeIntervalSince1970, expiresAt = now + 3600

        // A fixture supplies the author's authorization. The signed message and actual saved
        // introducer key still have to match before applying it to the recipient App.
        func deliver(_ removal: MembershipEndorsement, to vm: IntercomViewModel, store: FileGroupStore) throws -> Bool {
            let statement = removal.statement
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let receipt = GroupSnapshot.GroupRemovalReceipt(groupID: statement.groupID, eventID: statement.introductionID,
                signedDigest: Data(SHA256.hash(data: try encoder.encode(removal))), expiresAt: expiresAt)
            do {
                if try vm.groupRepository.hasAppliedGroupRemoval(receipt, now: now) { return true }
            } catch GroupStorageError.invalidUpdate { return false }
            guard statement.kind == .removal,
                  !statement.memberID.hasPrefix(GroupMember.pendingInvitePrefix),
                  !statement.introducerID.hasPrefix(GroupMember.pendingInvitePrefix),
                  statement.introducerID != statement.memberID,
                  let roster = try store.read()?.groups.first(where: { $0.id == statement.groupID }) else { return false }
            return removal.hasKnownSignature(in: roster)
                && vm.applyGroupMemberRemoval(statement.memberID, from: statement.groupID, receipt: receipt)
        }

        let rejected = try deliver(untrusted, to: observer, store: observerStore.file)
        #expect(!rejected)
        #expect(observer.currentCallReference == continuingCall)
        let beforeFailure = try targetStore.file.read()
        targetStore.store.failCommit = true
        let failed = try deliver(signed, to: target, store: targetStore.file)
        #expect(!failed)
        #expect(try targetStore.file.read() == beforeFailure)
        #expect(target.currentCallReference == targetCall)
        targetStore.store.failCommit = false
        target.disconnect()
        target.reloadSavedGroups()
        target.selectGroup(try #require(target.groups.first { $0.id == group.id }))

        let appliedToTarget = try deliver(signed, to: target, store: targetStore.file)
        let appliedToObserver = try deliver(signed, to: observer, store: observerStore.file)
        #expect(appliedToTarget && appliedToObserver)
        #expect(target.activeGroupID == nil && b.callSession.connectedGroup == nil)
        #expect(try target.groupRepository.credential(for: group.id) == nil)
        #expect(target.savedRemoteUsers.contains { $0.id == targetContact.id })
        #expect(observer.groups.first { $0.id == group.id }?.members.map(\.id) == [observerID, inviterID])
        #expect(observer.currentCallReference == continuingCall)
        #expect(try observer.groupRepository.credential(for: group.id) == observerCredential)
        #expect(Set(observer.callAccessAdmittedMemberships.keys.map(\.rawValue)) == [inviterID])
        #expect(c.callSession.audioPolicies.last?.peerPolicy == .admittedMemberships(observer.callAccessAdmittedMemberships))
        #expect(observer.peerProfiles[targetID] == nil)

        // Lose the in-memory receive state after the commit, as after a restart
        // between saving and returning a delivery acknowledgement.
        observer.disconnect()
        let savedObserver = try observerStore.file.read(), savedTarget = try targetStore.file.read()
        let observerAfterRestart = AppTestSupport.makeHarness(groups: [], groupRepository: observerStore.restart(),
            credentialStore: observerStore.keys, localMemberID: observerID).viewModel
        let targetAfterRestart = AppTestSupport.makeHarness(groups: [], groupRepository: targetStore.restart(),
            credentialStore: targetStore.keys, localMemberID: targetID).viewModel
        defer { observerAfterRestart.disconnect(); targetAfterRestart.disconnect() }
        let targetRetry = try deliver(signed, to: targetAfterRestart, store: targetStore.file)
        let observerRetry = try deliver(signed, to: observerAfterRestart, store: observerStore.file)
        #expect(targetRetry && observerRetry)
        #expect(try observerStore.file.read() == savedObserver)
        #expect(try targetStore.file.read() == savedTarget)
        #expect(try !deliver(untrusted, to: targetAfterRestart, store: targetStore.file))
        #expect(try !deliver(untrusted, to: observerAfterRestart, store: observerStore.file))
        let changedTarget = try MembershipEndorsement(.init(groupID: group.id, introductionID: event.introductionID,
            introducerID: inviterID, memberID: observerID, memberKey: observerSigner.publicKey, kind: .removal), signer: signer)
        #expect(try !deliver(changedTarget, to: observerAfterRestart, store: observerStore.file))
        #expect(try observerStore.file.read() == savedObserver)
        #expect(throws: GroupInviteTokenError.retiredGroupLink) { try targetAfterRestart.acceptInviteURL(oldURL) }
        observerAfterRestart.selectGroup(try #require(observerAfterRestart.groups.first { $0.id == group.id }))
        try authenticate(observerAfterRestart, peers: [signer, targetSigner])
        #expect(observerAfterRestart.peerProfiles[targetID]?.verified == nil)
        #expect(observerAfterRestart.groups.first?.members.contains { $0.id == targetID } == false)

        let lateRemoval = try MembershipEndorsement(.init(groupID: group.id, introductionID: UUID(),
            introducerID: inviterID, memberID: targetID, memberKey: targetSigner.publicKey, kind: .removal), signer: signer)
        observerStore.store.failAfterCommit = true
        let lostResponse = try deliver(lateRemoval, to: observerAfterRestart, store: observerStore.file)
        #expect(!lostResponse)
        observerStore.store.failAfterCommit = false
        observerAfterRestart.disconnect()
        observerAfterRestart.reloadSavedGroups()
        let afterInterruptedSave = try #require(try observerStore.file.read())
        #expect(afterInterruptedSave.groupRemovalReceipts.map(\.eventID) == [event.introductionID, lateRemoval.statement.introductionID])
        #expect(try deliver(lateRemoval, to: observerAfterRestart, store: observerStore.file))
        #expect(try observerStore.file.read() == afterInterruptedSave)
    }

    @Test func failedRegistrationDoesNotLeaveOnlyAContactOrOnlyAGroup() throws {
        let (a, b, token, _) = try prepared()
        defer { a.viewModel.disconnect(); b.viewModel.disconnect() }
        let before = b.groupStore.snapshot, url = try GroupInviteTokenCodec.joinURL(for: token, contactBootstrap: true)
        b.groupStore.failSaving = true
        #expect(throws: (any Error).self) { try b.viewModel.acceptContactInviteURL(url) }
        #expect(b.groupStore.snapshot == before)
        b.groupStore.failSaving = false
        b.viewModel.reloadSavedGroups()
        try b.viewModel.acceptContactInviteURL(url)
        #expect(b.viewModel.savedRemoteUsers.count == 1)
        #expect(b.viewModel.groups.contains { $0.id == token.invitedGroup?.id })
    }

    @Test func deletingTheGroupCancelsItsInvitationWithoutDeletingTheSavedName() throws {
        let (a, b, token, person) = try prepared()
        defer { a.viewModel.disconnect(); b.viewModel.disconnect() }
        let target = try #require(token.invitedGroup), id = try #require(token.directInvitation?.context.id)
        try b.viewModel.acceptContactInviteURL(GroupInviteTokenCodec.joinURL(for: token, contactBootstrap: true))
        let reply = try b.viewModel.contactReplyURLForSharing(id, expectedAccountAccessID: b.viewModel.accountAccessID)
        a.viewModel.deleteGroup(target.id)
        #expect(a.viewModel.contactInvitationRecord(id)?.state == .cancelled)
        let before = a.groupStore.snapshot
        #expect(throws: (any Error).self) { try a.viewModel.receiveContactReplyURL(reply) }
        #expect(a.groupStore.snapshot == before)
        #expect(a.viewModel.contactPerson(person)?.resolvedDisplayName == "My new rider")
        #expect(a.viewModel.savedRemoteUsers.isEmpty)
    }

    @Test(arguments: [false, true])
    func removingAnExpiredGroupInvitationKeepsThePersonWithoutRenewingTheGroup(wholeGroup: Bool) throws {
        var now = Date()
        let (a, b, token, person) = try prepared(now: { now })
        let vm = a.viewModel
        defer { vm.disconnect(); b.viewModel.disconnect() }
        let target = try #require(token.invitedGroup)
        let context = try #require(token.directInvitation?.context)
        now = Date(timeIntervalSince1970: context.expiresAt)
        try vm.groupRepository.removeExpiredContactInvitations(now: now.timeIntervalSince1970)
        let expired = try #require(vm.contactInvitationRecord(context.id))
        try #require(expired.state == .expired)

        if wholeGroup {
            #expect(vm.deleteGroup(target.id))
        } else {
            #expect(vm.removeMember(expired.pendingGroupMemberID, from: target.id))
        }
        #expect(vm.contactInvitationRecord(context.id)?.state == .cancelled)

        // Simulate an older build that removed the target but left the expired record renewable.
        var oldSnapshot = a.groupStore.snapshot
        oldSnapshot.contactInvitations.removeAll { $0.id == expired.id }
        oldSnapshot.contactInvitations.append(expired)
        try a.groupStore.commit(oldSnapshot)
        vm.reloadSavedGroups()
        #expect(vm.contactInvitationRecord(context.id)?.state == .cancelled)
        #expect(vm.contactPerson(person)?.resolvedDisplayName == "My new rider")
        #expect(vm.contactPersonInvitationForSharing(person) == nil)

        let share = try vm.prepareContactPersonShare(person, expectedAccountAccessID: vm.accountAccessID)
        let replacement = try GroupInviteTokenCodec.decodeJoinURL(share.url, contactBootstrap: true)
        #expect(replacement.invitedGroup == nil)
        #expect(vm.contactInvitationRecord(share.id)?.personID == person)
        #expect(vm.groups.first(where: { $0.id == target.id })?.members.map(\.id) == (wholeGroup ? nil : ["group-author"]))
    }

    @Test(arguments: [false, true])
    func sharingAnExpiredInvitationWithItsGroupSlotIntactRenewsTheSamePersonAndGroup(cleanedUp: Bool) throws {
        var now = Date()
        let (a, b, token, person) = try prepared(now: { now })
        let vm = a.viewModel
        defer { vm.disconnect(); b.viewModel.disconnect() }
        let target = try #require(token.invitedGroup)
        let id = try #require(token.directInvitation?.context.id)
        let initial = try #require(vm.contactInvitationRecord(id))
        now = Date(timeIntervalSince1970: initial.expiresAt - 0.001)
        let stillValid = try vm.prepareContactPersonShare(person, expectedAccountAccessID: vm.accountAccessID)
        #expect(stillValid.id == id)

        now = Date(timeIntervalSince1970: initial.expiresAt)
        if cleanedUp {
            try vm.groupRepository.removeExpiredContactInvitations(now: now.timeIntervalSince1970)
            vm.reloadSavedGroups()
        }
        #expect(vm.contactPersonInvitationForSharing(person)?.state == (cleanedUp ? .expired : .pending))

        let renewed = try vm.prepareContactPersonShare(person, expectedAccountAccessID: vm.accountAccessID)
        let replacement = try GroupInviteTokenCodec.decodeJoinURL(renewed.url, contactBootstrap: true)
        let record = try #require(vm.contactInvitationRecord(renewed.id))
        #expect(renewed.id != id && vm.contactInvitationRecord(id) == nil)
        #expect(record.personID == person && record.sent == false)
        #expect(replacement.invitedGroup == target)
        #expect(vm.groups.first(where: { $0.id == target.id })?.members.map(\.id) == ["group-author", record.pendingGroupMemberID])
    }

    @Test func deletingAReceivedGroupStopsItsReplyAndKeepsTheRegisteredContactAndPairCall() throws {
        let keys = InMemoryGroupCredentialStore()
        let (a, b, token, _) = try prepared(recipientCredentials: keys)
        defer { a.viewModel.disconnect(); b.viewModel.disconnect() }
        let target = try #require(token.invitedGroup), id = try #require(token.directInvitation?.context.id)
        let url = try GroupInviteTokenCodec.joinURL(for: token, contactBootstrap: true)
        try b.viewModel.acceptContactInviteURL(url)
        let person = try #require(b.viewModel.savedRemoteUsers.first)
        let pair = try #require(b.viewModel.groups.first(where: { $0.kind == .direct }))
        let pairKey = try b.viewModel.groupRepository.credential(for: pair.id)
        let replyKey = try #require(b.viewModel.contactInvitationRecord(id)?.credentialReference)
        #expect(b.viewModel.contactInvitationID == id && keys.values[replyKey] != nil)
        let saved = b.groupStore.snapshot
        b.groupStore.failSaving = true
        b.viewModel.deleteGroup(target.id)
        #expect(b.groupStore.snapshot == saved && keys.values[replyKey] != nil)
        #expect(b.viewModel.contactInvitationID == id)
        b.groupStore.failSaving = false; b.viewModel.reloadSavedGroups()
        #expect(b.viewModel.resumeContactInvitation(id))
        b.viewModel.deleteGroup(target.id)
        #expect(b.viewModel.contactInvitationRecord(id)?.state == .cancelled)
        #expect(b.viewModel.contactInvitationRecord(id)?.credentialReference == nil)
        #expect(b.viewModel.contactInvitationID == nil && keys.values[replyKey] == nil)
        #expect(b.viewModel.savedRemoteUsers == [person])
        #expect(b.viewModel.groups.contains { $0.id == pair.id })
        #expect(try b.viewModel.groupRepository.credential(for: pair.id) == pairKey)
        b.viewModel.reloadSavedGroups()
        let after = b.groupStore.snapshot
        #expect(throws: (any Error).self) { try b.viewModel.acceptContactInviteURL(url) }
        #expect(b.groupStore.snapshot == after && !b.viewModel.groups.contains { $0.id == target.id })
        #expect(!b.viewModel.canShareContactReply(try #require(b.viewModel.contactInvitationRecord(id))))
    }

    @Test func loadingAnOldReceivedReplyWithoutItsGroupCancelsItWithoutChangingACurrentCall() throws {
        let keys = InMemoryGroupCredentialStore()
        let (a, b, token, _) = try prepared(recipientCredentials: keys)
        defer { a.viewModel.disconnect(); b.viewModel.disconnect() }
        let target = try #require(token.invitedGroup), id = try #require(token.directInvitation?.context.id)
        let url = try GroupInviteTokenCodec.joinURL(for: token, contactBootstrap: true)
        try b.viewModel.acceptContactInviteURL(url)
        let replyKey = try #require(b.viewModel.contactInvitationRecord(id)?.credentialReference)
        b.viewModel.stopContactInvitationSession()
        b.groupStore.snapshot.groups.removeAll { $0.id == target.id } // Previously saved by the old deletion path.
        let orphaned = b.groupStore.snapshot
        b.groupStore.failSaving = true
        b.viewModel.reloadSavedGroups()
        #expect(b.groupStore.snapshot == orphaned && keys.values[replyKey] != nil)
        b.groupStore.failSaving = false
        b.viewModel.reloadSavedGroups()
        #expect(b.viewModel.contactInvitationRecord(id)?.state == .cancelled)
        #expect(b.viewModel.contactInvitationRecord(id)?.credentialReference == nil && keys.values[replyKey] == nil)
        b.viewModel.setSoundIsolationEnabled(false)
        #expect(b.viewModel.createTalkGroup(name: "Unrelated call"))
        let current = b.viewModel.currentCallReference
        #expect(throws: (any Error).self) { try b.viewModel.acceptContactInviteURL(url) }
        #expect(b.viewModel.currentCallReference == current)
        #expect(b.viewModel.savedRemoteUsers.count == 1)
    }

    @Test func cancellationReleasesTheGroupSlotAndKeepsThePerson() throws {
        let (a, b, token, person) = try prepared()
        defer { a.viewModel.disconnect(); b.viewModel.disconnect() }
        let target = try #require(token.invitedGroup), id = try #require(token.directInvitation?.context.id)
        try a.viewModel.cancelContactInvitation(id)
        #expect(a.viewModel.groups.first(where: { $0.id == target.id })?.members.map(\.id) == ["group-author"])
        #expect(a.viewModel.contactPerson(person) != nil)
    }

    @Test func acceptingTheGroupKeepsAnExistingCallAndRejectsAConflictingKey() throws {
        let (a, b, token, _) = try prepared()
        defer { a.viewModel.disconnect(); b.viewModel.disconnect() }
        b.viewModel.setSoundIsolationEnabled(false)
        #expect(b.viewModel.createTalkGroup(name: "Current conversation"))
        let current = b.viewModel.currentCallReference
        let url = try GroupInviteTokenCodec.joinURL(for: token, contactBootstrap: true)
        try b.viewModel.acceptContactInviteURL(url)
        #expect(b.viewModel.currentCallReference == current)
        let target = try #require(token.invitedGroup)
        let c = AppTestSupport.makeHarness(groups: [], localMemberID: "conflicting-recipient")
        defer { c.viewModel.disconnect() }
        let existing = try IntercomGroup(id: target.id, name: "Existing", members: [.init(id: "conflicting-recipient", displayName: "You")])
        try c.viewModel.groupRepository.save([existing], credential: .init(groupID: target.id, secret: "different-key"))
        c.viewModel.reloadSavedGroups()
        let before = c.groupStore.snapshot
        #expect(throws: (any Error).self) { try c.viewModel.acceptContactInviteURL(url) }
        #expect(c.groupStore.snapshot == before && c.viewModel.savedRemoteUsers.isEmpty)
    }

    @Test func multipleNewPeopleAndTheGroupSaveTogetherAndRetryDoesNotDuplicateThem() throws {
        let h = AppTestSupport.makeHarness(groups: [], localMemberID: "batch-author")
        defer { h.viewModel.disconnect() }
        h.viewModel.setSoundIsolationEnabled(false)
        var selection = MemberSelection(viewModel: h.viewModel, groupID: nil)
        selection.typedName = "Snow friends"
        selection.addNewPerson(); selection.newPeople[0].name = "First rider"
        selection.addNewPerson(); selection.newPeople[1].name = "Second rider"
        let before = h.groupStore.snapshot
        #expect(selection.memberCount == 3 && selection.canSave)
        #expect(h.groupStore.snapshot == before)
        h.groupStore.failSaving = true
        #expect(selection.save() == nil)
        #expect(h.groupStore.snapshot == before)
        h.groupStore.failSaving = false; h.viewModel.reloadSavedGroups()
        #expect(selection.save() == .some(.some(selection.newGroupID)))
        #expect(h.viewModel.groups.first?.members.count == 3)
        #expect(h.viewModel.directoryUsers.count == 2 && h.viewModel.savedRemoteUsers.isEmpty)
        #expect(h.groupStore.snapshot.contactInvitations.count == 2)
        let saved = h.groupStore.snapshot, reference = h.viewModel.currentCallReference
        #expect(selection.canSave && selection.memberCount == 3)
        #expect(selection.save() == .some(.some(selection.newGroupID)))
        #expect(h.groupStore.snapshot == saved && h.viewModel.currentCallReference == reference)
    }

    @Test func addingANewPersonKeepsTheCurrentCallAndGroupKey() throws {
        let h = AppTestSupport.makeHarness(groups: [], localMemberID: "adding-author")
        defer { h.viewModel.disconnect() }
        h.viewModel.setSoundIsolationEnabled(false)
        #expect(h.viewModel.createTalkGroup(name: "Ongoing"))
        let group = try #require(h.viewModel.groups.first), reference = h.viewModel.currentCallReference
        let key = try h.viewModel.groupRepository.credential(for: group.id)
        var selection = MemberSelection(viewModel: h.viewModel, groupID: group.id)
        selection.addNewPerson()
        #expect(selection.canSave && selection.memberCount == 2)
        #expect(selection.save() == .some(.some(group.id)))
        #expect(h.viewModel.currentCallReference == reference)
        #expect(try h.viewModel.groupRepository.credential(for: group.id) == key)
        #expect(h.viewModel.directoryUsers.count == 1)
    }

    @Test func aFreshInvitationAfterExpiryKeepsItsPersonAndTargetGroup() throws {
        var now = Date()
        let (a, b, token, person) = try prepared(now: { now })
        defer { a.viewModel.disconnect(); b.viewModel.disconnect() }
        now = now.addingTimeInterval(8 * 24 * 60 * 60)
        let share = try a.viewModel.prepareContactPersonShare(person, expectedAccountAccessID: a.viewModel.accountAccessID)
        let fresh = try GroupInviteTokenCodec.decodeJoinURL(share.url, contactBootstrap: true)
        #expect(fresh.invitedGroup == token.invitedGroup)
        #expect(fresh.directInvitation?.context.id != token.directInvitation?.context.id)
        #expect(a.viewModel.groupInvitationPeople(try #require(token.invitedGroup).id).map(\.id) == [person])
        #expect(a.viewModel.groups.first(where: { $0.id == token.invitedGroup?.id })?.members.count == 2)
        let pending = try #require(a.viewModel.contactInvitationRecord(share.id))
        #expect(a.viewModel.contactInvitationIsUnsent(pending))
        let repeated = try a.viewModel.prepareContactPersonShare(person, expectedAccountAccessID: a.viewModel.accountAccessID)
        #expect(repeated.id == share.id && repeated.url == share.url)
        a.viewModel.completeContactInvitationSharing(share)
        #expect(a.viewModel.contactInvitationRecord(share.id)?.sent == true)
        try b.viewModel.acceptContactInviteURL(share.url)
        #expect(b.viewModel.groups.contains { $0.id == token.invitedGroup?.id })
    }

    @Test func aMixedSelectionAndRenamedPendingPersonKeepTheSameSavedState() throws {
        let h = try AppTestSupport.makeHarnessWithSavedUser()
        defer { h.viewModel.disconnect() }
        h.viewModel.setSoundIsolationEnabled(false)
        let known = try #require(h.viewModel.savedRemoteUsers.first)
        var selection = MemberSelection(viewModel: h.viewModel, groupID: nil)
        selection.selected = [known.id]; selection.addNewPerson()
        #expect(selection.memberCount == 3)
        #expect(selection.save() == .some(.some(selection.newGroupID)))
        let saved = h.groupStore.snapshot
        #expect(selection.memberCount == 3 && selection.canSave)
        #expect(selection.save() == .some(.some(selection.newGroupID)))
        #expect(h.groupStore.snapshot == saved)
        let person = selection.newPeople[0].id
        #expect(h.viewModel.renameSavedUser(person, displayName: "Renamed new rider"))
        #expect(h.groupStore.snapshot.contactInvitations.first(where: { $0.personID == person })?.nickname == "Renamed new rider")
        #expect(h.viewModel.groups.first(where: { $0.id == selection.newGroupID })?.members.first(where: { $0.id.hasPrefix(GroupMember.pendingInvitePrefix) })?.resolvedDisplayName == "Renamed new rider")
    }

}

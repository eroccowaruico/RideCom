import Foundation
import Testing
import UserNotifications
@testable import RideIntercom

@MainActor @Suite(.serialized) struct GroupDeliveryFlowTests {
    @Test func selectingAKnownAccountQueuesEveryKnownDeviceInTheSameSave() throws {
        let peer = AccountPrincipal(issuer: "https://delivery.test", userID: String(repeating: "b", count: 64))
        let user = SavedUser(displayName: "Registered friend", memberIDs: ["friend-one", "friend-two"],
            deviceKeys: ["friend-one": testIdentitySigner("friend-one").publicKey, "friend-two": testIdentitySigner("friend-two").publicKey], principal: peer)
        let store = InMemoryGroupStore(groups: []); store.snapshot.users = [user]
        let h = AppTestSupport.makeHarness(groups: [], groupStore: store, localMemberID: "sender")
        defer { h.viewModel.disconnect() }
        #expect(h.viewModel.createTalkGroup(name: "Selected riders", userIDs: [user.id]))
        let group = try #require(h.viewModel.groups.first)
        #expect(group.members.count == 2, "The same account still occupies one participant slot")
        #expect(h.viewModel.groupRepository.groupDeliveries.count == 2)
        #expect(Set(h.viewModel.groupRepository.groupDeliveries.map(\.noticeID)).count == 1)
        #expect(h.viewModel.groupRepository.groupDeliveries.allSatisfy { $0.groupID == group.id && $0.state == .pending })
    }
    @Test func differentRecipientAccountsDoNotShareANotificationIdentifier() throws {
        let users = ["b", "c"].map { character in
            let member = "friend-" + character
            return SavedUser(displayName: member, memberIDs: [member], deviceKeys: [member: testIdentitySigner(member).publicKey],
                principal: AccountPrincipal(issuer: "https://delivery.test", userID: String(repeating: character, count: 64)))
        }
        let store = InMemoryGroupStore(groups: []); store.snapshot.users = users
        let h = AppTestSupport.makeHarness(groups: [], groupStore: store, localMemberID: "sender")
        defer { h.viewModel.disconnect() }
        let records = h.viewModel.groupDeliveryRecords(for: Set(users.map(\.id)), groupID: UUID())
        #expect(records.count == 2)
        #expect(Set(records.map(\.noticeID)).count == 2, "A recipient must not see a shared identifier linking other recipients")
    }
    @Test func unreadableNotificationPermissionsDoNotFetchAnInbox() async throws {
        let a = GroupDeliveryTestIdentity("unreadable-recipient"), b = GroupDeliveryTestIdentity("known-sender")
        defer { a.remove(); b.remove() }
        try a.authorizeFixture(userID: String(repeating: "a", count: 64)); try b.authorizeFixture(userID: String(repeating: "b", count: 64))
        try a.keychain.saveSecret("unreadable permissions", service: a.namespace + ".InternetConnection", account: "notification-permissions")
        let h = try a.harness(knowing: [b]); defer { h.viewModel.stopGroupDeliverySync(); h.viewModel.disconnect() }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [GroupDeliveryHTTPStub.self]
        GroupDeliveryHTTPStub.reset()
        h.viewModel.groupDeliveryClient = .init(session: URLSession(configuration: configuration))
        #expect(!h.viewModel.notifications.canUseNotifications)
        await h.viewModel.synchronizeGroupDeliveries()
        #expect(GroupDeliveryHTTPStub.requestCount == 0)
    }
    @Test func automaticDeliveryRetriesTheSamePacketAndARepeatedReceiptDoesNotRecreateADeletedGroup() async throws {
        let a = GroupDeliveryTestIdentity("delivery-author"), b = GroupDeliveryTestIdentity("delivery-recipient")
        defer { a.remove(); b.remove() }
        try a.authorizeFixture(userID: String(repeating: "a", count: 64)); try b.authorizeFixture(userID: String(repeating: "b", count: 64))
        let left = try a.harness(knowing: [b]), right = try b.harness(knowing: [a])
        defer { left.viewModel.stopGroupDeliverySync(); right.viewModel.stopGroupDeliverySync(); left.viewModel.disconnect(); right.viewModel.disconnect() }
        let session = URLSessionConfiguration.ephemeral; session.protocolClasses = [GroupDeliveryHTTPStub.self]
        let client = InternetAccountClient(session: URLSession(configuration: session))
        GroupDeliveryHTTPStub.reset()
        let leftAccess = try #require(try a.store.notificationAccess(memberID: a.memberID))
        let rightAccess = try #require(try b.store.notificationAccess(memberID: b.memberID))
        GroupDeliveryHTTPStub.users = [leftAccess.accessToken: try a.principal.userID, rightAccess.accessToken: try b.principal.userID]
        left.viewModel.groupDeliveryClient = client; right.viewModel.groupDeliveryClient = client
        let grant = try testCallNotificationGrant(owner: b.principal, allowedSender: a.principal, audience: "rideintercom-group-invitation")
        let permission = try CallNotificationPermissionMessage.make(owner: b.principal, allowedSender: a.principal,
            revision: 1, grant: nil, signer: b.signer, groupGrant: grant, groupInvitationsSupported: true)
        try left.viewModel.notifications.receivePermission(permission, peerID: b.memberID)
        #expect(right.viewModel.createTalkGroup(name: "Keep this conversation"))
        await right.viewModel.synchronizeGroupDeliveries()
        let rightCall = right.viewModel.currentCallReference
        GroupDeliveryHTTPStub.failNextSubmit = true
        #expect(left.viewModel.createTalkGroup(name: "Automatically delivered", userIDs: [b.personID]))
        let group = try #require(left.viewModel.groups.first), leftCall = left.viewModel.currentCallReference
        await left.viewModel.synchronizeGroupDeliveries()
        #expect(left.viewModel.groupRepository.groupDeliveries.first?.state == .pending)
        await left.viewModel.synchronizeGroupDeliveries()
        #expect(left.viewModel.groupRepository.groupDeliveries.first?.state == .queued)
        #expect(GroupDeliveryHTTPStub.submitted.count == 2 && Set(GroupDeliveryHTTPStub.submitted).count == 1, "Retries use the exact same encrypted envelope")
        GroupDeliveryHTTPStub.failNextAcknowledgement = true
        await right.viewModel.synchronizeGroupDeliveries()
        #expect(!right.viewModel.groups.contains { $0.id == group.id })
        #expect(right.viewModel.groupRepository.groupDeliveries.first?.state == .pending)
        GroupDeliveryHTTPStub.legacyAcknowledgement = true
        await right.viewModel.synchronizeGroupDeliveries()
        #expect(right.viewModel.groups.contains { $0.id == group.id })
        #expect(right.viewModel.currentCallReference == rightCall && left.viewModel.currentCallReference == leftCall)
        #expect(try right.viewModel.groupRepository.credential(for: group.id) == left.viewModel.groupRepository.credential(for: group.id))
        right.viewModel.deleteGroup(group.id)
        await right.viewModel.synchronizeGroupDeliveries()
        #expect(!right.viewModel.groups.contains { $0.id == group.id })
        await left.viewModel.synchronizeGroupDeliveries()
        #expect(left.viewModel.groupRepository.groupDeliveries.first?.state == .received)
        #expect(left.viewModel.groupRepository.groupDeliveries.first?.credentialReference == nil)
        #expect(right.viewModel.savedRemoteUsers.count == 1 && right.viewModel.currentCallReference == rightCall)
        #expect(left.viewModel.groupInvitationDeliveryState(for: try b.savedUser(), in: group.id) == .received)
        let owner = AppCallOwner(account: right.viewModel.accountSession, viewModel: right.viewModel)
        let notice = try #require(GroupInvitationTap(payload: ["version": 1, "kind": "groupInvitation", "requestID": UUID().uuidString, "recipientID": try b.principal.userID]))
        #expect(await owner.respondToGroupInvitation(notice))
        #expect(right.viewModel.currentCallReference == rightCall && owner.callPresentationID != nil && owner.groupsPresentationID == nil)
        let unrelated = try #require(GroupInvitationTap(payload: ["version": 1, "kind": "groupInvitation", "requestID": UUID().uuidString, "recipientID": try a.principal.userID]))
        #expect(!(await owner.respondToGroupInvitation(unrelated)))
    }

    @Test func oneForegroundPassReceivesMoreThanEightDifferentGroupInvitations() async throws {
        let a = GroupDeliveryTestIdentity("batch-author"), b = GroupDeliveryTestIdentity("batch-recipient")
        defer { a.remove(); b.remove() }
        try a.authorizeFixture(userID: String(repeating: "a", count: 64)); try b.authorizeFixture(userID: String(repeating: "b", count: 64))
        let left = try a.harness(knowing: [b]), right = try b.harness(knowing: [a])
        defer { left.viewModel.stopGroupDeliverySync(); right.viewModel.stopGroupDeliverySync(); left.viewModel.disconnect(); right.viewModel.disconnect() }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [GroupDeliveryHTTPStub.self]
        let client = InternetAccountClient(session: URLSession(configuration: configuration))
        GroupDeliveryHTTPStub.reset()
        GroupDeliveryHTTPStub.users = [try #require(try a.store.notificationAccess(memberID: a.memberID)).accessToken: try a.principal.userID,
            try #require(try b.store.notificationAccess(memberID: b.memberID)).accessToken: try b.principal.userID]
        let permission = try CallNotificationPermissionMessage.make(owner: b.principal, allowedSender: a.principal, revision: 1,
            grant: nil, signer: b.signer, groupGrant: testCallNotificationGrant(owner: b.principal, allowedSender: a.principal, audience: "rideintercom-group-invitation"), groupInvitationsSupported: true)
        try left.viewModel.notifications.receivePermission(permission, peerID: b.memberID)
        left.viewModel.groupDeliveryClient = nil
        var expected = Set<UUID>()
        for index in 0..<9 {
            let id = UUID(); expected.insert(id)
            #expect(left.viewModel.createTalkGroup(name: "Batch group \(index)", userIDs: [b.personID], id: id))
        }
        left.viewModel.groupDeliveryClient = client; right.viewModel.groupDeliveryClient = client
        await left.viewModel.synchronizeGroupDeliveries()
        #expect(GroupDeliveryHTTPStub.items.count == 9)
        let currentCall = right.viewModel.currentCallReference
        await right.viewModel.synchronizeGroupDeliveries()
        #expect(expected.isSubset(of: Set(right.viewModel.groups.map(\.id))), "All queued groups must arrive without a second foreground event")
        #expect(right.viewModel.currentCallReference == currentCall && !right.viewModel.hasAnyActiveGroupConnection)
        #expect(right.viewModel.groupRepository.groupDeliveries.filter { $0.direction == .incoming && $0.state == .received }.count == 9)
        await left.viewModel.synchronizeGroupDeliveries()
        #expect(left.viewModel.groupRepository.groupDeliveries.allSatisfy { $0.state == .received })
    }

    @Test(arguments: [403, 401, 429, 503]) func aRecipientRejectionDoesNotBlockOtherPeopleButASharedFailureStopsThePass(status: Int) async throws {
        let a = GroupDeliveryTestIdentity("rejection-author"), b = GroupDeliveryTestIdentity("rejection-first"), c = GroupDeliveryTestIdentity("rejection-second")
        defer { a.remove(); b.remove(); c.remove() }
        try a.authorizeFixture(userID: String(repeating: "a", count: 64)); try b.authorizeFixture(userID: String(repeating: "b", count: 64)); try c.authorizeFixture(userID: String(repeating: "c", count: 64))
        let h = try a.harness(knowing: [b, c]); defer { h.viewModel.stopGroupDeliverySync(); h.viewModel.disconnect() }
        h.viewModel.groupDeliveryClient = nil
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [GroupDeliveryHTTPStub.self]
        GroupDeliveryHTTPStub.reset()
        GroupDeliveryHTTPStub.users = [try #require(try a.store.notificationAccess(memberID: a.memberID)).accessToken: try a.principal.userID]
        for peer in [b, c] {
            let permission = try CallNotificationPermissionMessage.make(owner: peer.principal, allowedSender: a.principal, revision: 1,
                grant: nil, signer: peer.signer, groupGrant: testCallNotificationGrant(owner: peer.principal, allowedSender: a.principal, audience: "rideintercom-group-invitation"), groupInvitationsSupported: true)
            try h.viewModel.notifications.receivePermission(permission, peerID: peer.memberID)
        }
        #expect(h.viewModel.createTalkGroup(name: "Independent recipients", userIDs: [b.personID, c.personID]))
        let first = try #require(h.viewModel.groupRepository.groupDeliveries.first)
        GroupDeliveryHTTPStub.rejectedRecipientID = first.recipient.userID
        GroupDeliveryHTTPStub.submitRejectionStatus = status
        h.viewModel.groupDeliveryClient = .init(session: URLSession(configuration: configuration))
        await h.viewModel.synchronizeGroupDeliveries()
        let records = h.viewModel.groupRepository.groupDeliveries
        #expect(records.first(where: { $0.id == first.id })?.state == .pending, "A rejected recipient stays recoverable")
        #expect(GroupDeliveryHTTPStub.submitted.count == (status == 403 ? 2 : 1))
        #expect(records.filter { $0.id != first.id }.allSatisfy { $0.state == (status == 403 ? .queued : .pending) })
    }

    @Test func anInvalidInboxPacketWhoseDiscardFailsWaitsForTheNextLifecycleEvent() async throws {
        let a = GroupDeliveryTestIdentity("discard-recipient"), b = GroupDeliveryTestIdentity("discard-sender")
        defer { a.remove(); b.remove() }
        try a.authorizeFixture(userID: String(repeating: "a", count: 64)); try b.authorizeFixture(userID: String(repeating: "b", count: 64))
        let h = try a.harness(knowing: [b]); defer { h.viewModel.stopGroupDeliverySync(); h.viewModel.disconnect() }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [GroupDeliveryHTTPStub.self]
        GroupDeliveryHTTPStub.reset()
        GroupDeliveryHTTPStub.users = [try #require(try a.store.notificationAccess(memberID: a.memberID)).accessToken: try a.principal.userID]
        let id = UUID().uuidString.lowercased(), initialGroups = h.viewModel.groups.map(\.id)
        GroupDeliveryHTTPStub.items[id] = ["requestID": id, "expiresAt": Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000,
            "status": "queued", "senderUserID": try b.principal.userID, "recipientID": try a.principal.userID,
            "recipientKey": try a.signer.publicKey, "envelope": "invalid-base64"]
        GroupDeliveryHTTPStub.failNextAcknowledgement = true
        h.viewModel.groupDeliveryClient = .init(session: URLSession(configuration: configuration))
        await h.viewModel.synchronizeGroupDeliveries()
        #expect(GroupDeliveryHTTPStub.requestCount == 2, "GET and one failed discard, without re-fetching the same invalid packet")
        #expect(h.viewModel.groups.map(\.id) == initialGroups)
        await h.viewModel.synchronizeGroupDeliveries()
        #expect(GroupDeliveryHTTPStub.requestCount == 5, "A later lifecycle pass retries discard and then observes an empty inbox")
    }

    enum KeyConflictTiming: String, CaseIterable { case alreadySaved, beforeReceiptRetry, afterReceipt }

    @Test(arguments: KeyConflictTiming.allCases)
    func aConflictingGroupKeyDoesNotBlockTheNextInvitation(timing: KeyConflictTiming) async throws {
        let author = GroupDeliveryTestIdentity("conflicting-group-author")
        let recipient = GroupDeliveryTestIdentity("conflicting-group-recipient")
        defer { author.remove(); recipient.remove() }
        try author.authorizeFixture(userID: String(repeating: "a", count: 64))
        try recipient.authorizeFixture(userID: String(repeating: "b", count: 64))
        let left = try author.harness(knowing: [recipient]).viewModel
        let right = try recipient.harness(knowing: [author]).viewModel
        GroupDeliveryHTTPStub.reset()
        defer {
            left.stopGroupDeliverySync(); right.stopGroupDeliverySync()
            left.disconnect(); right.disconnect()
            GroupDeliveryHTTPStub.reset()
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GroupDeliveryHTTPStub.self]
        let client = InternetAccountClient(session: URLSession(configuration: configuration))
        let senderAccess = try #require(try author.store.notificationAccess(memberID: author.memberID))
        let recipientAccess = try #require(try recipient.store.notificationAccess(memberID: recipient.memberID))
        GroupDeliveryHTTPStub.users = [senderAccess.accessToken: try author.principal.userID,
                                       recipientAccess.accessToken: try recipient.principal.userID]
        left.groupDeliveryClient = client
        let grant = try testCallNotificationGrant(owner: recipient.principal, allowedSender: author.principal,
            audience: "rideintercom-group-invitation")
        try left.notifications.receivePermission(CallNotificationPermissionMessage.make(owner: recipient.principal,
            allowedSender: author.principal, revision: 1, grant: nil, signer: recipient.signer,
            groupGrant: grant, groupInvitationsSupported: true), peerID: recipient.memberID)

        let collision = UUID()
        var localCall: CallReference?
        func saveLocalGroup() {
            #expect(right.createTalkGroup(name: "Saved locally", id: collision))
            localCall = right.currentCallReference
        }
        if timing == .afterReceipt { GroupDeliveryHTTPStub.onAcknowledged = saveLocalGroup }
        if timing == .alreadySaved { saveLocalGroup() }
        #expect(left.createTalkGroup(name: "Conflicting invitation", userIDs: [recipient.personID], id: collision))
        await left.synchronizeGroupDeliveries()
        let record = try #require(left.groupRepository.groupDeliveries.first { $0.groupID == collision })
        let conflictID = record.id.uuidString.lowercased()
        #expect(GroupDeliveryHTTPStub.items[conflictID]?["status"] as? String == "queued")
        right.groupDeliveryClient = client
        if timing == .beforeReceiptRetry {
            GroupDeliveryHTTPStub.failNextAcknowledgement = true
            await right.synchronizeGroupDeliveries()
            #expect(right.groupRepository.groupDeliveries.first(where: { $0.id == record.id })?.state == .pending)
            saveLocalGroup()
        }
        await right.synchronizeGroupDeliveries()
        let localCredential = try #require(try right.groupRepository.credential(for: collision))
        #expect(localCredential != (try left.groupRepository.credential(for: collision)))
        #expect(GroupDeliveryHTTPStub.items[conflictID]?["status"] as? String == (timing == .afterReceipt ? "received" : "cancelled"))
        #expect(!right.groupRepository.groupDeliveries.contains { $0.id == record.id && $0.state == .pending })
        #expect(right.groupStorageIssue == nil)
        #expect(right.groupErrorMessage == nil)

        let valid = UUID()
        #expect(left.createTalkGroup(name: "Valid invitation", userIDs: [recipient.personID], id: valid))
        await left.synchronizeGroupDeliveries()
        await right.synchronizeGroupDeliveries()
        #expect(right.groups.first(where: { $0.id == valid })?.name == "Valid invitation")
        #expect(right.groups.first(where: { $0.id == collision })?.name == "Saved locally")
        #expect(try right.groupRepository.credential(for: collision) == localCredential)
        #expect(right.currentCallReference == localCall)
    }

    @Test func aGroupMembersStateUsesTheirAccountAndKeepsOtherGroupsSeparate() throws {
        let peer = AccountPrincipal(issuer: "https://delivery.test", userID: String(repeating: "b", count: 64))
        let user = SavedUser(displayName: "Two devices", memberIDs: ["state-one", "state-two"],
            deviceKeys: ["state-one": testIdentitySigner("state-one").publicKey, "state-two": testIdentitySigner("state-two").publicKey], principal: peer)
        let store = InMemoryGroupStore(groups: []); store.snapshot.users = [user]
        let h = AppTestSupport.makeHarness(groups: [], groupStore: store, localMemberID: "state-sender")
        defer { h.viewModel.disconnect() }
        #expect(h.viewModel.createTalkGroup(name: "State after closing the sheet", userIDs: [user.id]))
        let group = try #require(h.viewModel.groups.first)
        #expect(h.viewModel.groupInvitationDeliveryState(forMember: "state-one", in: group.id) == .pending)
        #expect(h.viewModel.groupInvitationDeliveries(in: group.id).count == 2)
        let record = try #require(h.viewModel.groupRepository.groupDeliveries.first)
        try h.viewModel.groupRepository.setGroupDeliveryState(record.id, state: .received)
        #expect(h.viewModel.groupInvitationDeliveryState(forMember: "state-two", in: group.id) == .received, "One known device's receipt confirms the same person")
        #expect(h.viewModel.groupInvitationDeliveryState(forMember: "unknown", in: group.id) == nil)
        let other = UUID()
        #expect(h.viewModel.groupInvitationDeliveryState(forMember: "state-one", in: other) == nil)
        #expect(h.viewModel.groupInvitationDeliveries(in: other).isEmpty)
    }

    @Test func aGroupInvitationNoticeIsNeverDecodedAsACallRequest() {
        let payload: [AnyHashable: Any] = ["version": 1, "kind": "groupInvitation", "requestID": UUID().uuidString,
            "recipientID": String(repeating: "a", count: 64)]
        #expect(CallNotificationTap(payload: payload) == nil)
        #expect(GroupInvitationTap(payload: payload) != nil)
        #expect(GroupInvitationTap(payload: ["version": 1, "requestID": UUID().uuidString, "recipientID": String(repeating: "a", count: 64)]) == nil)
    }

    @Test func foregroundGroupInvitationOnlyAppearsInNotificationCenter() throws {
        let identity = GroupDeliveryTestIdentity("quiet-group-invitation")
        defer { identity.remove() }
        try identity.authorizeFixture(userID: String(repeating: "a", count: 64))
        let model = try identity.harness(knowing: []).viewModel
        defer { model.stopGroupDeliverySync(); model.disconnect() }
        let owner = AppCallOwner(account: model.accountSession, viewModel: model)
        owner.notificationBridge.bind(to: owner)
        let notice = try #require(GroupInvitationTap(payload: [
            "version": 1, "kind": "groupInvitation", "requestID": UUID().uuidString,
            "recipientID": try identity.principal.userID
        ]))
        let wrongRecipient = try #require(GroupInvitationTap(payload: [
            "version": 1, "kind": "groupInvitation", "requestID": UUID().uuidString,
            "recipientID": String(repeating: "b", count: 64)
        ]))

        #expect(owner.notificationBridge.groupPresentationOptions(for: notice) == [.list])
        #expect(model.activeGroupID == nil)
        #expect(model.createTalkGroup(name: "Keep this call"))
        let call = model.currentCallReference
        #expect(owner.notificationBridge.groupPresentationOptions(for: notice) == [.list])
        #expect(owner.notificationBridge.groupPresentationOptions(for: wrongRecipient).isEmpty)
        #expect(model.currentCallReference == call)
        #expect(owner.callPresentationID == nil && owner.groupsPresentationID == nil)
    }

    @Test(arguments: [false, true])
    func savingAGroupRequestsBackgroundTimeAndKeepsTheSameDeliveryOnExpiry(expires: Bool) async throws {
        let a = GroupDeliveryTestIdentity("background-delivery-author")
        let b = GroupDeliveryTestIdentity("background-delivery-recipient")
        defer { a.remove(); b.remove() }
        try a.authorizeFixture(userID: String(repeating: "a", count: 64))
        try b.authorizeFixture(userID: String(repeating: "b", count: 64))
        let h = try a.harness(knowing: [b])
        let vm = h.viewModel
        defer { vm.stopGroupDeliverySync(); vm.disconnect() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GroupDeliveryHTTPStub.self]
        GroupDeliveryHTTPStub.reset()
        defer { GroupDeliveryHTTPStub.reset() }
        let access = try #require(try a.store.notificationAccess(memberID: a.memberID))
        GroupDeliveryHTTPStub.users = [access.accessToken: try a.principal.userID]
        vm.groupDeliveryClient = .init(session: URLSession(configuration: configuration))
        let permission = try CallNotificationPermissionMessage.make(owner: b.principal, allowedSender: a.principal, revision: 1,
            grant: nil, signer: b.signer, groupGrant: testCallNotificationGrant(owner: b.principal, allowedSender: a.principal,
                audience: "rideintercom-group-invitation"), groupInvitationsSupported: true)
        try vm.notifications.receivePermission(permission, peerID: b.memberID)
        var starts = 0, finishes = 0
        var expire: (@MainActor () -> Void)?
        vm.beginGroupDeliveryBackgroundTime = { onExpiration in
            starts += 1
            expire = onExpiration
            return { finishes += 1 }
        }
        GroupDeliveryHTTPStub.onQueued = {
            #expect(starts == 1 && finishes == 0, "The network write begins inside the app's requested time")
            if expires { expire?() }
        }
        let groupID = UUID()
        if expires {
            vm.requestGroupDeliverySync()
            #expect(starts == 0, "An ordinary inbox refresh does not request extra time")
        }
        #expect(vm.createTalkGroup(name: "Saved before leaving the app", userIDs: [b.personID], id: groupID))
        #expect(starts == 1, "Request extra time before the save action returns")
        let pass = try #require(vm.groupDeliveryTask)
        await pass.value
        #expect(finishes == 1)
        let record = try #require(vm.groupRepository.groupDeliveries.first)
        #expect(record.groupID == groupID && GroupDeliveryHTTPStub.items.count == 1)
        #expect(record.state == (expires ? .pending : .queued))
        if expires {
            GroupDeliveryHTTPStub.onQueued = nil
            await vm.synchronizeGroupDeliveries()
            let retried = try #require(vm.groupRepository.groupDeliveries.first)
            #expect(retried.id == record.id && retried.state == .queued)
            #expect(GroupDeliveryHTTPStub.items.count == 1 && GroupDeliveryHTTPStub.submitted.count == 2)
            #expect(Set(GroupDeliveryHTTPStub.submitted).count == 1, "Retry uses the same committed envelope")
            #expect(starts == 1 && finishes == 1)
        }
    }

    @Test(arguments: [false, true])
    func removedMemberIsNotSentAnInvitationAfterExpiryOrDuringAnotherDelivery(duringDelivery: Bool) async throws {
        let a = GroupDeliveryTestIdentity("removing-author"), b = GroupDeliveryTestIdentity("removed-recipient")
        defer { a.remove(); b.remove() }
        try a.authorizeFixture(userID: String(repeating: "a", count: 64))
        try b.authorizeFixture(userID: String(repeating: "b", count: 64))
        let h = try a.harness(knowing: [b])
        let vm = h.viewModel
        defer { vm.stopGroupDeliverySync(); vm.disconnect(); GroupDeliveryHTTPStub.reset() }
        GroupDeliveryHTTPStub.reset()
        let access = try #require(try a.store.notificationAccess(memberID: a.memberID))
        GroupDeliveryHTTPStub.users = [access.accessToken: try a.principal.userID]
        let grant = try testCallNotificationGrant(owner: b.principal, allowedSender: a.principal, audience: "rideintercom-group-invitation")
        let permission = try CallNotificationPermissionMessage.make(owner: b.principal, allowedSender: a.principal, revision: 1,
            grant: nil, signer: b.signer, groupGrant: grant, groupInvitationsSupported: true)
        try vm.notifications.receivePermission(permission, peerID: b.memberID)
        vm.groupDeliveryClient = nil
        #expect(vm.createTalkGroup(name: "Continue sending", userIDs: [b.personID]))
        #expect(vm.createTalkGroup(name: "Remove before sending", userIDs: [b.personID]))
        let queuedRecords = vm.groupRepository.groupDeliveries
        let unaffected = try #require(queuedRecords.first)
        let removed = try #require(queuedRecords.last)
        #expect(unaffected.id != removed.id && removed.credentialReference == nil)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GroupDeliveryHTTPStub.self]
        vm.groupDeliveryClient = .init(session: URLSession(configuration: configuration))
        if duringDelivery {
            GroupDeliveryHTTPStub.onQueued = { vm.removeMember(b.memberID, from: removed.groupID) }
            vm.requestGroupDeliverySync()
        } else {
            var expire: (@MainActor () -> Void)?
            vm.beginGroupDeliveryBackgroundTime = { onExpiration in
                expire = onExpiration
                return {}
            }
            vm.removeMember(b.memberID, from: removed.groupID)
            let endBackgroundTime = try #require(expire)
            endBackgroundTime()
            #expect(GroupDeliveryHTTPStub.submitted.isEmpty)
            #expect(vm.groupRepository.groupDeliveries.first(where: { $0.id == removed.id })?.state == .cancelled)
            vm.requestGroupDeliverySync()
        }
        await vm.groupDeliveryTask?.value
        #expect(vm.groupStorageIssue == nil)
        #expect(vm.groupRepository.groupDeliveries.map(\.id) == [unaffected.id])
        #expect(vm.groupRepository.groupDeliveries.first?.state == .queued)
        let submittedIDs = try GroupDeliveryHTTPStub.submitted.map { packet in
            let data = try #require(Data(base64Encoded: packet))
            return try JSONDecoder().decode(GroupInvitationEnvelope.self, from: data).id
        }
        let expectedIDs: Set<UUID> = [unaffected.id]
        #expect(Set(submittedIDs) == expectedIDs)
        #expect(GroupDeliveryHTTPStub.items[removed.id.uuidString.lowercased()] == nil)
    }

    @Test func aLateResponseCannotCommitAfterTheAccountSignsOut() async throws {
        let a = GroupDeliveryTestIdentity("late-author"), b = GroupDeliveryTestIdentity("late-recipient")
        defer { a.remove(); b.remove() }
        try a.authorizeFixture(userID: String(repeating: "a", count: 64)); try b.authorizeFixture(userID: String(repeating: "b", count: 64))
        let h = try a.harness(knowing: [b]); defer { h.viewModel.stopGroupDeliverySync(); h.viewModel.disconnect() }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [GroupDeliveryHTTPStub.self]
        GroupDeliveryHTTPStub.reset()
        GroupDeliveryHTTPStub.users = [try #require(try a.store.notificationAccess(memberID: a.memberID)).accessToken: try a.principal.userID]
        h.viewModel.groupDeliveryClient = .init(session: URLSession(configuration: configuration))
        let permission = try CallNotificationPermissionMessage.make(owner: b.principal, allowedSender: a.principal, revision: 1,
            grant: nil, signer: b.signer, groupGrant: testCallNotificationGrant(owner: b.principal, allowedSender: a.principal, audience: "rideintercom-group-invitation"), groupInvitationsSupported: true)
        try h.viewModel.notifications.receivePermission(permission, peerID: b.memberID)
        GroupDeliveryHTTPStub.onQueued = { h.viewModel.accountSession.signOut() }
        #expect(h.viewModel.createTalkGroup(name: "No late commit", userIDs: [b.personID]))
        await h.viewModel.synchronizeGroupDeliveries()
        #expect(!h.viewModel.hasCurrentAccountAccess)
        #expect(h.viewModel.groupRepository.groupDeliveries.first?.state == .pending)
    }

    @Test func aLocalWriteFailureAfterRemoteAcceptanceRemainsRecoverable() async throws {
        let a = GroupDeliveryTestIdentity("write-author"), b = GroupDeliveryTestIdentity("write-recipient")
        defer { a.remove(); b.remove() }
        try a.authorizeFixture(userID: String(repeating: "a", count: 64)); try b.authorizeFixture(userID: String(repeating: "b", count: 64))
        let h = try a.harness(knowing: [b]); defer { h.viewModel.stopGroupDeliverySync(); h.viewModel.disconnect() }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [GroupDeliveryHTTPStub.self]
        GroupDeliveryHTTPStub.reset()
        GroupDeliveryHTTPStub.users = [try #require(try a.store.notificationAccess(memberID: a.memberID)).accessToken: try a.principal.userID]
        h.viewModel.groupDeliveryClient = .init(session: URLSession(configuration: configuration))
        let permission = try CallNotificationPermissionMessage.make(owner: b.principal, allowedSender: a.principal, revision: 1,
            grant: nil, signer: b.signer, groupGrant: testCallNotificationGrant(owner: b.principal, allowedSender: a.principal, audience: "rideintercom-group-invitation"), groupInvitationsSupported: true)
        try h.viewModel.notifications.receivePermission(permission, peerID: b.memberID)
        GroupDeliveryHTTPStub.onQueued = { h.groupStore.failSaving = true }
        #expect(h.viewModel.createTalkGroup(name: "Saved before delivery", userIDs: [b.personID]))
        await h.viewModel.synchronizeGroupDeliveries()
        #expect(h.viewModel.groupStorageIssue != nil, "A failed manifest write must expose the existing reload recovery")
        #expect(h.viewModel.groupRepository.groupDeliveries.first?.state == .pending)
        h.groupStore.failSaving = false; GroupDeliveryHTTPStub.onQueued = nil
        h.viewModel.disconnect(); h.viewModel.reloadSavedGroups()
        await h.viewModel.synchronizeGroupDeliveries()
        #expect(h.viewModel.groupRepository.groupDeliveries.first?.state == .queued)
        #expect(h.viewModel.groups.count == 1 && h.viewModel.groupStorageIssue == nil)
        #expect(h.viewModel.createTalkGroup(name: "Saved before delivery", userIDs: [b.personID], id: try #require(h.viewModel.groups.first).id))
        #expect(h.viewModel.groups.count == 1 && h.viewModel.groupRepository.groupDeliveries.count == 1)
    }

}


private final class GroupDeliveryHTTPStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var users: [String: String] = [:]
    nonisolated(unsafe) static var items: [String: [String: Any]] = [:]
    nonisolated(unsafe) static var submitted: [String] = []
    nonisolated(unsafe) static var onQueued: (@MainActor () -> Void)?
    nonisolated(unsafe) static var onAcknowledged: (@MainActor () -> Void)?
    nonisolated(unsafe) static var rejectedRecipientID: String?
    nonisolated(unsafe) static var submitRejectionStatus = 403
    nonisolated(unsafe) static var failNextSubmit = false
    nonisolated(unsafe) static var failNextAcknowledgement = false
    nonisolated(unsafe) static var legacyAcknowledgement = false
    @MainActor static func reset() { requestCount = 0; users = [:]; items = [:]; submitted = []; rejectedRecipientID = nil; submitRejectionStatus = 403; failNextSubmit = false; failNextAcknowledgement = false; legacyAcknowledgement = false; onQueued = nil; onAcknowledged = nil }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "delivery.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requestCount += 1
        var captured = request
        if let stream = captured.httpBodyStream {
            stream.open(); defer { stream.close() }
            var body = Data(), buffer = [UInt8](repeating: 0, count: 8192)
            while true { let size = stream.read(&buffer, maxLength: buffer.count); if size <= 0 { break }; body.append(contentsOf: buffer.prefix(size)) }
            captured.httpBody = body
        }
        let value = captured
        Task { @MainActor [self] in
            let (status, object) = Self.respond(value)
            let response = HTTPURLResponse(url: value.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: object)); client?.urlProtocolDidFinishLoading(self)
        }
    }
    @MainActor private static func respond(_ request: URLRequest) -> (Int, [String: Any]) {
        let bearer = String((request.value(forHTTPHeaderField: "Authorization") ?? "").dropFirst(7))
        guard let caller = users[bearer], let url = request.url else { return (401, [:]) }
        if request.httpMethod == "POST", let body = request.httpBody,
           let fields = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let id = fields["requestID"] as? String, let expiry = fields["expiresAt"] as? Double,
           let encoded = fields["envelope"] as? String, let data = Data(base64Encoded: encoded),
           let envelope = try? JSONDecoder().decode(GroupInvitationEnvelope.self, from: data) {
            submitted.append(encoded)
            if envelope.recipient.userID == rejectedRecipientID { return (submitRejectionStatus, [:]) }
            if failNextSubmit { failNextSubmit = false; return (503, [:]) }
            if let old = items[id] {
                guard old["envelope"] as? String == encoded else { return (409, [:]) }
                return (200, ["requestID": id, "expiresAt": expiry, "status": old["status"]!])
            }
            items[id] = ["requestID": id, "expiresAt": expiry, "status": "queued", "senderUserID": caller,
                "recipientID": envelope.recipient.userID, "recipientKey": envelope.recipientKey, "envelope": encoded]
            onQueued?()
            return (200, ["requestID": id, "expiresAt": expiry, "status": "queued"])
        }
        if request.httpMethod == "GET" {
            if url.lastPathComponent != "group-invitations" {
                guard let item = items[url.lastPathComponent], item["recipientID"] as? String == caller else { return (404, [:]) }
                return (200, item)
            }
            let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
            let item = items.values.first { $0["recipientID"] as? String == caller && $0["recipientKey"] as? String == key && $0["status"] as? String == "queued" }
            return (200, ["delivery": item.map { $0 as Any } ?? NSNull()])
        }
        if request.httpMethod == "DELETE" {
            if failNextAcknowledgement { failNextAcknowledgement = false; return (503, [:]) }
            let id = url.lastPathComponent
            guard var item = items[id] else { return (404, [:]) }
            if item["status"] as? String == "queued" {
                let discard = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(.init(name: "discard", value: "1")) == true
                item["status"] = item["recipientID"] as? String == caller && !discard ? "received" : "cancelled"
                items[id] = item
                if item["status"] as? String == "received" {
                    let action = onAcknowledged
                    onAcknowledged = nil
                    action?()
                }
            }
            return (200, legacyAcknowledgement ? [:] : ["status": item["status"]!])
        }
        return (404, [:])
    }
    override func stopLoading() {}
}

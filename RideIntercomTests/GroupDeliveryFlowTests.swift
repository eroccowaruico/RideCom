import Foundation
import Testing
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

    @Test func aGroupInvitationNoticeIsNeverDecodedAsACallRequest() {
        let payload: [AnyHashable: Any] = ["version": 1, "kind": "groupInvitation", "requestID": UUID().uuidString,
            "recipientID": String(repeating: "a", count: 64)]
        #expect(CallNotificationTap(payload: payload) == nil)
        #expect(GroupInvitationTap(payload: payload) != nil)
        #expect(GroupInvitationTap(payload: ["version": 1, "requestID": UUID().uuidString, "recipientID": String(repeating: "a", count: 64)]) == nil)
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
    nonisolated(unsafe) static var failNextSubmit = false
    nonisolated(unsafe) static var failNextAcknowledgement = false
    @MainActor static func reset() { requestCount = 0; users = [:]; items = [:]; submitted = []; failNextSubmit = false; failNextAcknowledgement = false; onQueued = nil }
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
            let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
            let item = items.values.first { $0["recipientID"] as? String == caller && $0["recipientKey"] as? String == key && $0["status"] as? String == "queued" }
            return (200, ["delivery": item.map { $0 as Any } ?? NSNull()])
        }
        if request.httpMethod == "DELETE" {
            if failNextAcknowledgement { failNextAcknowledgement = false; return (503, [:]) }
            let id = url.lastPathComponent
            if var item = items[id] { item["status"] = item["recipientID"] as? String == caller ? "received" : "cancelled"; items[id] = item }
            return (200, [:])
        }
        return (404, [:])
    }
    override func stopLoading() {}
}

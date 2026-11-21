import CryptoKit
import Foundation
import RTC
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized)
struct RegularGroupRepresentativeTests {
    @Test func sevenSavedPeopleWithTwoDevicesEachUseSevenGroupSlots() throws {
        let store = InMemoryGroupStore(groups: [])
        store.snapshot.users = (1...7).map { index in
            let ids = ["friend-\(index)-a", "friend-\(index)-b"]
            return SavedUser(
                displayName: "Friend \(index)", memberIDs: ids,
                deviceKeys: Dictionary(uniqueKeysWithValues: ids.map { ($0, testIdentitySigner($0).publicKey) }),
                principal: .init(
                    issuer: "https://account.test", userID: String(repeating: String(index), count: 64)))
        }
        let harness = AppTestSupport.makeHarness(groups: [], groupStore: store, localMemberID: "local")
        defer { harness.viewModel.disconnect() }
        var selection = MemberSelection(viewModel: harness.viewModel, groupID: nil)
        selection.typedName = "Eight people"
        for person in store.snapshot.users { selection.toggle(person.id) }
        #expect(selection.memberCount == 8)
        #expect(selection.canSave)
        #expect(selection.save() != nil)
        let group = try #require(harness.viewModel.selectedGroup)
        #expect(group.members.count == 8)
        #expect(group.accountDevices.count == 7)
        #expect(harness.viewModel.availableUsers(for: group.id).isEmpty)
        #expect(!harness.viewModel.addSavedUsers([store.snapshot.users[0].id], to: group.id))
    }

    @Test(arguments: [false, true])
    func selectionUsesActualSlotsWhenAddingToAGroup(accountBased: Bool) throws {
        let group = try IntercomGroup(name: "Seven members", members: [.init(id: "local", displayName: "You")]
            + (1...6).map { .init(id: "existing-\($0)", displayName: "Existing \($0)") })
        let store = InMemoryGroupStore(groups: [group])
        let ids = (0..<8).map { "new-rider-\($0)" }
        let person = SavedUser(displayName: "New rider", memberIDs: ids,
            deviceKeys: Dictionary(uniqueKeysWithValues: ids.map { ($0, testIdentitySigner($0).publicKey) }),
            principal: accountBased
                ? .init(issuer: "https://account.test", userID: String(repeating: "c", count: 64)) : nil)
        store.snapshot.users = [person]
        let harness = AppTestSupport.makeHarness(groups: [group], groupStore: store, localMemberID: "local")
        defer { harness.viewModel.disconnect() }
        var selection = MemberSelection(viewModel: harness.viewModel, groupID: group.id)
        selection.toggle(person.id)
        #expect(selection.memberCount == (accountBased ? 8 : 15))
        #expect(selection.canSave == accountBased)
        if accountBased {
            #expect(selection.save() == .some(.some(group.id)))
            #expect(harness.groupStore.snapshot.groups.first?.members.count == 8)
            #expect(harness.groupStore.snapshot.groups.first?.members.last?.id == "new-rider-0")
        } else {
            let before = store.snapshot
            #expect(selection.save() == nil)
            #expect(store.snapshot == before)
        }
    }

    @Test func additionalDevicesCannotDisplaceSevenConnectedRepresentatives() throws {
        let fixture = try RegularRepresentativeFixture(); defer { fixture.stop() }
        let viewModel = fixture.harness.viewModel, accounts = ["b", "c", "d", "e", "f", "1", "2"]
        let representatives = accounts.indices.map { "rider-\($0)-phone" }
        fixture.harness.callSession.authenticate(representatives)
        for (id, account) in zip(representatives, accounts) {
            try fixture.deliver(fixture.signer(id, account: account))
        }
        let roster = viewModel.groups[0].members.map(\.id)
        let admitted = viewModel.callAccessAdmittedMemberships
        let lastRepresentative = try #require(representatives.last)
        let lastAccount = try #require(accounts.last)
        let oldChallenge = try #require(viewModel.peerProfiles[lastRepresentative]?.challenge)

        // This sorts before every representative, including the same person's
        // currently connected phone. It must not manufacture a departure.
        fixture.harness.callSession.authenticate(representatives + ["00-tablet"])
        try fixture.deliver(fixture.signer("00-tablet", account: lastAccount))
        #expect(viewModel.groups[0].members.map(\.id) == roster)
        #expect(viewModel.callAccessAdmittedMemberships == admitted)
        #expect(viewModel.peerProfiles[lastRepresentative]?.challenge == oldChallenge)
        #expect(viewModel.peerProfiles["00-tablet"]?.verified == nil)

        // Even more candidates than the bounded temporary budget may not evict
        // an already verified, still-connected representative.
        let candidates = (0..<8).map { "00-candidate-\($0)" }
        fixture.harness.callSession.authenticate(representatives + candidates)
        #expect(viewModel.peerProfiles.count == 14)
        #expect(viewModel.callAccessAdmittedMemberships == admitted)
        #expect(viewModel.groups[0].members.map(\.id) == roster)
    }

    @Test func sevenPeopleCanBeVerifiedWhenBothDevicesAppearTogether() throws {
        let fixture = try RegularRepresentativeFixture(); defer { fixture.stop() }
        let viewModel = fixture.harness.viewModel, accounts = ["b", "c", "d", "e", "f", "1", "2"]
        let phones = accounts.indices.map { "rider-\($0)-a" }
        let tablets = accounts.indices.map { "rider-\($0)-b" }
        fixture.harness.callSession.authenticate(phones + tablets)
        #expect(viewModel.peerProfiles.count == 14)
        for (id, account) in zip(phones, accounts) { try fixture.deliver(fixture.signer(id, account: account)) }
        for (id, account) in zip(tablets, accounts) { try fixture.deliver(fixture.signer(id, account: account)) }
        #expect(Set(viewModel.groups[0].members.map(\.id)) == Set(["local"] + phones))
        #expect(Set(viewModel.callAccessAdmittedMemberships.keys.map(\.rawValue)) == Set(phones))
        #expect(tablets.allSatisfy { viewModel.peerProfiles[$0]?.verified == nil })
        #expect(viewModel.savedUsers.isEmpty)
        #expect(try viewModel.internetSettingsStore.notificationPermissions().isEmpty)
    }

    @Test func changedMembershipStillRequiresFreshRepresentativeProof() throws {
        let fixture = try RegularRepresentativeFixture(); defer { fixture.stop() }
        let viewModel = fixture.harness.viewModel, signer = try fixture.signer("phone")
        fixture.harness.callSession.authenticate(["phone"])
        let previous = try fixture.profile(signer)
        try fixture.deliver(previous)
        let replacementMembership = UUID()
        viewModel.handleTransportEvent(.authenticated(members: [
            .init(peer: .init(id: .init(rawValue: "phone"), displayName: "Phone"), route: .multipeer,
                  isConnected: true, membershipID: replacementMembership)
        ]))
        #expect(viewModel.peerProfiles["phone"]?.challenge != previous.challenge)
        #expect(viewModel.callAccessAdmittedMemberships.isEmpty)
        try fixture.deliver(previous)
        #expect(viewModel.peerProfiles["phone"]?.verified == nil)
        try fixture.deliver(signer)
        #expect(viewModel.callAccessAdmittedMemberships[.init(rawValue: "phone")] == replacementMembership)
    }

    @Test func samePersonWaitsForActiveRepresentativeThenReplacesAfterFreshChallenge() throws {
        let fixture = try RegularRepresentativeFixture(); defer { fixture.stop() }
        let viewModel = fixture.harness.viewModel, first = try fixture.signer("phone"),
            second = try fixture.signer("tablet")
        fixture.harness.callSession.authenticate(["phone"]); try fixture.deliver(first, name: "本人")
        #expect(viewModel.renameGroupMember("phone", in: fixture.groupID, displayName: "呼び名"))
        try viewModel.groupRepository.recordSponsoredStart(100, for: fixture.groupID, now: 200)
        let reference = viewModel.currentCallReference,
            secret = try viewModel.groupRepository.credential(for: fixture.groupID)
        fixture.harness.callSession.authenticate(["phone", "tablet"])
        let pending = try fixture.profile(second)
        try fixture.deliver(pending)
        #expect(viewModel.peerProfiles["tablet"]?.verified == nil)
        #expect(viewModel.groups[0].members.map(\.id) == ["local", "phone"])
        let count = fixture.harness.callSession.sentApplicationDataMessages.count
        fixture.harness.callSession.authenticate(["tablet"])
        #expect(
            fixture.harness.callSession.sentApplicationDataMessages.dropFirst(count).contains {
                $0.namespace == PeerProfileChallenge.namespace
            })
        #expect(viewModel.peerProfiles["tablet"]?.challenge != pending.challenge)
        try fixture.deliver(pending)
        #expect(viewModel.peerProfiles["tablet"]?.verified == nil)
        try fixture.deliver(second, name: "新しい本人名")
        let group = try #require(viewModel.groupRepository.storedGroup(fixture.groupID))
        #expect(group.members.map(\.id) == ["local", "tablet"])
        #expect(group.members[1].localName == "呼び名")
        #expect(group.members[1].displayName == "新しい本人名")
        #expect(group.accountDevices["phone"] == nil)
        #expect(viewModel.currentCallReference == reference)
        #expect(try viewModel.groupRepository.credential(for: fixture.groupID) == secret)
        #expect(viewModel.groupRepository.lastSponsoredStart(for: fixture.groupID) == 100)
        #expect(Set(viewModel.callAccessAdmittedMemberships.keys.map(\.rawValue)) == ["tablet"])
        #expect(viewModel.savedUsers.isEmpty)
        #expect(try viewModel.internetSettingsStore.notificationPermissions().isEmpty)
    }

    @Test func explicitInvitationFromSecondDeviceKeepsActiveRepresentative() throws {
        let fixture = try RegularRepresentativeFixture(); defer { fixture.stop() }
        let viewModel = fixture.harness.viewModel, first = try fixture.signer("phone"),
            second = try fixture.signer("tablet")
        fixture.harness.callSession.authenticate(["phone"]); try fixture.deliver(first)
        let credential = try #require(try viewModel.groupRepository.credential(for: fixture.groupID))
        let reference = viewModel.currentCallReference
        let token = try GroupInviteToken.make(authority: testInvitationAuthority(), signer: second,
            credential: credential, groupName: "Friends",
            inviterMemberID: "tablet", inviterDisplayName: "Person")
        try viewModel.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: token))
        #expect(viewModel.groups[0].members.map(\.id) == ["local", "phone"])
        #expect(viewModel.currentCallReference == reference)
        #expect(viewModel.savedRemoteUsers.first?.memberIDs == ["tablet"])
        fixture.harness.callSession.authenticate(["phone", "tablet"]); try fixture.deliver(second)
        #expect(viewModel.peerProfiles["tablet"]?.verified == nil)
        fixture.harness.callSession.authenticate(["tablet"]); try fixture.deliver(second)
        #expect(viewModel.groups[0].members.map(\.id) == ["local", "tablet"])
        #expect(viewModel.savedRemoteUsers.first?.memberIDs == ["tablet"])
        viewModel.removeMember("tablet", from: fixture.groupID)
        #expect(viewModel.groups[0].accountDevices["tablet"] == nil)
        #expect(viewModel.peerProfiles["tablet"] == nil)
        #expect(fixture.harness.callSession.audioPolicies.last?.peerPolicy == .admittedMemberships([:]))
        #expect(viewModel.standardCallStatus == .connecting)
    }

}

@MainActor final class RegularRepresentativeFixture {
    let issuer = P256.Signing.PrivateKey()
    let harness: AppTestSupport.Harness
    let groupID: UUID
    let namespace: String
    init(enforce: Bool = false) throws {
        namespace = "RideIntercom.RegularGroup.Tests.\(UUID())"
        let settings = InternetConnectionSettingsStore(keychain: DictionaryKeychain(), namespace: namespace)
        let key = try settings.deviceSigningKey()
        let certificate = try testIdentityCertificate(
            signer: issuer, deviceID: settings.accountDeviceID(), memberID: "local",
            deviceKey: IdentityEncoding.encode(key.publicKey.x963Representation))
        let origin = try #require(URL(string: "https://account.test"))
        let identity = try certificate.verify(origin: origin, trustedIssuerKey: certificate.issuerKey)
        try settings.save(
            url: "https://account.test",
            token:
                "ri1.\(String(repeating: "d", count: 64)).\(identity.deviceID).\(String(repeating: "e", count: 64))",
            identity: identity)
        let access = RegularRepresentativeAccess()
        harness = AppTestSupport.makeHarness(groups: [], internetSettingsStore: settings, localMemberID: "local",
            enforceCallAccess: enforce, callAccessEvaluation: { _ in access.value })
        #expect(harness.viewModel.createTalkGroup(name: "Friends"))
        groupID = try #require(harness.viewModel.selectedGroup?.id)
        access.value = .init(status: .notPurchased)
        harness.viewModel.refreshCallAccess()
    }
    func signer(_ id: String, account: String = "b", key: P256.Signing.PrivateKey? = nil) throws
        -> DeviceIdentitySigner {
        let key = key ?? TestDeviceIdentities.key(id)
        let certificate = try testIdentityCertificate(
            signer: issuer, userID: String(repeating: account, count: 64), memberID: id,
            deviceKey: IdentityEncoding.encode(key.publicKey.x963Representation))
        let origin = try #require(URL(string: "https://account.test"))
        return try DeviceIdentitySigner(memberID: id, key: key,
            identity: certificate.verify(origin: origin, trustedIssuerKey: certificate.issuerKey))
    }
    func profile(_ signer: DeviceIdentitySigner, name: String = "Person", revision: UInt64 = 1) throws
        -> SharedDisplayName {
        try testPeerProfile(
            harness.viewModel, peerID: signer.memberID, displayName: name, revision: revision, signer: signer)
    }
    func deliver(_ signer: DeviceIdentitySigner, name: String = "Person", revision: UInt64 = 1) throws {
        try deliver(profile(signer, name: name, revision: revision))
    }
    func deliver(_ value: SharedDisplayName) throws {
        harness.viewModel.handleTransportEvent(.receivedApplicationData(peerID: value.memberID,
            message: .init(namespace: SharedDisplayName.namespace, payload: try JSONEncoder().encode(value))))
    }
    func stop() { harness.viewModel.disconnect(); UserDefaults.standard.removePersistentDomain(forName: namespace) }
}

@MainActor private final class RegularRepresentativeAccess { var value = StoreAccessEvaluation(status: .active) }

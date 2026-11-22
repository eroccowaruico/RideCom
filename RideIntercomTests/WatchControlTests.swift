import Foundation
import Testing
@testable import RideIntercom

@MainActor
struct WatchControlTests {
    private func savePerson(in model: IntercomViewModel) throws {
        defer { model.disconnect() }
        let group = model.groups[0]
        let token = try GroupInviteToken.make(
            authority: testInvitationAuthority(), signer: testIdentitySigner("friend"),
            credential: .init(groupID: group.id, secret: "group-key"), groupName: group.name, inviterMemberID: "friend")
        try model.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: token))
    }

    @Test func watchDirectoryOffersOnlySavedPeopleAndRejectsOrdinaryGroupStarts() async throws {
        let rig = AppTestSupport.makeHarness(), model = rig.viewModel
        defer { model.disconnect() }
        let group = model.groups[0]
        try savePerson(in: model)
        let user = try #require(model.savedRemoteUsers.first)
        let owner = AppCallOwner(account: model.accountSession, viewModel: model)
        let userTarget = try #require(owner.callTargets.first { $0.destination == .user(user.id) })
        let groupTarget = try #require(owner.callTargets.first { $0.destination == .group(group.id) })
        let initial = owner.watchSnapshot()

        #expect(initial.targets.map(\.id) == [userTarget.entity.id],
                "The Watch directory offers saved people; Widget and Siri retain their group destinations")
        #expect(owner.callTargets.contains { $0.destination == .group(group.id) })
        let reply = await owner.handleWatchRequest(.init(.start(groupTarget.entity.id), snapshot: initial))
        #expect(reply.problem == .missingDestination)
        #expect(!model.hasAnyActiveGroupConnection, "A forged ordinary-group target must not start a Watch call")
        model.disconnect()

        let current = owner.watchSnapshot()
        #expect(await owner.handleWatchRequest(.init(.start(userTarget.entity.id), snapshot: current)).problem == nil)
        #expect(model.hasAnyActiveGroupConnection && model.isUsingWatchAudio,
                "The supported saved-person start path remains available")
    }

    @Test func audioMeterChangesDoNotPublishControlStateButCallChangesDo() async throws {
        let rig = AppTestSupport.makeHarness(); let model = rig.viewModel
        defer { model.disconnect() }
        let owner = AppCallOwner(account: model.accountSession, viewModel: model)
        let now = Date()
        let idle = owner.watchSnapshot(now: now)
        #expect(idle.needsPublication(after: nil))
        #expect(model.startCall(to: .group(model.groups[0].id), accountAccessID: model.accountAccessID))
        rig.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { model.isAudioReady }
        let talking = owner.watchSnapshot(now: now)
        #expect(talking.needsPublication(after: idle))
        for index in 1...20 {
            model.setLocalVoiceLevel(Float(index) / 20)
            model.setVoiceActive(index.isMultiple(of: 2))
            let updated = owner.watchSnapshot(now: now.addingTimeInterval(Double(index)))
            #expect(!updated.needsPublication(after: talking))
            #expect(updated != talking, "The wire snapshot must still retain fresh request expiry and reply ordering")
        }
        model.applyLocalMute(true)
        let muted = owner.watchSnapshot(now: now.addingTimeInterval(21))
        #expect(muted.needsPublication(after: talking))
        model.disconnect()
        #expect(owner.watchSnapshot().needsPublication(after: muted))
    }

    @Test func watchRemoteStartsWithPhoneAudioAndKeepsTheWatchDeadline() async throws {
        let now = Date()
        let rig = try AppTestSupport.makeHarnessWithSavedUser(callAccessNow: { now })
        let model = rig.viewModel
        defer { model.disconnect() }
        model.setCallDisconnectInterval(.oneMinute, usingWatch: true)
        let owner = AppCallOwner(account: model.accountSession, viewModel: model)
        let initial = owner.watchSnapshot(now: now)
        let target = try #require(initial.targets.first)

        let start = await owner.handleWatchRequest(.init(.startRemote(target.id), snapshot: initial), now: now)
        try #require(start.problem == nil)
        #expect(start.snapshot.supportsRemoteStart == true)
        #expect(start.snapshot.hasCall && start.audioEndpoint == nil)
        #expect(!model.isUsingWatchAudio && model.watchAudioLink == nil)
        await AppTestSupport.waitUntil { model.isAudioReady }
        #expect(rig.inputBackend.startCount == 1)
        let reference = model.currentCallReference
        #expect(model.callDisconnectDeadline == now.addingTimeInterval(60))

        let muted = await owner.handleWatchRequest(.init(.setMuted(true), snapshot: start.snapshot), now: now)
        #expect(muted.problem == nil && muted.snapshot.isMuted)
        #expect(
            model.currentCallReference == reference
                && model.callDisconnectDeadline == now.addingTimeInterval(60))

        let end = await owner.handleWatchRequest(.init(.end, snapshot: muted.snapshot), now: now)
        #expect(end.problem == nil && !end.snapshot.hasCall)
        #expect(rig.inputBackend.stopCount > 0)
    }

    @Test func watchStartDoesNotOpenThePhoneMicrophoneBeforeItsAudioDeviceConnects() async throws {
        let rig = AppTestSupport.makeHarness(); let model = rig.viewModel
        defer { model.disconnect() }
        #expect(
            model.startCall(
                to: .group(model.groups[0].id), accountAccessID: model.accountAccessID, source: .watchAudio
            ))
        let deadline = model.callDisconnectDeadline
        rig.callSession.authenticate(["member-108"])
        for _ in 0..<20 { await Task.yield() }
        #expect(model.isUsingWatchAudio)
        #expect(!model.isAudioReady)
        #expect(rig.inputBackend.startCount == 0)
        #expect(model.callDisconnectDeadline == deadline)
        model.disconnect()
        #expect(!model.isUsingWatchAudio)
        #expect(model.watchAudioLink == nil)
    }

    @Test func switchingToWatchStopsPhoneCaptureAndRetainsTheCallDeadline() async throws {
        let rig = AppTestSupport.makeHarness(); let model = rig.viewModel
        defer { model.disconnect() }
        #expect(model.startCall(to: .group(model.groups[0].id), accountAccessID: model.accountAccessID))
        rig.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { model.isAudioReady }
        #expect(rig.inputBackend.startCount == 1)
        let deadline = model.callDisconnectDeadline
        model.selectWatchAudioRoute()
        #expect(model.isUsingWatchAudio && !model.isAudioReady)
        #expect(rig.inputBackend.stopCount > 0)
        #expect(model.callDisconnectDeadline == deadline)
        model.startAudioPipelineIfNeeded()
        for _ in 0..<20 { await Task.yield() }
        #expect(rig.inputBackend.startCount == 1)
    }

    @Test func startsAndEndsAreSafeToRepeatButWatchInputRejectsPhoneMute() async throws {
        let rig = AppTestSupport.makeHarness(); let model = rig.viewModel
        defer { model.disconnect() }
        try savePerson(in: model)
        let owner = AppCallOwner(account: model.accountSession, viewModel: model)
        let now = Date(); let initial = owner.watchSnapshot(now: now)
        let target = try #require(initial.targets.first)
        let muteWriteBaseline = rig.callSession.localMuteValues.count
        let start = WatchControlRequest(.start(target.id), snapshot: initial)
        #expect(await owner.handleWatchRequest(start, now: now).problem == nil)
        #expect(model.hasAnyActiveGroupConnection)
        let reference = model.currentCallReference
        _ = await owner.handleWatchRequest(start, now: now)
        #expect(model.currentCallReference == reference)
        let running = owner.watchSnapshot(now: now)
        let mute = WatchControlRequest(.setMuted(true), snapshot: running)
        #expect(await owner.handleWatchRequest(mute, now: now).problem == .denied)
        #expect(await owner.handleWatchRequest(mute, now: now).problem == .denied)
        #expect(
            !model.isMuted
                && Array(rig.callSession.localMuteValues.dropFirst(muteWriteBaseline)) == [false])
        let end = WatchControlRequest(.end, snapshot: running)
        #expect(await owner.handleWatchRequest(end, now: now).problem == nil)
        _ = await owner.handleWatchRequest(end, now: now)
        #expect(!model.hasAnyActiveGroupConnection)
    }

    @Test func expiredAndPreviousCallCommandsCannotStartOrUnmuteAnotherCall() async throws {
        let rig = AppTestSupport.makeHarness(); let model = rig.viewModel
        defer { model.disconnect() }
        try savePerson(in: model)
        let owner = AppCallOwner(account: model.accountSession, viewModel: model)
        let now = Date(); let initial = owner.watchSnapshot(now: now)
        let groupIDs = model.regularGroups.map(\.id)
        let target = try #require(initial.targets.first)
        #expect(
            await owner.handleWatchRequest(
                .init(.start(target.id), snapshot: initial), now: now.addingTimeInterval(121)
            ).problem == .stale)
        #expect(model.activeGroupID == nil)
        #expect(model.startCall(to: .group(groupIDs[0]), accountAccessID: model.accountAccessID))
        let old = owner.watchSnapshot(now: now)
        #expect(model.startCall(to: .group(groupIDs[1]), accountAccessID: model.accountAccessID))
        model.applyLocalMute(true)
        #expect(await owner.handleWatchRequest(.init(.setMuted(false), snapshot: old), now: now).problem == .stale)
        #expect(await owner.handleWatchRequest(.init(.end, snapshot: old), now: now).problem == .stale)
        #expect(model.isMuted && model.activeGroupID == groupIDs[1])
    }

    @Test func reconnectingToTheSameGroupRejectsOldAndOutOfWindowWatchCommands() async throws {
        let model = AppTestSupport.makeHarness().viewModel
        defer { model.disconnect() }
        let owner = AppCallOwner(account: model.accountSession, viewModel: model)
        let now = Date()
        let groupID = try #require(model.regularGroups.first?.id)
        try #require(model.startCall(to: .group(groupID), accountAccessID: model.accountAccessID))
        let previous = owner.watchSnapshot(now: now)
        model.disconnect()

        try #require(model.startCall(to: .group(groupID), accountAccessID: model.accountAccessID))
        model.applyLocalMute(true)
        let current = owner.watchSnapshot(now: now)
        let outsideWindow = owner.watchSnapshot(now: now.addingTimeInterval(1))
        try #require(current.reference != previous.reference)
        #expect(await owner.handleWatchRequest(.init(.end, snapshot: previous), now: now).problem == .stale)
        #expect(await owner.handleWatchRequest(.init(.setMuted(false), snapshot: previous), now: now).problem == .stale)
        #expect(await owner.handleWatchRequest(.init(.end, snapshot: outsideWindow), now: now).problem == .stale)
        let expired = await owner.handleWatchRequest(.init(.end, snapshot: current), now: current.validUntil)
        #expect(expired.problem == .stale)
        #expect(model.activeGroupID == groupID && model.isMuted)
        #expect(await owner.handleWatchRequest(.init(.setMuted(false), snapshot: current), now: now).problem == nil)
        #expect(!model.isMuted)
        #expect(await owner.handleWatchRequest(.init(.end, snapshot: current), now: now).problem == nil)
        #expect(model.activeGroupID == nil)
    }

    @Test func removedSavedUserCannotStart() async throws {
        let rig = AppTestSupport.makeHarness(); let model = rig.viewModel
        defer { model.disconnect() }
        let group = model.groups[0]
        let token = try GroupInviteToken.make(
            authority: testInvitationAuthority(), signer: testIdentitySigner("friend"),
            credential: .init(groupID: group.id, secret: "group-key"), groupName: group.name, inviterMemberID: "friend")
        try model.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: token))
        let user = try #require(model.savedRemoteUsers.first)
        let owner = AppCallOwner(account: model.accountSession, viewModel: model)
        let snapshot = owner.watchSnapshot()
        let target = try #require(snapshot.targets.first { $0.id.contains(user.id.uuidString) })
        #expect(model.removeSavedUser(user.id))
        #expect(
            await owner.handleWatchRequest(.init(.start(target.id), snapshot: snapshot)).problem
                == .missingDestination)
        #expect(owner.watchSnapshot().targets.isEmpty)
    }

    @Test func signOutAndNewLoginCannotReuseAnOldWatchSnapshot() async throws {
        let fixture = AccountFixture(); defer { fixture.remove() }; fixture.signIn()
        let rig = AppTestSupport.makeHarness(accountSession: fixture.session); let model = rig.viewModel
        defer { model.disconnect() }
        try savePerson(in: model)
        let owner = AppCallOwner(account: fixture.session, viewModel: model)
        let old = owner.watchSnapshot(); let target = try #require(old.targets.first)
        fixture.session.signOut(); fixture.signIn()
        #expect(await owner.handleWatchRequest(.init(.start(target.id), snapshot: old)).problem == .noAccount)
        #expect(owner.watchSnapshot().reference == nil)
        #expect(owner.watchSnapshot().targets.isEmpty)
        #expect(model.activeGroupID == nil)
    }

    @Test func anotherActiveCallCannotBeReplacedAndReplyDescribesActualState() async throws {
        let rig = AppTestSupport.makeHarness(); let model = rig.viewModel
        defer { model.disconnect() }
        try savePerson(in: model)
        let owner = AppCallOwner(account: model.accountSession, viewModel: model)
        let activeGroupID = try #require(model.regularGroups.first?.id)
        #expect(model.startCall(to: .group(activeGroupID), accountAccessID: model.accountAccessID))
        let current = owner.watchSnapshot(); let target = try #require(current.targets.last)
        let reply = await owner.handleWatchRequest(.init(.start(target.id), snapshot: current))
        #expect(reply.problem == .denied && reply.snapshot.hasCall)
        #expect(model.activeGroupID == activeGroupID)
        #expect(reply.snapshot.reference == current.reference)
        #expect(try JSONDecoder().decode(WatchControlReply.self, from: JSONEncoder().encode(reply)) == reply)
    }
    @Test func deletingACurrentContactEndsTheCallTheWatchShows() async throws {
        let rig = AppTestSupport.makeHarness(); let model = rig.viewModel
        defer { model.disconnect() }
        let group = model.groups[0]
        let token = try GroupInviteToken.make(
            authority: testInvitationAuthority(), signer: testIdentitySigner("friend"),
            credential: .init(groupID: group.id, secret: "group-key"), groupName: group.name, inviterMemberID: "friend")
        try model.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: token))
        let user = try #require(model.savedRemoteUsers.first)
        #expect(model.startCall(to: .user(user.id), accountAccessID: model.accountAccessID))
        let owner = AppCallOwner(account: model.accountSession, viewModel: model)
        let current = owner.watchSnapshot()
        #expect(model.removeSavedUser(user.id))
        #expect(model.activeGroupID == nil)
        #expect(owner.watchSnapshot().reference != current.reference)
    }

}

import Foundation
import Testing
@testable import RideIntercom

@MainActor
struct CallDisconnectTimerTests {
    @Test func waitingCallEndsAtTheDefaultDeadlineAndRejectsOldEvents() throws {
        let started = Date(timeIntervalSince1970: 2_000_000_000)
        let harness = AppTestSupport.makeHarness(callAccessNow: { started }), viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        #expect(viewModel.startCall(to: .group(viewModel.groups[0].id), accountAccessID: viewModel.accountAccessID))
        let oldHandler = harness.callSession.onEvent
        viewModel.handleCallTick(now: started.timeIntervalSince1970 + 10_799)
        #expect(viewModel.hasAnyActiveGroupConnection)
        viewModel.handleCallTick(now: started.timeIntervalSince1970 + 10_800)
        #expect(viewModel.activeGroupID == nil)
        #expect(viewModel.connectionState == .idle)
        #expect(harness.callSession.disconnectCallCount == 1)
        oldHandler?(.connected(peerIDs: ["member-108"]))
        #expect(viewModel.activeGroupID == nil && viewModel.connectedPeerIDs.isEmpty)
        #expect(viewModel.groupErrorMessage?.contains("timer") == true)
    }

    @Test func retryingConnectionStillExpiresWithoutAnotherStart() {
        let started = Date(timeIntervalSince1970: 2_000_000_000)
        let harness = AppTestSupport.makeHarness(callAccessNow: { started }), viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        #expect(viewModel.startCall(to: .group(viewModel.groups[0].id), accountAccessID: viewModel.accountAccessID))
        viewModel.handleTransportEvent(.linkFailed(willRetry: true))
        #expect(viewModel.connectionState == .reconnectingOffline)
        #expect((viewModel.callTicker as? NoOpCallTicker)?.isRunning == true)
        viewModel.handleCallTick(now: started.timeIntervalSince1970 + 10_800)
        #expect(viewModel.activeGroupID == nil && viewModel.connectionState == .idle)
        #expect(harness.callSession.disconnectCallCount == 1)
    }

    @Test func supportedDurationsAreFiniteAndSettingsRoundTripIndependently() throws {
        #expect(
            CallDisconnectInterval.allCases.map(\.rawValue) == [
                60, 180, 300, 600, 900, 1800, 3600, 7200, 10800, 21600, 28800, 43200, 86400
            ])
        let suite = "RideIntercom.Tests.Timer." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsAppSettingsStore(defaults: defaults)
        #expect(store.load().callDisconnectInterval == .threeHours)
        #expect(store.load().watchCallDisconnectInterval == .fiveMinutes)
        for interval in CallDisconnectInterval.allCases {
            var settings = store.load()
            settings.callDisconnectInterval = interval
            settings.watchCallDisconnectInterval = .oneMinute
            store.save(settings)
            #expect(store.load().callDisconnectInterval == interval)
            #expect(store.load().watchCallDisconnectInterval == .oneMinute)
        }
        defaults.set(0, forKey: "RideIntercom.settings.callDisconnectInterval")
        defaults.set(999, forKey: "RideIntercom.settings.watchCallDisconnectInterval")
        #expect(store.load().callDisconnectInterval == .threeHours)
        #expect(store.load().watchCallDisconnectInterval == .fiveMinutes)
    }

    @Test func everyIntervalExpiresAtItsBoundary() {
        let started = Date(timeIntervalSince1970: 2_000_000_000)
        for interval in CallDisconnectInterval.allCases {
            let harness = AppTestSupport.makeHarness(callAccessNow: { started }), viewModel = harness.viewModel
            viewModel.setCallDisconnectInterval(interval)
            #expect(viewModel.startCall(to: .group(viewModel.groups[0].id), accountAccessID: viewModel.accountAccessID))
            viewModel.handleCallTick(now: started.timeIntervalSince1970 + interval.seconds - 0.001)
            #expect(viewModel.hasAnyActiveGroupConnection)
            viewModel.handleCallTick(now: started.timeIntervalSince1970 + interval.seconds)
            #expect(!viewModel.hasAnyActiveGroupConnection && viewModel.callDisconnectDeadline == nil)
            #expect((viewModel.callTicker as? NoOpCallTicker)?.isRunning == false)
            #expect(harness.callSession.disconnectCallCount == 1)
        }
    }

    @Test func reconnectAndDuplicateStartDoNotExtendTheCurrentDeadline() throws {
        var now = Date(timeIntervalSince1970: 2_000_000_000)
        let harness = AppTestSupport.makeHarness(callAccessNow: { now }), viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        viewModel.setCallDisconnectInterval(.oneMinute)
        let destination = CallDestination.group(viewModel.groups[0].id)
        #expect(viewModel.startCall(to: destination, accountAccessID: viewModel.accountAccessID))
        let deadline = try #require(viewModel.callDisconnectDeadline)
        now = now.addingTimeInterval(30)
        viewModel.handleTransportEvent(.linkFailed(willRetry: true))
        viewModel.handleTransportEvent(.connected(peerIDs: ["member-108"]))
        #expect(viewModel.startCall(to: destination, accountAccessID: viewModel.accountAccessID))
        #expect(viewModel.callDisconnectDeadline == deadline)
        #expect(viewModel.setCallMuted(true, for: viewModel.currentCallReference))
        viewModel.setCallDisconnectInterval(.twentyFourHours)
        #expect(viewModel.callDisconnectDeadline == deadline)
        viewModel.handleCallTick(now: deadline.timeIntervalSince1970)
        #expect(viewModel.activeGroupID == nil)
        now = deadline
        #expect(viewModel.startCall(to: destination, accountAccessID: viewModel.accountAccessID))
        #expect(viewModel.callDisconnectDeadline == deadline.addingTimeInterval(86400))
        #expect(viewModel.groupErrorMessage == nil)
    }

    @Test func watchStartUsesItsOwnSettingWithoutChangingThePhoneSetting() async throws {
        var now = Date(timeIntervalSince1970: 2_000_000_000)
        let harness = try AppTestSupport.makeHarnessWithSavedUser(callAccessNow: { now }), viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        let owner = AppCallOwner(account: viewModel.accountSession, viewModel: viewModel)
        let snapshot = owner.watchSnapshot(now: now)
        let target = try #require(snapshot.targets.first)
        #expect(await owner.handleWatchRequest(.init(.start(target.id), snapshot: snapshot), now: now).problem == nil)
        let deadline = try #require(viewModel.callDisconnectDeadline)
        #expect(deadline == now.addingTimeInterval(300))
        now = now.addingTimeInterval(60)
        let running = owner.watchSnapshot(now: now)
        #expect(await owner.handleWatchRequest(.init(.start(target.id), snapshot: running), now: now).problem == nil)
        #expect(await owner.handleWatchRequest(.init(.setMuted(true), snapshot: running), now: now).problem == .denied)
        #expect(viewModel.callDisconnectDeadline == deadline)
        viewModel.handleCallTick(now: deadline.timeIntervalSince1970)
        #expect(viewModel.activeGroupID == nil)
        now = deadline
        #expect(viewModel.startCall(to: .group(viewModel.groups[0].id), accountAccessID: viewModel.accountAccessID))
        #expect(viewModel.callDisconnectDeadline == deadline.addingTimeInterval(10800))
    }

    @Test func delayedRecoveryAfterTheDeadlineCannotRestartAudio() {
        var now = Date(timeIntervalSince1970: 2_000_000_000)
        let harness = AppTestSupport.makeHarness(callAccessNow: { now }), viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        viewModel.setCallDisconnectInterval(.oneMinute)
        #expect(viewModel.startCall(to: .group(viewModel.groups[0].id), accountAccessID: viewModel.accountAccessID))
        viewModel.handleTransportEvent(.linkFailed(willRetry: true))
        now = now.addingTimeInterval(61)
        harness.callSession.onEvent?(.connected(peerIDs: ["member-108"]))
        #expect(viewModel.activeGroupID == nil && !viewModel.isAudioReady)
        #expect(harness.callSession.startMediaCallCount == 0)
        #expect(harness.callSession.disconnectCallCount == 1)
    }

    @Test func manualSwitchAndStopDiscardThePreviousDeadline() throws {
        var now = Date(timeIntervalSince1970: 2_000_000_000)
        let harness = AppTestSupport.makeHarness(callAccessNow: { now }), viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        viewModel.setCallDisconnectInterval(.oneMinute)
        #expect(viewModel.startCall(to: .group(viewModel.groups[0].id), accountAccessID: viewModel.accountAccessID))
        let old = viewModel.currentCallReference, oldDeadline = try #require(viewModel.callDisconnectDeadline)
        now = now.addingTimeInterval(30)
        #expect(viewModel.startCall(to: .group(viewModel.groups[1].id), accountAccessID: viewModel.accountAccessID))
        #expect(viewModel.callDisconnectDeadline == oldDeadline.addingTimeInterval(30))
        #expect(!viewModel.endCall(old))
        viewModel.handleCallTick(now: oldDeadline.timeIntervalSince1970)
        #expect(viewModel.activeGroupID == viewModel.groups[1].id)
        #expect(viewModel.endCall(viewModel.currentCallReference))
        #expect(viewModel.callDisconnectDeadline == nil)
    }

    @Test func settingsRestoreResetAndAccountEndKeepTimerOwnershipLocal() {
        let store = InMemoryAppSettingsStore()
        let account = AccountFixture(); defer { account.remove() }; account.signIn()
        let harness = AppTestSupport.makeHarness(accountSession: account.session, appSettingsStore: store),
            viewModel = harness.viewModel
        viewModel.setCallDisconnectInterval(.sixHours)
        viewModel.setCallDisconnectInterval(.fifteenMinutes, usingWatch: true)
        let restored = AppTestSupport.makeHarness(appSettingsStore: store).viewModel
        #expect(restored.callDisconnectInterval == .sixHours && restored.watchCallDisconnectInterval == .fifteenMinutes)
        viewModel.resetAllSettings()
        #expect(
            store.load().callDisconnectInterval == .threeHours
                && store.load().watchCallDisconnectInterval == .fiveMinutes)
        #expect(viewModel.startCall(to: .group(viewModel.groups[0].id), accountAccessID: viewModel.accountAccessID))
        account.session.signOut()
        #expect(viewModel.callDisconnectDeadline == nil && viewModel.activeGroupID == nil)
        #expect((viewModel.callTicker as? NoOpCallTicker)?.isRunning == false)
    }

    @Test func permanentTransportStopDoesNotLeaveAnIdleTicker() {
        let harness = AppTestSupport.makeHarness(), viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        #expect(viewModel.startCall(to: .group(viewModel.groups[0].id), accountAccessID: viewModel.accountAccessID))
        viewModel.handleTransportEvent(.linkFailed(willRetry: false))
        #expect(viewModel.callDisconnectDeadline == nil)
        #expect((viewModel.callTicker as? NoOpCallTicker)?.isRunning == false)
        #expect(viewModel.startCall(to: .group(viewModel.groups[0].id), accountAccessID: viewModel.accountAccessID))
        #expect(viewModel.callDisconnectDeadline != nil)
        viewModel.handleTransportEvent(.disconnected)
        #expect(viewModel.callDisconnectDeadline == nil)
        #expect((viewModel.callTicker as? NoOpCallTicker)?.isRunning == false)
    }

    @Test func permanentStopRejectsQueuedConnectionEventsAndUnboundedMediaRestart() {
        for ending in [TransportEvent.disconnected, .linkFailed(willRetry: false)] {
            let harness = AppTestSupport.makeHarness(), viewModel = harness.viewModel
            #expect(viewModel.startCall(to: .group(viewModel.groups[0].id), accountAccessID: viewModel.accountAccessID))
            let oldHandler = harness.callSession.onEvent
            oldHandler?(ending)
            oldHandler?(.connected(peerIDs: ["member-108"]))
            #expect(viewModel.connectionState == .idle && viewModel.connectedPeerIDs.isEmpty)
            viewModel.startAudioPipelineIfNeeded()
            #expect(!viewModel.isAudioReady && harness.callSession.startMediaCallCount == 0)
            viewModel.disconnect()
        }
    }

}

// Actions arriving between the deadline and the next timer tick.
extension CallDisconnectTimerTests {
    @Test func expiredStartBeforeTheNextTickEndsTheCallWithoutStartingAnother() throws {
        for switchesDestination in [false, true] {
            var now = Date(timeIntervalSince1970: 2_000_000_000)
            let harness = AppTestSupport.makeHarness(callAccessNow: { now }), viewModel = harness.viewModel
            defer { viewModel.disconnect() }
            viewModel.setCallDisconnectInterval(.oneMinute)
            #expect(viewModel.startCall(to: .group(viewModel.groups[0].id), accountAccessID: viewModel.accountAccessID))
            let previousCall = viewModel.currentCallReference
            let next = CallDestination.group(viewModel.groups[switchesDestination ? 1 : 0].id)
            now = now.addingTimeInterval(60)
            #expect(!viewModel.startCall(to: next, accountAccessID: viewModel.accountAccessID))
            #expect(viewModel.activeGroupID == nil && viewModel.callDisconnectDeadline == nil)
            #expect(viewModel.groupErrorMessage?.contains("timer") == true)
            #expect(harness.callSession.disconnectCallCount == 1)
            #expect(viewModel.startCall(to: next, accountAccessID: viewModel.accountAccessID))
            #expect(viewModel.currentCallReference != previousCall)
            #expect(viewModel.callDisconnectDeadline == now.addingTimeInterval(60))
        }
    }

    @Test func watchSnapshotCannotUnmutePastAShorterCallDeadlineBeforeTheNextTick() async throws {
        var now = Date(timeIntervalSince1970: 2_000_000_000)
        let harness = try AppTestSupport.makeHarnessWithSavedUser(callAccessNow: { now }), viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        viewModel.setCallDisconnectInterval(.oneMinute, usingWatch: true)
        let owner = AppCallOwner(account: viewModel.accountSession, viewModel: viewModel)
        viewModel.applyLocalMute(true)
        let idle = owner.watchSnapshot(now: now), target = try #require(idle.targets.first)
        #expect(await owner.handleWatchRequest(.init(.start(target.id), snapshot: idle), now: now).problem == nil)
        #expect(!viewModel.setCallMuted(true, for: viewModel.currentCallReference))
        let running = owner.watchSnapshot(now: now)
        let unmute = WatchControlRequest(.setMuted(false), snapshot: running)
        now = now.addingTimeInterval(60)
        #expect(running.validUntil > now)
        let reply = await owner.handleWatchRequest(unmute, now: now)
        #expect(reply.problem != nil && !reply.snapshot.hasCall)
        #expect(viewModel.isMuted && harness.callSession.localMuteValues == [true, false, true])
        #expect(viewModel.activeGroupID == nil && viewModel.groupErrorMessage?.contains("timer") == true)
        #expect(await owner.handleWatchRequest(.init(.start(target.id), snapshot: running), now: now).problem == .stale)
        let fresh = owner.watchSnapshot(now: now)
        #expect(await owner.handleWatchRequest(.init(.start(target.id), snapshot: fresh), now: now).problem == nil)
        #expect(viewModel.callDisconnectDeadline == now.addingTimeInterval(60))
    }

    @Test func microphoneToggleCannotUnmuteAnExpiredCallBeforeTheNextTick() {
        var now = Date(timeIntervalSince1970: 2_000_000_000)
        let harness = AppTestSupport.makeHarness(callAccessNow: { now }), viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        viewModel.setCallDisconnectInterval(.oneMinute)
        #expect(viewModel.startCall(to: .group(viewModel.groups[0].id), accountAccessID: viewModel.accountAccessID))
        let reference = viewModel.currentCallReference
        #expect(viewModel.setCallMuted(true, for: reference))
        now = now.addingTimeInterval(60)
        viewModel.toggleMute()
        #expect(viewModel.isMuted && harness.callSession.localMuteValues == [true])
        #expect(viewModel.activeGroupID == nil && viewModel.callDisconnectDeadline == nil)
        #expect(!viewModel.setCallMuted(false, for: reference))
    }

    @Test func deviceChangeAtTheDeadlineDoesNotPauseTheNextCall() async {
        var now = Date(timeIntervalSince1970: 2_000_000_000)
        let harness = AppTestSupport.makeHarness(callAccessNow: { now }), viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        viewModel.setCallDisconnectInterval(.oneMinute)
        let destination = CallDestination.group(viewModel.groups[0].id)
        #expect(viewModel.startCall(to: destination, accountAccessID: viewModel.accountAccessID))
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { viewModel.isAudioReady }
        #expect(viewModel.isAudioReady)
        now = now.addingTimeInterval(60)
        viewModel.refreshAudioDevicesIfNeeded()
        #expect(viewModel.activeGroupID == nil && viewModel.callDisconnectDeadline == nil)
        #expect(!viewModel.isAudioPausedForDeviceChange && viewModel.audioRouteNotice == nil)
        #expect(viewModel.groupErrorMessage?.contains("timer") == true)
        #expect(viewModel.startCall(to: destination, accountAccessID: viewModel.accountAccessID))
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { viewModel.isAudioReady }
        #expect(viewModel.isAudioReady && !viewModel.isAudioPausedForDeviceChange)
        #expect(viewModel.audioRouteNotice == nil && viewModel.groupErrorMessage == nil)
    }
}

import Foundation
import RTC
import Testing
@testable import RideIntercom

@MainActor
struct CommandSchedulingTests {
    @Test func accountConflictRetainsManualRecoveryMeaningAcrossTheAppAdapter() async {
        let rtc = FakeRTCCallSession()
        let adapter = RideIntercomCallSessionAdapter(rtcSession: rtc)
        var received: [TransportEvent] = []
        adapter.onEvent = { received.append($0) }
        adapter.connect(group: IntercomSeedData.recentGroups[0])
        await rtc.waitForOperation("startConnection")
        rtc.emit(.error(.connectionBlocked(.webRTC, "End the existing call")))
        await AppTestSupport.waitUntil { received.contains(.serviceBlocked("End the existing call")) }
        #expect(received.contains(.serviceBlocked("End the existing call")))
        #expect(!received.contains(.serviceError("End the existing call")))
        adapter.disconnect()
    }

    @Test func liveAudioSettingsKeepTheConnectionAndApplyOnlyTheFinalPolicy() async {
        let rtc = FakeRTCCallSession(); let gate = ManualAsyncGate(); rtc.prepareGate = gate
        var creations = 0
        let adapter = RideIntercomCallSessionAdapter(memberID: "member-001", sessionFactory: { _, _, _ in
            creations += 1
            return rtc
        })
        adapter.connect(group: IntercomSeedData.recentGroups[0])
        await gate.waitForEntry()
        for rate in [16_000.0, 48_000, 24_000] {
            adapter.setAudioPolicy(
                .init(preferredSendFormat: .init(sampleRate: rate), preferredCodecs: [.opus, .pcm16]))
        }
        #expect(adapter.pendingCommandCount == 1)
        adapter.startMedia()
        await gate.release()
        await AppTestSupport.waitUntil { rtc.operations.contains("startMedia") }
        #expect(creations == 1)
        #expect(rtc.operations == ["prepare", "startConnection", "audioPolicy", "startMedia"])
        #expect(rtc.audioPolicies.map(\.preferredSendFormat.sampleRate) == [24_000])
        adapter.disconnect()
    }
    @Test func reconnectAfterOverflowAppliesSettingsRequestedDuringFailure() async throws {
        let old = FakeRTCCallSession(); let next = FakeRTCCallSession()
        let gate = ManualAsyncGate(); old.prepareGate = gate
        var routes: [Set<RTC.RouteKind>] = []
        let adapter = RideIntercomCallSessionAdapter(memberID: "member-001", sessionFactory: { _, value, _ in
            routes.append(value)
            return routes.count == 1 ? old : next
        })
        defer { adapter.disconnect() }
        let group = IntercomSeedData.recentGroups[0]
        var reconnectRejected = false
        adapter.onEvent = { if case .commandQueueFailed = $0 { reconnectRejected = true } }
        adapter.connect(group: group)
        await gate.waitForEntry()
        for _ in 0..<65 { adapter.sendApplicationData(.init(namespace: "ordered", payload: Data([1]))) }
        adapter.setLocalMute(true)
        adapter.setEnabledRoutes([.webRTC])
        await gate.release()
        // Recording the stop call does not mean the adapter has resumed after awaiting it.
        await AppTestSupport.waitUntil {
            reconnectRejected = false
            adapter.connect(group: group)
            return !reconnectRejected
        }
        try #require(!reconnectRejected)
        adapter.startMedia()
        await AppTestSupport.waitUntil { next.operations.contains("startMedia") }
        #expect(next.operations.contains("startMedia"))
        #expect(routes.last == [.webRTC])
        #expect(next.localMuteValues.last == true)
    }

    @Test func muteChangesDoNotAccumulateNonCooperativeAudioTasks() async {
        let rtc = FakeRTCCallSession(); let gate = ManualAsyncGate(); rtc.audioGate = gate
        let adapter = RideIntercomCallSessionAdapter(rtcSession: rtc)
        adapter.connect(group: IntercomSeedData.recentGroups[0]); adapter.startMedia()
        let send = adapter.makeAudioPacketSink(whileSourceIsActive: { true })
        await rtc.waitForOperation("startMedia")
        send(.init(sequenceNumber: 0, codec: .pcm16, payload: Data([0, 0])))
        await gate.waitForEntry()
        for sequence in 1...100 {
            adapter.setLocalMute(true); adapter.setLocalMute(false)
            send(.init(sequenceNumber: UInt64(sequence), codec: .pcm16, payload: Data([0, 0])))
            await Task.yield()
        }
        #expect(await gate.entryCount == 1)
        await gate.release()
        await AppTestSupport.waitUntil { rtc.sentAudioSequences.last == 100 }
        #expect(rtc.sentAudioSequences == [0, 100])
        adapter.disconnect()
    }

    @Test func supersededMediaStartDoesNotTransmitWhileTheStopIsPending() async {
        let rtc = FakeRTCCallSession()
        let starting = ManualAsyncGate(), stopping = ManualAsyncGate()
        rtc.startMediaGate = starting
        rtc.stopMediaGate = stopping
        let adapter = RideIntercomCallSessionAdapter(rtcSession: rtc)
        defer { adapter.disconnect() }
        adapter.connect(group: IntercomSeedData.recentGroups[0])
        adapter.startMedia()
        await starting.waitForEntry()
        adapter.stopMedia()
        adapter.startMedia()
        await starting.release()
        await stopping.waitForEntry()

        let send = adapter.makeAudioPacketSink(whileSourceIsActive: { true })
        send(.init(sequenceNumber: 1, codec: .pcm16, payload: Data([0, 0])))
        await AppTestSupport.waitUntil(timeout: .milliseconds(150)) { !rtc.sentAudioSequences.isEmpty }
        #expect(rtc.sentAudioSequences.isEmpty)

        await stopping.release()
        let expectedOrder = ["prepare", "startConnection", "startMedia", "stopMedia", "startMedia"]
        await AppTestSupport.waitUntil { rtc.operations == expectedOrder }
        #expect(rtc.operations == expectedOrder)
        send(.init(sequenceNumber: 2, codec: .pcm16, payload: Data([0, 0])))
        await AppTestSupport.waitUntil { rtc.sentAudioSequences.last == 2 }
        #expect(rtc.sentAudioSequences == [2])
    }

    @Test func preparingTheSameDestinationRequiresNewMediaAdmission() async throws {
        let rtc = FakeRTCCallSession()
        let adapter = RideIntercomCallSessionAdapter(rtcSession: rtc)
        defer { adapter.disconnect() }
        let group = IntercomSeedData.recentGroups[0]
        let send = adapter.makeAudioPacketSink(whileSourceIsActive: { true })
        adapter.connect(group: group)
        adapter.startMedia()
        await rtc.waitForOperation("startMedia")
        send(.init(sequenceNumber: 1, codec: .pcm16, payload: Data([0, 0])))
        await AppTestSupport.waitUntil { rtc.sentAudioSequences == [1] }
        try #require(rtc.sentAudioSequences == [1])

        adapter.connect(group: group)
        adapter.setLocalMute(true)
        await AppTestSupport.waitUntil { rtc.localMuteValues.last == true }
        try #require(rtc.localMuteValues.last == true)
        adapter.setLocalMute(false)
        await AppTestSupport.waitUntil { rtc.localMuteValues.last == false }
        try #require(rtc.localMuteValues.last == false)
        send(.init(sequenceNumber: 2, codec: .pcm16, payload: Data([0, 0])))
        await AppTestSupport.waitUntil(timeout: .milliseconds(150)) { rtc.sentAudioSequences != [1] }
        #expect(rtc.sentAudioSequences == [1], "Preparing a new connection must revoke the previous media admission")

        adapter.startMedia()
        await AppTestSupport.waitUntil { rtc.operations.filter { $0 == "startMedia" }.count == 2 }
        send(.init(sequenceNumber: 3, codec: .pcm16, payload: Data([0, 0])))
        await AppTestSupport.waitUntil { rtc.sentAudioSequences.last == 3 }
        #expect(rtc.sentAudioSequences == [1, 3])
    }

    @Test func slowConnectionKeepsOnlyFinalSettingsAndPreservesMediaOrder() async {
        let rtc = FakeRTCCallSession(); let gate = ManualAsyncGate(); rtc.prepareGate = gate
        let adapter = RideIntercomCallSessionAdapter(rtcSession: rtc)
        adapter.connect(group: IntercomSeedData.recentGroups[0])
        await gate.waitForEntry()
        for index in 0..<10_000 { adapter.setLocalMute(index.isMultiple(of: 2)) }
        #expect(adapter.pendingCommandCount == 1)
        adapter.startMedia()
        adapter.stopMedia()
        adapter.disconnect()
        #expect(adapter.pendingCommandCount == 4)
        await gate.release()
        await rtc.waitForOperation("stopConnection")
        #expect(rtc.operations == ["prepare", "startConnection", "startMedia", "stopMedia", "stopConnection"])
        #expect(rtc.localMuteValues == [false, false])
        #expect(adapter.pendingCommandCount == 0)
    }

    @Test func changingRoutesRestartsTheRequestedMediaAndDropsAudioDuringTheTransition() async throws {
        let current = FakeRTCCallSession()
        let replacement = FakeRTCCallSession()
        let starting = ManualAsyncGate()
        replacement.startMediaGate = starting
        let adapter = RideIntercomCallSessionAdapter(memberID: "member-001", sessionFactory: { _, routes, _ in
            routes == [.webRTC] ? replacement : current
        })
        defer { adapter.disconnect() }
        let sink = adapter.makeAudioPacketSink(whileSourceIsActive: { true })
        func send(_ sequence: UInt64) {
            sink(.init(sequenceNumber: sequence, codec: .pcm16, payload: Data([0, 0])))
        }

        adapter.connect(group: IntercomSeedData.recentGroups[0])
        adapter.startMedia()
        await AppTestSupport.waitUntil { current.operations.contains("startMedia") }
        try #require(current.operations.contains("startMedia"))
        send(1)
        await AppTestSupport.waitUntil { current.sentAudioSequences == [1] }
        try #require(current.sentAudioSequences == [1])

        adapter.setEnabledRoutes([.webRTC])
        await AppTestSupport.waitUntil { replacement.operations.contains("startConnection") }
        send(2)
        // This command runs after the replacement RTC completes startMedia.
        adapter.setAudioPolicy(.init(preferredSendFormat: .init(sampleRate: 24_000), preferredCodecs: [.pcm16]))
        await starting.release()
        await AppTestSupport.waitUntil { replacement.operations.contains("audioPolicy") }
        try #require(replacement.operations == ["prepare", "startConnection", "startMedia", "audioPolicy"])
        send(3)
        await AppTestSupport.waitUntil { replacement.sentAudioSequences.contains(3) }
        #expect(current.sentAudioSequences == [1])
        #expect(replacement.sentAudioSequences == [3])
    }
    @Test func overflowReportsOnceAndStopsBeforeAcceptingReconnect() async {
        let rtc = FakeRTCCallSession(); let gate = ManualAsyncGate(); rtc.prepareGate = gate
        let adapter = RideIntercomCallSessionAdapter(rtcSession: rtc)
        var failures = 0
        adapter.onEvent = { if case .commandQueueFailed = $0 { failures += 1 } }
        adapter.connect(group: IntercomSeedData.recentGroups[0])
        await gate.waitForEntry()
        for _ in 0..<65 { adapter.sendApplicationData(.init(namespace: "ordered", payload: Data([1]))) }
        #expect(failures == 1)
        #expect(adapter.pendingCommandCount == 1)
        await gate.release()
        await rtc.waitForOperation("stopConnection")
        #expect(rtc.operations == ["prepare", "startConnection", "stopConnection"])
    }
    @Test func settingsDoNotConstructIntermediateSessionsWhileBackendIsBusy() async {
        let old = FakeRTCCallSession(); let next = FakeRTCCallSession()
        let gate = ManualAsyncGate(); old.prepareGate = gate
        var creations = 0
        let adapter = RideIntercomCallSessionAdapter(memberID: "member-001", sessionFactory: { _, _, _ in
            creations += 1
            return creations == 1 ? old : next
        })
        adapter.connect(group: IntercomSeedData.recentGroups[0])
        await gate.waitForEntry()
        let configuration = RTC.CloudflareRealtimeConfiguration(
            workerURL: URL(string: "https://fixture.invalid")!, accessToken: "fixture")
        for _ in 0..<10_000 { adapter.updateInternetConfiguration(configuration) }
        #expect(creations == 1)
        #expect(adapter.pendingCommandCount == 1)
        await gate.release()
        await next.waitForOperation("startConnection")
        #expect(creations == 2)
        adapter.disconnect()
        await next.waitForOperation("stopConnection")
    }
}

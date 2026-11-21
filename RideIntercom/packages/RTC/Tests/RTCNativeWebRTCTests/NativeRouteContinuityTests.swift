import Foundation
import Testing
import RTCTestSupport
@testable import RTC

@Suite(.serialized) struct NativeRouteContinuityTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
    func nativeQUICControlSurvivesMediaBlackholesAndWebRTCRecovers(bothDirections: Bool, blockedAtStart: Bool)
        async throws {
        let pair = NativeContinuityPair()
        let tasks = pair.recordEvents()
        defer { tasks.forEach { $0.cancel() } }
        let credential = RTCCredential.derived(groupID: UUID().uuidString, secret: "native-route-fixture")
        var proxies: [MediaBlackhole] = []
        do {
            try await pair.connect(credential: credential)
            let media = try await pair.startMedia(proxies: &proxies)
            if !blockedAtStart {
                try await waitForLocalReceipts(pair: pair, media: media, markers: 1...100)
            }
            try await verifyWebRTCFallback(pair: pair, media: media, proxies: proxies, bothDirections: bothDirections)
            for proxy in proxies { proxy.setBlocked(false) }
            try await waitForLocalReceipts(pair: pair, media: media, markers: 2000...2100)
            try await verifyRecoveredLocalPaths(
                pair: pair, bothDirections: bothDirections, blockedAtStart: blockedAtStart
            )
            try await verifyStoppedMedia(pair: pair, media: media)
        } catch {
            for manager in pair.managers { await manager.stopConnection() }
            for proxy in proxies { proxy.stop() }
            await pair.server.stop()
            throw error
        }
        for proxy in proxies { proxy.stop() }
        await pair.server.stop()
    }

    private func waitForLocalReceipts(
        pair: NativeContinuityPair, media: [LocalDatagramTransport], markers: ClosedRange<UInt32>
    ) async throws {
        for marker in markers {
            await pair.sendAudio(marker)
            if media[0].hasRecentMediaReceipt(for: pair.ids[1]) && media[1].hasRecentMediaReceipt(for: pair.ids[0]) {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(media[0].hasRecentMediaReceipt(for: pair.ids[1]) && media[1].hasRecentMediaReceipt(for: pair.ids[0]))
    }

    private func verifyWebRTCFallback(
        pair: NativeContinuityPair, media: [LocalDatagramTransport], proxies: [MediaBlackhole], bothDirections: Bool
    ) async throws {
        proxies[0].setBlocked(true)
        if bothDirections { proxies[1].setBlocked(true) }
        for marker in UInt32(1000)...1099 {
            await pair.sendAudio(marker)
            try await Task.sleep(for: .milliseconds(20))
        }
        for record in pair.records {
            try await requireContinuity("Fresh media arrives over the surviving route") {
                await record.has(1099)
            }
        }
        #expect(media[0].isReady(for: pair.ids[1]) && !media[0].hasRecentMediaReceipt(for: pair.ids[1]))
        if bothDirections {
            #expect(media[1].isReady(for: pair.ids[0]) && !media[1].hasRecentMediaReceipt(for: pair.ids[0]))
        }
        #expect(await pair.internet[0].mediaSends > 0)
        let fallbackDispatch = try #require(await pair.managers[0].networkDiagnostics().outboundAudioDispatch)
        #expect(fallbackDispatch.transportAcceptance == [.multipeer: true, .webRTC: true],
            "The network can drop Local packets after the backend has accepted them")
        #expect(
            await pair.server.forwardedMedia > 0,
            "Fallback must cross native DTLS/SCTP, not a manufactured route event")
        let control = ApplicationDataMessage(namespace: "control-proof", payload: Data([1]))
        for route in pair.local { _ = await route.sendApplicationData(control) }
        for record in pair.records {
            try await requireContinuity("QUIC still carries reliable control") {
                await record.localControl.contains(control)
            }
        }
        #expect(proxies[0].droppedCount > 0)
        if bothDirections { #expect(proxies[1].droppedCount > 0) }
    }

    private func verifyRecoveredLocalPaths(
        pair: NativeContinuityPair, bothDirections: Bool, blockedAtStart: Bool
    ) async throws {
        let before = [await pair.internet[0].mediaSends, await pair.internet[1].mediaSends]
        await pair.sendAudio(3000)
        for record in pair.records {
            try await requireContinuity("New media arrives after Local recovery") { await record.has(3000) }
        }
        let after = [await pair.internet[0].mediaSends, await pair.internet[1].mediaSends]
        #expect(after == before, "Proven Local paths suppress unnecessary Internet copies")
        for index in pair.ids.indices {
            let dispatch = try #require(await pair.managers[index].networkDiagnostics().outboundAudioDispatch)
            #expect(dispatch.transportAcceptance == [.multipeer: true])
            #expect(dispatch.internetCoveredByLocal)
            let markers = await pair.records[index].markers
            #expect(
                Set(markers).count == markers.count,
                "Multiple native copies are delivered to the receiver only once")
            if !blockedAtStart && (index == 1 || bothDirections) {
                #expect(!markers.contains(1000), "Lost old speech is not replayed")
            }
            #expect(await pair.records[index].localPeers == [pair.ids[1 - index]])
            #expect(await pair.records[index].errors.isEmpty)
            #expect(await pair.internet[index].starts == 1, "Recovery must not restart the group")
        }
    }

    private func verifyStoppedMedia(pair: NativeContinuityPair, media: [LocalDatagramTransport]) async throws {
        for manager in pair.managers { await manager.stopConnection() }
        let stopped = [await pair.records[0].markers.count, await pair.records[1].markers.count]
        await pair.sendAudio(4000)
        try await Task.sleep(for: .milliseconds(100))
        for index in pair.ids.indices {
            #expect(await pair.records[index].markers.count == stopped[index])
            #expect(!media[index].hasRecentMediaReceipt(for: pair.ids[1 - index]))
        }
    }
}

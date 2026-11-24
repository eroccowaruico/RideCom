import Foundation
import RTC

#if canImport(WebRTC)
import WebRTC

private final class WebRTCHandle: @unchecked Sendable {
    private struct OwnedReference: @unchecked Sendable {
        let pointer: OpaquePointer
        let observation: AnyObject?
        let release: (OpaquePointer) -> Void

        func dispose() { withExtendedLifetime(observation) { release(pointer) } }
    }

    private static let disposal = DispatchQueue(label: "RideCom.WebRTC.disposal")
    private let lock = NSLock()
    private let release: (OpaquePointer) -> Void
    private var pointer: OpaquePointer?
    private var observation: AnyObject?

    init(_ pointer: OpaquePointer, release: @escaping (OpaquePointer) -> Void) {
        self.pointer = pointer
        self.release = release
    }

    deinit {
        guard let owned = takeReference() else { return }
        // A callback can hold the last Swift reference on an SDK thread.
        // Unregister observers and release SDK threads outside that callback.
        Self.disposal.async { owned.dispose() }
    }

    func use<Value>(_ body: (OpaquePointer) -> Value) -> Value? {
        lock.withLock { pointer.map(body) }
    }

    func observe(_ context: AnyObject, register: (OpaquePointer, UnsafeMutableRawPointer) -> Void) {
        lock.withLock {
            guard let pointer else { return }
            register(pointer, Unmanaged.passUnretained(context).toOpaque())
            observation = context
        }
    }

    func close() { takeReference()?.dispose() }

    private func takeReference() -> OwnedReference? {
        lock.withLock {
            guard let reference = pointer else { return nil }
            let owned = OwnedReference(pointer: reference, observation: observation, release: release)
            pointer = nil
            observation = nil
            return owned
        }
    }
}

final class ModularWebRTCFactory: Sendable {
    private let handle: WebRTCHandle

    init?(includeLoopback: Bool) {
        guard let factory = RideComRTCFactoryCreate(includeLoopback) else { return nil }
        handle = WebRTCHandle(factory, release: RideComRTCFactoryRelease)
    }

    func makePeer() -> ModularWebRTCPeer? {
        guard let peer = handle.use({ RideComRTCPeerCreate($0) }) ?? nil else { return nil }
        return ModularWebRTCPeer(peer)
    }
}

private final class WebRTCCompletion<Value: Sendable>: Sendable {
    let continuation: CheckedContinuation<Value, Never>

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }
}

private final class IceObservation: Sendable {
    let changed: @Sendable (RideComRTCIceState) -> Void

    init(_ changed: @escaping @Sendable (RideComRTCIceState) -> Void) {
        self.changed = changed
    }
}

final class ModularWebRTCPeer: Sendable {
    private let handle: WebRTCHandle

    init(_ peer: OpaquePointer) {
        handle = WebRTCHandle(peer, release: RideComRTCPeerRelease)
    }

    func setIceServers(_ servers: [WebRTCIceServer]) -> Bool {
        var storage: [UnsafeMutablePointer<CChar>] = []
        defer { for pointer in storage { free(pointer) } }
        func copy(_ string: String) -> UnsafePointer<CChar>? {
            guard !string.utf8.contains(0), let pointer = strdup(string) else { return nil }
            storage.append(pointer)
            return UnsafePointer(pointer)
        }

        var entries: [RideComRTCIceServer] = []
        for server in servers {
            guard let username = copy(server.username ?? ""), let password = copy(server.credential ?? "") else {
                return false
            }
            for url in server.urls {
                guard let address = copy(url) else { return false }
                entries.append(.init(url: address, username: username, password: password))
            }
        }
        return handle.use { peer in
            entries.withUnsafeBufferPointer { RideComRTCPeerSetIceServers(peer, $0.baseAddress, $0.count) }
        } ?? false
    }

    func observeIce(_ changed: @escaping @Sendable (RideComRTCIceState) -> Void) {
        handle.observe(IceObservation(changed)) { peer, context in
            RideComRTCPeerObserveIce(peer, context) { @Sendable pointer, state in
                guard let pointer else { return }
                Unmanaged<IceObservation>.fromOpaque(pointer).takeUnretainedValue().changed(state)
            }
        }
    }

    func makeChannel(label: String, id: Int32, delivery: ApplicationDataDelivery) -> ModularWebRTCChannel? {
        let channel = handle.use { RideComRTCChannelCreate($0, label, id, delivery == .reliable) } ?? nil
        guard let channel else { return nil }
        return ModularWebRTCChannel(channel, id: id, delivery: delivery)
    }

    private func waitForDescription(
        _ request: (OpaquePointer, UnsafeMutableRawPointer, RideComRTCDescriptionCompletion) -> Void
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let requested = handle.use { peer in
                let context = Unmanaged.passRetained(WebRTCCompletion(continuation)).toOpaque()
                request(peer, context) { @Sendable pointer, success in
                    guard let pointer else { return }
                    let completion = Unmanaged<WebRTCCompletion<Bool>>.fromOpaque(pointer).takeRetainedValue()
                    completion.continuation.resume(returning: success)
                }
                return true
            } ?? false
            if !requested { continuation.resume(returning: false) }
        }
    }

    func makeLocalDescription() async -> String? {
        guard await waitForDescription(RideComRTCPeerSetLocalDescription) else { return nil }
        for _ in 0..<100 {
            if handle.use({ RideComRTCPeerHasGatheredCandidates($0) }) != false || Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return handle.use { peer in
            guard let sdp = RideComRTCPeerCopyLocalDescription(peer) else { return nil }
            defer { RideComRTCDescriptionRelease(sdp) }
            return String(cString: sdp)
        } ?? nil
    }

    func setRemoteDescription(_ sdp: String, kind: RideComRTCDescriptionKind) async -> Bool {
        guard !sdp.utf8.contains(0) else { return false }
        return await waitForDescription { peer, context, completion in
            sdp.withCString { RideComRTCPeerSetRemoteDescription(peer, kind, $0, context, completion) }
        }
    }

    func roundTripTime() async -> Double? {
        await withCheckedContinuation { continuation in
            let requested = handle.use { peer in
                let context = Unmanaged.passRetained(WebRTCCompletion(continuation)).toOpaque()
                RideComRTCPeerGetIceRoundTripTime(peer, context) { @Sendable pointer, available, seconds in
                    guard let pointer else { return }
                    let completion = Unmanaged<WebRTCCompletion<Double?>>.fromOpaque(pointer).takeRetainedValue()
                    completion.continuation.resume(returning: available ? seconds : nil)
                }
                return true
            } ?? false
            if !requested { continuation.resume(returning: nil) }
        }
    }

    func close() { handle.close() }
}

private final class ChannelObservation: Sendable {
    let changed: @Sendable () -> Void
    let received: @Sendable (Data) -> Void

    init(changed: @escaping @Sendable () -> Void, received: @escaping @Sendable (Data) -> Void) {
        self.changed = changed
        self.received = received
    }
}

final class ModularWebRTCChannel: Sendable {
    let id: Int32
    let delivery: ApplicationDataDelivery
    private let handle: WebRTCHandle

    init(_ channel: OpaquePointer, id: Int32, delivery: ApplicationDataDelivery) {
        self.id = id
        self.delivery = delivery
        handle = WebRTCHandle(channel, release: RideComRTCChannelRelease)
    }

    var isOpen: Bool { handle.use { RideComRTCChannelGetState($0) == RideComRTCChannelOpen } ?? false }
    var bufferedBytes: UInt64 { handle.use { RideComRTCChannelBufferedBytes($0) } ?? 0 }

    func observe(changed: @escaping @Sendable () -> Void, received: @escaping @Sendable (Data) -> Void) {
        handle.observe(ChannelObservation(changed: changed, received: received)) { channel, context in
            RideComRTCChannelObserve(
                channel, context,
                { @Sendable pointer in
                    guard let pointer else { return }
                    Unmanaged<ChannelObservation>.fromOpaque(pointer).takeUnretainedValue().changed()
                },
                { @Sendable pointer, bytes, count in
                    guard let pointer, let bytes else { return }
                    let observation = Unmanaged<ChannelObservation>.fromOpaque(pointer).takeUnretainedValue()
                    observation.received(Data(bytes: bytes, count: count))
                }
            )
        }
    }

    func send(_ data: Data) -> Bool {
        handle.use { channel in
            data.withUnsafeBytes { buffer in
                RideComRTCChannelSend(channel, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count)
            }
        } ?? false
    }

    func close() { handle.close() }
}
#endif

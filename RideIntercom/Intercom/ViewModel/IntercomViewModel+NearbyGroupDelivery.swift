import Foundation
import RTC

@MainActor
final class NearbyGroupDeliveryWindow {
    let id = UUID()
    var timeout: Task<Void, Never>?
    var nextBatch: Task<Void, Never>?
    var endBackgroundTime: (() -> Void)?
}

/// The order of outstanding work stays with the account model, across finite attempts.
struct NearbyGroupDeliverySchedule {
    private var eligibleDeliveryIDs: Set<UUID> = []
    private var offeredInSweep: Set<PeerID> = []

    mutating func update(with pending: [GroupDeliveryRecord], afterSave: Bool) -> Set<PeerID> {
        let newPeers = afterSave ? Set(pending.filter { !eligibleDeliveryIDs.contains($0.id) }
            .map { PeerID(rawValue: $0.recipientMemberID) }) : []
        eligibleDeliveryIDs = Set(pending.map(\.id))
        offeredInSweep.formIntersection(pending.map { PeerID(rawValue: $0.recipientMemberID) })
        return newPeers
    }

    mutating func select(from pending: [GroupDeliveryRecord], retaining current: Set<PeerID>, prioritize newPeers: Set<PeerID>,
                         startsWindow: Bool) -> (offered: Set<PeerID>, hasMore: Bool) {
        var seen: Set<PeerID> = []
        let ranked = pending.sorted { $0.expiresAt > $1.expiresAt }.map { PeerID(rawValue: $0.recipientMemberID) }
            .filter { seen.insert($0).inserted }
        if startsWindow && seen.isSubset(of: offeredInSweep) {
            offeredInSweep.removeAll()
        }
        let priority = ranked.filter { newPeers.contains($0) } + ranked.filter { current.contains($0) }
        let untried = ranked.filter { !offeredInSweep.contains($0) }
        var offered: Set<PeerID> = []
        for peer in priority + untried {
            offered.insert(peer)
            if offered.count == RTCLocalDataChannel.maximumOfferedPeers { break }
        }
        offeredInSweep.formUnion(offered)
        return (offered, !seen.isSubset(of: offeredInSweep))
    }
}

@MainActor
final class NearbyGroupDeliveryExchange {
    let id: UUID
    let credentials: [PeerID: RTCCredential]
    let offeredPeers: Set<PeerID>
    let channel: RTCLocalDataChannel
    var sent: [PeerID: Set<UUID>] = [:]
    var connected: Set<PeerID> = []

    init(id: UUID, credentials: [PeerID: RTCCredential], offeredPeers: Set<PeerID>, channel: RTCLocalDataChannel) {
        self.id = id
        self.credentials = credentials
        self.offeredPeers = offeredPeers
        self.channel = channel
    }
}

private enum NearbyGroupDeliveryFrame: Codable {
    case invitation(GroupInvitationEnvelope)
    case receipt(GroupInvitationReceipt)
}

extension IntercomViewModel {
    private var canUseNearbyGroupDelivery: Bool {
        allowsNearbyGroupDelivery && canEditSavedGroups && enabledRTCTransportRoutes.contains(.multipeer)
    }

    func nearbyGroupDeliveryCredentials() -> [PeerID: RTCCredential] {
        guard canEditSavedGroups, let localAccountPrincipal,
              let signer = try? internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID) else { return [:] }
        var credentials: [PeerID: RTCCredential] = [:]
        for person in savedRemoteUsers {
            guard let principal = person.principal, principal != localAccountPrincipal,
                  principal.issuer == localAccountPrincipal.issuer else { continue }
            for peer in person.memberIDs {
                guard let key = person.deviceKeys?[peer],
                      let secret = try? signer.nearbyGroupDeliverySecret(peerMemberID: peer, peerPublicKey: key)
                else { continue }
                credentials[.init(rawValue: peer)] = .derived(groupID: DeviceIdentitySigner.nearbyGroupDeliveryDomain,
                                                               secret: IdentityEncoding.encode(secret))
            }
        }
        return credentials
    }

    func setNearbyGroupDeliveryForeground(_ foreground: Bool) {
        guard nearbyGroupDeliveryIsForeground != foreground else { return }
        nearbyGroupDeliveryIsForeground = foreground
        if foreground {
            refreshNearbyGroupDelivery()
        } else if nearbyGroupDeliveryWindow == nil {
            stopNearbyGroupDelivery()
        }
    }

    func refreshNearbyGroupDelivery(startOffers: Bool = true, afterSave: Bool = false, advanceBatch: Bool = false) {
        guard canUseNearbyGroupDelivery,
              nearbyGroupDeliveryIsForeground || afterSave || nearbyGroupDeliveryWindow != nil
        else { stopNearbyGroupDelivery(); return }
        let credentials = nearbyGroupDeliveryCredentials()
        guard !credentials.isEmpty else { stopNearbyGroupDelivery(); return }
        let pending = pendingNearbyGroupDeliveries().filter { credentials[.init(rawValue: $0.recipientMemberID)] != nil }
        let priorWindow = nearbyGroupDeliveryWindow
        let newPeers = nearbyGroupDeliverySchedule.update(with: pending, afterSave: afterSave)
        if !pending.isEmpty && startOffers {
            openNearbyGroupDeliveryWindow(afterSave: afterSave, renew: !newPeers.isEmpty)
        }

        var offered: Set<PeerID> = []
        if let window = nearbyGroupDeliveryWindow {
            let previous = nearbyGroupDeliveryExchange?.offeredPeers ?? []
            let batch = nearbyGroupDeliverySchedule.select(from: pending, retaining: advanceBatch ? [] : previous,
                                                           prioritize: newPeers, startsWindow: priorWindow == nil)
            offered = batch.offered
            if offered.isEmpty {
                closeNearbyGroupDeliveryWindow()
            } else {
                scheduleNearbyGroupDeliveryBatch(on: window, hasMore: batch.hasMore, changed: previous != offered)
            }
        }
        guard nearbyGroupDeliveryIsForeground || !offered.isEmpty else { stopNearbyGroupDelivery(); return }
        if let exchange = nearbyGroupDeliveryExchange, exchange.offeredPeers == offered, exchange.credentials == credentials {
            sendNearbyGroupDeliveries(on: exchange)
            return
        }

        nearbyGroupDeliveryExchange?.channel.stop()
        let id = UUID()
        let channel = RTCLocalDataChannel(localID: .init(rawValue: localMemberIdentity.memberID), knownPeers: credentials,
                                          offeredPeers: offered) { [weak self] event in
            DispatchQueue.main.async { self?.receiveNearbyGroupDeliveryEvent(event, on: id) }
        }
        nearbyGroupDeliveryExchange = .init(id: id, credentials: credentials, offeredPeers: offered, channel: channel)
        channel.start()
    }

    private func pendingNearbyGroupDeliveries() -> [GroupDeliveryRecord] {
        let now = callAccessNow().timeIntervalSince1970
        return groupRepository.groupDeliveries.filter { record in
            record.direction == .outgoing && (record.state == .pending || record.state == .queued)
                && record.expiresAt > now && record.sourceRequestID == nil
                && savedRemoteUsers.contains {
                    $0.principal == record.recipient && $0.memberIDs.contains(record.recipientMemberID)
                        && $0.deviceKeys?[record.recipientMemberID] == record.recipientKey
                }
        }
    }

    private func openNearbyGroupDeliveryWindow(afterSave: Bool, renew: Bool) {
        let window = nearbyGroupDeliveryWindow ?? NearbyGroupDeliveryWindow()
        nearbyGroupDeliveryWindow = window
        if window.timeout == nil || renew {
            // Renew only the app deadline. Any system expiration still ends the entire window.
            window.timeout?.cancel()
            let id = window.id
            window.timeout = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(20))
                    try Task.checkCancellation()
                } catch { return }
                self?.expireNearbyGroupDeliveryWindow(id)
            }
        }
        guard afterSave, window.endBackgroundTime == nil else { return }
        let id = window.id
        let end = beginGroupDeliveryBackgroundTime { [weak self] in self?.expireNearbyGroupDeliveryWindow(id) }
        if nearbyGroupDeliveryWindow === window { window.endBackgroundTime = end }
        else { end?() }
    }

    private func scheduleNearbyGroupDeliveryBatch(on window: NearbyGroupDeliveryWindow, hasMore: Bool, changed: Bool) {
        if changed || !hasMore {
            window.nextBatch?.cancel()
            window.nextBatch = nil
        }
        guard hasMore, window.nextBatch == nil else { return }
        let id = window.id
        window.nextBatch = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(8))
                try Task.checkCancellation()
            } catch { return }
            guard let self, let current = self.nearbyGroupDeliveryWindow, current.id == id else { return }
            current.nextBatch = nil
            self.refreshNearbyGroupDelivery(startOffers: false, advanceBatch: true)
        }
    }

    private func expireNearbyGroupDeliveryWindow(_ id: UUID) {
        guard nearbyGroupDeliveryWindow?.id == id else { return }
        closeNearbyGroupDeliveryWindow()
        refreshNearbyGroupDelivery(startOffers: false)
    }

    private func closeNearbyGroupDeliveryWindow() {
        let window = nearbyGroupDeliveryWindow
        nearbyGroupDeliveryWindow = nil
        window?.timeout?.cancel()
        window?.nextBatch?.cancel()
        window?.endBackgroundTime?()
    }

    func finishNearbyGroupDeliveryIfComplete() {
        guard let exchange = nearbyGroupDeliveryExchange, !exchange.offeredPeers.isEmpty,
              !pendingNearbyGroupDeliveries().contains(where: { exchange.offeredPeers.contains(.init(rawValue: $0.recipientMemberID)) })
        else { return }
        refreshNearbyGroupDelivery(startOffers: false, advanceBatch: true)
    }

    func stopNearbyGroupDelivery() {
        closeNearbyGroupDeliveryWindow()
        nearbyGroupDeliveryExchange?.channel.stop()
        nearbyGroupDeliveryExchange = nil
    }

    private func receiveNearbyGroupDeliveryEvent(_ event: RTCLocalDataChannel.Event, on id: UUID) {
        guard canUseNearbyGroupDelivery, let exchange = nearbyGroupDeliveryExchange, exchange.id == id else { return }
        switch event {
        case .members(let peers):
            exchange.connected = Set(peers)
            exchange.sent = exchange.sent.filter { exchange.connected.contains($0.key) }
            sendNearbyGroupDeliveries(on: exchange)
        case .message(let data, let peer):
            guard let frame = try? JSONDecoder().decode(NearbyGroupDeliveryFrame.self, from: data) else { return }
            do {
                switch frame {
                case .invitation(let envelope):
                    if let receipt = try receiveNearbyGroupInvitation(envelope, from: peer.rawValue) {
                        let response = try JSONEncoder().encode(NearbyGroupDeliveryFrame.receipt(receipt))
                        exchange.channel.send(response, to: peer)
                    }
                case .receipt(let receipt):
                    try acknowledgeNearbyGroupInvitation(receipt, from: peer.rawValue)
                    finishNearbyGroupDeliveryIfComplete()
                }
            } catch let error as GroupStorageError {
                reportGroupStorageError(error)
            } catch {
                // An invalid or stale frame leaves the saved state and current candidate intact.
            }
        case .failed:
            stopNearbyGroupDelivery()
        }
    }

    private func sendNearbyGroupDeliveries(on exchange: NearbyGroupDeliveryExchange) {
        guard let localAccountPrincipal, !exchange.offeredPeers.isDisjoint(with: exchange.connected) else { return }
        for record in pendingNearbyGroupDeliveries() {
            let peer = PeerID(rawValue: record.recipientMemberID)
            guard exchange.offeredPeers.contains(peer), exchange.connected.contains(peer),
                  exchange.sent[peer]?.contains(record.id) != true else { continue }
            do {
                if let envelope = try prepareGroupDeliveryEnvelope(record, sender: localAccountPrincipal) {
                    let data = try JSONEncoder().encode(NearbyGroupDeliveryFrame.invitation(envelope))
                    guard data.count <= 65_536 else { continue }
                    try groupRepository.recordNearbyGroupHandoff(record.id)
                    exchange.channel.send(data, to: peer)
                    exchange.sent[peer, default: []].insert(record.id)
                }
            } catch {
                reportGroupStorageError(error)
                return
            }
        }
    }
}

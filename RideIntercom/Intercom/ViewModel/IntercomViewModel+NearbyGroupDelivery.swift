import Foundation
import RTC

@MainActor
final class NearbyGroupDeliveryWindow {
    let id = UUID()
    var timeout: Task<Void, Never>?
    var nextBatch: Task<Void, Never>?
    var endBackgroundTime: (() -> Void)?
}

struct PendingNearbyDelivery {
    enum WorkID: Hashable {
        case group(GroupDeliveryRecord.NearbyWork)
        case contactDeletion(UUID)
    }

    enum Payload {
        case group(GroupDeliveryRecord, GroupDeliveryRecord.NearbyWork)
        case contactDeletion(ContactDeletionNotice)
    }

    let id: WorkID
    let peer: PeerID
    let expiresAt: TimeInterval
    let payload: Payload
}

struct NearbyDeliveryPeer: Equatable {
    let publicKey: String
    let localPublicKey: String
    let credential: RTCCredential
}

/// The order of outstanding work stays with the account model, across finite attempts.
struct NearbyGroupDeliverySchedule {
    private var eligibleWork: Set<PendingNearbyDelivery.WorkID> = []
    private var offeredInSweep: Set<PeerID> = []

    mutating func update(with pending: [PendingNearbyDelivery], afterSave: Bool) -> Set<PeerID> {
        let newPeers = afterSave ? Set(pending.filter { !eligibleWork.contains($0.id) }.map(\.peer)) : []
        eligibleWork = Set(pending.map(\.id))
        offeredInSweep.formIntersection(pending.map(\.peer))
        return newPeers
    }

    mutating func select(
        from pending: [PendingNearbyDelivery], retaining current: Set<PeerID>, prioritize newPeers: Set<PeerID>,
        startsWindow: Bool
    ) -> (offered: Set<PeerID>, hasMore: Bool) {
        var seen: Set<PeerID> = []
        let ranked = pending.sorted { $0.expiresAt > $1.expiresAt }.map(\.peer)
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
    let peers: [PeerID: NearbyDeliveryPeer]
    let offeredPeers: Set<PeerID>
    let channel: RTCLocalDataChannel
    var sent: [PeerID: Set<PendingNearbyDelivery.WorkID>] = [:]
    var connected: Set<PeerID> = []

    init(id: UUID, peers: [PeerID: NearbyDeliveryPeer], offeredPeers: Set<PeerID>, channel: RTCLocalDataChannel) {
        self.id = id
        self.peers = peers
        self.offeredPeers = offeredPeers
        self.channel = channel
    }
}

nonisolated enum NearbyGroupDeliveryFrame: Codable {
    case invitation(GroupInvitationEnvelope)
    case receipt(GroupInvitationReceipt)
    case cancellation(GroupInvitationCancellation)
    case cancellationReceipt(GroupInvitationCancellationReceipt)
    case contactDeletion(ContactDeletionNotice)
    case contactDeletionReceipt(ContactDeletionReceipt)
}

extension IntercomViewModel {
    private var canUseNearbyGroupDelivery: Bool {
        allowsNearbyGroupDelivery && canEditSavedGroups && enabledRTCTransportRoutes.contains(.multipeer)
    }

    func nearbyGroupDeliveryCredentials() -> [PeerID: RTCCredential] {
        nearbyDeliveryPeers().mapValues(\.credential)
    }

    private func nearbyDeliveryPeers() -> [PeerID: NearbyDeliveryPeer] {
        guard canEditSavedGroups,
              let signer = try? internetSettingsStore.contactDeletionSigner(memberID: localMemberIdentity.memberID)
        else { return [:] }
        let now = callAccessNow()
        let account = localAccountPrincipal
        let directPeers = Set(groups.filter { $0.kind == .direct && $0.accountPair == nil }
            .flatMap { $0.members.map(\.id) })
        var keys: [String: String] = [:]
        // Keep the verified peer's key while the deletion or a possible retransmission is outstanding.
        for receipt in groupRepository.contactDeletionReceipts
        where receipt.target.recipientKey == signer.publicKey && receipt.target.isCurrent(at: now) {
            keys[receipt.target.senderMemberID] = receipt.senderKey
        }
        for former in groupRepository.contactDeletionFormerPairs
        where groupRepository.canUseFormerContactDeletionPair(former, signer: signer, now: now) {
            keys[former.peerID] = former.peerKey
        }
        for notice in groupRepository.contactDeletions
        where notice.proof.publicKey == signer.publicKey && notice.target.isCurrent(at: now) {
            keys[notice.target.recipientMemberID] = notice.target.recipientKey
        }
        for person in savedRemoteUsers {
            let canExchangeGroupInvitations = person.principal.map {
                $0 != account && $0.issuer == account?.issuer
            } ?? false
            for peer in person.memberIDs where canExchangeGroupInvitations || directPeers.contains(peer) {
                if let key = person.deviceKeys?[peer] { keys[peer] = key }
            }
        }
        return Dictionary(uniqueKeysWithValues: keys.compactMap { peer, key in
            guard let secret = try? signer.nearbyGroupDeliverySecret(peerMemberID: peer, peerPublicKey: key)
            else { return nil }
            let credential = RTCCredential.derived(groupID: DeviceIdentitySigner.nearbyGroupDeliveryDomain,
                                                  secret: IdentityEncoding.encode(secret))
            let deliveryPeer = NearbyDeliveryPeer(
                publicKey: key, localPublicKey: signer.publicKey, credential: credential)
            return (PeerID(rawValue: peer), deliveryPeer)
        })
    }

    func refreshNearbyGroupDelivery(startOffers: Bool = true, afterSave: Bool = false, advanceBatch: Bool = false) {
        guard canUseNearbyGroupDelivery,
              groupDeliveryIsForeground || afterSave || nearbyGroupDeliveryWindow != nil
        else { stopNearbyGroupDelivery(); return }
        let peers = nearbyDeliveryPeers()
        guard !peers.isEmpty else { stopNearbyGroupDelivery(); return }
        let pending = pendingNearbyDeliveries(for: peers)
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
        guard groupDeliveryIsForeground || !offered.isEmpty else { stopNearbyGroupDelivery(); return }
        if let exchange = nearbyGroupDeliveryExchange, exchange.offeredPeers == offered, exchange.peers == peers {
            sendNearbyGroupDeliveries(on: exchange)
            return
        }

        nearbyGroupDeliveryExchange?.channel.stop()
        let id = UUID()
        let channel = RTCLocalDataChannel(
            localID: .init(rawValue: localMemberIdentity.memberID), knownPeers: peers.mapValues(\.credential),
            offeredPeers: offered
        ) { [weak self] event in
            DispatchQueue.main.async { self?.receiveNearbyGroupDeliveryEvent(event, on: id) }
        }
        nearbyGroupDeliveryExchange = .init(id: id, peers: peers, offeredPeers: offered, channel: channel)
        channel.start()
    }

    private func pendingNearbyDeliveries(for peers: [PeerID: NearbyDeliveryPeer]) -> [PendingNearbyDelivery] {
        let now = callAccessNow()
        let deletions = groupRepository.contactDeletions.compactMap { notice -> PendingNearbyDelivery? in
            let peer = PeerID(rawValue: notice.target.recipientMemberID)
            guard notice.target.isCurrent(at: now),
                  peers[peer]?.publicKey == notice.target.recipientKey,
                  peers[peer]?.localPublicKey == notice.proof.publicKey else { return nil }
            return .init(id: .contactDeletion(notice.id), peer: peer, expiresAt: notice.target.expiresAt,
                         payload: .contactDeletion(notice))
        }
        let records = groupRepository.groupDeliveries
        let people = savedRemoteUsers
        let cancellationFirst = records.filter { $0.state == .cancelled } + records.filter { $0.state != .cancelled }
        let invitations = cancellationFirst.compactMap { record -> PendingNearbyDelivery? in
            let peer = PeerID(rawValue: record.recipientMemberID)
            guard let work = record.nearbyWork, record.expiresAt > now.timeIntervalSince1970,
                  peers[peer]?.publicKey == record.recipientKey,
                  people.contains(where: {
                    $0.principal == record.recipient && $0.memberIDs.contains(record.recipientMemberID)
                        && $0.deviceKeys?[record.recipientMemberID] == record.recipientKey
                  }) else { return nil }
            return .init(id: .group(work), peer: peer, expiresAt: record.expiresAt, payload: .group(record, work))
        }
        return deletions + invitations
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
        if nearbyGroupDeliveryWindow === window { window.endBackgroundTime = end } else { end?() }
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
              !pendingNearbyDeliveries(for: exchange.peers).contains(where: { exchange.offeredPeers.contains($0.peer) })
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
                if let response = try responseToNearbyGroupDelivery(frame, from: peer) {
                    exchange.channel.send(try JSONEncoder().encode(response), to: peer)
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

    private func responseToNearbyGroupDelivery(
        _ frame: NearbyGroupDeliveryFrame, from peer: PeerID
    ) throws -> NearbyGroupDeliveryFrame? {
        switch frame {
        case .invitation(let envelope):
            return try receiveNearbyGroupInvitation(envelope, from: peer.rawValue).map(NearbyGroupDeliveryFrame.receipt)
        case .receipt(let receipt):
            try acknowledgeNearbyGroupInvitation(receipt, from: peer.rawValue)
            finishNearbyGroupDeliveryIfComplete()
            return nil
        case .cancellation(let cancellation):
            return .cancellationReceipt(try receiveNearbyGroupInvitationCancellation(cancellation, from: peer.rawValue))
        case .cancellationReceipt(let receipt):
            try acknowledgeNearbyGroupCancellation(receipt, from: peer.rawValue)
            finishNearbyGroupDeliveryIfComplete()
            return nil
        case .contactDeletion(let notice):
            return .contactDeletionReceipt(try receiveContactDeletion(notice, from: peer.rawValue))
        case .contactDeletionReceipt(let receipt):
            try acknowledgeContactDeletion(receipt, from: peer.rawValue)
            finishNearbyGroupDeliveryIfComplete()
            if hasPendingContactDeletionRelay { requestGroupDeliverySync(.localChange) }
            return nil
        }
    }

    private func sendNearbyGroupDeliveries(on exchange: NearbyGroupDeliveryExchange) {
        guard !exchange.offeredPeers.isDisjoint(with: exchange.connected) else { return }
        for delivery in pendingNearbyDeliveries(for: exchange.peers) {
            let peer = delivery.peer
            guard exchange.offeredPeers.contains(peer), exchange.connected.contains(peer),
                  exchange.sent[peer]?.contains(delivery.id) != true else { continue }
            do {
                guard let frame = try outgoingNearbyGroupDeliveryFrame(for: delivery.payload) else { continue }
                let data = try JSONEncoder().encode(frame)
                guard data.count <= 65_536 else { continue }
                if case .group(let record, .invitation) = delivery.payload {
                    try groupRepository.recordNearbyGroupHandoff(record.id)
                }
                exchange.channel.send(data, to: peer)
                exchange.sent[peer, default: []].insert(delivery.id)
            } catch {
                reportGroupStorageError(error)
                return
            }
        }
    }

    private func outgoingNearbyGroupDeliveryFrame(
        for payload: PendingNearbyDelivery.Payload
    ) throws -> NearbyGroupDeliveryFrame? {
        switch payload {
        case .contactDeletion(let notice):
            return .contactDeletion(notice)
        case .group(let record, let work):
            guard let localAccountPrincipal else { return nil }
            switch work {
            case .invitation:
                return try prepareGroupDeliveryEnvelope(record, sender: localAccountPrincipal)
                    .map(NearbyGroupDeliveryFrame.invitation)
            case .cancellation:
                return .cancellation(try makeNearbyGroupCancellation(for: record, sender: localAccountPrincipal))
            }
        }
    }
}

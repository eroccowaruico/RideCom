import Foundation
import RTC

@MainActor
final class NearbyGroupDeliveryWindow {
    let id = UUID()
    var timeout: Task<Void, Never>?
    var endBackgroundTime: (() -> Void)?
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

    func refreshNearbyGroupDelivery(startOffers: Bool = true, afterSave: Bool = false) {
        guard canUseNearbyGroupDelivery,
              nearbyGroupDeliveryIsForeground || afterSave || nearbyGroupDeliveryWindow != nil
        else { stopNearbyGroupDelivery(); return }
        let credentials = nearbyGroupDeliveryCredentials()
        guard !credentials.isEmpty else { stopNearbyGroupDelivery(); return }
        let pending = pendingNearbyGroupDeliveries().filter { credentials[.init(rawValue: $0.recipientMemberID)] != nil }
        if pending.isEmpty {
            closeNearbyGroupDeliveryWindow()
        } else if startOffers {
            openNearbyGroupDeliveryWindow(afterSave: afterSave)
        }

        var offered: Set<PeerID> = []
        if nearbyGroupDeliveryWindow != nil {
            for record in pending.sorted(by: { $0.expiresAt > $1.expiresAt }) {
                offered.insert(.init(rawValue: record.recipientMemberID))
                if offered.count == RTCLocalDataChannel.maximumOfferedPeers { break }
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

    private func openNearbyGroupDeliveryWindow(afterSave: Bool) {
        let window: NearbyGroupDeliveryWindow
        if let active = nearbyGroupDeliveryWindow {
            window = active
        } else {
            window = NearbyGroupDeliveryWindow()
            nearbyGroupDeliveryWindow = window
            let id = window.id
            window.timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                self?.expireNearbyGroupDeliveryWindow(id)
            }
        }
        guard afterSave, window.endBackgroundTime == nil else { return }
        let id = window.id
        let end = beginGroupDeliveryBackgroundTime { [weak self] in self?.expireNearbyGroupDeliveryWindow(id) }
        if nearbyGroupDeliveryWindow === window { window.endBackgroundTime = end }
        else { end?() }
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
        window?.endBackgroundTime?()
    }

    func finishNearbyGroupDeliveryIfComplete() {
        guard let exchange = nearbyGroupDeliveryExchange, !exchange.offeredPeers.isEmpty,
              !pendingNearbyGroupDeliveries().contains(where: { exchange.offeredPeers.contains(.init(rawValue: $0.recipientMemberID)) })
        else { return }
        closeNearbyGroupDeliveryWindow()
        refreshNearbyGroupDelivery(startOffers: false)
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

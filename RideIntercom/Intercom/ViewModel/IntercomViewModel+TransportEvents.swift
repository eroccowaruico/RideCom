import AVFoundation
import Codec
import CryptoKit
import Foundation
import Logging
import OSLog
import RTC
import SessionManager
import VADGate

extension IntercomViewModel {
    func broadcastControl(_ message: ControlMessage) {
        callSession.sendControl(message)
    }

    func broadcastMetadataKeepalive() {
        callSession.sendControl(.keepalive)
        sendPendingInvitationReceipt()
    }

    func sendStateMetadataSnapshot() {
        sendPeerProfileChallenges()
        broadcastControl(.peerMuteState(isMuted: effectiveInputMuted))
        broadcastMetadataKeepalive()
    }

    func handleTransportEvent(_ event: TransportEvent) {
        guard !disconnectIfTimerExpired(now: callAccessNow().timeIntervalSince1970) else { return }
        switch event {
        case .routesChanged(let snapshot):
            handleCallRoutesChanged(snapshot)
        case .commandQueueFailed:
            disconnect()
            groupErrorMessage = "Too many pending operations. The call stopped; connect again to retry."
        case .serviceBlocked(let reason):
            internetFailureDetail = reason
            internetTransportNotice = reason
        case .serviceError(let reason):
            internetFailureDetail = reason
            internetTransportNotice =
                "Internet is unavailable. Retrying automatically; reachable riders stay connected."
        case .connected(let peerIDs):
            handleConnectedPeers(peerIDs)
        case .authenticated(let members):
            handleAuthenticatedPeers(members)
        case .disconnected:
            finishTransportConnection()
        case .linkFailed(let willRetry):
            handleLinkFailure(willRetry: willRetry)
        case .remotePeerMuteState, .remotePeerMetadata, .remoteRuntimeStatus, .receivedApplicationData,
             .receivedAudioPacket, .networkDiagnostics, .routeMetrics, .localNetworkStatus:
            handleTransportData(event)
        }
    }

    private func handleTransportData(_ event: TransportEvent) {
        switch event {
        case .remotePeerMuteState(let peerID, let isMuted):
            updateAuthenticatedPeer(peerID) {
                setRemotePeerMuteState(peerID: peerID, isMuted: isMuted)
            }
        case .remotePeerMetadata(let peerID, let activeCodec):
            updateAuthenticatedPeer(peerID) {
                if let activeCodec { setRemotePeerCodec(peerID, codec: activeCodec) }
            }
        case .remoteRuntimeStatus(let peerID, let status):
            updateAuthenticatedPeer(peerID) {
                remoteRuntimeStatuses[peerID] = status
            }
        case .receivedApplicationData(let peerID, let message):
            handleAppData(peerID: peerID, message: message)
        case .receivedAudioPacket(let received, let reception):
            handleReceivedAudioPacket(received, reception: reception)
        case .networkDiagnostics(let report):
            networkDiagnostics = report
        case .routeMetrics(let metrics):
            handleRouteMetrics(metrics)
        case .localNetworkStatus(let event):
            localNetworkStatus = event.status
            lastLocalNetworkPeerID = event.peerID
            lastLocalNetworkEventAt = event.occurredAt
        default:
            break
        }
    }

    private func updateAuthenticatedPeer(_ peerID: String, update: () -> Void) {
        guard authenticatedPeerIDs.contains(peerID) else { return }
        update()
    }

    private func handleCallRoutesChanged(_ snapshot: RTC.ActiveRouteSnapshot) {
        let newlyAvailable = snapshot.availableRoutes.subtracting(availableCallRoutes)
        availableCallRoutes = snapshot.availableRoutes
        if !authenticatedPeerIDs.isEmpty {
            connectionState = routeConnectionState(isConnected: true)
        } else if connectionState == .localConnecting || connectionState == .internetConnecting {
            connectionState = routeConnectionState(isConnected: false)
        }
        if snapshot.availableRoutes.contains(.webRTC) {
            internetTransportNotice = nil
            internetFailureDetail = nil
        }
        if activeGroupID != nil {
            if newlyAvailable.contains(.webRTC) { requestInvitationInternetReply() }
            if newlyAvailable.contains(.multipeer) { resumeSavedNearbyOrdinaryGroupReplies() }
        }
    }

    private func handleConnectedPeers(_ peerIDs: [String]) {
        AppLoggers.rtc.info(
            "rtc.connection.started",
            metadata: .event("rtc.connection.started", [
                "route": "\(routeLabel)",
                "peerCount": "\(peerIDs.count)"
            ])
        )
        connectedPeerIDs = peerIDs
        removeDisconnectedAuthenticatedPeers(connectedPeerIDs: peerIDs)
        refreshCallAccess()
        refreshCallMediaAdmission()
        localNetworkStatus = peerIDs.isEmpty ? .advertisingBrowsing : .connected
        connectionState = routeConnectionState(isConnected: !peerIDs.isEmpty)
        markConnectedMembers(peerIDs: peerIDs)
        publishRuntimePackageReports(force: true)
    }

    private func handleAuthenticatedPeers(_ members: [RTC.CallMemberState]) {
        let peerIDs = members.filter { $0.isConnected && $0.peer.id.rawValue != localMemberIdentity.memberID }
            .map { $0.peer.id.rawValue }
        let authenticatedPeerIDSet = Set(peerIDs)
        if let group = groups.first(where: { $0.id == activeGroupID }),
           group.kind == .direct, group.accountPair == nil,
           !authenticatedPeerIDSet.isSubset(of: group.members.map(\.id).filter { $0 != localMemberIdentity.memberID }) {
            disconnect()
            groupErrorMessage = "An unexpected participant joined this individual call. The call was stopped."
            return
        }
        authenticatedPeerIDs = Array(authenticatedPeerIDSet).sorted()
        synchronizePeerProfiles(members: members)
        connectedPeerIDs = Array(Set(connectedPeerIDs).union(authenticatedPeerIDSet)).sorted()
        connectionState = routeConnectionState(isConnected: !authenticatedPeerIDs.isEmpty)
        markConnectedMembers(peerIDs: connectedPeerIDs)
        startActiveCallAfterAuthenticatedPeer()
        sendStateMetadataSnapshot()
        publishRuntimePackageReports(force: true)
    }

    private func finishTransportConnection() {
        connectionGeneration = UUID()
        callSession.onEvent = nil
        callDisconnectDeadline = nil
        networkDiagnostics = nil
        callTicker.stop()
        connectedPeerIDs = []
        authenticatedPeerIDs = []
        peerProfiles.removeAll()
        stopAudioPipeline()
        localNetworkStatus = .idle
        connectionState = .idle
        markMembers(.offline)
        publishRuntimePackageReports(force: true)
    }

    private func handleAppData(peerID: String, message: ApplicationDataMessage) {
        receivePeerProfileChallenge(peerID: peerID, message: message)
        receiveSharedDisplayName(peerID: peerID, message: message)
        receiveInvitationReceipt(peerID: peerID, message: message)
        receiveCallAccess(peerID: peerID, message: message)
        receiveNotificationPermission(peerID: peerID, message: message)
        let announcesContact = [
            PeerProfileChallenge.namespace, SharedDisplayName.namespace, DirectInvitationReceipt.namespace
        ].contains(message.namespace)
        if announcesContact {
            // A person met for the first time gets their grant before it is shared.
            Task { [weak self, weak notifications] in
                await notifications?.allowEveryContact(); self?.sendNotificationPermissions()
            }
        }
    }

    private func handleLinkFailure(willRetry: Bool) {
        AppLoggers.rtc.error(
            "rtc.connection.failed",
            metadata: .event("rtc.connection.failed", [
                "route": "\(routeLabel)",
                "isRecoverable": "\(willRetry)"
            ])
        )
        guard willRetry else {
            finishTransportConnection()
            return
        }
        networkDiagnostics = nil
        connectedPeerIDs = []
        authenticatedPeerIDs = []
        peerProfiles.removeAll()
        refreshCallMediaAdmission()
        localNetworkStatus = .unavailable
        connectionState = .reconnectingOffline
        markMembers(.connecting)
        publishRuntimePackageReports(force: true)
    }
}

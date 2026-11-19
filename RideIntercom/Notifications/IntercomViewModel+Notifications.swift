import Foundation
import RTC

extension IntercomViewModel {
    /// Registers for notifications by itself when the OS allows them and lets every saved person notify you.
    func startNotifications() async {
        await notifications.start()
        sendNotificationPermissions()
        await synchronizeGroupDeliveries()
    }
    /// Application data is a broadcast API. Personal grants therefore use only
    /// an account-bound direct call with exactly its intended peer connected.
    private func notificationExchangeContext() -> (peerID: String, group: IntercomGroup)? {
        guard canStartCalls, let local = localAccountPrincipal, let activeGroupID,
              let group = groups.first(where: { $0.id == activeGroupID }), group.kind == .direct,
              group.accountDevices[localMemberIdentity.memberID]?.principal == local,
              authenticatedPeerIDs.count == 1, connectedPeerIDs.count == 1,
              let peerID = authenticatedPeerIDs.first, connectedPeerIDs.first == peerID,
              let profile = peerProfiles[peerID]?.verified, profile.identity.memberID == peerID,
              let user = savedRemoteUsers.first(where: { $0.memberIDs.contains(peerID) }), let peer = user.principal,
              peer != local, peer.issuer == local.issuer, group.accountPair?.other(than: local) == peer,
              group.accountDevices[peerID]?.principal == peer,
              group.accountDevices[peerID]?.publicKey == profile.identity.publicKey,
              user.deviceKeys?[peerID] == profile.identity.publicKey,
              profile.identity.principal == nil || profile.identity.principal == peer else { return nil }
        return (peerID, group)
    }
    func sendNotificationPermissions() {
        guard notifications.hasPermissionsToShare, let context = notificationExchangeContext(),
              let signer = try? internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID),
              context.group.accountDevices[localMemberIdentity.memberID]?.publicKey == signer.publicKey,
              let value = try? notifications.permissionMessage(for: context.peerID, signer: signer),
              let payload = try? JSONEncoder().encode(value), payload.count <= 8192 else { return }
        if let groupValue = try? notifications.groupPermissionMessage(for: context.peerID, signer: signer),
           let groupPayload = try? JSONEncoder().encode(groupValue), groupPayload.count <= 8192 {
            callSession.sendApplicationData(.init(namespace: CallNotificationPermissionMessage.groupNamespace, payload: groupPayload))
        }
        callSession.sendApplicationData(.init(namespace: CallNotificationPermissionMessage.namespace, payload: payload))
    }
    func receiveNotificationPermission(peerID: String, message: ApplicationDataMessage) {
        guard [CallNotificationPermissionMessage.namespace, CallNotificationPermissionMessage.groupNamespace].contains(message.namespace), message.payload.count <= 8192,
              notificationExchangeContext()?.peerID == peerID,
              let value = message.decodedPayload(CallNotificationPermissionMessage.self, from: peerID) else { return }
        do { try notifications.receivePermission(value, peerID: peerID); requestGroupDeliverySync(forNewWork: message.namespace == CallNotificationPermissionMessage.groupNamespace) }
        catch { /* Untrusted or unrelated capabilities cannot authorize a call. */ }
    }
}

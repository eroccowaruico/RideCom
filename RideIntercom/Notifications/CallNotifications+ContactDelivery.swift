import Foundation

extension CallNotifications {
    var canUseNotifications: Bool { access() != nil }

    func allowsIncoming(from id: UUID) -> Bool {
        guard let context = access(), let record = permission(id, context: context) else { return false }
        return record.allowsIncoming && record.receiving != nil
    }
    func canNotify(_ id: UUID) -> Bool {
        guard let context = access(), let record = permission(id, context: context) else { return false }
        return record.sending?.isAddressed(to: record.peer, from: context.principal) == true
    }

    /// Issues the receiving grant for every saved person who does not have one yet. Stops at the first failure
    /// (usually offline) and tries again at the next start.
    func allowEveryContact() async {
        guard let context = access() else { return }
        for user in contacts() where contact(user.id, context: context) != nil && !allowsIncoming(from: user.id) {
            guard await setIncomingAllowed(true, contactID: user.id) else { return }
        }
        await allowGroupInvitations()
    }

    func groupInvitationGrant(for contactID: UUID) -> CallNotificationGrant? {
        guard let context = access(), let record = permission(contactID, context: context),
            let grant = record.groupSending,
            grant.isAddressed(to: record.peer, from: context.principal, audience: "rideintercom-group-invitation")
        else { return nil }
        return grant
    }

    func permissionMessage(
        for peerID: String, signer: DeviceIdentitySigner
    ) throws -> CallNotificationPermissionMessage? {
        guard let context = access(), let user = contacts().first(where: { $0.memberIDs.contains(peerID) }),
              let record = permission(user.id, context: context), record.revision > 0 else { return nil }
        return try .make(owner: context.principal, allowedSender: record.peer, revision: record.revision,
                         grant: record.allowsIncoming ? record.receiving : nil, signer: signer)
    }
    func groupPermissionMessage(for peerID: String, signer: DeviceIdentitySigner) throws
        -> CallNotificationPermissionMessage? {
        guard let context = access(), let user = contacts().first(where: { $0.memberIDs.contains(peerID) }),
              let record = permission(user.id, context: context), record.revision > 0 else { return nil }
        return try .make(owner: context.principal, allowedSender: record.peer, revision: record.revision,
                         grant: record.allowsIncoming ? record.receiving : nil, signer: signer,
            groupGrant: record.allowsGroupInvitations == true ? record.groupReceiving : nil,
            groupInvitationsSupported: true)
    }
    func receivePermission(_ value: CallNotificationPermissionMessage, peerID: String) throws {
        guard let context = access(), let user = contacts().first(where: { $0.memberIDs.contains(peerID) }),
              contact(user.id, context: context) != nil else { throw DeviceIdentityProof.Failure.invalid }
        let grant = try value.verifiedGrant(peerID: peerID, savedUser: user, local: context.principal)
        guard let source = value.proof?.publicKey else { throw DeviceIdentityProof.Failure.invalid }
        let previous = permission(user.id, context: context)
        let updatesCall =
            !(previous?.receivedRevisionSource == source && value.revision <= (previous?.receivedRevision ?? 0))
            && !(grant == nil && previous?.sending != nil && previous?.receivedRevisionSource != source)
        let updatesGroup = value.groupInvitationsSupported == true
            && !(previous?.groupReceivedRevisionSource == source
                && value.revision <= (previous?.groupReceivedRevision ?? 0))
            && !(value.groupGrant == nil && previous?.groupSending != nil
                && previous?.groupReceivedRevisionSource != source)
        guard updatesCall || updatesGroup else { return }
        try update(user.id, context: context) {
            if updatesCall {
                $0.sending = grant; $0.receivedRevision = value.revision; $0.receivedRevisionSource = source
            }
            if updatesGroup {
                $0.groupSending = value.groupGrant; $0.groupReceivedRevision = value.revision
                $0.groupReceivedRevisionSource = source
            }
        }
    }

    func send(to contactID: UUID) async -> CallNotificationReply? {
        // Not held back by `isBusy`: grants are issued by themselves at launch and sign-in, and a notice
        // that is sent once and never followed up must not be lost to that housekeeping.
        guard let context = access(), let record = permission(contactID, context: context),
            let grant = record.sending, grant.isAddressed(to: record.peer, from: context.principal)
        else { return nil }
        let capability = grant.capability
        let expected = generation
        do {
            let reply = try await client.sendCallNotification(
                origin: context.origin, token: context.accessToken, capability: capability, requestID: UUID())
            guard current(context, generation: expected),
                permission(contactID, context: context)?.sending?.capability == capability
            else { return nil }
            // A courtesy sent once: its result is not shown or followed up.
            return reply
        } catch { return nil }
    }
    func canReceive(_ tap: CallNotificationTap) -> Bool { receivingAccess(for: tap) != nil }
    private func receivingAccess(for tap: CallNotificationTap) -> CallNotificationServiceAccess? {
        guard isEnabled, let context = access(), context.principal.userID == tap.recipientID else { return nil }
        return context
    }
    func resolveTap(_ tap: CallNotificationTap) async -> UUID? {
        guard let context = receivingAccess(for: tap) else { return nil }
        let expected = generation
        do {
            let reply = try await client.readCallNotification(
                origin: context.origin, token: context.accessToken, recipientUserID: tap.recipientID,
                requestID: tap.requestID)
            guard isEnabled, current(context, generation: expected), reply.isLive(at: now()),
                let user = contacts().first(where: {
                    $0.principal?.userID == reply.senderUserID && $0.principal?.issuer == context.principal.issuer
                }),
                  allowsIncoming(from: user.id) else { return nil }
            return user.id
        } catch { return nil }
    }
}

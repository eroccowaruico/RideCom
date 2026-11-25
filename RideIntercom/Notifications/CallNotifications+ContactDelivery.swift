import Foundation

nonisolated struct ResolvedCallNotification: Sendable {
    let userID: UUID
    let expiresAt: Date
    let grantID: UUID
    let authorizationGeneration: Int
    let deviceDisableGeneration: Int
    let tapLookupGeneration: Int
}

extension CallNotifications {
    var canUseNotifications: Bool { access() != nil }

    var hasGroupInvitationReceivingPermission: Bool {
        guard let context = access() else { return false }
        return contacts().contains { user in
            guard let peer = user.principal, let record = permission(user.id, context: context),
                  record.allowsGroupInvitations == true else { return false }
            return record.groupReceiving?.isAddressed(
                to: context.principal, from: peer, audience: "rideintercom-group-invitation"
            ) == true
        }
    }

    func allowsIncoming(from id: UUID) -> Bool {
        guard let context = access() else { return false }
        return receivingGrant(from: id, context: context) != nil
    }
    private func receivingGrant(from id: UUID, context: CallNotificationServiceAccess) -> CallNotificationGrant? {
        guard let record = permission(id, context: context), record.allowsIncoming else { return nil }
        return record.receiving
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
    func canRespond(to resolved: ResolvedCallNotification, tap: CallNotificationTap) -> Bool {
        guard generation == resolved.authorizationGeneration,
              deviceDisableGeneration == resolved.deviceDisableGeneration,
              tapLookupGeneration == resolved.tapLookupGeneration,
              let context = receivingAccess(for: tap) else { return false }
        return receivingGrant(from: resolved.userID, context: context)?.grantID == resolved.grantID
    }

    func cancelTapLookups() {
        tapLookupGeneration += 1
        for lookup in tapLookups.values { lookup.cancel() }
        tapLookups.removeAll()
    }

    private func readCallNotification(
        _ tap: CallNotificationTap, context: CallNotificationServiceAccess
    ) async throws -> CallNotificationReply {
        let id = UUID()
        let lookup = Task { [client] in
            try Task.checkCancellation()
            return try await client.readCallNotification(
                origin: context.origin, token: context.accessToken, recipientUserID: tap.recipientID,
                requestID: tap.requestID)
        }
        tapLookups[id] = lookup
        defer { tapLookups[id] = nil }
        return try await withTaskCancellationHandler {
            try await lookup.value
        } onCancel: {
            lookup.cancel()
        }
    }

    func resolveTap(_ tap: CallNotificationTap) async -> ResolvedCallNotification? {
        guard !Task.isCancelled, let context = receivingAccess(for: tap) else { return nil }
        let expected = generation, expectedDevice = deviceDisableGeneration
        let expectedLookup = tapLookupGeneration
        do {
            let reply = try await readCallNotification(tap, context: context)
            guard tapLookupGeneration == expectedLookup, deviceDisableGeneration == expectedDevice,
                current(context, generation: expected),
                receivingAccess(for: tap) == context, reply.isLive(at: now()),
                let user = contacts().first(where: {
                    $0.principal?.userID == reply.senderUserID && $0.principal?.issuer == context.principal.issuer
                }),
                let grant = receivingGrant(from: user.id, context: context) else { return nil }
            return .init(
                userID: user.id, expiresAt: Date(timeIntervalSince1970: reply.expiresAt / 1000),
                grantID: grant.grantID, authorizationGeneration: expected, deviceDisableGeneration: expectedDevice,
                tapLookupGeneration: expectedLookup)
        } catch { return nil }
    }
}

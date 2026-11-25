import Foundation
import RTC

extension IntercomViewModel {
    private var contactInvitationRoutes: Set<RTC.RouteKind> {
        activeGroupID == nil ? enabledRTCTransportRoutes : enabledRTCTransportRoutes.intersection([.multipeer])
    }

    var contactInvitationWaitsForCurrentCall: Bool { contactInvitationRoutes.isEmpty }

    var pendingContactInvitations: [ContactInvitationRecord] {
        _ = contactInvitationRevision
        let now = callAccessNow().timeIntervalSince1970
        // Expired outgoing invitations stay until replaced or cancelled.
        return groupRepository.contactInvitations.filter { !contactInvitationIsComplete($0)
                && ($0.canResume(at: now) || $0.isExpiredOutgoing(at: now)) }
            .sorted { $0.expiresAt > $1.expiresAt }
    }

    /// Direct contact consent is independent of the right to create a group.
    func makeContactInviteURL(replacingExpiredInvitation id: UUID? = nil) -> URL? {
        guard canEditSavedGroups else { groupErrorMessage = groupStorageNotice; return nil }
        do {
            let signer = try internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID)
            let token = try ContactInvitationSession.makeToken(authority: invitationAuthority, signer: signer,
                displayName: localMemberIdentity.displayName, now: callAccessNow().timeIntervalSince1970)
            try groupRepository.stageContactInvitation(
                token, now: callAccessNow().timeIntervalSince1970, replacingExpiredInvitation: id)
            refreshGroupStorageStatus()
            let url = try GroupInviteTokenCodec.joinURL(for: token, contactBootstrap: true)
            _ = resumeContactInvitation(try contactID(token))
            return url
        } catch {
            contactInvitationMessage = "Could not save this invitation. Try again."
            return nil
        }
    }

    func acceptContactInviteURL(_ url: URL) throws {
        guard canEditSavedGroups else { throw ContactInvitationError.unavailable }
        let token = try GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true)
        let id = try contactID(token)
        let signer = try internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID)
        let acceptance = try token.accept(
            signer: signer, displayName: localMemberIdentity.displayName, trust: internetSettingsStore.identityTrust(),
            now: callAccessNow().timeIntervalSince1970, contactBootstrap: true)
        do { try groupRepository.acceptContactInvitation(token, accepted: acceptance,
                localDisplayName: localMemberIdentity.displayName, now: callAccessNow().timeIntervalSince1970)
        } catch { reportGroupStorageError(error); throw error }
        adoptStoredContactRegistration(with: acceptance.inviter.memberID, invitationID: id)
        refreshGroupStorageStatus()
        _ = resumeContactInvitation(id, continuingInBackground: true)
    }

    @discardableResult
    func resumeContactInvitation(_ id: UUID, continuingInBackground: Bool = false) -> Bool {
        let routes = contactInvitationRoutes
        guard canEditSavedGroups,
              let record = groupRepository.contactInvitations.first(where: { $0.id == id }),
              record.canResume else { return false }
        guard !record.hasExpired(at: callAccessNow().timeIntervalSince1970) else {
            if contactInvitationID == id { stopContactInvitationSession() }
            contactInvitationMessage = "This invitation can no longer be used."
            refreshGroupStorageStatus()
            return false
        }
        if canTryContactInternetReply(record) {
            requestInvitationInternetReply(restart: continuingInBackground)
        }
        guard !routes.isEmpty else { return activeInternetContactReplyIDs.contains(id) }
        if contactInvitationID == id, let session = contactInvitationSession, !session.isStopped {
            if continuingInBackground { requestContactInvitationBackgroundTime(for: session) }
            guard !session.isStopped else { return false }
            session.retry()
            return true
        }
        do {
            return try restoreContactInvitation(record, routes: routes, continuingInBackground: continuingInBackground)
        } catch {
            stopContactInvitationSession()
            contactInvitationMessage = "This invitation could not be resumed. Try again."
            return false
        }
    }

    private func restoreContactInvitation(
        _ record: ContactInvitationRecord, routes: Set<RTC.RouteKind>, continuingInBackground: Bool
    ) throws -> Bool {
        let id = record.id
        let payload = try groupRepository.contactInvitationPayload(id)
        let expectedKey = record.direction == .outgoing
            ? payload.token.identityProof?.publicKey
            : payload.receipt?.inviteeDeviceKey
        let signer = try internetSettingsStore.invitationSigner(
            memberID: localMemberIdentity.memberID, expectedPublicKey: expectedKey)
        let trust = try internetSettingsStore.identityTrust()
        stopContactInvitationSession()
        let transport = contactSessionFactory?()
        let configuration = try contactInvitationInternetConfiguration(transport: transport, routes: routes)
        let access = accountAccessID
        let session = ContactInvitationSession(
            transport: transport, authority: invitationAuthority, signer: signer,
            displayName: localMemberIdentity.displayName, trust: trust, routes: routes,
            internetConfiguration: configuration,
            now: { [weak self] in self?.callAccessNow().timeIntervalSince1970 ?? .infinity },
            confirmReceipt: { [weak self] verified in
                guard let self else { throw ContactInvitationError.unavailable }
                try self.confirmContactInvitationReceipt(verified, id: id, access: access)
            }, acknowledged: { [weak self] invitee in
                guard let self else { throw ContactInvitationError.unavailable }
                try self.acknowledgeContactInvitationReceipt(id, invitee: invitee, access: access)
            }, confirm: { _, _ in
                // Explicit acceptance is committed atomically before restore.
                throw ContactInvitationError.unavailable
            })
        observeContactInvitationPermissions(session, id: id, access: access)
        contactPermissionExchange = (false, false)
        contactInvitationID = id
        contactInvitationSession = session
        if continuingInBackground { requestContactInvitationBackgroundTime(for: session) }
        guard !session.isStopped else { return false }
        try session.restore(payload)
        // Each explicit retry has a finite radio lifetime. The durable
        // invitation keeps its independent seven-day validity after pausing.
        let remaining = Duration.seconds(max(0, record.expiresAt - callAccessNow().timeIntervalSince1970))
        let attempt = min(.seconds(60), max(.zero, contactNotificationAttemptDuration))
        closeContactInvitation(id, after: min(remaining, attempt))
        return true
    }

    private func contactInvitationInternetConfiguration(
        transport: CallSession?, routes: Set<RTC.RouteKind>
    ) throws -> RTC.CloudflareRealtimeConfiguration? {
        guard transport == nil, routes.contains(.webRTC) else { return nil }
        do {
            return try internetSettingsStore.load()
        } catch {
            guard routes.contains(.multipeer) else { throw error }
            return nil
        }
    }

    private func confirmContactInvitationReceipt(_ verified: VerifiedDirectInvitation, id: UUID, access: UUID) throws {
        guard canEditSavedGroups, accountAccessID == access, contactInvitationID == id,
              verified.receipt.invitation?.id == id else { throw ContactInvitationError.unavailable }
        try groupRepository.confirmContactInvitation(
            verified, localDisplayName: localMemberIdentity.displayName, now: callAccessNow().timeIntervalSince1970)
        adoptStoredContactRegistration(with: verified.identity.memberID, invitationID: id)
        contactInvitationMessage = nil
        refreshGroupStorageStatus()
    }

    private func acknowledgeContactInvitationReceipt(_ id: UUID, invitee: VerifiedDeviceProof, access: UUID) throws {
        guard canEditSavedGroups, accountAccessID == access, contactInvitationID == id
        else { throw ContactInvitationError.unavailable }
        let signer = try? internetSettingsStore.invitationSigner(
            memberID: localMemberIdentity.memberID, expectedPublicKey: invitee.publicKey)
        try saveContactAcknowledgement(id, invitee: invitee, signer: signer)
        contactInvitationMessage = nil
        refreshGroupStorageStatus()
        // Registration is complete. The exchange stays only as long as the two notification
        // permissions need, and not at all when this device cannot take part.
        if notifications.canUseNotifications {
            closeContactInvitation(id, after: contactPermissionExchangeDuration)
        } else {
            stopContactInvitationSession()
        }
    }

    private func observeContactInvitationPermissions(_ session: ContactInvitationSession, id: UUID, access: UUID) {
        session.onRegisteredPeerAlone = { [weak self, weak session] peerID in
            guard let self, let session else { return }
            self.shareNotificationPermission(with: peerID, over: session, invitationID: id, access: access)
        }
        session.onNotificationPermission = { [weak self, weak session] peerID, message in
            guard let self, let session, self.accountAccessID == access, self.contactInvitationID == id,
                  let value = message.decodedPayload(CallNotificationPermissionMessage.self, from: peerID)
            else { return }
            // An unverifiable permission authorizes nothing; the first one-to-one connection shares it again.
            guard (try? self.notifications.receivePermission(value, peerID: peerID)) != nil else { return }
            self.requestGroupDeliverySync(
                message.namespace == CallNotificationPermissionMessage.groupNamespace ? .localChange : .refresh)
            self.contactPermissionExchange.received = true
            self.finishContactPermissionExchange(id, session: session)
        }
    }

    /// A registration can finish its existing reply attempt after the user leaves the app.
    private func requestContactInvitationBackgroundTime(for session: ContactInvitationSession) {
        guard endContactInvitationBackgroundTime == nil else { return }
        let end = beginContactInvitationBackgroundTime { [weak self, weak session] in
            guard let self, let session, self.contactInvitationSession === session else { return }
            self.pauseContactInvitationSession()
        }
        guard contactInvitationSession === session else {
            end?()
            return
        }
        endContactInvitationBackgroundTime = end
    }

    private func closeContactInvitation(_ id: UUID, after delay: Duration) {
        contactInvitationExpiryTask?.cancel()
        contactInvitationExpiryTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.contactInvitationID == id else { return }
            self.stopContactInvitationSession()
            do {
                try self.groupRepository.removeExpiredContactInvitations(
                    now: self.callAccessNow().timeIntervalSince1970)
                self.refreshGroupStorageStatus()
            } catch { self.contactInvitationMessage = "Could not update this invitation. Try again." }
        }
    }

    /// The two people have just saved each other and are alone in the exchange: share the permission to
    /// notify now, so the first call can already reach them (otherwise it is shared at the first
    /// one-to-one connection). The grant is issued here when it does not exist yet.
    private func shareNotificationPermission(with peerID: String, over session: ContactInvitationSession,
                                             invitationID id: UUID, access: UUID) {
        Task { [weak self, weak session] in
            await self?.notifications.allowEveryContact()
            guard let self, let session, !session.isStopped,
                  self.accountAccessID == access, self.contactInvitationID == id,
                  let signer = try? self.internetSettingsStore.invitationSigner(
                    memberID: self.localMemberIdentity.memberID),
                  let value = try? self.notifications.permissionMessage(for: peerID, signer: signer),
                  let payload = try? JSONEncoder().encode(value) else { return }
            // Send the new channel first; the complete legacy message remains unchanged for older peers.
            if let groupValue = try? self.notifications.groupPermissionMessage(for: peerID, signer: signer),
               let groupPayload = try? JSONEncoder().encode(groupValue) {
                _ = session.sendNotificationPermission(
                    groupPayload, namespace: CallNotificationPermissionMessage.groupNamespace)
            }
            guard session.sendNotificationPermission(payload) else { return }
            self.contactPermissionExchange.sent = true
            self.finishContactPermissionExchange(id, session: session)
        }
    }

    /// The person who accepted has nothing left to do once both permissions have crossed. The inviter
    /// keeps listening for the rest of the attempt, as before.
    private func finishContactPermissionExchange(_ id: UUID, session: ContactInvitationSession) {
        guard contactInvitationID == id, session.isAcknowledged,
              contactPermissionExchange.sent, contactPermissionExchange.received else { return }
        stopContactInvitationSession()
    }

    /// Saves the name the inviter gives the person before sending. Blank clears it.
    @discardableResult
    /// `refresh: false` saves without republishing state, for saves made while a share sheet opens.
    func setContactInvitationNickname(_ id: UUID, _ name: String, refresh: Bool = true) -> Bool {
        guard canEditSavedGroups else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || IntercomGroup.isValidName(trimmed) else { return false }
        do {
            try groupRepository.setContactInvitationNickname(id, nickname: trimmed.isEmpty ? nil : trimmed)
            if refresh { refreshGroupStorageStatus() }
            return true
        } catch {
            return false
        }
    }

    func cancelContactInvitation(_ id: UUID) throws {
        guard canEditSavedGroups else { throw ContactInvitationError.unavailable }
        // Commit the cancellation before stopping; a failed save remains retryable.
        try groupRepository.cancelContactInvitation(id)
        refreshContactInvitationGroup(id)
        if contactInvitationID == id { stopContactInvitationSession() }
        refreshGroupStorageStatus()
    }

    func stopContactInvitationSession() {
        let end = endContactInvitationBackgroundTime
        endContactInvitationBackgroundTime = nil
        suspendedContactInvitation = nil
        contactInvitationExpiryTask?.cancel()
        contactInvitationExpiryTask = nil
        contactInvitationSession?.stop()
        contactInvitationSession = nil
        contactInvitationID = nil
        end?()
        reconcileAutomaticInternetEnrollment()
    }

    private func contactID(_ token: GroupInviteToken) throws -> UUID {
        guard let context = token.directInvitation?.context, context.contactBootstrap == true
        else { throw GroupInviteTokenError.invalidTokenEncoding }
        return context.id
    }
}

enum ContactInvitationError: Error {
    case unavailable
}

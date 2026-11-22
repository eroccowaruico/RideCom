import Foundation

extension CloudKitCallRelationshipBackupSession {
    func respondToGroupRestore(_ request: CallRelationshipRestoreRequest) async throws
        -> CallRelationshipRestoreResponse? {
        guard let model, current != nil, let signer = try model.callRelationshipBackupSigner(),
              let trust = try model.internetSettingsStore.identityTrust() else { throw Failure.accountUnavailable }
        guard let groupID = try request.verifiedGroupCallID(addressedTo: signer, trust: trust, now: Date()),
              model.groupRepository.storedGroup(groupID)?.kind == .group else { return nil }
        let checked = try await readCurrentBackup(for: model, as: signer)
        guard let backup = checked.backup else { return nil }
        return try model.groupRepository.sealGroupRestore(
            request, as: checked.signer, matching: backup, verifying: (checked.trust, Date()))
    }

    func retryDirectRestoreRelayWork() {
        retrySelectedDirectRestore()
        retryDirectRestoreInbox()
    }

    private func retryDirectRestoreInbox() {
        guard let client = directRestoreClient, let checkpoints = restoreSelectionCheckpoints else { return }
        guard restoreInboxRun == nil else {
            restoreInboxNeedsRetry = true
            return
        }
        let run = UUID()
        restoreInboxRun = run
        directRestoreInboxTask = Task { [weak self] in
            guard let self else { return 0 }
            defer { finishDirectRestoreInbox(run) }
            return try await respondToRelayedDirectRestores(using: client, checkpoints: checkpoints, limit: .max)
        }
    }

    private func finishDirectRestoreInbox(_ run: UUID) {
        guard restoreInboxRun == run else { return }
        restoreInboxRun = nil
        if restoreInboxNeedsRetry {
            restoreInboxNeedsRetry = false
            retryDirectRestoreInbox()
        }
    }

    func respondToNextRelayedDirectRestore(using client: InternetAccountClient) async throws -> Bool {
        try await respondToRelayedDirectRestores(using: client, checkpoints: restoreSelectionCheckpoints, limit: 1) > 0
    }

    private func respondToRelayedDirectRestores(
        using client: InternetAccountClient, checkpoints: CallRelationshipBackupCheckpointStore?, limit: Int
    ) async throws -> Int {
        let account = try relayAccount()
        guard respondingToRelay != account.generation else { return 0 }
        respondingToRelay = account.generation
        defer { if respondingToRelay == account.generation { respondingToRelay = nil } }
        let inbox = try await client.directRestoreInbox(access: account.access)
        try requireRelayAccount(account)
        try checkpoints?.pruneRestoreReplies(keeping: Set(inbox.map(\.id)), as: account.signer)

        var answered = 0
        for packet in inbox {
            guard try await sendRestoreReply(to: packet, account: account, checkpoints: checkpoints,
                                             using: client) else { continue }
            try requireRelayAccount(account)
            try await client.retireDirectRestorePacket(packet.id, access: account.access)
            try requireRelayAccount(account)
            try checkpoints?.saveRestoreReply(nil, for: packet.id, as: account.signer)
            answered += 1
            if answered >= limit { break }
        }
        return answered
    }

    private func sendRestoreReply(
        to packet: DirectCallRestoreRelayPacket.Delivery, account: RelayAccount,
        checkpoints: CallRelationshipBackupCheckpointStore?, using client: InternetAccountClient
    ) async throws -> Bool {
        try requireRelayAccount(account)
        guard let opened = try? packet.openRequest(as: account.signer, trust: account.trust, now: Date()),
              let checked = try await directRestoreResponderBackup(for: opened.request),
              let model, let backup = checked.backup, let binding = checked.signer.identity?.sessionBinding
        else { return false }
        try requireRelayAccount(account)
        let saved = try checkpoints?.loadRestoreReply(for: packet.id, as: account.signer)
        let fingerprint = DirectRestoreResponseDraft.fingerprint(of: packet)
        let now = Date()
        guard Double(packet.expiresAt) > now.timeIntervalSince1970 * 1_000, opened.request.expiresAt > now
        else { return false }
        let draft = try model.groupRepository.withAuthorizedDirectRestoreResponse(
            opened.request, as: checked.signer, matching: backup, verifying: (checked.trust, now)
        ) { reference, makeResponse -> DirectRestoreResponseDraft? in
            if let saved {
                guard saved.matches(fingerprint: fingerprint, reference: reference, responder: binding,
                                    recipient: opened.replyTo),
                      Double(saved.payload.expiresAt) > now.timeIntervalSince1970 * 1_000 else { return nil }
                return saved
            }
            let submission = try DirectCallRestoreRelayPacket.seal(
                .response(value: makeResponse()), to: opened.replyTo, as: checked.signer, now: now)
            return .init(requestFingerprint: fingerprint, credentialReference: reference,
                         responderBinding: binding, payload: submission.payload)
        }
        guard let draft else { return false }
        if saved == nil { try checkpoints?.saveRestoreReply(draft, for: packet.id, as: account.signer) }
        let sendTime = Date()
        guard opened.request.expiresAt > sendTime,
              Double(min(packet.expiresAt, draft.payload.expiresAt)) > sendTime.timeIntervalSince1970 * 1_000
        else { return false }
        try requireRelayAccount(account)
        let submission = DirectCallRestoreRelaySubmission(sender: account.access.principal, payload: draft.payload)
        try await client.submitDirectRestorePacket(submission, access: account.access)
        return true
    }
}

import CallControl
import Foundation

/// Choosing from a list: `opened` started or reopened that call; `showsLiveCall` kept you where you are,
/// because a connection is one place at a time and leaving it takes ending the call first.
enum DestinationOpening: Equatable { case opened, showsLiveCall }

nonisolated enum CallDestination: Codable, Equatable, Sendable {
    case group(UUID)
    case user(UUID)
}

enum CallStartSource {
    case thisDevice
    case watchRemote
    case watchAudio
}

extension IntercomViewModel {
    var recentCallDestination: CallDestination? {
        guard canStartCalls, groupStorageIssue == nil, let destination = storedRecentCallDestination else { return nil }
        switch destination {
        case .user(let id): return savedRemoteUsers.contains { $0.id == id } ? destination : nil
        case .group(let id): return regularGroups.contains { $0.id == id } ? destination : nil
        }
    }

    var recentCallTitle: String? {
        switch recentCallDestination {
        case .user(let id): savedRemoteUsers.first { $0.id == id }?.resolvedDisplayName
        case .group(let id): regularGroups.first { $0.id == id }?.name
        case nil: nil
        }
    }

    /// Transport connection alone is insufficient: the current participant proof
    /// and the local media pipeline must both be ready.
    func recordEstablishedCall() {
        guard canStartCalls, isAudioReady, !enforceCallAccess || callAccessState.isEstablished,
              authenticatedPeerIDs.contains(where: { currentRepresentativeProfiles[$0]?.verified != nil }),
              let group = groups.first(where: { $0.id == activeGroupID }) else { return }
        guard let destination = callDestination(of: group), destination != storedRecentCallDestination else { return }
        storedRecentCallDestination = destination
        saveAppSettings()
    }

    /// The saved destination a call belongs to: the group itself, or the saved person of an individual
    /// call. An individual call whose person is no longer saved has none.
    func callDestination(of group: IntercomGroup) -> CallDestination? {
        if group.kind == .group { return .group(group.id) }
        if let principal = directCallAccountRecipient(for: group) {
            return savedRemoteUsers.first { $0.principal == principal }.map { .user($0.id) }
        }
        if let memberID = directCallRecipient(for: group) {
            return savedRemoteUsers.first { $0.memberIDs.contains(memberID) }.map { .user($0.id) }
        }
        return nil
    }

    func discardUnavailableRecentCall() {
        // A read failure is not evidence that the destination was removed.
        guard canStartCalls, groupStorageIssue == nil,
              storedRecentCallDestination != nil, recentCallDestination == nil else { return }
        storedRecentCallDestination = nil
        saveAppSettings()
    }

    var currentCallReference: CallReference {
        .init(accountAccessID: accountAccessID, connectionGeneration: connectionGeneration, groupID: activeGroupID)
    }

    /// Resolve a durable destination again when the action runs, not when a screen
    /// or external control originally displayed it.
    @discardableResult
    func startCall(to destination: CallDestination, accountAccessID requestedAccess: UUID,
                   allowSwitchingCall: Bool = true, source: CallStartSource = .thisDevice) -> Bool {
        guard !disconnectIfTimerExpired(now: callAccessNow().timeIntervalSince1970) else { return false }
        guard canStartCalls, requestedAccess == accountAccessID else {
            groupErrorMessage = groupStorageNotice ?? "This sign-in has ended. Open your current account to continue."
            return false
        }
        switch destination {
        case .group(let id):
            guard let group = groups.first(where: { $0.id == id }) else {
                groupErrorMessage = "This saved group is no longer available."
                return false
            }
            // A retained individual call is not a way around removing its contact.
            // Keep its existing ID and key when reconnecting a still-saved contact.
            guard
                group.kind != .direct || directCallAccountRecipient(for: group) != nil
                    || directCallRecipient(for: group) != nil
            else {
                groupErrorMessage = "This saved user is no longer available for an individual call."
                return false
            }
            guard requireCallSwitchAllowed(to: group.id, allowSwitchingCall: allowSwitchingCall) else { return false }
            selectGroup(group, connectIfIdle: false)
        case .user(let id):
            guard selectUser(id, connectIfIdle: false, allowSwitchingCall: allowSwitchingCall) else { return false }
        }
        guard let selectedGroup else { return false }
        if activeGroupID == selectedGroup.id, hasAnyActiveGroupConnection { return true }
        connectSelectedGroup(source: source)
        let started = activeGroupID == selectedGroup.id && hasAnyActiveGroupConnection
        // Every new one-to-one connection notifies the person once, from a list, Widget, Watch or Siri.
        if started, case .user(let id) = destination { noticeNewDirectCall(to: id) }
        return started
    }

    func requireCallSwitchAllowed(to groupID: UUID, allowSwitchingCall: Bool) -> Bool {
        guard allowSwitchingCall || !hasAnyActiveGroupConnection || activeGroupID == groupID else {
            groupErrorMessage = "End the current call before starting a different call."
            return false
        }
        return true
    }

    /// Choosing someone from a list: connect when idle, reopen the current call. While connected (waiting
    /// included) you stay in one place: another choice only shows the live call, never switches or asks.
    @discardableResult
    func openDestination(_ destination: CallDestination) -> DestinationOpening {
        if hasAnyActiveGroupConnection, !isActiveCall(destination) {
            showLiveCall()
            return .showsLiveCall
        }
        connectOrShow(destination)
        return .opened
    }

    /// Shows the call that is live now, without connecting or switching anything.
    func showLiveCall() {
        guard let live = groups.first(where: { $0.id == activeGroupID }) else { return }
        selectGroup(live, connectIfIdle: false)
    }

    /// A start that cannot proceed still shows the destination, where the reason is explained.
    private func connectOrShow(_ destination: CallDestination) {
        guard !startCall(to: destination, accountAccessID: accountAccessID) else { return }
        let message = groupErrorMessage
        switch destination {
        case .group(let id):
            if let group = groups.first(where: { $0.id == id }) { selectGroup(group, connectIfIdle: false) }
        case .user(let id): selectUser(id, connectIfIdle: false)
        }
        if groupErrorMessage == nil { groupErrorMessage = message }
    }

    func isActiveCall(_ destination: CallDestination) -> Bool {
        guard let active = groups.first(where: { $0.id == activeGroupID }) else { return false }
        switch destination {
        case .group(let id): return id == active.id
        case .user(let id):
            guard active.kind == .direct, let user = savedRemoteUsers.first(where: { $0.id == id }) else {
                return false
            }
            if let principal = user.principal, let local = localAccountPrincipal {
                return active.accountPair?.other(than: local) == principal
            }
            return active.members.contains { user.memberIDs.contains($0.id) }
        }
    }

    @discardableResult
    func endCall(_ reference: CallReference) -> Bool {
        guard reference.groupID != nil, matchesCurrentCall(reference) else { return false }
        disconnect()
        return true
    }

    @discardableResult
    func setCallMuted(_ muted: Bool, for reference: CallReference) -> Bool {
        guard !disconnectIfTimerExpired(now: callAccessNow().timeIntervalSince1970) else { return false }
        guard canStartCalls, canControlMicrophone, matchesCurrentCall(reference) else { return false }
        applyLocalMute(muted)
        return true
    }

    private func matchesCurrentCall(_ reference: CallReference) -> Bool {
        hasCurrentAccountAccess && currentCallReference == reference
    }
}

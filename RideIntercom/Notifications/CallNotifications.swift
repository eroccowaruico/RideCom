import Foundation
import Observation

/// Account-scoped notification consent and pending requests; never starts audio.
@MainActor @Observable
final class CallNotifications {
    var receivesNotifications = false
    var authorizationDenied = false
    var isBusy = false
    var message: String?
    private var permissions: [CallNotificationPermission] = []
    @ObservationIgnored let store: InternetConnectionSettingsStore
    @ObservationIgnored let memberID: String
    @ObservationIgnored let client: InternetAccountClient
    @ObservationIgnored let isCurrentUser: @MainActor () -> Bool
    @ObservationIgnored let permitsDeviceRegistration: @MainActor () -> Bool
    @ObservationIgnored let contacts: @MainActor () -> [SavedUser]
    @ObservationIgnored private let requestAuthorization: @MainActor () async throws -> Bool
    @ObservationIgnored let authorizationGranted: @MainActor () async -> Bool
    @ObservationIgnored let register: @MainActor () -> Void
    @ObservationIgnored let unregister: @MainActor () -> Void
    @ObservationIgnored let now: @MainActor () -> Date
    @ObservationIgnored var generation = 0
    @ObservationIgnored var deviceDisableGeneration = 0
    @ObservationIgnored var tapLookupGeneration = 0
    @ObservationIgnored var tapLookups: [UUID: Task<CallNotificationReply, Error>] = [:]
    @ObservationIgnored var tokenGeneration = 0
    @ObservationIgnored var deviceOperations: [(id: UUID, task: Task<Void, Never>)] = []
    @ObservationIgnored private var storageAvailable = true

    init(
        store: InternetConnectionSettingsStore, memberID: String, client: InternetAccountClient = .init(),
        isCurrentUser: @escaping @MainActor () -> Bool, contacts: @escaping @MainActor () -> [SavedUser],
        permitsDeviceRegistration: @escaping @MainActor () -> Bool = { true },
        requestAuthorization: @escaping @MainActor () async throws -> Bool = NotificationSystem.requestAuthorization,
        authorizationGranted: @escaping @MainActor () async -> Bool = NotificationSystem.authorizationGranted,
        register: @escaping @MainActor () -> Void = NotificationSystem.register,
        unregister: @escaping @MainActor () -> Void = NotificationSystem.unregister,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.store = store; self.memberID = memberID; self.client = client; self.isCurrentUser = isCurrentUser
        self.contacts = contacts; self.permitsDeviceRegistration = permitsDeviceRegistration
        self.requestAuthorization = requestAuthorization; self.authorizationGranted = authorizationGranted
        self.register = register; self.unregister = unregister; self.now = now
        do { permissions = try store.notificationPermissions() } catch {
            storageAvailable = false
            message = "Notification permissions could not be read. Your saved data has been preserved."
        }
    }
    var canRegisterNotifications: Bool { serviceAccess() != nil }
    var hasPermissionsToShare: Bool {
        guard !permissions.isEmpty, let context = access() else { return false }
        return permissions.contains { record in
            record.owner == context.principal && record.revision > 0
                && contacts().contains { $0.principal == record.peer }
        }
    }
    var isEnabled: Bool { store.notificationRegistrationEnabled }
    /// Turning notifications off in the OS left a server removal that has not finished yet.
    var removalPending: Bool { store.notificationRemovalPending }
    func serviceAccess() -> CallNotificationServiceAccess? {
        guard isCurrentUser() else { return nil }
        return try? store.notificationAccess(memberID: memberID)
    }
    func access() -> CallNotificationServiceAccess? { storageAvailable ? serviceAccess() : nil }
    func current(_ context: CallNotificationServiceAccess, generation expected: Int) -> Bool {
        generation == expected && !Task.isCancelled && serviceAccess() == context
    }
    func contact(_ id: UUID, context: CallNotificationServiceAccess) -> SavedUser? {
        contacts().first {
            $0.id == id && $0.principal?.isValid == true && $0.principal?.issuer == context.principal.issuer
                && $0.principal != context.principal && $0.deviceKeys?.isEmpty == false
        }
    }
    func permission(_ id: UUID, context: CallNotificationServiceAccess) -> CallNotificationPermission? {
        guard let user = contact(id, context: context) else { return nil }
        return permissions.first { $0.owner == context.principal && $0.peer == user.principal }
    }
    func update(
        _ id: UUID, context: CallNotificationServiceAccess, _ change: (inout CallNotificationPermission) -> Void
    ) throws {
        guard let user = contact(id, context: context), let peer = user.principal else {
            throw DeviceIdentityProof.Failure.invalid
        }
        var next = permissions
        if let index = next.firstIndex(where: { $0.owner == context.principal && $0.peer == peer }) {
            next[index].contactID = id
            change(&next[index])
        } else {
            var record = CallNotificationPermission(contactID: id, owner: context.principal, peer: peer)
            change(&record); next.append(record)
        }
        try savePermissions(next)
    }
    private func savePermissions(_ next: [CallNotificationPermission]) throws {
        try store.saveNotificationPermissions(next)
        permissions = next
    }
    func enable() async {
        guard !isBusy, let context = serviceAccess() else { return }
        let expected = generation; isBusy = true
        defer { if generation == expected { isBusy = false } }
        do {
            let granted = try await requestAuthorization()
            guard current(context, generation: expected) else { return }
            authorizationDenied = !granted
            guard granted else {
                receivesNotifications = false
                if isEnabled { await disable() }
                reportAuthorizationDenied(context, generation: expected)
                return
            }
            store.notificationRegistrationEnabled = true
            registerIfAllowed()
        } catch {
            guard current(context, generation: expected) else { return }
            message = "Notification permission could not be checked. Please try again."
        }
    }
    /// Notifications follow the OS alone: there is no switch in the app. Once the OS allows them, this device
    /// registers by itself after sign-in, and everyone you registered may notify you (the grant is shared at the
    /// next one-to-one connection). When the OS turns them off, `refresh` removes the registration.
    func start() async {
        guard serviceAccess() != nil else { await refresh(); return }
        let granted = await authorizationGranted()
        if granted && !isEnabled && !isBusy { await enable() } else { await refresh() }
        if granted { await allowEveryContact() } else { await allowGroupInvitations() }
    }
    /// Inbox delivery is independent of OS alert permission. Directly registered people may invite you.
    func allowGroupInvitations() async {
        guard let context = access() else { return }
        let expected = generation
        for user in contacts()
        where contact(user.id, context: context) != nil
            && permission(user.id, context: context)?.groupReceiving == nil {
            guard let peer = user.principal else { continue }
            var issued: CallNotificationGrant?
            do {
                let grant = try await client.issueGroupInvitationGrant(
                    origin: context.origin, token: context.accessToken, senderUserID: peer.userID)
                issued = grant
                guard grant.isAddressed(to: context.principal, from: peer, audience: "rideintercom-group-invitation"),
                    current(context, generation: expected), contact(user.id, context: context) != nil
                else { throw DeviceIdentityProof.Failure.invalid }
                let revision = try store.nextNotificationRevision(
                    after: permission(user.id, context: context)?.revision ?? 0)
                try update(user.id, context: context) {
                    $0.groupReceiving = grant; $0.allowsGroupInvitations = true; $0.revision = revision
                }
            } catch {
                if let issued { try? await revoke(issued, context: context) }
                return
            }
        }
    }
    func refresh() async {
        guard isCurrentUser() else { return }
        // Device removal must still work with unreadable contact permissions.
        if !storageAvailable, let loaded = try? store.notificationPermissions() {
            permissions = loaded
            storageAvailable = true
            message = nil
        }
        guard let context = serviceAccess() else { return }
        let expected = generation
        if authorizationDenied && !isEnabled {
            let granted = await authorizationGranted()
            guard current(context, generation: expected) else { return }
            if granted { authorizationDenied = false }
        }
        if isEnabled {
            let granted = await authorizationGranted()
            guard current(context, generation: expected) else { return }
            authorizationDenied = !granted
            if granted { registerIfAllowed() } else {
                await disable()
                reportAuthorizationDenied(context, generation: expected)
            }
        } else if store.notificationRemovalPending {
            await removePendingDevice(context, generation: expected)
        }
        await retryRevocations()
    }
    func reportAuthorizationDenied(_ context: CallNotificationServiceAccess, generation expected: Int) {
        if current(context, generation: expected), !store.notificationRemovalPending {
            message = "Notifications are off in system settings."
        }
    }
}

// Receiving grants stay with the account's permission state and persistence.
extension CallNotifications {
    @discardableResult
    func setIncomingAllowed(_ allowed: Bool, contactID: UUID) async -> Bool {
        guard !isBusy, let context = access(), contact(contactID, context: context) != nil else { return false }
        let expected = generation; isBusy = true
        defer { if generation == expected { isBusy = false } }
        do {
            if !allowed {
                let revision = try store.nextNotificationRevision(
                    after: permission(contactID, context: context)?.revision ?? 0)
                try update(contactID, context: context) { $0.allowsIncoming = false; $0.revision = revision }
                await retryRevocations()
                return current(context, generation: expected)
            }
            if let existing = permission(contactID, context: context), !existing.allowsIncoming,
                let grant = existing.receiving {
                try await revoke(grant, context: context)
                guard current(context, generation: expected), contact(contactID, context: context) != nil else {
                    return false
                }
                try update(contactID, context: context) { if $0.receiving == grant { $0.receiving = nil } }
            }
            guard try await ensureReceivingGrant(contactID, context: context, generation: expected) else {
                return false
            }
            message = "Call notification permission saved. It is shared when you connect one to one with this person."
            return true
        } catch {
            guard current(context, generation: expected) else { return false }
            message = "Notification permission could not be updated. Please try again when online."
            return false
        }
    }
    private func ensureReceivingGrant(
        _ contactID: UUID, context: CallNotificationServiceAccess, generation expected: Int
    ) async throws -> Bool {
        guard permission(contactID, context: context)?.receiving == nil else { return true }
        guard let peer = contact(contactID, context: context)?.principal else { return false }
        let grant = try await client.issueNotificationGrant(
            origin: context.origin, token: context.accessToken, senderUserID: peer.userID)
        guard current(context, generation: expected), contact(contactID, context: context) != nil else {
            try? await revoke(grant, context: context)
            return false
        }
        do {
            let revision = try store.nextNotificationRevision(
                after: permission(contactID, context: context)?.revision ?? 0)
            try update(contactID, context: context) {
                $0.receiving = grant; $0.allowsIncoming = true; $0.revision = revision
            }
        } catch {
            // Never knowingly lose a newly issued, unpersisted grant.
            try? await revoke(grant, context: context)
            throw error
        }
        return true
    }
    func suppressContact(_ id: UUID) throws {
        guard let context = access(), permission(id, context: context) != nil else { return }
        let revision = try store.nextNotificationRevision(after: permission(id, context: context)?.revision ?? 0)
        try update(id, context: context) {
            $0.allowsIncoming = false; $0.allowsGroupInvitations = false; $0.sending = nil; $0.groupSending = nil
            $0.revision = revision
        }
    }
    func retryRevocations() async {
        guard let context = access() else { return }
        let expected = generation
        guard await revokePendingGrants(\.receiving, context: context, generation: expected, where: {
            !$0.allowsIncoming
        }), current(context, generation: expected) else { return }
        guard await revokePendingGrants(\.groupReceiving, context: context, generation: expected, where: {
            $0.allowsGroupInvitations == false
        }), current(context, generation: expected) else { return }
        let next = permissions.filter { record in
            !(record.owner == context.principal && record.receiving == nil && record.groupReceiving == nil
                && !record.allowsIncoming
              && !contacts().contains(where: { $0.principal == record.peer }))
        }
        guard next.count != permissions.count else { return }
        do {
            // Keep issued revisions monotonic even after the last contact row is removed.
            try store.retainNotificationRevision(atLeast: permissions.map(\.revision).max() ?? 0)
            try savePermissions(next)
        } catch {
            // A failed write must leave the persisted records and in-memory retry state intact.
        }
    }
    private func revokePendingGrants(
        _ receiving: WritableKeyPath<CallNotificationPermission, CallNotificationGrant?>,
        context: CallNotificationServiceAccess, generation expected: Int,
        where isSuppressed: (CallNotificationPermission) -> Bool
    ) async -> Bool {
        for record in permissions where record.owner == context.principal && isSuppressed(record) {
            guard let grant = record[keyPath: receiving] else { continue }
            do {
                try await revoke(grant, context: context)
                guard current(context, generation: expected) else { return false }
                var next = permissions
                if let index = next.firstIndex(where: {
                    $0.contactID == record.contactID && isSuppressed($0) && $0[keyPath: receiving] == grant
                }) {
                    next[index][keyPath: receiving] = nil
                    try savePermissions(next)
                }
            } catch { break } // Keep this grant and still reclaim already cancelled rows.
        }
        return true
    }
    private func revoke(_ grant: CallNotificationGrant, context: CallNotificationServiceAccess) async throws {
        try await client.revokeNotificationGrant(
            origin: context.origin, token: context.accessToken, grantID: grant.grantID)
    }
}

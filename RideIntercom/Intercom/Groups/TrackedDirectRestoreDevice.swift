import Foundation

/// Routing data for a certificate that may have reached the Worker.
struct TrackedDirectRestoreDevice: Codable, Equatable {
    let contactID: UUID
    let publisher: AccountPrincipal
    let deviceID: String
    let reader: String
    let slot: String
    let registration: UUID
    var expiresAt: Int64
    var withdrawalPending: Bool

    var withdrawal: DirectRestoreDeviceWithdrawal { .init(publisher: publisher, slot: slot, reader: reader) }

    var isValid: Bool {
        publisher.isValid && publisher.userID != reader
            && InternetAccountClient.notificationUserID(reader) && InternetAccountClient.notificationUserID(slot)
            && UUID(uuidString: deviceID)?.uuidString.lowercased() == deviceID
            && (1...9_007_199_254_740_991).contains(expiresAt)
    }
}

extension GroupSnapshot {
    mutating func reconcileDirectRestoreDevices(localMemberID: String?) {
        for index in directRestoreDevices.indices
            where !containsDirectRestoreRegistration(directRestoreDevices[index], localMemberID: localMemberID) {
            directRestoreDevices[index].withdrawalPending = true
        }
    }

    func containsDirectRestoreRegistration(_ device: TrackedDirectRestoreDevice, localMemberID: String?) -> Bool {
        let principal = AccountPrincipal(issuer: device.publisher.issuer, userID: device.reader)
        guard let localMemberID, let user = users.first(where: {
            $0.id == device.contactID && $0.isRegistered && $0.principal == principal
        }), user.memberIDs.count == 1, let peer = user.memberIDs.first else { return false }
        return confirmedContactRegistration(localMemberID: localMemberID, peerMemberID: peer) == device.registration
    }
}

extension GroupRepository {
    func trackDirectRestoreDevice(
        _ publication: DirectRestoreDevicePublication, for contactID: UUID,
        as identity: VerifiedDeviceIdentity, now: Date
    ) throws {
        guard let snapshot = writableSnapshot else { throw IntercomGroupError.storageUnavailable }
        guard identity.memberID == localMemberID, identity.issuer == publication.publisher.issuer,
              identity.userID == publication.publisher.userID,
              Double(publication.expiresAt) > now.timeIntervalSince1970 * 1_000
        else { throw GroupStorageError.identityConflict }
        let tracked = TrackedDirectRestoreDevice(contactID: contactID, publisher: publication.publisher,
            deviceID: identity.deviceID, reader: publication.reader, slot: publication.slot,
            registration: publication.registration, expiresAt: publication.expiresAt, withdrawalPending: false)
        guard snapshot.containsDirectRestoreRegistration(tracked, localMemberID: localMemberID)
        else { throw GroupStorageError.invalidUpdate }
        try amend(snapshot, now: now.timeIntervalSince1970) { next in
            if let index = next.directRestoreDevices.firstIndex(where: { $0.slot == publication.slot }) {
                let previous = next.directRestoreDevices[index]
                guard previous.publisher == tracked.publisher, previous.reader == tracked.reader,
                      previous.deviceID == tracked.deviceID, previous.contactID == tracked.contactID,
                      previous.registration == tracked.registration,
                      !previous.withdrawalPending else { throw GroupStorageError.invalidUpdate }
                next.directRestoreDevices[index].expiresAt = max(previous.expiresAt, tracked.expiresAt)
            } else {
                next.directRestoreDevices.append(tracked)
            }
        }
    }

    func finishDirectRestoreWithdrawal(_ completed: TrackedDirectRestoreDevice, now: Date) throws {
        guard let snapshot = writableSnapshot else { throw IntercomGroupError.storageUnavailable }
        guard completed.withdrawalPending, snapshot.directRestoreDevices.contains(completed) else { return }
        try amend(snapshot, now: now.timeIntervalSince1970) { next in
            next.directRestoreDevices.removeAll { $0 == completed }
        }
    }
}

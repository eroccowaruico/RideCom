import CloudKit
import CryptoKit
import Foundation

/// Stores restore candidates in the app container's private database.
struct CloudKitCallRelationshipBackupStore {
    struct Saved {
        let backup: CallRelationshipBackup
        fileprivate let record: CKRecord
    }

    enum Failure: Error, Equatable {
        case invalidRecord
        case nothingToSave
        case missingSaveResult
    }

    private static let recordType = "CallRelationshipBackup"
    private static let payloadField = "payload"
    private let fetch: (CKRecord.ID) async throws -> CKRecord
    private let write: (CKRecord, CKModifyRecordsOperation.RecordSavePolicy) async throws -> CKRecord

    init(container: CKContainer) {
        let database = container.privateCloudDatabase
        self.init(fetch: { try await database.record(for: $0) }, write: { record, policy in
            let results = try await database.modifyRecords(
                saving: [record], deleting: [], savePolicy: policy, atomically: false)
            guard let result = results.saveResults[record.recordID] else { throw Failure.missingSaveResult }
            return try result.get()
        })
    }

    init(
        fetch: @escaping (CKRecord.ID) async throws -> CKRecord,
        write: @escaping (CKRecord, CKModifyRecordsOperation.RecordSavePolicy) async throws -> CKRecord
    ) {
        self.fetch = fetch
        self.write = write
    }

    func checkingAccess(_ check: @escaping () async throws -> Void) -> Self {
        .init(fetch: { id in
            try await check()
            return try await fetch(id)
        }, write: { record, policy in
            try await check()
            return try await write(record, policy)
        })
    }

    func load(as signer: DeviceIdentitySigner, now: TimeInterval) async throws -> Saved? {
        let owner = try CallRelationshipBackup.verifiedOwner(of: signer, now: now)
        let id = Self.recordID(for: owner)
        let record: CKRecord
        do {
            record = try await fetch(id)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
        return try decoded(record, id: id, as: signer, now: now)
    }

    func save(
        _ backup: CallRelationshipBackup, replacing previous: Saved?, as signer: DeviceIdentitySigner,
        now: TimeInterval, clearing removal: CallRelationshipBackupRemoval? = nil
    ) async throws -> Saved {
        let owner = try CallRelationshipBackup.verifiedOwner(of: signer, now: now)
        _ = try backup.validated(for: owner)
        if backup.isEmpty {
            guard let previous, let removal, try removal.permitsClearing(previous.backup) else {
                throw Failure.nothingToSave
            }
        }
        let id = Self.recordID(for: owner)
        let record: CKRecord
        if let previous {
            guard previous.record.recordID == id, let copy = previous.record.copy() as? CKRecord else {
                throw Failure.invalidRecord
            }
            record = copy
        } else {
            record = CKRecord(recordType: Self.recordType, recordID: id)
        }
        record.encryptedValues[Self.payloadField] = try JSONEncoder().encode(backup) as NSData
        let written = try await write(record, .ifServerRecordUnchanged)
        let saved = try decoded(written, id: id, as: signer, now: now)
        guard saved.backup == backup else { throw Failure.invalidRecord }
        return saved
    }

    private func decoded(
        _ record: CKRecord, id: CKRecord.ID, as signer: DeviceIdentitySigner, now: TimeInterval
    ) throws -> Saved {
        guard record.recordType == Self.recordType, record.recordID == id,
              record.allKeys().allSatisfy({ $0 == Self.payloadField }), record[Self.payloadField] == nil,
              let data = record.encryptedValues[Self.payloadField] as? Data else {
            throw Failure.invalidRecord
        }
        return Saved(backup: try CallRelationshipBackup.read(data, as: signer, now: now), record: record)
    }

    private static func recordID(for owner: AccountPrincipal) -> CKRecord.ID {
        let material = Data("ridecom.call-backup.v1|\(owner.orderingKey)".utf8)
        let digest = SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
        return CKRecord.ID(recordName: "call-backup-\(digest)")
    }
}

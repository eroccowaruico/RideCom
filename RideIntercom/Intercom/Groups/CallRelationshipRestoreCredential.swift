import CryptoKit
import Foundation

/// The same request, confirmation and membership used for candidate checks, key transfer and local storage.
struct CallRelationshipRestoreContext {
    let request: CallRelationshipRestoreRequest
    let confirmation: CallRelationshipRestoreConfirmation
    let record: GroupSnapshot.Record

    fileprivate static func header(
        for request: CallRelationshipRestoreRequest, confirmedBy confirmation: CallRelationshipRestoreConfirmation
    ) throws -> Data {
        let authorization = Authorization(request: request, confirmation: confirmation)
        return try Data(SHA256.hash(data: restoreProofPayload(authorization)))
    }

    fileprivate func membershipFingerprint() throws -> Data {
        try Data(SHA256.hash(data: restoreProofPayload(RestoreMembership(record))))
    }

    private struct Authorization: Encodable {
        let request: CallRelationshipRestoreRequest
        let confirmation: CallRelationshipRestoreConfirmation
    }
}

/// Carries a call key already authorized by the caller for release to the requesting device.
struct CallRelationshipRestoreCredential: Codable {
    private static let domain = "rideintercom.call-restore-credential.ecdh.v3"
    private static let publicKeySize = 65
    private static let overhead = publicKeySize + 28
    private static let maximumSecretSize = 256
    private static let maximumPayloadSize = 8_192
    private let packet: Data
    private let proof: DeviceIdentityProof

    private struct Packet: Encodable {
        let header: Data
        let packet: Data
    }

    fileprivate struct Payload: Codable {
        let fingerprint: Data
        let secret: String
        let directMembership: DirectRestoreMembership?
    }

    init(
        _ credential: GroupAccessCredential, for context: CallRelationshipRestoreContext,
        as signer: DeviceIdentitySigner, trust: DeviceIdentityTrust, now: Date
    ) throws {
        let verified = try context.confirmation.verifiedConfirmation(for: context.request, trust: trust, now: now)
        let owner = try CallRelationshipBackup.verifiedOwner(of: signer, now: now.timeIntervalSince1970)
        let secret = Data(credential.secret.utf8)
        guard signer.memberID == verified.responderMemberID,
              verified.responder == .init(principal: owner, publicKey: signer.publicKey),
              context.record.id == verified.callID,
              credential.groupID == verified.callID, (1...Self.maximumSecretSize).contains(secret.count),
              let target = IdentityEncoding.decode(verified.requester.publicKey)
        else { throw DeviceIdentityProof.Failure.invalid }
        let header = try CallRelationshipRestoreContext.header(for: context.request, confirmedBy: context.confirmation)
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let recipient = try P256.KeyAgreement.PublicKey(x963Representation: target)
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let key = DeviceIdentitySigner.sealedPayloadKey(shared, domain: Self.domain, header: header)
        let payload = try restoreProofPayload(Payload(fingerprint: context.membershipFingerprint(),
            secret: credential.secret, directMembership: DirectRestoreMembership(context.record, verified: verified)))
        guard payload.count <= Self.maximumPayloadSize,
              let sealed = try AES.GCM.seal(payload, using: key, authenticating: header).combined
        else { throw DeviceIdentityProof.Failure.invalid }
        packet = ephemeral.publicKey.x963Representation + sealed
        proof = try signer.sign(restoreProofPayload(Packet(header: header, packet: packet)),
                                purpose: .deliverCallRelationshipRestoreCredential)
    }

    func open(for context: CallRelationshipRestoreContext, as signer: DeviceIdentitySigner,
              trust: DeviceIdentityTrust, now: Date) throws
        -> (confirmation: CallRelationshipRestoreConfirmation.Verified, credential: GroupAccessCredential) {
        let (verified, payload) = try openPayload(for: context.request, confirmedBy: context.confirmation,
                                                   as: signer, trust: trust, now: now)
        guard context.record.id == verified.callID,
              try payload.fingerprint == context.membershipFingerprint()
        else { throw DeviceIdentityProof.Failure.invalid }
        return (verified, .init(groupID: verified.callID, secret: payload.secret))
    }

    fileprivate func openPayload(
        for request: CallRelationshipRestoreRequest, confirmedBy confirmation: CallRelationshipRestoreConfirmation,
        as signer: DeviceIdentitySigner, trust: DeviceIdentityTrust, now: Date
    ) throws -> (CallRelationshipRestoreConfirmation.Verified, Payload) {
        guard (Self.overhead + 1...Self.overhead + Self.maximumPayloadSize).contains(packet.count)
        else { throw DeviceIdentityProof.Failure.invalid }
        let verified = try confirmation.verify(for: request, as: signer, trust: trust, now: now)
        let header = try CallRelationshipRestoreContext.header(for: request, confirmedBy: confirmation)
        let sender = try proof.verify(restoreProofPayload(Packet(header: header, packet: packet)),
            purpose: .deliverCallRelationshipRestoreCredential, memberID: verified.responderMemberID,
            trust: trust, now: now)
        guard sender.principal == verified.responder.principal, sender.publicKey == verified.responder.publicKey
        else { throw DeviceIdentityProof.Failure.invalid }
        let data = try signer.openSealedPayload(packet.dropFirst(Self.publicKeySize),
            ephemeralKey: packet.prefix(Self.publicKeySize), domain: Self.domain, header: header)
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data), payload.fingerprint.count == 32,
              (1...Self.maximumSecretSize).contains(payload.secret.utf8.count)
        else { throw DeviceIdentityProof.Failure.invalid }
        return (verified, payload)
    }
}

private struct DirectRestoreMembership: Codable {
    let devices: [String: AccountDeviceBinding]
    let responderName: String
    let joinedByInvitation: Bool?

    init?(_ record: GroupSnapshot.Record, verified: CallRelationshipRestoreConfirmation.Verified) {
        guard record.kind == .direct, record.accountPair != nil,
              let responder = record.members.first(where: { $0.id == verified.responderMemberID }) else { return nil }
        devices = record.accountDevices
        responderName = responder.displayName
        joinedByInvitation = record.joinedByInvitation
    }

    func rebuild(
        for verified: CallRelationshipRestoreConfirmation.Verified, contact: CallRelationshipBackup.Contact,
        localDisplayName: String
    ) throws -> (GroupSnapshot.Record, SavedUser) {
        guard contact.principal == verified.responder.principal,
              devices[verified.responderMemberID] == verified.responder,
              devices[verified.requesterMemberID] == nil,
              let previous = devices[verified.previousMemberID], previous.principal == verified.requester.principal,
              previous.publicKey != verified.requester.publicKey else { throw DeviceIdentityProof.Failure.invalid }
        let peers = devices.filter { $0.value.principal == contact.principal }
        let user = SavedUser(id: contact.id, displayName: responderName, memberIDs: peers.keys.sorted(),
                             deviceKeys: peers.mapValues(\.publicKey), principal: contact.principal)
        let pair = AccountCallPair(verified.requester.principal, contact.principal)
        guard pair.id == verified.callID else { throw DeviceIdentityProof.Failure.invalid }
        let local = GroupMember(id: verified.previousMemberID, displayName: localDisplayName)
        let members = [local] + user.memberIDs.map { GroupMember(id: $0, displayName: responderName) }
        let group = try IntercomGroup(id: pair.id, name: "Direct Call", members: members, kind: .direct,
                                      accountPair: pair, accountDevices: devices)
        var record = GroupSnapshot.Record(group)
        record.joinedByInvitation = joinedByInvitation
        return (record, user)
    }
}

extension CallRelationshipRestoreResponse {
    init(sealing key: GroupAccessCredential, for context: CallRelationshipRestoreContext,
         as signer: DeviceIdentitySigner, verifying verification: (trust: DeviceIdentityTrust, now: Date)) throws {
        confirmation = context.confirmation
        credential = try CallRelationshipRestoreCredential(
            key, for: context, as: signer, trust: verification.trust, now: verification.now)
    }

    func restoreBatch(
        for request: CallRelationshipRestoreRequest, contact: CallRelationshipBackup.Contact,
        localDisplayName: String, as signer: DeviceIdentitySigner, verifying: (trust: DeviceIdentityTrust, now: Date)
    ) throws -> ConfirmedCallRestore {
        let (verified, payload) = try credential.openPayload(for: request, confirmedBy: confirmation,
            as: signer, trust: verifying.trust, now: verifying.now)
        guard let membership = payload.directMembership else { throw DeviceIdentityProof.Failure.invalid }
        let (record, user) = try membership.rebuild(for: verified, contact: contact, localDisplayName: localDisplayName)
        let context = CallRelationshipRestoreContext(request: request, confirmation: confirmation, record: record)
        guard try payload.fingerprint == context.membershipFingerprint() else {
            throw DeviceIdentityProof.Failure.invalid
        }
        return .init(owner: verified.requester.principal, previousMemberID: verified.previousMemberID,
                     users: [user], calls: [.init(context: context, transferredCredential: credential)])
    }
}

/// The authorization fields that may affect the restored membership and group permissions.
private struct RestoreMembership: Encodable {
    private struct Removal: Encodable {
        let memberIDs: [String]
        let principal: AccountPrincipal?
        let removedAt: TimeInterval
        let priorInvitationIDs: [String]?
        let reinstated: Bool?

        init(_ removal: GroupSnapshot.RemovedMember) {
            memberIDs = removal.memberIDs.sorted()
            principal = removal.principal
            removedAt = removal.removedAt
            priorInvitationIDs = removal.priorInvitationIDs?.map(\.uuidString).sorted()
            reinstated = removal.reinstated
        }
    }

    private let id: UUID
    private let kind: IntercomGroup.Kind?
    private let members: [String]
    private let accountPair: AccountCallPair?
    private let accountDevices: [String: AccountDeviceBinding]
    private let invitationDeviceKeys: [String: String]?
    private let joinedByInvitation: Bool?
    private let removedMembers: [Removal]?

    init(_ record: GroupSnapshot.Record) {
        id = record.id
        kind = record.kind
        members = record.members.map(\.id).sorted()
        accountPair = record.accountPair
        accountDevices = record.accountDevices
        invitationDeviceKeys = record.invitationDeviceKeys
        joinedByInvitation = record.joinedByInvitation
        removedMembers = record.removedMembers?.isEmpty == false ? record.removedMembers?.map(Removal.init) : nil
    }
}

import Foundation

struct GroupRestoreMembership: Codable {
    private struct Member: Codable {
        let id: String
        let displayName: String
    }

    private let members: [Member]
    private let accountDevices: [String: AccountDeviceBinding]
    private let invitationDeviceKeys: [String: String]?
    private let removedMembers: [GroupSnapshot.RemovedMember]?

    init(_ source: GroupSnapshot.Record) {
        members = source.members.filter { !$0.id.hasPrefix(GroupMember.pendingInvitePrefix) }
            .map { Member(id: $0.id, displayName: $0.displayName) }
        let memberIDs = Set(members.map(\.id))
        accountDevices = source.accountDevices.filter { memberIDs.contains($0.key) }
        invitationDeviceKeys = source.invitationDeviceKeys?.filter { memberIDs.contains($0.key) }
        removedMembers = source.removedMembers?.filter(\.isExcluded).map {
            .init(memberIDs: $0.memberIDs, principal: $0.principal, removedAt: $0.removedAt)
        }
    }

    func record(groupID: UUID, name: String) throws -> GroupSnapshot.Record {
        guard members.allSatisfy({ !$0.id.hasPrefix(GroupMember.pendingInvitePrefix) }),
              removedMembers?.allSatisfy({ $0.isValid && $0.isExcluded && $0.priorInvitationIDs == nil }) ?? true
        else { throw DeviceIdentityProof.Failure.invalid }
        let group = try IntercomGroup(id: groupID, name: name,
            members: members.map { .init(id: $0.id, displayName: $0.displayName) }, accountDevices: accountDevices)
        var record = GroupSnapshot.Record(group)
        record.invitationDeviceKeys = invitationDeviceKeys
        record.removedMembers = removedMembers
        return record
    }
}

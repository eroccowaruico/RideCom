import Foundation

/// A local address-book entry, independent of group membership and device IDs.
/// Entries are not evidence of an authenticated account or permission to join.
struct SavedUser: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var displayName: String
    var memberIDs: [String]
    var localName: String?
    var deviceKeys: [String: String]?
    var principal: AccountPrincipal?
    /// True only when the empty input explicitly adopted the generated candidate. Nil is unknown legacy data.
    var usesProvisionalName: Bool?
    var needsNameConfirmation: Bool {
        usesProvisionalName == true && isRegistered && localName != nil && localName != displayName
    }
    /// Regular groups select one deterministic device per verified account.
    /// Device-only contacts retain every saved identity because no common account is known.
    var groupMemberIDs: [String] {
        principal == nil ? memberIDs : Array(memberIDs.sorted().prefix(1))
    }
    var isRegistered: Bool { !memberIDs.isEmpty }
    var resolvedDisplayName: String { localName ?? displayName }
}

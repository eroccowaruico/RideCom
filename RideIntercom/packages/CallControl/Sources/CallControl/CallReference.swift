import Foundation

/// The account and connection an operation belongs to, including idle microphone intent.
public struct CallReference: Equatable, Sendable {
    public let accountAccessID: UUID
    public let connectionGeneration: UUID
    public let groupID: UUID?

    public init(accountAccessID: UUID, connectionGeneration: UUID, groupID: UUID?) {
        self.accountAccessID = accountAccessID
        self.connectionGeneration = connectionGeneration
        self.groupID = groupID
    }

    public var encoded: String {
        "\(accountAccessID.uuidString)|\(connectionGeneration.uuidString)|\(groupID?.uuidString ?? "idle")"
    }

    public var displayedCall: CallSurfaceReference? {
        guard let groupID else { return nil }
        return .init(accountAccessID: accountAccessID, connectionGeneration: connectionGeneration, groupID: groupID)
    }
}

/// A displayed operation is bound to an active group. Idle commands use CallReference.
public struct CallSurfaceReference: Codable, Hashable, Sendable {
    public let accountAccessID: UUID
    public let connectionGeneration: UUID
    public let groupID: UUID

    public init(accountAccessID: UUID, connectionGeneration: UUID, groupID: UUID) {
        self.accountAccessID = accountAccessID
        self.connectionGeneration = connectionGeneration
        self.groupID = groupID
    }

    public var callReference: CallReference {
        .init(accountAccessID: accountAccessID, connectionGeneration: connectionGeneration, groupID: groupID)
    }

    public var encoded: String { callReference.encoded }

    public init?(encoded: String) {
        guard encoded.utf8.count == 110 else { return nil }
        let parts = encoded.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3, let access = UUID(uuidString: String(parts[0])),
              let generation = UUID(uuidString: String(parts[1])), let group = UUID(uuidString: String(parts[2]))
        else { return nil }
        self.init(accountAccessID: access, connectionGeneration: generation, groupID: group)
    }
}

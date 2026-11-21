import Foundation
@testable import RideIntercom

enum IntercomSeedData {
    static let recentGroups: [IntercomGroup] = [
        makeGroup(
            id: "11111111-1111-1111-1111-111111111111",
            name: "Ridge Team",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-108", displayName: "Aki"),
                GroupMember(id: "member-215", displayName: "Mina")
            ],
            accessSecret: "fixture-ridge-team-secret"
        ),
        makeGroup(
            id: "22222222-2222-2222-2222-222222222222",
            name: "Morning Hike",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-400", displayName: "Ken")
            ],
            accessSecret: "fixture-morning-hike-secret"
        )
    ]

    private static func makeGroup(
        id: String,
        name: String,
        members: [GroupMember],
        accessSecret: String
    ) -> IntercomGroup {
        guard let groupID = UUID(uuidString: id) else {
            preconditionFailure("Invalid group ID in the test fixture.")
        }
        do {
            return try IntercomGroup(id: groupID, name: name, members: members, accessSecret: accessSecret)
        } catch {
            preconditionFailure("Invalid group in the test fixture.")
        }
    }
}

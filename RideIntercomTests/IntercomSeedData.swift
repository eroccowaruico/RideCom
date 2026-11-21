import Foundation
@testable import RideIntercom

enum IntercomSeedData {
    static let recentGroups: [IntercomGroup] = [
        makeGroup(
            id: UUID(uuid: (
                0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11,
                0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11
            )),
            name: "Ridge Team",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-108", displayName: "Aki"),
                GroupMember(id: "member-215", displayName: "Mina")
            ],
            accessSecret: "fixture-ridge-team-secret"
        ),
        makeGroup(
            id: UUID(uuid: (
                0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22,
                0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22
            )),
            name: "Morning Hike",
            members: [
                GroupMember(id: "member-001", displayName: "You"),
                GroupMember(id: "member-400", displayName: "Ken")
            ],
            accessSecret: "fixture-morning-hike-secret"
        )
    ]

    private static func makeGroup(
        id: UUID,
        name: String,
        members: [GroupMember],
        accessSecret: String
    ) -> IntercomGroup {
        do {
            return try IntercomGroup(id: id, name: name, members: members, accessSecret: accessSecret)
        } catch {
            preconditionFailure("Invalid group in the test fixture.")
        }
    }
}

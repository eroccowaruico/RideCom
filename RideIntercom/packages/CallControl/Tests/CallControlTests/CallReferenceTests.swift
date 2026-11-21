import CallControl
import Foundation
import Testing

struct CallReferenceTests {
    private let access = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let generation = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let group = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!

    @Test func watchAndDisplayedControlsEncodeTheSameActiveReference() throws {
        let current = CallReference(accountAccessID: access, connectionGeneration: generation, groupID: group)
        let expected = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA|BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB|CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
        let displayed = try #require(current.displayedCall)
        #expect(current.encoded == expected)
        #expect(displayed.encoded == expected)
        #expect(CallSurfaceReference(encoded: expected)?.callReference == current)
    }

    @Test func idleReferenceIsOnlyAvailableToUnboundControls() {
        let idle = CallReference(accountAccessID: access, connectionGeneration: generation, groupID: nil)
        #expect(idle.encoded == "\(access.uuidString)|\(generation.uuidString)|idle")
        #expect(idle.displayedCall == nil)
        #expect(CallSurfaceReference(encoded: idle.encoded) == nil)
    }

    @Test func missingInvalidAndExtraFieldsCannotBeUsedAsDisplayedControls() {
        let active = CallSurfaceReference(accountAccessID: access, connectionGeneration: generation, groupID: group)
        #expect(CallSurfaceReference(encoded: active.encoded + "|") == nil)
        #expect(CallSurfaceReference(encoded: "\(access.uuidString)||\(group.uuidString)") == nil)
        #expect(CallSurfaceReference(encoded: active.encoded.replacingOccurrences(of: "A", with: "G")) == nil)
    }

    @Test func displayedReferenceDecodesTheExistingSnapshotFieldsAndRequiresAGroup() throws {
        let json = #"{"accountAccessID":"\#(access.uuidString)","connectionGeneration":"\#(generation.uuidString)","groupID":"\#(group.uuidString)"}"#
        let displayed = try JSONDecoder().decode(CallSurfaceReference.self, from: Data(json.utf8))
        #expect(displayed == .init(accountAccessID: access, connectionGeneration: generation, groupID: group))
        let missingGroup = #"{"accountAccessID":"\#(access.uuidString)","connectionGeneration":"\#(generation.uuidString)"}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CallSurfaceReference.self, from: Data(missingGroup.utf8))
        }
    }
}

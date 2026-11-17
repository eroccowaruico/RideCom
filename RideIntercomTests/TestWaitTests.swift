import Foundation
import Testing
@testable import RideIntercom

@MainActor
struct TestWaitTests {
    /// The whole suite shares the main thread. A wait that another test kept from running has not
    /// waited: it must still give the awaited work its turns before it gives up.
    @Test func aWaitThatTheMainThreadKeptFromRunningStillSeesTheAwaitedWork() async {
        var finished = false
        Task { @MainActor in
            Thread.sleep(forTimeInterval: 1.2)
            Task { @MainActor in finished = true }
        }
        await AppTestSupport.waitUntil { finished }
        #expect(finished)
    }

    @Test func aWaitForSomethingThatNeverHappensEnds() async {
        let start = ContinuousClock.now
        await AppTestSupport.waitUntil(timeout: .milliseconds(100)) { false }
        #expect(start.duration(to: .now) < .seconds(5))
    }
}

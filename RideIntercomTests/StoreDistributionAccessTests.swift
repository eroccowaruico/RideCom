import Foundation
import StoreKit
import Testing
@testable import RideIntercom

@MainActor
struct StoreDistributionAccessTests {
    @Test func verifiedSandboxIsADistributionGrantAndOtherEnvironmentsAreNot() {
        #expect(
            StoreDistributionAccess.evaluate(
                isVerified: true, bundleID: "app", expectedBundleID: "app", environment: .sandbox)
                == .testDistribution)
        #expect(
            StoreDistributionAccess.evaluate(
                isVerified: true, bundleID: "app", expectedBundleID: "app", environment: .production) == .standard)
        #expect(
            StoreDistributionAccess.evaluate(
                isVerified: true, bundleID: "app", expectedBundleID: "app", environment: .xcode) == .standard)
        #expect(
            StoreDistributionAccess.evaluate(
                isVerified: true, bundleID: "app", expectedBundleID: "app", environment: .init(rawValue: "future"))
                == .unknown)
        #expect(!StoreDistributionAccess.automaticCheckEnabled)
    }
    @Test func unverifiedWrongAppAndRevokedAppDoNotGrant() {
        #expect(
            StoreDistributionAccess.evaluate(
                isVerified: false, bundleID: "app", expectedBundleID: "app", environment: .sandbox) == .unknown)
        #expect(
            StoreDistributionAccess.evaluate(
                isVerified: true, bundleID: "other", expectedBundleID: "app", environment: .sandbox) == .unknown)
        #expect(
            StoreDistributionAccess.evaluate(
                isVerified: true, bundleID: "", expectedBundleID: "", environment: .sandbox) == .unknown)
        #expect(
            StoreDistributionAccess.evaluate(
                isVerified: true, bundleID: "app", expectedBundleID: "app", environment: .sandbox,
                revocationDate: Date()) == .standard)
    }
    @Test func unconfiguredCatalogCanUseDistributionGrantWithoutPurchaseRequests() async {
        let fixture = DistributionFixture()
        let access = StoreKitAccess(catalog: .unconfigured, source: fixture,
                                    distributionReader: { try await fixture.distribution() })
        await access.start()
        let state = access.evaluation(at: Date())
        #expect(state.status == .active && state.origin == .testDistribution && state.activeUntil == nil)
        #expect(
            fixture.distributionCount == 1 && fixture.readCount == 0 && fixture.syncCount == 0
                && fixture.listenCount == 0)
        access.stop()
        #expect(access.evaluation(at: Date()).status != .active)
    }
    @Test func transientFailureKeepsOnlyTheCurrentProcessGrantAndProductionClearsIt() async {
        let fixture = DistributionFixture()
        let access = StoreKitAccess(catalog: .unconfigured, source: fixture,
                                    distributionReader: { try await fixture.distribution() })
        await access.start()
        fixture.fails = true
        await access.refresh()
        #expect(access.evaluation(at: Date()).origin == .testDistribution)
        fixture.fails = false
        fixture.result = .unknown
        await access.refresh()
        #expect(access.evaluation(at: Date()).status == .unknown)
        fixture.result = .testDistribution
        await access.refresh()
        #expect(access.evaluation(at: Date()).origin == .testDistribution)
        fixture.result = .standard
        await access.refresh()
        #expect(access.evaluation(at: Date()).status == .unconfigured)
        #expect(access.distributionAccess == .standard)
        fixture.result = .unknown
        await access.refresh()
        #expect(access.evaluation(at: Date()).status == .unknown)
        access.stop()
        let nextProcess = StoreKitAccess(catalog: .unconfigured, source: fixture,
                                         distributionReader: { try await fixture.distribution() })
        #expect(nextProcess.evaluation(at: Date()).status == .unknown)
    }
    @Test func productionWithoutPurchasesRemainsNotPurchased() async {
        let fixture = DistributionFixture()
        fixture.hasPurchase = false
        fixture.result = StoreDistributionAccess.evaluate(
            isVerified: true, bundleID: "app", expectedBundleID: "app", environment: .production)
        let access = StoreKitAccess(
            catalog: .init(weeklyProductID: "fixture.week", monthlyProductID: nil), source: fixture,
                                    distributionReader: { try await fixture.distribution() })
        await access.start()
        #expect(access.evaluation(at: fixture.bought).status == .notPurchased)
        #expect(access.evaluation(at: fixture.bought).origin == nil)
        #expect(fixture.syncCount == 0 && fixture.readCount == 1 && fixture.distributionCount == 1)
        fixture.result = .unknown
        await access.refresh()
        #expect(access.evaluation(at: fixture.bought).status == .unknown)
        fixture.result = .standard
        await access.refresh()
        #expect(access.evaluation(at: fixture.bought).status == .notPurchased)
        access.stop()
    }
    @Test func unknownDistributionCanBeCheckedAgainWithoutRestoringPurchases() async {
        let fixture = DistributionFixture()
        fixture.fails = true
        let access = StoreKitAccess(catalog: .unconfigured, source: fixture,
                                    distributionReader: { try await fixture.distribution() })
        await access.start()
        #expect(access.evaluation(at: Date()).status == .unknown && !access.isCheckingAccess)
        fixture.fails = false
        let gate = ManualAsyncGate()
        fixture.gate = gate
        let checking = Task { await access.refresh() }
        await gate.waitForEntry()
        #expect(access.isCheckingAccess)
        await gate.release()
        await checking.value
        #expect(access.evaluation(at: Date()).origin == .testDistribution && !access.isCheckingAccess)
        #expect(
            fixture.distributionCount == 2 && fixture.syncCount == 0 && fixture.readCount == 0
                && fixture.listenCount == 0)
        access.stop()
    }
    @Test func stopDiscardsDelayedDistributionResultAndRestartCanReadAgain() async {
        let fixture = DistributionFixture()
        let gate = ManualAsyncGate()
        fixture.gate = gate
        let owner = DistributionOwner()
        let access = StoreKitAccess(catalog: .unconfigured, source: fixture,
            isCurrentUser: { owner.current }, distributionReader: { try await fixture.distribution() })
        let old = Task { await access.start() }
        await gate.waitForEntry()
        owner.current = false
        access.stop()
        await old.value
        #expect(access.evaluation(at: Date()).status == .unknown)
        owner.current = true
        fixture.gate = nil; fixture.result = .standard
        await access.start()
        await gate.release()
        for _ in 0..<10 { await Task.yield() }
        #expect(access.distributionAccess == .standard && fixture.distributionCount == 2)
        access.stop()
    }
    @Test func stopDuringRestoreCannotStartANewDistributionCheck() async {
        let fixture = DistributionFixture()
        let access = StoreKitAccess(
            catalog: .init(weeklyProductID: "fixture.week", monthlyProductID: nil), source: fixture,
                                    distributionReader: { try await fixture.distribution() })
        await access.start()
        let gate = ManualAsyncGate()
        fixture.syncGate = gate
        let restoring = Task { await access.restore() }
        await gate.waitForEntry()
        access.stop()
        await restoring.value
        #expect(fixture.distributionCount == 1)
        #expect(access.distributionAccess == .unknown)
        await gate.release()
    }
    @Test func distributionGrantDoesNotWaitForThePurchaseStatusRequest() async {
        let fixture = DistributionFixture()
        let gate = ManualAsyncGate()
        fixture.purchaseGate = gate
        let access = StoreKitAccess(
            catalog: .init(weeklyProductID: "fixture.week", monthlyProductID: nil), source: fixture,
                                    distributionReader: { try await fixture.distribution() })
        let loading = Task { await access.start() }
        await gate.waitForEntry()
        for _ in 0..<100 where access.distributionAccess != .testDistribution { await Task.yield() }
        #expect(access.evaluation(at: fixture.bought).origin == .testDistribution)
        access.stop()
        await loading.value
        await gate.release()
    }
    @Test func purchaseUpdatesDoNotRepeatTheDistributionCheck() async {
        let fixture = DistributionFixture()
        let access = StoreKitAccess(
            catalog: .init(weeklyProductID: "fixture.week", monthlyProductID: nil), source: fixture,
                                    distributionReader: { try await fixture.distribution() })
        await access.start()
        fixture.continuation?.yield(())
        for _ in 0..<100 where fixture.readCount < 2 { await Task.yield() }
        #expect(fixture.readCount == 2 && fixture.distributionCount == 1)
        access.stop()
    }
    @Test func hangingDistributionReadTimesOutWithoutLosingPurchaseRights() async {
        let fixture = DistributionFixture()
        fixture.gate = ManualAsyncGate()
        let access = StoreKitAccess(
            catalog: .init(weeklyProductID: "fixture.week", monthlyProductID: nil), source: fixture,
            readTimeout: .milliseconds(30), distributionReader: { try await fixture.distribution() })
        await access.start()
        #expect(!access.isRefreshing)
        #expect(access.evaluation(at: fixture.bought).status == .active)
        #expect(access.evaluation(at: fixture.bought).origin == .purchase)
        #expect(access.distributionAccess == .unknown)
        await fixture.gate?.release()
        access.stop()
    }
}

@MainActor
private final class DistributionOwner { var current = true }

@MainActor
private final class DistributionFixture: StoreKitAccessSource {
    enum Failure: Error { case offline }
    let bought = Date(timeIntervalSince1970: 1_800_000_000)
    var hasPurchase = true
    var result: StoreDistributionAccess = .testDistribution
    var fails = false
    var syncGate: ManualAsyncGate?
    var purchaseGate: ManualAsyncGate?
    var continuation: AsyncStream<Void>.Continuation?
    var gate: ManualAsyncGate?
    var distributionCount = 0
    var readCount = 0
    var syncCount = 0
    var listenCount = 0
    func distribution() async throws -> StoreDistributionAccess {
        distributionCount += 1
        let value = result
        if let gate { await gate.wait() }
        if fails { throw Failure.offline }
        return value
    }
    func read(catalog: StoreProductCatalog, onVerifiedTransactions: @MainActor (StoreEntitlementSnapshot) -> Bool)
        async throws -> StoreEntitlementSnapshot {
        readCount += 1
        let snapshot = StoreEntitlementSnapshot(
            entitlements: [
                .init(
                    transactionID: 1, productID: "fixture.week", kind: .week,
                    purchaseDate: bought, expirationDate: nil, revocationDate: nil, isUpgraded: false,
                    isFreeTrial: false, graceExpirationDate: nil)
            ].filter { _ in hasPurchase }, hasUnverifiedTransactions: false)
        _ = onVerifiedTransactions(snapshot)
        if let purchaseGate { await purchaseGate.wait() }
        return snapshot
    }
    func sync() async throws {
        syncCount += 1
        if let syncGate { await syncGate.wait() }
    }
    func updates(catalog: StoreProductCatalog) -> AsyncStream<Void> {
        listenCount += 1
        return AsyncStream { continuation = $0 }
    }
}

import Foundation
import StoreKit

@MainActor
final class SystemStoreKitAccessSource: StoreKitAccessSource {
    private let subscriptionStatuses: @MainActor (String) async throws -> [Product.SubscriptionInfo.Status]

    init(subscriptionStatuses: (@MainActor (String) async throws -> [Product.SubscriptionInfo.Status])? = nil) {
        self.subscriptionStatuses = subscriptionStatuses ?? { try await Product.SubscriptionInfo.status(for: $0) }
    }

    func read(
        catalog: StoreProductCatalog,
        onVerifiedTransactions: @MainActor (StoreEntitlementSnapshot) -> Bool = { _ in false }
    ) async throws -> StoreEntitlementSnapshot {
        guard catalog.isConfigured else { return .init(entitlements: [], hasUnverifiedTransactions: false) }

        var entitlements: [StoreEntitlement] = []
        var verifiedIDs: Set<UInt64> = []
        // All non-renewing purchases must be evaluated independently. A later
        // refunded purchase must not hide an earlier still-active ticket.
        var unverified = await readHistory(productID: catalog.weeklyProductID, type: .nonRenewable) { transaction in
            verifiedIDs.insert(transaction.id)
            entitlements.append(Self.entitlement(transaction, kind: .week))
        }
        var monthlyGroups: [String: [StoreEntitlement]] = [:]
        let unverifiedMonthly = await readHistory(
            productID: catalog.monthlyProductID, type: .autoRenewable
        ) { transaction in
            verifiedIDs.insert(transaction.id)
            let value = Self.entitlement(transaction, kind: .monthly)
            if let group = transaction.subscriptionGroupID {
                monthlyGroups[group, default: []].append(value)
            } else {
                entitlements.append(value)
                unverified = true
            }
        }
        unverified = unverified || unverifiedMonthly
        monthlyGroups = monthlyGroups.mapValues(StoreEntitlement.latestSubscriptionPeriods)
        // Publish locally verified purchase dates/expirations before any status
        // request. A slow StoreKit status service must not hide a known ticket.
        let localSnapshot = StoreEntitlementSnapshot(
            entitlements: entitlements + monthlyGroups.values.flatMap { $0 },
            hasUnverifiedTransactions: unverified
        )
        await finishAdoptedTransactions(localSnapshot, verifiedIDs: verifiedIDs, catalog: catalog,
                                        adopt: onVerifiedTransactions)
        for (group, fallback) in monthlyGroups {
            try Task.checkCancellation()
            do {
                let result = try await readMonthlyStatus(for: group, productID: catalog.monthlyProductID,
                                                         fallback: fallback)
                verifiedIDs.formUnion(result.verifiedIDs)
                unverified = unverified || result.snapshot.hasUnverifiedTransactions
                entitlements += result.snapshot.entitlements
            } catch {
                unverified = true
                entitlements += fallback
            }
        }
        let snapshot = StoreEntitlementSnapshot(entitlements: entitlements, hasUnverifiedTransactions: unverified)
        await finishAdoptedTransactions(snapshot, verifiedIDs: verifiedIDs, catalog: catalog,
                                        adopt: onVerifiedTransactions)
        return snapshot
    }

    private func readHistory(
        productID: String?,
        type: Product.ProductType,
        onVerified: (Transaction) -> Void
    ) async -> Bool {
        guard let productID, !productID.isEmpty else { return false }
        var unverified = false
        for await result in Transaction.all(for: productID) {
            guard case .verified(let transaction) = result,
                  transaction.productID == productID, transaction.productType == type else {
                unverified = true
                continue
            }
            onVerified(transaction)
        }
        return unverified
    }

    private func readMonthlyStatus(
        for group: String,
        productID: String?,
        fallback: [StoreEntitlement]
    ) async throws -> (snapshot: StoreEntitlementSnapshot, verifiedIDs: Set<UInt64>) {
        // Evaluate both purchased and family subscriptions to the same product.
        let statuses = try await subscriptionStatuses(group)
        var values: [StoreEntitlement] = []
        var verifiedIDs: Set<UInt64> = []
        var incomplete = false
        for status in statuses where status.transaction.unsafePayloadValue.productID == productID {
            guard case .verified(let transaction) = status.transaction, transaction.productType == .autoRenewable else {
                incomplete = true
                continue
            }
            verifiedIDs.insert(transaction.id)
            let result = Self.subscriptionEntitlement(transaction, status: status)
            values.append(result.entitlement)
            incomplete = incomplete || result.incomplete
        }
        if incomplete || values.isEmpty {
            incomplete = true
            // Preserve only independently verified history for series
            // for which StoreKit did not return a verified status.
            values += fallback.filter { old in
                !values.contains {
                    $0.originalTransactionID == old.originalTransactionID && $0.ownershipType == old.ownershipType
                }
            }
        }
        return (.init(entitlements: values, hasUnverifiedTransactions: incomplete), verifiedIDs)
    }

    private static func subscriptionEntitlement(
        _ transaction: Transaction,
        status: Product.SubscriptionInfo.Status
    ) -> (entitlement: StoreEntitlement, incomplete: Bool) {
        var grace: Date?
        var incomplete = transaction.expirationDate == nil
        if status.state == .inGracePeriod {
            if case .verified(let renewal) = status.renewalInfo {
                grace = renewal.gracePeriodExpirationDate
            } else {
                incomplete = true
            }
        }
        var value = entitlement(transaction, kind: .monthly, grace: grace)
        switch status.state {
        case .subscribed: value.subscriptionStatus = "subscribed"
        case .inGracePeriod: value.subscriptionStatus = "grace"
        case .expired: value.subscriptionStatus = "expired"
        case .inBillingRetryPeriod: value.subscriptionStatus = "billingRetry"
        case .revoked: value.subscriptionStatus = "revoked"
        default:
            value.subscriptionStatus = "unknown"
            incomplete = true
        }
        return (value, incomplete)
    }

    private func finishAdoptedTransactions(_ snapshot: StoreEntitlementSnapshot, verifiedIDs: Set<UInt64>,
                                           catalog: StoreProductCatalog,
                                           adopt: @MainActor (StoreEntitlementSnapshot) -> Bool) async {
        // Delivery is the current login generation adopting the verified read.
        // Keep every history ID: the UI may display only the latest renewal.
        guard !Task.isCancelled, adopt(snapshot), !verifiedIDs.isEmpty else { return }
        for await result in Transaction.unfinished {
            guard !Task.isCancelled else { break }
            guard case .verified(let transaction) = result,
                  verifiedIDs.contains(transaction.id),
                  catalog.accepts(productID: transaction.productID, type: transaction.productType) else { continue }
            // Enumeration suspends. Recheck adoption immediately before finish;
            // a stopped, superseded, or timed-out read must leave it unfinished.
            guard adopt(snapshot) else { break }
            await transaction.finish()
        }
    }

    func sync() async throws { try await AppStore.sync() }

    func updates(catalog: StoreProductCatalog) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let transactions = Task {
                for await result in Transaction.updates {
                    guard !Task.isCancelled else { break }
                    // Unverified payloads are used only to request a fresh read.
                    if catalog.productIDs.contains(result.unsafePayloadValue.productID) { continuation.yield(()) }
                }
            }
            let subscriptions = Task {
                for await status in Product.SubscriptionInfo.Status.updates {
                    guard !Task.isCancelled else { break }
                    if catalog.productIDs.contains(status.transaction.unsafePayloadValue.productID) {
                        continuation.yield(())
                    }
                }
            }
            continuation.onTermination = { _ in transactions.cancel(); subscriptions.cancel() }
        }
    }

    private static func entitlement(
        _ transaction: Transaction,
        kind: StoreEntitlement.Kind,
        grace: Date? = nil
    ) -> StoreEntitlement {
        .init(transactionID: transaction.id, productID: transaction.productID, kind: kind,
              purchaseDate: transaction.purchaseDate, expirationDate: transaction.expirationDate,
              revocationDate: transaction.revocationDate, isUpgraded: transaction.isUpgraded,
              isFreeTrial: transaction.offer?.paymentMode == .freeTrial, graceExpirationDate: grace,
              originalTransactionID: transaction.originalID, ownershipType: transaction.ownershipType.rawValue,
              environment: transaction.environment.rawValue)
    }
}

import Foundation
import Observation
import RevenueCat

/// Subscription entitlement via RevenueCat (iOS-PRD §2/§7). Drives the paywall UX;
/// the backend webhook independently sets the server-side flag, so this is never
/// the access authority. `appUserID` is the Cognito `sub` so events map to the user.
///
/// In mock mode (`AppConfig.useMockAuth`) the RevenueCat calls are skipped so the
/// flow is demoable offline. Authored on Windows — verify the RC API on a Mac.
@MainActor
@Observable
final class EntitlementService {
    var isSubscribed = false
    private(set) var annualPackage: Package?
    private(set) var monthlyPackage: Package?

    func bootstrap() async {
        guard !AppConfig.useMockAuth else { return }
        Purchases.logLevel = .warn
        Purchases.configure(withAPIKey: AppConfig.revenueCatAPIKey)
        await refresh()
    }

    /// Tie purchases to the Cognito user so the webhook maps to the right account.
    func login(userId: String) async {
        guard !AppConfig.useMockAuth else { return }
        _ = try? await Purchases.shared.logIn(userId)
        await refresh()
    }

    func reset() async {
        isSubscribed = false
        guard !AppConfig.useMockAuth else { return }
        _ = try? await Purchases.shared.logOut()
    }

    func refresh() async {
        guard !AppConfig.useMockAuth else { return }
        if let info = try? await Purchases.shared.customerInfo() {
            isSubscribed = info.entitlements[AppConfig.entitlementID]?.isActive == true
        }
        if let offering = try? await Purchases.shared.offerings().current {
            annualPackage = offering.annual ?? offering.availablePackages.first { $0.packageType == .annual }
            monthlyPackage = offering.monthly
        }
    }

    enum Plan { case annual, monthly }

    /// Display pricing for a plan, taken from StoreKit so it is correct in every
    /// storefront and currency — never hardcoded (App Store Guideline 3.1.2).
    /// `perMonth` and `savingsPercent` describe the annual plan's monthly-equivalent
    /// and its saving versus the monthly plan.
    struct PlanPrice {
        let total: String
        let perMonth: String?
        let savingsPercent: Int?
    }

    /// Pricing for a plan, or `nil` until the offering has loaded. Reads the
    /// observed packages, so a SwiftUI view calling this refreshes when they arrive.
    func price(for plan: Plan) -> PlanPrice? {
        // Dev/preview only: StoreKit is not wired under mock auth, so show
        // representative sample values. A real build has useMockAuth == false and
        // never takes this path.
        if AppConfig.useMockAuth {
            return plan == .annual
                ? PlanPrice(total: "$39.99", perMonth: "$3.33", savingsPercent: 58)
                : PlanPrice(total: "$7.99", perMonth: nil, savingsPercent: nil)
        }
        guard let package = (plan == .annual ? annualPackage : monthlyPackage) else { return nil }
        let product = package.storeProduct
        guard plan == .annual else {
            return PlanPrice(total: product.localizedPriceString, perMonth: nil, savingsPercent: nil)
        }
        // Annual: derive the monthly-equivalent and saving, formatted in the
        // product's own currency via its StoreKit price formatter.
        let perMonthValue = product.price / 12
        let perMonth = product.priceFormatter?.string(from: perMonthValue as NSDecimalNumber)
        var savings: Int?
        if let monthly = monthlyPackage?.storeProduct.price, monthly > 0 {
            let ratio = ((monthly - perMonthValue) / monthly) as NSDecimalNumber
            let pct = Int(ratio.doubleValue * 100)
            if pct > 0 { savings = pct }
        }
        return PlanPrice(total: product.localizedPriceString, perMonth: perMonth, savingsPercent: savings)
    }

    /// Purchase / start the trial. Returns true if it resulted in an active entitlement.
    @discardableResult
    func purchase(_ plan: Plan) async throws -> Bool {
        if AppConfig.useMockAuth {
            try? await Task.sleep(for: .milliseconds(500))
            isSubscribed = true
            return true
        }
        let package = plan == .annual ? annualPackage : monthlyPackage
        guard let package else { throw APIError.notConfigured }
        let result = try await Purchases.shared.purchase(package: package)
        isSubscribed = result.customerInfo.entitlements[AppConfig.entitlementID]?.isActive == true
        return isSubscribed
    }

    func restore() async {
        guard !AppConfig.useMockAuth else { return }
        if let info = try? await Purchases.shared.restorePurchases() {
            isSubscribed = info.entitlements[AppConfig.entitlementID]?.isActive == true
        }
    }
}

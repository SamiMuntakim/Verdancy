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

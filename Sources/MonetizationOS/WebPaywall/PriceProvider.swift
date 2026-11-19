/// Localized store prices for the product ids a paywall shows. Back it with your own StoreKit code.
public protocol PriceProvider: Sendable {
    /// Products the store does not know are left out.
    func prices(productIDs: Set<String>) async -> [String: StorePrice]
}

public struct StorePrice: Sendable, Equatable {
    /// Formatted by the store for the user's storefront, e.g. "$4.99".
    public let displayPrice: String
    /// The subscription period, e.g. "month" or "3 months"; nil for one-off purchases.
    public let displayPeriod: String?
    public let introductoryDisplayPrice: String?

    public init(displayPrice: String, displayPeriod: String? = nil, introductoryDisplayPrice: String? = nil) {
        self.displayPrice = displayPrice
        self.displayPeriod = displayPeriod
        self.introductoryDisplayPrice = introductoryDisplayPrice
    }
}

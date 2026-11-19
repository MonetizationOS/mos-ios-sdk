import MonetizationOS
import MonetizationOSUI
import SwiftUI

/// A server-rendered html paywall in MOSWebPaywallView, priced by the app.
struct WebPaywallScreen: View {
    @Environment(Showcase.self) private var showcase
    @State private var result: DecisionResult?
    @State private var closed = false
    @State private var event = "none yet"
    @State private var lastCall: LastCall?

    var body: some View {
        ScreenScaffold(
            title: "Web paywall",
            explainer: "decision.experience(\"webPaywall\") is .web(html): MOSWebPaywallView shows it, fills prices from a PriceProvider and reports onRedemption and onClose.",
            lastCall: lastCall
        ) {
            ValueRow("Page event", event, id: "webPaywall.event")
            switch result?.decision?.experience("webPaywall") {
            case .web(let html)? where !closed:
                MOSWebPaywallView(
                    html: html,
                    mos: showcase.mos,
                    priceProvider: FixedPrices(),
                    onRedemption: { redemption in
                        event = "onRedemption: \(describe(redemption))"
                        lastCall = .redemption(redemption, call: "onRedemption (mos://redeem in the page)")
                    },
                    onClose: {
                        closed = true
                        event = "onClose"
                        lastCall = .text("onClose (mos://close in the page)", ["closed": true])
                    }
                )
                .frame(height: 380)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("webPaywall.view")
            case .web?:
                Button("The page closed. Show it again") { closed = false }
                    .accessibilityIdentifier("webPaywall.reopen")
            case .native?:
                Text("The workflow sent a native paywall under this key; see the Native paywall screen.")
            case nil where result != nil:
                Text("No paywall: this reader has access.").font(.headline).accessibilityIdentifier("paywall.none")
            case nil:
                ProgressView()
            }
        }
        .task { await decide() }
    }

    private func decide() async {
        let result = await showcase.mos.decide(resource: Resource(id: "paywall/web"))
        self.result = result
        showcase.didDecide(result)
        lastCall = .decision(result, call: "decide(resource: \"paywall/web\")")
    }
}

private func describe(_ redemption: RedemptionResult) -> String {
    switch redemption {
    case .redeemed(let action, _, _): "redeemed, \(action.json["type"]?.stringValue ?? "")"
    case .declined: "declined"
    case .failed(let failure): "failed, \(failure.reason.rawValue)"
    }
}

/// Fixed prices standing in for StoreKit, so the swap from the page's fallback text is visible.
/// A real app answers from `Product.products(for:)`.
struct FixedPrices: PriceProvider {
    func prices(productIDs: Set<String>) async -> [String: StorePrice] {
        let known = [
            "com.monetizationos.showcase.monthly": StorePrice(displayPrice: "€4.99", displayPeriod: "month"),
            "com.monetizationos.showcase.annual": StorePrice(displayPrice: "€39.99", displayPeriod: "year"),
        ]
        return known.filter { productIDs.contains($0.key) }
    }
}

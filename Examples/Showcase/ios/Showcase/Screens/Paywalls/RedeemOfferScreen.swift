import MonetizationOS
import SwiftUI

/// One offer per redemption outcome, and what an app does with each.
struct RedeemOfferScreen: View {
    @Environment(Showcase.self) private var showcase
    @State private var offers: [Offer] = []
    @State private var outcome: String?
    @State private var navigateTo: URL?
    @State private var lastCall: LastCall?
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScreenScaffold(
            title: "Redeem an offer",
            explainer: "redeem(offerToken:) returns a RedemptionResult: redeemed with an action (custom, navigate or none), declined, or failed. Turn Offline on to see failed.",
            lastCall: lastCall
        ) {
            ForEach(Array(offers.enumerated()), id: \.offset) { index, offer in
                Button { Task { await redeem(offer) } } label: {
                    VStack(alignment: .leading) {
                        Text(offer.presentation["title"]?.stringValue ?? offer.id).font(.headline)
                        Text(offer.presentation["subtitle"]?.stringValue ?? "").font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("redeem.offer.\(index)")
            }
            if let outcome {
                Text(outcome)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("redeem.outcome")
            }
            if let navigateTo {
                Button("Open \(navigateTo.absoluteString)") { openURL(navigateTo) }
            }
        }
        .task { await decide() }
    }

    private func decide() async {
        let result = await showcase.mos.decide(resource: Resource(id: "offers/redeem"))
        offers = result.decision?.experience("offers")?.offers.compactMap(\.offer) ?? []
        showcase.didDecide(result)
        lastCall = .decision(result, call: "decide(resource: \"offers/redeem\")")
    }

    private func redeem(_ offer: Offer) async {
        let result = await showcase.mos.redeem(offerToken: offer.token)
        navigateTo = nil
        switch result {
        case .redeemed(.custom(let type, let properties), _, _):
            // Your handler for the custom type; for custom:storekit, buy the product with StoreKit.
            outcome = "Redeemed: \(type). Hand it to your own code, e.g. buy \(properties["storeProductId"]?.stringValue ?? "the product")."
        case .redeemed(.navigate(let url, _), _, _):
            outcome = "Redeemed: navigate. Open \(url.absoluteString)."
            navigateTo = url
        case .redeemed(.noAction, _, _):
            outcome = "Redeemed: none. Nothing to do but decide again for the new entitlements."
        case .declined(let message, let statusCode, _):
            outcome = "Declined (\(statusCode)): \(message ?? "no message"). Show the message."
        case .failed(let failure):
            outcome = "Failed: \(failure.reason.rawValue). The redemption may not have run. For a timeout or server error it may have, so check before retrying."
        }
        lastCall = .redemption(result, call: "redeem(offerToken:) · \(offer.presentation["title"]?.stringValue ?? offer.id)")
    }
}

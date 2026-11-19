import MonetizationOS
import SwiftUI

/// A native paywall: copy from the experience JSON, offers from its slots, redeem on tap.
struct NativePaywallScreen: View {
    @Environment(Showcase.self) private var showcase
    @State private var result: DecisionResult?
    @State private var lastCall: LastCall?

    var body: some View {
        ScreenScaffold(
            title: "Native paywall",
            explainer: "decision.experience(\"paywall\") is .native: SwiftUI renders its copy and offer slots, and a tap calls redeem(offerToken:).",
            lastCall: lastCall
        ) {
            let experience = result?.decision?.experience("paywall")
            if let experience, case .native = experience {
                NativePaywall(experience: experience) { offer in
                    let redemption = await showcase.mos.redeem(offerToken: offer.token)
                    lastCall = .redemption(redemption, call: "redeem(offerToken:) · \(offer.presentation["title"]?.stringValue ?? offer.id)")
                }
            } else if experience != nil {
                Text("The workflow sent a web paywall under this key; see the Web paywall screen.")
            } else if result != nil {
                Text("No paywall: this reader has access.").font(.headline).accessibilityIdentifier("paywall.none")
            } else {
                ProgressView()
            }
        }
        .task { await decide() }
    }

    private func decide() async {
        let result = await showcase.mos.decide(resource: Resource(id: "paywall/native"))
        self.result = result
        showcase.didDecide(result)
        lastCall = .decision(result, call: "decide(resource: \"paywall/native\")")
    }
}

/// The paywall itself. The copy is whatever shape your experience defines; this one is
/// `{ headline, body, benefits }`.
struct NativePaywall: View {
    struct Copy: Decodable {
        let headline: String
        let body: String?
        let benefits: [String]?
    }

    let experience: Experience
    let onSelect: @MainActor (Offer) async -> Void

    var body: some View {
        let copy = try? experience.decode(Copy.self)
        VStack(alignment: .leading, spacing: 12) {
            Text(copy?.headline ?? "Paywall").font(.title2.bold()).accessibilityIdentifier("paywall.headline")
            if let body = copy?.body { Text(body).foregroundStyle(.secondary) }
            ForEach(copy?.benefits ?? [], id: \.self) { benefit in
                Label(benefit, systemImage: "checkmark")
            }
            ForEach(Array(experience.offers.compactMap(\.offer).enumerated()), id: \.offset) { index, offer in
                Button { Task { await onSelect(offer) } } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(offer.presentation["title"]?.stringValue ?? offer.id).font(.headline)
                            if let subtitle = offer.presentation["subtitle"]?.stringValue {
                                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let badge = offer.presentation["badge"]?.stringValue {
                            Text(badge).font(.caption.bold()).padding(4).background(.yellow.opacity(0.4), in: Capsule())
                        }
                        // A real app shows the store's localized price for offer.storeProductID.
                        Text(offer.presentation["fallbackPrice"]?.stringValue ?? "")
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("paywall.offer.\(index)")
            }
        }
    }
}

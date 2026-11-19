import MonetizationOS
import SwiftUI

/// An on/off feature property: the workflow decides whether this reader sees the ad slot.
struct FeatureSwitchScreen: View {
    @Environment(Showcase.self) private var showcase
    @State private var result: DecisionResult?
    @State private var lastCall: LastCall?

    var body: some View {
        ScreenScaffold(
            title: "Feature switch",
            explainer: "hasAccess(feature: \"ads\", property: \"enabled\") shows or hides an ad slot. The fixtures turn ads off for signed-in readers.",
            lastCall: lastCall
        ) {
            if let result {
                let adsOn = result.hasAccess(feature: "ads", property: "enabled")
                ValueRow("ads.enabled", adsOn ? "on" : "off", id: "feature.state")
                VStack(alignment: .leading, spacing: 12) {
                    feedItem(1)
                    feedItem(2)
                    if adsOn {
                        Text("Ad slot")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 80)
                            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(.gray, style: StrokeStyle(lineWidth: 1, dash: [6])))
                            .accessibilityIdentifier("feature.adSlot")
                    }
                    feedItem(3)
                }
            } else {
                ProgressView()
            }
            Button("Decide again") { Task { await decide() } }
                .buttonStyle(.bordered)
        }
        .task { await decide() }
    }

    private func feedItem(_ number: Int) -> some View {
        HStack(spacing: 12) {
            PlaceholderBlock(height: 48, width: 48)
            VStack(alignment: .leading, spacing: 6) {
                Text("Item \(number)").font(.subheadline.bold())
                PlaceholderBlock(height: 10)
            }
        }
    }

    private func decide() async {
        let result = await showcase.mos.decide(resource: Resource(id: "feed"))
        self.result = result
        showcase.didDecide(result)
        lastCall = .decision(result, call: "decide(resource: \"feed\")")
    }
}

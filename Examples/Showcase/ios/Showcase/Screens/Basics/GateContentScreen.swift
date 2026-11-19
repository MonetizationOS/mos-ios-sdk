import MonetizationOS
import SwiftUI

/// Decide on an article, then show it or a locked placeholder from one boolean feature property.
struct GateContentScreen: View {
    @Environment(Showcase.self) private var showcase
    @State private var premium = false
    @State private var result: DecisionResult?
    @State private var lastCall: LastCall?

    var body: some View {
        ScreenScaffold(
            title: "Gate content",
            explainer: "decide(resource:) on an article, then hasAccess(feature: \"article\", property: \"enabled\") picks the content or a locked placeholder.",
            lastCall: lastCall
        ) {
            Picker("Article", selection: $premium) {
                Text("Free · article/1").tag(false)
                Text("Premium · article/2").tag(true)
            }
            .pickerStyle(.segmented)

            if let result {
                if result.hasAccess(feature: "article", property: "enabled") {
                    Text("Access granted").font(.headline).accessibilityIdentifier("gate.access")
                    PlaceholderArticle(title: premium ? "Article 2" : "Article 1")
                } else {
                    Text("No access").font(.headline).accessibilityIdentifier("gate.access")
                    LockedPlaceholder(text: "Article 2 is for subscribers.")
                }
            } else {
                ProgressView()
            }
        }
        .task(id: premium) { await decide() }
    }

    private func decide() async {
        // `meta` is open context for the workflow; here it tells the two tiers apart.
        let resource = premium
            ? Resource(id: "article/2", meta: ["tier": "premium"])
            : Resource(id: "article/1", meta: ["tier": "free"])
        let result = await showcase.mos.decide(resource: resource)
        self.result = result
        showcase.didDecide(result)
        lastCall = .decision(result, call: "decide(resource: \"\(resource.id)\")")
    }
}

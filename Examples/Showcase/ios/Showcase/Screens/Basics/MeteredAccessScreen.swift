import MonetizationOS
import SwiftUI

/// A meter on its own surface: each new item id consumes one free view; opening it again does not.
struct MeteredAccessScreen: View {
    @Environment(Showcase.self) private var showcase
    @State private var item: Int?
    @State private var result: DecisionResult?
    @State private var lastCall: LastCall?

    var body: some View {
        ScreenScaffold(
            title: "Metered access",
            explainer: "decide(resource:surface: \"showcase-metered\") consumes the items.views meter once per new item id; re-opening an item is free (uniqueResources). 3 free items.",
            lastCall: lastCall
        ) {
            HStack {
                ForEach(1...5, id: \.self) { number in
                    Button("Item \(number)") { Task { await open(number) } }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("metered.item.\(number)")
                }
            }

            if let item, let result {
                let meter = views(result)
                ValueRow("Remaining", meter.map { "\(Int($0.remainingUnits ?? 0)) of \(Int($0.totalUnits ?? 0))" } ?? "-", id: "metered.remaining")
                ValueRow("Consumed by this call", meter?.consumedInRequest == true ? "yes" : "no", id: "metered.consumed")
                ValueRow("Item already counted", meter?.resourceIDUsed == true ? "yes" : "no", id: "metered.used")
                if result.hasAccess(feature: "items", property: "views") {
                    PlaceholderArticle(title: "Item \(item)")
                } else {
                    LockedPlaceholder(text: "You have used your 3 free items.")
                        .accessibilityIdentifier("metered.locked")
                }
            }
        }
    }

    private func open(_ number: Int) async {
        // Per-call surface: this screen's meter lives on its own surface, not the app's default.
        let result = await showcase.mos.decide(resource: Resource(id: "item/\(number)"), surface: "showcase-metered")
        item = number
        self.result = result
        showcase.didDecide(result)
        lastCall = .decision(result, call: "decide(resource: \"item/\(number)\", surface: \"showcase-metered\")")
    }

    private func views(_ result: DecisionResult) -> Meterable? {
        if case .meterable(let meter) = result.decision?.features["items"]?.properties["views"] { return meter }
        return nil
    }
}

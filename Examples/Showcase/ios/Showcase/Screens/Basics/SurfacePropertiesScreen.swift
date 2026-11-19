import MonetizationOS
import SwiftUI

/// Open JSON the workflow sets on the surface, rendered natively: a banner's text and tone.
struct SurfacePropertiesScreen: View {
    @Environment(Showcase.self) private var showcase
    @State private var banner: JSONValue?
    @State private var decided = false
    @State private var lastCall: LastCall?

    var body: some View {
        ScreenScaffold(
            title: "Surface properties",
            explainer: "decision.surfaceProperties[\"banner\"] is open JSON from the workflow on the showcase-home surface; the app reads text, tone and cta and draws its own banner.",
            lastCall: lastCall
        ) {
            if let banner, let text = banner["text"]?.stringValue {
                VStack(alignment: .leading, spacing: 8) {
                    Text(text).accessibilityIdentifier("surface.banner")
                    if let cta = banner["cta"]?.stringValue {
                        Text(cta).font(.subheadline.bold())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(tint(banner["tone"]?.stringValue).opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint(banner["tone"]?.stringValue)))
            } else if decided {
                Text("The workflow set no banner.").foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
            ForEach(1...3, id: \.self) { number in
                HStack(spacing: 12) {
                    PlaceholderBlock(height: 40, width: 40)
                    Text("Home row \(number)")
                }
            }
        }
        .task { await decide() }
    }

    private func decide() async {
        let result = await showcase.mos.decide(resource: Resource(id: "home"), surface: "showcase-home")
        banner = result.decision?.surfaceProperties["banner"]
        decided = true
        showcase.didDecide(result)
        lastCall = .decision(result, call: "decide(resource: \"home\", surface: \"showcase-home\")")
    }

    /// The workflow sends a tone, not a colour, so the app keeps its own palette.
    private func tint(_ tone: String?) -> Color {
        switch tone {
        case "success": .green
        case "warning": .orange
        default: .blue
        }
    }
}

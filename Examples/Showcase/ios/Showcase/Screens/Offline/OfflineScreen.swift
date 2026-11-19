import MonetizationOS
import SwiftUI

/// Decisions without a network: served from the cache, then a fallback, then unavailable, with
/// metering queued for later.
struct OfflineScreen: View {
    @Environment(Showcase.self) private var showcase
    @State private var result: DecisionResult?
    @State private var flushResult: FlushResult?
    @State private var lastCall: LastCall?

    var body: some View {
        ScreenScaffold(
            title: "Offline",
            explainer: "With the network gone, decide() serves the cached decision, then the latest one for another resource, then nothing (failOpen answers hasAccess). Meters consumed offline queue until flush().",
            lastCall: lastCall
        ) {
            Toggle("Offline", isOn: Binding(get: { showcase.isOffline }, set: { showcase.setOffline($0) }))
                .accessibilityIdentifier("offline.toggle")
            HStack {
                ForEach(1...2, id: \.self) { number in
                    Button("Decide offline/\(number)") { Task { await decide(number) } }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("offline.decide.\(number)")
                }
            }
            if let result {
                ValueRow("source", result.source.label, id: "offline.source")
                ValueRow("hasAccess", "\(result.hasAccess(feature: "offline", property: "views"))", id: "offline.hasAccess")
                if result.decision == nil {
                    Text("No decision: hasAccess answered offline.failOpen, which this app sets to true.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            ValueRow("Queued counter updates", "\(showcase.queuedUpdates)", id: "offline.queued")
            if let flushResult {
                ValueRow("Last flush", "sent \(flushResult.sent), remaining \(flushResult.remaining)\(flushResult.failure.map { ", \($0.reason.rawValue)" } ?? "")", id: "offline.flush")
            }
            HStack {
                Button("Flush") { Task { await flush() } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("offline.flushButton")
                Button("Clear cache") { Task { await clearCache() } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("offline.clearCache")
            }
        }
    }

    private func decide(_ number: Int) async {
        let result = await showcase.mos.decide(resource: Resource(id: "offline/\(number)"), surface: "showcase-metered")
        self.result = result
        showcase.didDecide(result)
        lastCall = .decision(result, call: "decide(resource: \"offline/\(number)\", surface: \"showcase-metered\")")
    }

    /// Call it when the app comes to the foreground or connectivity returns. A network decision also flushes.
    private func flush() async {
        let result = await showcase.mos.flush()
        flushResult = result
        lastCall = .text("flush()", [
            "sent": .number(Double(result.sent)), "dropped": .number(Double(result.dropped)),
            "remaining": .number(Double(result.remaining)), "failure": result.failure?.json ?? .null,
        ])
    }

    private func clearCache() async {
        await showcase.mos.clearCache()
        lastCall = .text("clearCache()", ["cleared": true])
    }
}

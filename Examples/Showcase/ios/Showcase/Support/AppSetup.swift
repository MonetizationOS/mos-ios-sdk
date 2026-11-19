import Foundation
import MonetizationOS

extension Showcase {
    /// One MOS per app. Fixture mode swaps the transport; everything else is the real SDK.
    static func makeMOS(
        _ settings: ShowcaseSettings, offline: OfflineSwitch, logs: AsyncStream<LogEvent>.Continuation
    ) throws -> MOS {
        let base: any HTTPTransport = settings.mode == .fixture ? FixtureTransport() : URLSessionTransport()
        return try MOS(config: MOSConfig(
            publicKey: settings.effectivePublicKey,
            surface: "showcase",
            app: .init(name: "MOSShowcase", version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"),
            apiBaseURL: settings.effectiveApiBaseUrl,
            offline: .init(failOpen: true),
            onLog: { event in
                print(event)
                logs.yield(event)
            },
            transport: OfflineTransport(base: base, offline: offline)
        ))
    }
}

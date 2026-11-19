import Foundation
import Testing
@testable import MonetizationOS

@Suite("Per-call surface")
struct SurfaceTests {
    @Test("surface: an override sends its slug, caches under it and logs it; nil uses config.surface")
    func overrideSlug() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc")
        _ = await harness.mos.decide(resource: Resource(id: "article/1"), surface: "article-meter")
        await harness.mos.waitForBackgroundFlush()
        _ = await harness.decide("article/1")
        #expect(harness.transport.requests.map { $0.json["surfaceSlug"] } == ["article-meter", "app-paywall"])
        #expect(Set(harness.cache.entries.map(\.surface)) == ["article-meter", "app-paywall"])
        #expect(harness.logs.events("decision:start").map { $0.context["surface"] } == ["article-meter", "app-paywall"])
        #expect(harness.logs.events("decision:success").first?.context["surface"] == "article-meter")
    }

    @Test("surface: fallback-to-latest stays within the surface")
    func fallbackWithinSurface() async {
        let harness = Harness(
            anonymousIdentifier: "mos-anon-v1-abc", cached: [Decisions.entry(resourceId: "article/1", surface: "app-paywall")], handler: networkDown
        )
        let other = await harness.mos.decide(resource: Resource(id: "article/2"), surface: "article-meter")
        #expect(other.source == .unavailable)
        #expect(other.failure?.reason == .requestFailed)
        let own = await harness.mos.decide(resource: Resource(id: "article/2"))
        #expect(own.source == .fallback(ageMs: 0, fromResourceID: "article/1"))
        #expect(harness.logs.events("decision:fallback").first?.context["surface"] == "app-paywall")
    }

    @Test("surface: an empty surface fails with requestFailed without sending")
    func emptySurface() async {
        let calls = Box(0)
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", jwtProvider: {
            calls.set(calls.get() + 1)
            return nil
        }, cached: [Decisions.entry(surface: "")])
        for policy in [CachePolicy.networkFirst, .cacheOnly, .networkOnly, .cacheFirst(maxAge: .seconds(60))] {
            let result = await harness.mos.decide(resource: Resource(id: "article/1"), policy: policy, surface: "")
            #expect(result.source == .unavailable)
            #expect(result.decision == nil)
            #expect(result.failure?.reason == .requestFailed)
        }
        #expect(harness.transport.count == 0)
        #expect(calls.get() == 0)
        #expect(harness.logs.events("decision:error").first?.context["reason"] == "requestFailed")
    }
}

import Foundation
import Testing
@testable import MonetizationOS

@Suite("Cache policies and failOpen")
struct CachePolicyTests {
    private static let anon = "anon:mos-anon-v1-abc"

    private func makeHarness(cached: [DecisionCacheEntry] = [], fallbackToLatest: Bool = true, failOpen: Bool = true, handler: @escaping FakeTransport.Handler = networkDown) -> Harness {
        Harness(
            anonymousIdentifier: "mos-anon-v1-abc",
            offline: MOSConfig.Offline(failOpen: failOpen, fallbackToLatest: fallbackToLatest),
            now: TestTime.base + TestTime.hour,
            cached: cached,
            handler: handler
        )
    }

    @Test("networkFirst: success comes from the network")
    func networkFirstSuccess() async {
        let harness = makeHarness(handler: { _ in .json(Decisions.make()) })
        let result = await harness.decide("article/1")
        #expect(result.source == .network)
        #expect(result.failure == nil)
        #expect(result.decision?.eventID == "evt-1")
        #expect(harness.transport.count == 1)
    }

    @Test("networkFirst: on failure the exact entry serves, with the failure attached")
    func networkFirstServesExact() async {
        let harness = makeHarness(cached: [Decisions.entry(resourceId: "article/1", identityKey: Self.anon)])
        let result = await harness.decide("article/1")
        #expect(result.source == .cache(ageMs: TestTime.hour))
        #expect(result.failure?.reason == .requestFailed)
        #expect(harness.logs.count("decision:cache-hit") == 1)
    }

    @Test("networkFirst: with no exact entry the latest for this identity is the fallback")
    func networkFirstFallsBack() async {
        let harness = makeHarness(cached: [
            Decisions.entry(resourceId: "article/older", identityKey: Self.anon, storedAt: TestTime.base - TestTime.minute),
            Decisions.entry(resourceId: "article/newer", identityKey: Self.anon, storedAt: TestTime.base),
        ])
        let result = await harness.decide("article/9")
        #expect(result.source == .fallback(ageMs: TestTime.hour, fromResourceID: "article/newer"))
        #expect(result.failure?.reason == .requestFailed)
        #expect(harness.logs.events("decision:fallback").first?.context["fromResourceId"] == "article/newer")
    }

    @Test("networkFirst: fallbackToLatest = false gives unavailable")
    func networkFirstWithoutFallback() async {
        let harness = makeHarness(cached: [Decisions.entry(resourceId: "article/other", identityKey: Self.anon)], fallbackToLatest: false)
        let result = await harness.decide("article/9")
        #expect(result.source == .unavailable)
        #expect(result.decision == nil)
        #expect(result.failure?.reason == .requestFailed)
        #expect(harness.logs.count("decision:unavailable") == 1)
    }

    @Test("networkFirst: nothing cached gives unavailable with the failure")
    func networkFirstUnavailable() async {
        let result = await makeHarness().decide("article/1")
        #expect(result.source == .unavailable)
        #expect(result.failure?.reason == .requestFailed)
    }

    @Test("cacheFirst(maxAge): a fresh exact entry serves without touching the network")
    func cacheFirstFresh() async {
        let harness = makeHarness(cached: [Decisions.entry(resourceId: "article/1", identityKey: Self.anon)])
        let result = await harness.decide("article/1", policy: .cacheFirst(maxAge: .seconds(3_600)))
        #expect(result.source == .cache(ageMs: TestTime.hour))
        #expect(result.failure == nil)
        #expect(harness.transport.count == 0)
    }

    @Test("cacheFirst(maxAge): a huge maxAge saturates instead of trapping")
    func cacheFirstHugeMaxAge() async {
        let harness = makeHarness(cached: [Decisions.entry(resourceId: "article/1", identityKey: Self.anon)])
        let result = await harness.decide("article/1", policy: .cacheFirst(maxAge: .seconds(Int64.max)))
        #expect(result.source == .cache(ageMs: TestTime.hour))
        #expect(harness.transport.count == 0)
    }

    @Test("cacheFirst(maxAge): an older entry behaves as networkFirst")
    func cacheFirstStale() async {
        let cached = [Decisions.entry(resourceId: "article/1", identityKey: Self.anon)]
        let online = makeHarness(cached: cached, handler: { _ in .json(Decisions.make(eventId: "fresh")) })
        let result = await online.decide("article/1", policy: .cacheFirst(maxAge: .seconds(60)))
        #expect(result.source == .network)
        #expect(result.decision?.eventID == "fresh")
        #expect(online.transport.count == 1)

        let offline = makeHarness(cached: cached)
        let served = await offline.decide("article/1", policy: .cacheFirst(maxAge: .seconds(60)))
        #expect(served.source == .cache(ageMs: TestTime.hour))
        #expect(served.failure?.reason == .requestFailed)
        #expect(offline.transport.count == 1)
    }

    @Test("cacheOnly: exact, then fallback, then unavailable, never the network, never a failure")
    func cacheOnly() async {
        let harness = makeHarness(cached: [Decisions.entry(resourceId: "article/1", identityKey: Self.anon)], handler: { _ in .json(Decisions.make()) })
        let exact = await harness.decide("article/1", policy: .cacheOnly)
        #expect(exact.source == .cache(ageMs: TestTime.hour))
        #expect(exact.failure == nil)
        let fallback = await harness.decide("article/2", policy: .cacheOnly)
        #expect(fallback.source == .fallback(ageMs: TestTime.hour, fromResourceID: "article/1"))
        #expect(fallback.failure == nil)
        #expect(harness.transport.count == 0)

        let empty = makeHarness(handler: { _ in .json(Decisions.make()) })
        let unavailable = await empty.decide("article/1", policy: .cacheOnly)
        #expect(unavailable.source == .unavailable)
        #expect(unavailable.failure == nil)
        #expect(empty.transport.count == 0)
    }

    @Test("networkOnly: no cache read on failure, but the cache is written on success")
    func networkOnly() async {
        let harness = makeHarness(cached: [Decisions.entry(resourceId: "article/1", identityKey: Self.anon)])
        let failed = await harness.decide("article/1", policy: .networkOnly)
        #expect(failed.source == .unavailable)
        #expect(failed.failure?.reason == .requestFailed)
        #expect(harness.transport.count == 1)

        harness.transport.respond { _ in .json(Decisions.make(eventId: "fresh")) }
        let succeeded = await harness.decide("article/2", policy: .networkOnly)
        #expect(succeeded.source == .network)
        #expect(harness.cache.entries.contains { $0.resourceId == "article/2" && $0.decision["eventId"] == "fresh" })
    }

    @Test("failOpen true: hasAccess is true with no decision or a missing property; real values win")
    func failOpenTrue() async {
        let unavailable = await makeHarness(failOpen: true).decide("article/1")
        #expect(unavailable.hasAccess(feature: "article", property: "enabled"))

        let denied = Decisions.make(meters: [Decisions.Meter(hasAccess: false)])
        let decided = await makeHarness(failOpen: true, handler: { _ in .json(denied) }).decide("article/1")
        #expect(!decided.hasAccess(feature: "article", property: "enabled"))
        #expect(decided.hasAccess(feature: "article", property: "missing"))
        #expect(decided.hasAccess(feature: "missing", property: "enabled"))
    }

    @Test("A meterable without a counterId keeps its hasAccess, never failOpen")
    func meterableWithoutCounterId() async {
        // What a workflow that switches a property off returns: nothing to count, so no counterId.
        for hasAccess in [true, false] {
            let body = Decisions.make(meters: [Decisions.Meter(counterId: nil, hasAccess: hasAccess, consumedInRequest: false)])
            let decided = await makeHarness(failOpen: !hasAccess, handler: { _ in .json(body) }).decide("article/1")
            #expect(decided.hasAccess(feature: "article", property: "enabled") == hasAccess)
        }
    }

    @Test("failOpen false: hasAccess is false with no decision or a missing property")
    func failOpenFalse() async {
        let unavailable = await makeHarness(failOpen: false).decide("article/1")
        #expect(!unavailable.hasAccess(feature: "article", property: "enabled"))

        let granted = Decisions.make(meters: [Decisions.Meter(hasAccess: true)])
        let decided = await makeHarness(failOpen: false, handler: { _ in .json(granted) }).decide("article/1")
        #expect(decided.hasAccess(feature: "article", property: "enabled"))
        #expect(!decided.hasAccess(feature: "article", property: "missing"))
    }

    @Test("hasAccess reads boolean properties; a null boolean falls back to failOpen")
    func hasAccessBooleans() async {
        let harness = makeHarness(failOpen: false, handler: { _ in .fixture("decision-success.json") })
        let result = await harness.decide("article/1")
        #expect(result.hasAccess(feature: "article", property: "enabled"))
        #expect(!result.hasAccess(feature: "podcast", property: "enabled"))
        #expect(!result.hasAccess(feature: "article", property: "adsFree"))
        #expect(!result.hasAccess(feature: "article", property: "maxArticles"))
    }
}

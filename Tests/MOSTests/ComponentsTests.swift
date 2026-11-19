import Foundation
import Testing
@testable import MonetizationOS

@Suite("Component selection", .timeLimit(.minutes(1)))
struct ComponentsTests {
    static let decisionPath = "/api/v1/surface-decisions"

    @Test("components: sent sorted and deduplicated, [] sent as is, nil omitted")
    func requestBody() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc")
        _ = await harness.mos.decide(resource: Resource(id: "article/1"), components: ["paywall", "banner", "paywall"])
        _ = await harness.mos.decide(resource: Resource(id: "article/1"), components: [])
        _ = await harness.mos.decide(resource: Resource(id: "article/1"))
        let bodies = harness.transport.requests(to: Self.decisionPath).map(\.json)
        #expect(bodies.map { $0["components"] } == [.array(["banner", "paywall"]), .array([]), nil])
    }

    @Test("components: each selection has its own cache entry; order does not matter")
    func cachedPerSelection() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc")
        _ = await harness.mos.decide(resource: Resource(id: "article/1"), components: ["paywall", "banner"])
        #expect(harness.cache.entries.map(\.components) == [["banner", "paywall"]])

        let sameSet = await harness.mos.decide(resource: Resource(id: "article/1"), policy: .cacheOnly, components: ["banner", "paywall"])
        #expect(sameSet.source == .cache(ageMs: 0))
        for other in [nil, [], ["paywall"]] as [[String]?] {
            let result = await harness.mos.decide(resource: Resource(id: "article/1"), policy: .cacheOnly, components: other)
            #expect(result.source == .unavailable, "components: \(String(describing: other))")
        }

        _ = await harness.mos.decide(resource: Resource(id: "article/1"))
        #expect(Set(harness.cache.entries.map(\.components)) == [["banner", "paywall"], nil])
    }

    @Test("components: fallback-to-latest stays within the selection")
    func fallbackWithinSelection() async {
        let harness = Harness(
            anonymousIdentifier: "mos-anon-v1-abc",
            cached: [Decisions.entry(resourceId: "article/1", components: ["paywall"])],
            handler: networkDown
        )
        let same = await harness.mos.decide(resource: Resource(id: "article/2"), components: ["paywall"])
        #expect(same.source == .fallback(ageMs: 0, fromResourceID: "article/1"))
        for other in [nil, [], ["banner"]] as [[String]?] {
            let result = await harness.mos.decide(resource: Resource(id: "article/2"), components: other)
            #expect(result.source == .unavailable, "components: \(String(describing: other))")
        }
    }

    @Test("components: different selections send separate calls; the same set in another order joins")
    func coalescing() async {
        let gate = Gate()
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", handler: route(decision: { _ in
            await gate.wait()
            return .json(Decisions.make())
        }))
        async let all = harness.mos.decide(resource: Resource(id: "article/1"))
        async let paywall = harness.mos.decide(resource: Resource(id: "article/1"), components: ["paywall", "banner"])
        await waitUntil { harness.transport.requests(to: Self.decisionPath).count == 2 }
        async let reordered = harness.mos.decide(resource: Resource(id: "article/1"), components: ["banner", "paywall"])
        await waitUntil { harness.logs.count("decision:coalesced") == 1 }
        await gate.open()
        _ = await (all, paywall, reordered)
        #expect(harness.transport.requests(to: Self.decisionPath).count == 2)
    }

    @Test("components: the cache file names a selection and leaves it out when there is none")
    func persisted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mos-sdk-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let entries = [Decisions.entry(components: ["paywall"]), Decisions.entry(resourceId: "article/2")]
        FileDecisionCacheStore(directory: directory).save(entries)
        #expect(try FileDecisionCacheStore(directory: directory).load() == entries)
        let stored = JSONValue.parse(try Data(contentsOf: directory.appendingPathComponent("cache.json")))?["entries"]?.arrayValue
        #expect(stored?.map { $0["components"] } == [.array(["paywall"]), nil])
    }
}

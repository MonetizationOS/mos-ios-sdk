import Foundation
import Testing
@testable import MonetizationOS

@Suite("Coalescing and stale responses", .timeLimit(.minutes(1)))
struct CoalescingTests {
    static let decisionPath = "/api/v1/surface-decisions"
    static let redemptionPath = "/api/v1/offer-redemptions"

    @Test("coalescing: N concurrent identical decides make 1 transport call and all get the result")
    func identicalDecidesCoalesce() async {
        let gate = Gate()
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", handler: route(decision: { _ in
            await gate.wait()
            return .json(Decisions.make(eventId: "evt-shared"))
        }))
        let results = await withTaskGroup(of: DecisionResult.self) { group in
            for _ in 0..<5 {
                group.addTask { await harness.mos.decide(resource: Resource(id: "article/1"), properties: ["plan": "trial"]) }
            }
            await waitUntil { harness.logs.count("decision:coalesced") == 4 }
            await gate.open()
            return await group.reduce(into: [DecisionResult]()) { $0.append($1) }
        }
        await harness.mos.waitForBackgroundFlush()
        #expect(harness.transport.requests(to: Self.decisionPath).count == 1)
        #expect(results.count == 5)
        #expect(results.allSatisfy { $0.source == .network && $0.decision?.eventID == "evt-shared" })
        #expect(harness.logs.count("decision:start") == 1)
        #expect(harness.logs.count("cache:put") == 1)
        #expect(harness.logs.events("decision:coalesced").allSatisfy { $0.level == .debug })

        // The entry is gone once the request completes; the next call sends.
        await harness.decide("article/1", properties: ["plan": "trial"])
        #expect(harness.transport.requests(to: Self.decisionPath).count == 2)
    }

    @Test("coalescing: different properties or surfaces send separate calls")
    func differentPropertiesDoNotCoalesce() async {
        let gate = Gate()
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", handler: route(decision: { _ in
            await gate.wait()
            return .json(Decisions.make())
        }))
        async let first = harness.mos.decide(resource: Resource(id: "article/1"), properties: ["plan": "trial"])
        async let second = harness.mos.decide(resource: Resource(id: "article/1"), properties: ["plan": "paid"])
        async let third = harness.mos.decide(resource: Resource(id: "article/1"), properties: ["plan": "trial"], surface: "article-meter")
        await waitUntil { harness.transport.requests(to: Self.decisionPath).count == 3 }
        await gate.open()
        _ = await (first, second, third)
        #expect(harness.transport.requests(to: Self.decisionPath).count == 3)
        #expect(harness.logs.count("decision:coalesced") == 0)
    }

    @Test("coalescing: a joiner applies its own policy fallback to the shared failure")
    func joinerAppliesItsOwnPolicy() async {
        let gate = Gate()
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", cached: [Decisions.entry(resourceId: "article/1")], handler: { _ in
            await gate.wait()
            throw URLError(.notConnectedToInternet)
        })
        async let networkOnly = harness.mos.decide(resource: Resource(id: "article/1"), policy: .networkOnly)
        await waitUntil { harness.transport.count == 1 }
        async let networkFirst = harness.mos.decide(resource: Resource(id: "article/1"))
        await waitUntil { harness.logs.count("decision:coalesced") == 1 }
        await gate.open()
        let (leader, joiner) = await (networkOnly, networkFirst)
        #expect(harness.transport.count == 1)
        #expect(leader.source == .unavailable)
        #expect(joiner.source == .cache(ageMs: 0))
        #expect(leader.failure?.reason == .requestFailed)
        #expect(joiner.failure?.reason == .requestFailed)
    }

    @Test("coalescing: a redeem double-tap makes 1 call")
    func redeemDoubleTapCoalesces() async {
        let gate = Gate()
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", handler: { _ in
            await gate.wait()
            return .fixture("redemption-custom.json")
        })
        let token = Tokens.offer(expirationMsUtc: nil)
        async let first = harness.mos.redeem(offerToken: token)
        async let second = harness.mos.redeem(offerToken: token)
        await waitUntil { harness.logs.count("redeem:coalesced") == 1 }
        await gate.open()
        let (a, b) = await (first, second)
        #expect(a == b)
        guard case .redeemed(.custom(let type, _), _, _) = a else {
            Issue.record("expected a custom redemption, got \(a)")
            return
        }
        #expect(type == "custom:purchase")
        #expect(harness.transport.requests(to: Self.redemptionPath).count == 1)
        #expect(harness.logs.count("redeem:success") == 1)

        _ = await harness.mos.redeem(offerToken: token)
        #expect(harness.transport.requests(to: Self.redemptionPath).count == 2)
    }

    @Test("coalescing: cancelling the first caller neither cancels the shared request nor makes the joiner send again")
    func cancellingTheFirstCallerKeepsTheSharedRequest() async {
        let gate = Gate()
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", handler: route(decision: { _ in
            await gate.wait()
            return .json(Decisions.make(eventId: "evt-shared"))
        }))
        let first = Task { await harness.mos.decide(resource: Resource(id: "article/1")) }
        await waitUntil { harness.transport.count == 1 }
        let joiner = Task { await harness.mos.decide(resource: Resource(id: "article/1")) }
        await waitUntil { harness.logs.count("decision:coalesced") == 1 }
        first.cancel()
        await gate.open()
        let joined = await joiner.value
        _ = await first.value
        await harness.mos.waitForBackgroundFlush()
        #expect(joined.source == .network)
        #expect(joined.decision?.eventID == "evt-shared")
        #expect(harness.transport.requests(to: Self.decisionPath).count == 1)
        #expect(harness.cache.entries.count == 1)
    }

    @Test("stale responses: the pending link still clears when the identity moved on mid-flight")
    func linkClearsDespiteIdentityChange() async {
        let gate = Gate()
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", handler: route(decision: { _ in
            await gate.wait()
            return .json(Decisions.make(identifier: "user_42", isAuthenticated: true))
        }))
        await harness.mos.identify(userJWT: nil)
        await harness.mos.identify(userJWT: Tokens.jwt(sub: "user_42"))
        async let inFlight = harness.mos.decide(resource: Resource(id: "article/1"))
        await waitUntil { harness.transport.count == 1 }
        #expect(harness.transport.requests.first?.json["properties"] == ["platform": "ios", "previousAnonymousIdentifier": "mos-anon-v1-abc"])
        await harness.mos.identify(userJWT: Tokens.jwt(sub: "user_43"))
        await gate.open()
        let result = await inFlight

        #expect(result.linkedAnonymousIdentifier)
        #expect(harness.identity.pendingPreviousAnonymousIdentifier == nil)
        #expect(harness.logs.count("identity:previous-anon-sent") == 1)
        #expect(harness.logs.events("identity:stale-response").map(\.context) == [["reason": "identity-changed"]])
        #expect(harness.cache.entries.isEmpty)
    }

    @Test("linkedAnonymousIdentifier: of two in-flight decisions carrying the link, only the one that clears it reports true")
    func onlyTheClearingResultIsLinked() async {
        let first = Gate()
        let second = Gate()
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", handler: route(decision: { request in
            await (request.json["resource"]?["id"] == "article/1" ? first : second).wait()
            return .json(Decisions.make(identifier: "user_42", isAuthenticated: true))
        }))
        await harness.mos.identify(userJWT: nil)
        await harness.mos.identify(userJWT: Tokens.jwt(sub: "user_42"))
        async let one = harness.mos.decide(resource: Resource(id: "article/1"))
        async let two = harness.mos.decide(resource: Resource(id: "article/2"))
        await waitUntil { harness.transport.count == 2 }
        #expect(harness.transport.requests.allSatisfy { $0.json["properties"] == ["platform": "ios", "previousAnonymousIdentifier": "mos-anon-v1-abc"] })
        await second.open()
        await waitUntil { harness.identity.pendingPreviousAnonymousIdentifier == nil }
        await first.open()
        let (a, b) = await (one, two)
        #expect(!a.linkedAnonymousIdentifier)
        #expect(b.linkedAnonymousIdentifier)
        #expect(harness.logs.count("identity:previous-anon-sent") == 1)
    }

    @Test("linkedAnonymousIdentifier: coalesced decides share the result but only the sender reports the link")
    func onlyTheSenderOfACoalescedLinkReportsIt() async {
        let gate = Gate()
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", handler: route(decision: { _ in
            await gate.wait()
            return .json(Decisions.make(identifier: "user_42", isAuthenticated: true))
        }))
        await harness.mos.identify(userJWT: nil)
        await harness.mos.identify(userJWT: Tokens.jwt(sub: "user_42"))
        let results = await withTaskGroup(of: DecisionResult.self) { group in
            for _ in 0..<3 {
                group.addTask { await harness.mos.decide(resource: Resource(id: "article/1")) }
            }
            await waitUntil { harness.logs.count("decision:coalesced") == 2 }
            await gate.open()
            return await group.reduce(into: [DecisionResult]()) { $0.append($1) }
        }
        #expect(harness.transport.requests(to: Self.decisionPath).count == 1)
        #expect(results.filter(\.linkedAnonymousIdentifier).count == 1)
    }

    @Test("stale responses: after a reset mid-flight the link is not reported as delivered")
    func linkNotDeliveredAcrossReset() async {
        let gate = Gate()
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", handler: route(decision: { _ in
            await gate.wait()
            return .json(Decisions.make(identifier: "user_42", isAuthenticated: true))
        }))
        await harness.mos.identify(userJWT: nil)
        await harness.mos.identify(userJWT: Tokens.jwt(sub: "user_42"))
        async let inFlight = harness.mos.decide(resource: Resource(id: "article/1"))
        await waitUntil { harness.transport.count == 1 }
        await harness.mos.reset()
        await gate.open()
        let result = await inFlight
        #expect(result.source == .network)
        #expect(!result.linkedAnonymousIdentifier)
        #expect(harness.logs.count("identity:previous-anon-sent") == 0)
    }

    @Test("coalescing never spans a reset")
    func coalescingNeverSpansReset() async {
        let gate = Gate()
        let jwt = Tokens.jwt(sub: "user_42")
        let harness = Harness(jwtProvider: { jwt }, handler: route(decision: { _ in
            await gate.wait()
            return .json(Decisions.make(identifier: "user_42", isAuthenticated: true))
        }))
        async let before = harness.mos.decide(resource: Resource(id: "article/1"))
        await waitUntil { harness.transport.count == 1 }
        await harness.mos.reset()
        async let after = harness.mos.decide(resource: Resource(id: "article/1"))
        await waitUntil { harness.transport.count == 2 }
        await gate.open()
        _ = await (before, after)
        #expect(harness.transport.requests(to: Self.decisionPath).count == 2)
        #expect(harness.transport.requests[0].body == harness.transport.requests[1].body)
        #expect(harness.logs.count("decision:coalesced") == 0)
    }

    @Test("stale responses: identity switched mid-flight, result returned, nothing cached or persisted")
    func identitySwitchedMidFlight() async {
        let gate = Gate()
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", queued: [Decisions.queued()], handler: route(decision: { _ in
            await gate.wait()
            return .json(Decisions.make(identifier: "mos-anon-v1-reminted", eventId: "evt-stale"))
        }))
        async let inFlight = harness.mos.decide(resource: Resource(id: "article/1"))
        await waitUntil { harness.transport.count == 1 }
        await harness.mos.identify(userJWT: Tokens.jwt(sub: "user_42"))
        await gate.open()
        let result = await inFlight
        await harness.mos.waitForBackgroundFlush()

        #expect(result.source == .network)
        #expect(result.decision?.eventID == "evt-stale")
        #expect(harness.cache.entries.isEmpty)
        #expect(harness.identity.anonymousIdentifier == "mos-anon-v1-abc")
        #expect(harness.transport.requests(to: "/api/v1/counter-updates").isEmpty)
        #expect(harness.logs.events("identity:stale-response").map(\.context) == [["reason": "identity-changed"]])
        #expect(harness.logs.events("identity:stale-response").first?.level == .debug)
        #expect(harness.logs.count("identity:anon-persisted") == 0)
    }

    @Test("stale responses: a second concurrent mint is returned but neither persisted nor cached")
    func secondConcurrentMintNotPersisted() async {
        let first = Gate()
        let second = Gate()
        let harness = Harness(handler: route(decision: { request in
            if request.json["resource"]?["id"] == "article/1" {
                await first.wait()
                return .json(Decisions.make(identifier: "mos-anon-v1-first"))
            }
            await second.wait()
            return .json(Decisions.make(identifier: "mos-anon-v1-second"))
        }))
        async let one = harness.mos.decide(resource: Resource(id: "article/1"))
        async let two = harness.mos.decide(resource: Resource(id: "article/2"))
        await waitUntil { harness.transport.count == 2 }
        #expect(harness.transport.requests.allSatisfy { $0.json["identity"] == ["createAnonymousIdentifier": true] })
        await first.open()
        await waitUntil { harness.identity.anonymousIdentifier != nil }
        await second.open()
        let (a, b) = await (one, two)
        await harness.mos.waitForBackgroundFlush()

        #expect(a.decision?.identity.identifier == "mos-anon-v1-first")
        #expect(b.decision?.identity.identifier == "mos-anon-v1-second")
        #expect(b.source == .network)
        #expect(harness.identity.anonymousIdentifier == "mos-anon-v1-first")
        #expect(harness.cache.entries.map(\.identityKey) == ["anon:mos-anon-v1-first"])
        #expect(harness.cache.entries.map(\.resourceId) == ["article/1"])
        #expect(harness.logs.events("identity:stale-response").map(\.context) == [["reason": "anonymous-already-stored"]])
    }

    @Test("stale responses: reset mid-flight persists and caches nothing")
    func resetMidFlight() async {
        let gate = Gate()
        let harness = Harness(handler: route(decision: { _ in
            await gate.wait()
            return .json(Decisions.make())
        }))
        async let inFlight = harness.mos.decide(resource: Resource(id: "article/1"))
        await waitUntil { harness.transport.count == 1 }
        await harness.mos.reset()
        await gate.open()
        let result = await inFlight
        #expect(result.source == .network)
        #expect(harness.identity.anonymousIdentifier == nil)
        #expect(harness.identity.lastIdentityKey == nil)
        #expect(harness.cache.entries.isEmpty)
        #expect(harness.logs.events("identity:stale-response").map(\.context) == [["reason": "reset"]])
    }
}

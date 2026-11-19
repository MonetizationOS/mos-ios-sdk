import Foundation
import Testing
@testable import MonetizationOS

@Suite("Decision cache")
struct CacheTests {
    @Test("cache put after every successful network decision")
    func cachePut() async throws {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc")
        await harness.decide("article/1")
        let entry = try #require(harness.cache.entries.first)
        #expect(entry.surface == "app-paywall")
        #expect(entry.identityKey == "anon:mos-anon-v1-abc")
        #expect(entry.resourceId == "article/1")
        #expect(entry.decision["eventId"] == "evt-1")
        #expect(entry.storedAt == TestTime.base)
        #expect(entry.expiresAt == TestTime.base + TestTime.day)
        #expect(harness.logs.count("cache:put") == 1)

        harness.clock.advance(ms: 5_000)
        let served = await harness.decide("article/1", policy: .cacheOnly)
        #expect(served.source == .cache(ageMs: 5_000))
        #expect(served.decision?.eventID == "evt-1")
    }

    @Test("the cached decision drops identity.jwtClaims; the network result keeps them")
    func cacheDropsClaims() async throws {
        let harness = Harness(jwtProvider: { Tokens.jwt(sub: "user_42") }, handler: { _ in .fixture("decision-success-authenticated.json") })
        let result = await harness.decide("article/1")
        #expect(result.decision?.identity.jwtClaims["sub"] == "user_42")
        let entry = try #require(harness.cache.entries.first)
        #expect(entry.decision["identity"]?["jwtClaims"] == nil)
        #expect(entry.decision["identity"]?["isAuthenticated"] == true)
    }

    @Test("a JWT request answered anonymously is returned but neither cached nor metered: the signed-in user's entry and counts stay")
    func anonymousAnswerToJWTIsNotCached() async {
        let token = Tokens.jwt(sub: "user_42")
        let meter = Decisions.Meter(consumedUnits: 1, totalUnits: 100, uniqueResources: true)
        let harness = Harness(jwtProvider: { token }, handler: { _ in
            .json(Decisions.make(identifier: "user_42", isAuthenticated: true, meters: [meter], surfaceProperties: ["plan": "subscriber"]))
        })
        await harness.decide()
        let entries = harness.cache.entries
        let ledger = harness.meters.entries

        // The token expired: the server answers as a fresh anonymous user.
        var anonymousMeter = meter
        anonymousMeter.totalUnits = 3
        let anonymous = anonymousMeter
        harness.transport.respond { _ in
            .json(Decisions.make(identifier: "mos-anon-v1-fresh", isAuthenticated: false, meters: [anonymous], surfaceProperties: ["plan": "anonymous"]))
        }
        let answered = await harness.decide()
        #expect(answered.source == .network)
        #expect(answered.decision?.surfaceProperties["plan"] == "anonymous")
        #expect(harness.cache.entries == entries)
        #expect(harness.meters.entries == ledger)
        let skipped = harness.logs.events("cache:skipped")
        #expect(skipped.map(\.context) == [["reason": "anonymous-answer", "surface": "app-paywall"]])
        #expect(skipped.first?.level == .debug)

        harness.transport.respond(networkDown)
        let offline = await harness.decide()
        #expect(offline.source == .cache(ageMs: 0))
        #expect(offline.decision?.identity.isAuthenticated == true)
        #expect(offline.decision?.surfaceProperties["plan"] == "subscriber")
    }

    @Test("ttl expiry: an expired entry is never served and is evicted on read")
    func ttlExpiry() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", offline: MOSConfig.Offline(ttl: .seconds(3_600)))
        await harness.decide("article/1")
        #expect(harness.cache.entries.first?.expiresAt == TestTime.base + TestTime.hour)

        harness.clock.advance(ms: TestTime.hour - 1)
        #expect(await harness.decide("article/1", policy: .cacheOnly).source == .cache(ageMs: TestTime.hour - 1))

        harness.clock.advance(ms: 1)
        let expired = await harness.decide("article/1", policy: .cacheOnly)
        #expect(expired.source == .unavailable)
        #expect(harness.cache.entries.isEmpty)
        #expect(harness.logs.events("cache:evicted").last?.context == ["count": 1, "reason": "expired"])
    }

    @Test("a huge ttl saturates instead of trapping: the entry never expires")
    func hugeTtlSaturates() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", offline: MOSConfig.Offline(ttl: .seconds(Int64.max)))
        await harness.decide("article/1")
        #expect(harness.cache.entries.first?.expiresAt == Int64.max)
        harness.clock.advance(ms: 365 * TestTime.day)
        #expect(await harness.decide("article/1", policy: .cacheOnly).decision != nil)
        #expect(Duration.seconds(Int64.max).milliseconds == Int64.max)
        #expect(Duration.seconds(Int64.min).milliseconds == Int64.min)
        #expect(Duration.saturatingMilliseconds(seconds: .infinity) == Int64.max)
        #expect(Duration.saturatingMilliseconds(seconds: 1e30) == Int64.max)
        #expect(Duration.saturatingMilliseconds(seconds: 1.5) == 1_500)
    }

    @Test("offer-token expiry shortens the entry; null and non-token strings are ignored")
    func offerTokenExpiryShortening() async {
        let soon = TestTime.base + 10 * TestTime.minute
        let decision = Decisions.make(offerTokens: [
            Tokens.offer(expirationMsUtc: TestTime.base + 2 * TestTime.day),
            Tokens.offer(expirationMsUtc: nil),
            "not.a.jwt",
        ], surfaceProperties: ["banner": ["offer": ["token": .string(Tokens.offer(expirationMsUtc: soon))]]])
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", handler: { _ in .json(decision) })

        await harness.decide("article/1")
        #expect(harness.cache.entries.first?.expiresAt == soon)

        harness.clock.advance(ms: 10 * TestTime.minute - 1)
        #expect(await harness.decide("article/1", policy: .cacheOnly).decision != nil)
        harness.clock.advance(ms: 1)
        #expect(await harness.decide("article/1", policy: .cacheOnly).source == .unavailable)
    }

    @Test("an offer token later than the ttl leaves the ttl in charge")
    func offerTokenLaterThanTtl() {
        let decision = Decisions.make(offerTokens: [Tokens.offer(expirationMsUtc: TestTime.base + 3 * TestTime.day)])
        #expect(DecisionCache.expiresAt(storedAt: TestTime.base, ttlMs: TestTime.day, decision: decision) == TestTime.base + TestTime.day)
    }

    @Test("offer tokens a web experience redeems, by href or data-mos-redeem, shorten the entry too")
    func markupOfferTokenExpiry() async {
        let soon = TestTime.base + 10 * TestTime.minute
        let web = { (html: String) in Decisions.make(surfaceProperties: ["paywall": [["type": "html", "content": .string(html)]]]) }
        let href = web("<a href=\"mos://redeem?token=\(Tokens.offer(expirationMsUtc: soon))\">Buy</a>")
        let attribute = web("<button data-mos-redeem=\"\(Tokens.offer(expirationMsUtc: soon))\">Buy</button>")
        for decision in [href, attribute] {
            #expect(DecisionCache.expiresAt(storedAt: TestTime.base, ttlMs: TestTime.day, decision: decision) == soon)
        }

        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", handler: { _ in .json(href) })
        await harness.decide("article/1")
        #expect(harness.cache.entries.first?.expiresAt == soon)
        harness.clock.advance(ms: 10 * TestTime.minute)
        #expect(await harness.decide("article/1", policy: .cacheOnly).source == .unavailable)
    }

    @Test("max entries evicts the oldest storedAt")
    func maxEntries() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", offline: MOSConfig.Offline(maxEntries: 2))
        for resource in ["article/1", "article/2", "article/3"] {
            await harness.decide(resource)
            harness.clock.advance(ms: 1_000)
        }
        #expect(harness.cache.entries.map(\.resourceId).sorted() == ["article/2", "article/3"])
        #expect(harness.logs.events("cache:evicted").last?.context == ["count": 1, "reason": "max-entries"])

        // Re-deciding a cached resource replaces its entry instead of growing the cache.
        await harness.decide("article/3")
        #expect(harness.cache.entries.map(\.resourceId).sorted() == ["article/2", "article/3"])
    }

    @Test("per-identity isolation: an entry cached for anon:x is never served to jwt:y")
    func perIdentityIsolation() async {
        let entry = Decisions.entry(resourceId: "article/1", identityKey: "anon:x")
        let jwt = Tokens.jwt(sub: "user_42")

        let asJwt = Harness(jwtProvider: { jwt }, cached: [entry], handler: networkDown)
        let cacheOnly = await asJwt.decide("article/1", policy: .cacheOnly)
        #expect(cacheOnly.source == .unavailable)
        let networkFirst = await asJwt.decide("article/1")
        #expect(networkFirst.source == .unavailable)
        #expect(networkFirst.failure?.reason == .requestFailed)

        let asAnon = Harness(anonymousIdentifier: "x", cached: [entry], handler: networkDown)
        #expect(await asAnon.decide("article/1", policy: .cacheOnly).source == .cache(ageMs: 0))
    }

    @Test("the cache is per surface")
    func perSurface() async {
        let entry = Decisions.entry(resourceId: "article/1", identityKey: "anon:x", surface: "other-surface")
        let harness = Harness(anonymousIdentifier: "x", cached: [entry])
        #expect(await harness.decide("article/1", policy: .cacheOnly).source == .unavailable)
        #expect(await harness.mos.decide(resource: Resource(id: "article/1"), policy: .cacheOnly, surface: "other-surface").source == .cache(ageMs: 0))
        #expect(harness.transport.count == 0)
    }
}

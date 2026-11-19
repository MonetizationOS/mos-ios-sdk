import Foundation
import Testing
@testable import MonetizationOS

/// Asserts what fixtures/README.md says about each shared fixture.
@Suite("Conformance fixtures")
struct ConformanceTests {
    private static let covered: Set<String> = [
        "decision-success.json", "decision-success-paywalled.json", "decision-success-jwt-fallback.json",
        "decision-success-authenticated.json", "decision-success-minimal.json",
        "error-400.json", "error-401.json", "error-402.json", "error-404.json", "error-429.json", "error-531.json",
        "redemption-navigate.json", "redemption-custom.json", "redemption-custom-bare.json", "redemption-none.json",
        "redemption-failure.json",
        "counter-update-success.json", "offer-tokens.json", "offer-tokens-markup.json", "invalid-json.txt",
    ]

    private func decision(_ name: String) throws -> Decision {
        guard let decision = Decision(json: Fixtures.json(name)) else { throw FixtureError.notADecision }
        return decision
    }

    private func meterable(_ property: Property?) throws -> Meterable {
        guard case .meterable(let meterable) = property else { throw FixtureError.notMeterable }
        return meterable
    }

    private enum FixtureError: Error { case notADecision, notMeterable }

    /// Serves `fixture` from the cache for `resourceId` and returns what that queued.
    private func queuedByCacheServe(_ fixture: String, identityKey: String = "anon:mos-anon-v1-abc", resourceId: String = "article/999") async -> [QueuedCounterUpdate] {
        let entry = Decisions.entry(
            resourceId: resourceId, identityKey: identityKey, decision: Fixtures.json(fixture),
            storedAt: TestTime.before2020, expiresAt: TestTime.before2020 + TestTime.day
        )
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", now: TestTime.before2020, cached: [entry])
        let result = await harness.decide(resourceId, policy: .cacheOnly)
        #expect(result.source == .cache(ageMs: 0))
        return harness.queue.entries
    }

    @Test("every fixture file is loaded by a conformance test")
    func everyFixtureCovered() {
        #expect(Set(Fixtures.fileNames) == Self.covered)
    }

    @Test("decision-success.json")
    func decisionSuccess() async throws {
        let decision = try decision("decision-success.json")
        #expect(decision.eventID == "11111111-1111-4111-8111-111111111111")
        #expect(decision.identity.isAuthenticated == false)
        #expect(decision.identity.identifier == "mos-anon-v1-abc")

        let article = try #require(decision.features["article"])
        let enabled = try meterable(article.properties["enabled"])
        #expect(enabled.counterID == "default:feat_article.enabled")
        #expect(enabled.hasAccess == true)
        #expect(enabled.consumedInRequest == true)
        #expect(enabled.consumedUnitsInRequest == 1)
        #expect(enabled.uniqueResources == true)
        #expect(enabled.remainingUnits == 2)
        #expect(article.properties["maxArticles"] == .number(3, isFallback: false))
        #expect(article.properties["tier"] == .string("free", isFallback: true))
        #expect(article.properties["adsFree"] == .boolean(nil, isFallback: false))
        guard case .unknown(let type, let raw) = article.properties["future"] else {
            Issue.record("future should decode as unknown")
            return
        }
        #expect(type == "gauge")
        #expect(raw["value"] == 42)

        let podcast = try meterable(decision.features["podcast"]?.properties["enabled"])
        #expect(podcast.hasAccess == false)
        #expect(podcast.consumedUnits == nil && podcast.remainingUnits == nil && podcast.totalUnits == nil)
        #expect(podcast.consumedUnitsInRequest == nil && podcast.excessUnitsInRequest == nil)
        #expect(decision.surfaceProperties["entitled"] == false)

        let tokens = OfferTokens.discover(in: decision.raw)
        #expect(tokens.count == 3)
        #expect(tokens.compactMap(\.expirationMsUtc).sorted() == [1_577_836_800_000, 1_893_456_000_000])
        #expect(tokens.filter { $0.expirationMsUtc == nil }.count == 1)
        let homeTokens = OfferTokens.discover(in: ["componentBehaviors": .object(["home": decision.raw["componentBehaviors"]!["home"]!])])
        #expect(homeTokens == [OfferTokenPayload(expirationMsUtc: 1_577_836_800_000)])
        #expect(OfferTokens.decode("not.a.jwt") == nil)

        // Expiry is min(t + 24h, 1577836800000): already expired at any time after 2020-01-01.
        let t = TestTime.base
        #expect(DecisionCache.expiresAt(storedAt: t, ttlMs: TestTime.day, decision: decision.raw) == 1_577_836_800_000)
        let harness = Harness(now: t, handler: { _ in .fixture("decision-success.json") })
        await harness.decide("article/1")
        #expect(harness.identity.anonymousIdentifier == "mos-anon-v1-abc")
        #expect(harness.cache.entries.first?.expiresAt == 1_577_836_800_000)
        #expect(await harness.decide("article/1", policy: .cacheOnly).source == .unavailable)

        let queued = await queuedByCacheServe("decision-success.json")
        #expect(queued.map { [$0.counterId, $0.resourceId] } == [["default:feat_article.enabled", "article/999"]])
        #expect(queued.map(\.update) == [1])
    }

    @Test("decision-success-paywalled.json")
    func decisionPaywalled() async throws {
        let decision = try decision("decision-success-paywalled.json")
        let enabled = try meterable(decision.features["article"]?.properties["enabled"])
        #expect(enabled.hasAccess == false)
        #expect(enabled.consumedInRequest == false)
        #expect(enabled.excessUnitsInRequest == 1)
        #expect(decision.componentsSkipped == true)
        #expect(OfferTokens.discover(in: decision.raw) == [OfferTokenPayload(expirationMsUtc: 1_893_456_000_000)])
        #expect(await queuedByCacheServe("decision-success-paywalled.json").isEmpty)
    }

    @Test("decision-success-jwt-fallback.json")
    func decisionJwtFallback() async {
        let harness = Harness(jwtProvider: { Tokens.jwt(sub: "user_42") }, handler: { _ in .fixture("decision-success-jwt-fallback.json") })
        await harness.decide()
        #expect(harness.transport.requests.first?.json["identity"]?["userJwt"] != nil)
        #expect(harness.identity.anonymousIdentifier == "mos-anon-v1-minted")
    }

    @Test("decision-success-authenticated.json")
    func decisionAuthenticated() async throws {
        let decision = try decision("decision-success-authenticated.json")
        #expect(decision.identity.isAuthenticated == true)
        #expect(decision.identity.jwtClaims["sub"] == "user_42")
        #expect(decision.customer.hasProducts == true)
        #expect(decision.customer.customerIdentifiers.count == 2)
        let enabled = try meterable(decision.features["article"]?.properties["enabled"])
        #expect(enabled.uniqueResources == false)
        #expect(enabled.consumedUnitsInRequest == 2)

        let harness = Harness(jwtProvider: { Tokens.jwt(sub: "user_42") }, handler: { _ in .fixture("decision-success-authenticated.json") })
        await harness.decide()
        #expect(harness.identity.anonymousIdentifier == nil)

        let queued = await queuedByCacheServe("decision-success-authenticated.json")
        #expect(queued.map(\.update) == [2])
    }

    @Test("decision-success-minimal.json")
    func decisionMinimal() throws {
        let decision = try decision("decision-success-minimal.json")
        #expect(decision.raw["identity"]?["jwtClaims"] == nil)
        #expect(decision.identity.jwtClaims == [:])
        #expect(decision.surfaceBehavior == [:])
        #expect(decision.surfaceProperties == [:])
        #expect(decision.features.isEmpty)
        #expect(OfferTokens.discover(in: decision.raw).isEmpty)
    }

    static let errorFixtures: [(String, Int, Failure.Reason)] = [
        ("error-400.json", 400, .apiError), ("error-401.json", 401, .unauthorized), ("error-402.json", 402, .apiError),
        ("error-404.json", 404, .apiError), ("error-429.json", 429, .rateLimited), ("error-531.json", 531, .apiError),
    ]

    @Test("error-*.json decode as the error envelope and map to their failure, on their status or on a 200")
    func errorFixtures() async {
        for (fixture, statusCode, reason) in Self.errorFixtures {
            let envelope = Fixtures.json(fixture)
            #expect(envelope["status"] == "error")
            #expect(envelope["statusCode"]?.intValue == statusCode)
            for httpStatus in [statusCode, 200] {
                let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", handler: { _ in .fixture(fixture, status: httpStatus) })
                let failure = await harness.decide().failure
                #expect(failure?.reason == reason, "\(fixture) on HTTP \(httpStatus)")
                #expect(failure?.statusCode == statusCode)
                #expect(failure?.status == httpStatus)
                #expect(failure?.message == envelope["message"]?.stringValue)
                #expect(harness.transport.count == 1)
            }
        }
    }

    @Test("redemption-*.json map to redeemed, declined and their actions")
    func redemptionFixtures() {
        let response = { (name: String, status: Int) in MOS.redemptionResult(HTTPResponse(status: status, body: Fixtures.data(name))) }
        #expect(response("redemption-navigate.json", 200) == .redeemed(
            action: .navigate(url: URL(string: "https://example.com/post-checkout")!, properties: ["plan": "monthly"]),
            eventID: "66666666-6666-4666-8666-666666666666", statusCode: 200
        ))
        guard case .redeemed(.custom(let type, let properties), _, _) = response("redemption-custom.json", 200) else {
            Issue.record("redemption-custom.json should be a custom action")
            return
        }
        #expect(type == "custom:purchase")
        #expect(properties["productId"] == "com.example.monthly")
        guard case .redeemed(.custom(let bareType, let bareProperties), _, _) = response("redemption-custom-bare.json", 200) else {
            Issue.record("redemption-custom-bare.json should be a custom action")
            return
        }
        #expect(bareType == "custom")
        #expect(bareProperties["productId"] == "com.example.annual")
        guard case .redeemed(.noAction(properties: _), _, _) = response("redemption-none.json", 200) else {
            Issue.record("redemption-none.json should be a none action")
            return
        }
        // The server sends a decline with the body's statusCode as the HTTP status.
        #expect(response("redemption-failure.json", 409) == .declined(message: "Already redeemed", statusCode: 409, eventID: "99999999-9999-4999-8999-999999999999"))
    }

    @Test("counter-update-success.json with HTTP 200 counts as sent")
    func counterUpdateSuccess() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", queued: [Decisions.queued()], handler: { _ in .fixture("counter-update-success.json") })
        #expect(await harness.mos.flush() == FlushResult(sent: 1, dropped: 0, remaining: 0, failure: nil))
    }

    @Test("an offer token expiry beyond Int64 saturates instead of trapping, as on Android")
    func offerTokenExpirySaturates() {
        let decode = { (value: Double) in OfferTokens.decode(Tokens.make(payload: ["expirationMsUtc": .number(value)])) }
        #expect(decode(1e19) == OfferTokenPayload(expirationMsUtc: .max))
        #expect(decode(-1e19) == OfferTokenPayload(expirationMsUtc: .min))
        #expect(decode(1_893_456_000_000) == OfferTokenPayload(expirationMsUtc: 1_893_456_000_000))
        let offer = Offer(json: ["id": "o", "token": .string(Tokens.make(payload: ["expirationMsUtc": .number(1e19)]))])
        #expect(offer?.expiresAt != nil)
    }

    @Test("offer-tokens.json: future, expired, noExpiry decode; garbage, twoParts, badPayload are not tokens")
    func offerTokenFixtures() throws {
        let tokens = Fixtures.json("offer-tokens.json")
        let decode = { (name: String) in OfferTokens.decode(tokens[name]!.stringValue!) }
        #expect(decode("future") == OfferTokenPayload(expirationMsUtc: 1_893_456_000_000))
        #expect(decode("expired") == OfferTokenPayload(expirationMsUtc: 1_577_836_800_000))
        #expect(decode("noExpiry") == OfferTokenPayload(expirationMsUtc: nil))
        #expect(decode("garbage") == nil)
        #expect(decode("twoParts") == nil)
        #expect(decode("badPayload") == nil)
    }

    @Test("offer-tokens-markup.json: each case's markup yields exactly its tokens, in order")
    func markupOfferTokenFixtures() throws {
        let cases = try #require(Fixtures.json("offer-tokens-markup.json").arrayValue)
        #expect(!cases.isEmpty)
        for item in cases {
            let expected = try #require(item["tokens"]?.arrayValue).compactMap(\.stringValue)
            #expect(OfferTokens.markupTokens(in: try #require(item["markup"]?.stringValue)) == expected, "\(item["case"]?.stringValue ?? "")")
        }
    }

    @Test("invalid-json.txt: httpError on 502, invalidJSON on 200, the cache serves, one transport call")
    func invalidJsonFixture() async {
        for (status, reason) in [(502, Failure.Reason.httpError), (200, .invalidJSON)] {
            let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", cached: [Decisions.entry()], handler: { _ in .fixture("invalid-json.txt", status: status) })
            let result = await harness.decide("article/1")
            #expect(result.failure?.reason == reason)
            #expect(result.failure?.status == status)
            #expect(result.source == .cache(ageMs: 0))
            #expect(harness.transport.count == 1)
        }
    }
}

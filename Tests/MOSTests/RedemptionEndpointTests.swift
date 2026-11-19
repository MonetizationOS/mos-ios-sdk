import Foundation
import Testing
@testable import MonetizationOS

@Suite("Redemption and endpoints")
struct RedemptionEndpointTests {
    private let offerToken = Tokens.offer(expirationMsUtc: TestTime.base + TestTime.day)

    @Test("redeem: success maps navigate, custom (bare or custom:*) and none actions")
    func redeemActions() async {
        let cases: [(String, Action)] = [
            ("redemption-navigate.json", .navigate(url: URL(string: "https://example.com/post-checkout")!, properties: ["plan": "monthly"])),
            ("redemption-custom.json", .custom(type: "custom:purchase", properties: ["productId": "com.example.monthly", "promoSignature": "abc"])),
            ("redemption-custom-bare.json", .custom(type: "custom", properties: ["productId": "com.example.annual"])),
            ("redemption-none.json", .noAction(properties: [:])),
        ]
        for (fixture, action) in cases {
            let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", handler: { _ in .fixture(fixture) })
            let result = await harness.mos.redeem(offerToken: offerToken)
            let eventID = Fixtures.json(fixture)["eventId"]?.stringValue
            #expect(result == .redeemed(action: action, eventID: eventID, statusCode: 200))
            #expect(harness.logs.count("redeem:success") == 1)
        }
    }

    @Test("redeem: status failure is declined")
    func redeemDeclined() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", handler: { _ in .fixture("redemption-failure.json", status: 409) })
        let result = await harness.mos.redeem(offerToken: offerToken)
        #expect(result == .declined(message: "Already redeemed", statusCode: 409, eventID: "99999999-9999-4999-8999-999999999999"))
        #expect(harness.logs.count("redeem:declined") == 1)
    }

    @Test("redeem: an error envelope, HTTP or JSON failure is failed, and never retried")
    func redeemFailed() async {
        let cases: [(HTTPResponse, Failure.Reason)] = [
            (.fixture("error-400.json", status: 400), .apiError),
            (.fixture("error-531.json", status: 531), .apiError),
            (.fixture("error-400.json"), .apiError),
            (.fixture("invalid-json.txt", status: 502), .httpError),
            (.fixture("invalid-json.txt"), .invalidJSON),
            (.json(["status": "pending"]), .invalidResponse),
        ]
        for (response, reason) in cases {
            let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", handler: { _ in response })
            guard case .failed(let failure) = await harness.mos.redeem(offerToken: offerToken) else {
                Issue.record("expected a failure for \(reason)")
                continue
            }
            #expect(failure.reason == reason)
            #expect(harness.transport.count == 1)
            #expect(harness.cache.entries.isEmpty)
            #expect(harness.logs.count("redeem:error") == 1)
        }
        let down = Harness(anonymousIdentifier: "mos-anon-v1-abc", handler: networkDown)
        #expect(await down.mos.redeem(offerToken: offerToken) == .failed(Failure(reason: .requestFailed, message: "The request failed: \(URLError(.notConnectedToInternet).localizedDescription)")))
        #expect(down.transport.count == 1)
    }

    @Test("redeem: redeemed clears the decision cache as clearCache() does; declined and failed leave it", arguments: [
        ("redemption-none.json", 200, true), ("redemption-custom.json", 200, true), ("redemption-navigate.json", 200, true),
        ("redemption-failure.json", 409, false), ("error-400.json", 400, false),
    ])
    func redeemClearsCache(fixture: String, status: Int, clears: Bool) async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", handler: { request in
            request.url.path == "/api/v1/offer-redemptions" ? .fixture(fixture, status: status) : .json(Decisions.make(meters: [Decisions.Meter(consumedUnits: 1, totalUnits: 3)]))
        })
        let policy = CachePolicy.cacheFirst(maxAge: .seconds(300))
        #expect(await harness.decide(policy: policy).source == .network)
        let ledger = harness.meters.entries
        #expect(!ledger.isEmpty)
        _ = await harness.mos.redeem(offerToken: offerToken)
        #expect(harness.cache.entries.isEmpty == clears)
        #expect(harness.logs.events("cache:cleared").map(\.context) == (clears ? [["reason": "entitlements-changed"]] : []))
        #expect(harness.meters.entries == ledger)

        let again = await harness.decide(policy: policy)
        #expect(again.source == (clears ? .network : .cache(ageMs: 0)))
        #expect(harness.transport.requests(to: "/api/v1/surface-decisions").count == (clears ? 2 : 1))
    }

    @Test("redeem: a decision in flight while an offer is redeemed is returned but not cached")
    func redeemDropsInFlightDecision() async {
        let gate = Gate()
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", handler: { request in
            if request.url.path == "/api/v1/offer-redemptions" { return .fixture("redemption-none.json") }
            await gate.wait()
            return .json(Decisions.make())
        })
        let pending = Task { await harness.mos.decide(resource: Resource(id: "article/1")) }
        await waitUntil { harness.transport.requests(to: "/api/v1/surface-decisions").count == 1 }
        guard case .redeemed = await harness.mos.redeem(offerToken: offerToken) else {
            Issue.record("expected redeemed")
            return
        }
        await gate.open()
        #expect(await pending.value.source == .network)
        #expect(harness.cache.entries.isEmpty)
    }

    @Test("redeem: the request carries identity, offer token and properties")
    func redeemRequest() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", handler: { _ in .fixture("redemption-none.json") })
        _ = await harness.mos.redeem(offerToken: offerToken, properties: ["source": "paywall"])
        let request = harness.transport.requests.first
        #expect(request?.url.absoluteString == "https://api.example.com/api/v1/offer-redemptions")
        #expect(request?.json == [
            "identity": ["anonymousIdentifier": "mos-anon-v1-abc"],
            "offerToken": .string(offerToken),
            "properties": ["source": "paywall"],
        ])

        let jwt = Tokens.jwt(sub: "user_42")
        let signedIn = Harness(jwtProvider: { jwt }, handler: { _ in .fixture("redemption-none.json") })
        _ = await signedIn.mos.redeem(offerToken: offerToken)
        // No anonymous fallback: a bad JWT must fail with 401, not redeem for a minted anon id.
        #expect(signedIn.transport.requests.first?.json["identity"] == ["userJwt": .string(jwt)])
        #expect(signedIn.transport.requests.first?.json["identity"]?["createAnonymousIdentifierFallback"] == nil)
        #expect(signedIn.transport.requests.first?.json["properties"] == nil)
    }

    @Test("redeem: with no anon id and no JWT it cannot mint, so it is notConfigured")
    func redeemNotConfigured() async {
        let harness = Harness()
        let result = await harness.mos.redeem(offerToken: offerToken)
        #expect(result == .failed(Failure(reason: .notConfigured, message: "There is no anonymous identifier or JWT yet; make a decision first.")))
        #expect(harness.transport.count == 0)
    }

    @Test("action mapping: unknown types and navigate without a URL map to noAction, logged as none")
    func actionMapping() {
        #expect(Action(json: ["type": "mystery", "properties": ["a": 1]]) == .noAction(properties: ["a": 1]))
        #expect(Action.noAction(properties: [:]).type == "none")
        #expect(Action(json: ["type": "navigate"]) == .noAction(properties: [:]))
        #expect(Action(json: nil) == .noAction(properties: [:]))
        #expect(Action(json: ["type": "custom:x"]) == .custom(type: "custom:x", properties: [:]))
        #expect(Action(json: ["type": "custom", "properties": ["productId": "m"]]) == .custom(type: "custom", properties: ["productId": "m"]))
        #expect(Action(json: ["type": "customer"]) == .noAction(properties: [:]))
    }

    @Test("env parsing: exactly the two segments after pk; an unparseable key is notConfigured")
    func envParsing() async {
        #expect(APIRequests.environment(fromPublicKey: "pk_live_abc_secret") == "live_abc")
        #expect(APIRequests.environment(fromPublicKey: "pk_live_abc_sec_ret_more") == "live_abc")
        #expect(APIRequests.environment(fromPublicKey: "pk_live_abc") == nil)
        #expect(APIRequests.environment(fromPublicKey: "pk_live_abc_") == nil)
        #expect(APIRequests.environment(fromPublicKey: "pk__abc_secret") == nil)
        #expect(APIRequests.environment(fromPublicKey: "pk_test") == nil)

        let harness = Harness(publicKey: "pk_test")
        let result = await harness.mos.callEndpoint(path: "registration", body: [:])
        guard case .failed(let failure) = result else {
            Issue.record("expected notConfigured")
            return
        }
        #expect(failure.reason == .notConfigured)
        #expect(harness.transport.count == 0)
        #expect(harness.logs.count("endpoint:error") == 1)
    }
}

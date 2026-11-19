import Foundation
import Testing
@testable import MonetizationOS

@Suite("Logging")
struct LoggingTests {
    static let requiredCodes: Set<String> = [
        "decision:start", "decision:success", "decision:error", "decision:cache-hit", "decision:fallback",
        "decision:unavailable", "cache:put", "cache:evicted", "cache:cleared", "cache:corrupt",
        "identity:anon-persisted", "identity:changed", "identity:previous-anon-sent",
        "metering:queued", "metering:deduped", "metering:dropped", "metering:rejected", "metering:flushed",
        "metering:flush-failed", "redeem:success", "redeem:declined", "redeem:error",
        "endpoint:success", "endpoint:error", "config:invalid-key",
        "decision:coalesced", "redeem:coalesced", "identity:stale-response", "cache:schema-mismatch",
        "transport:degraded", "transport:recovered", "endpoint:header-ignored",
    ]

    /// A store whose persisted data is unreadable, to reach `cache:corrupt`.
    final class CorruptCacheStore: DecisionCacheStore {
        struct Corrupt: Error {}
        func load() throws -> [DecisionCacheEntry] { throw Corrupt() }
        func save(_ entries: [DecisionCacheEntry]) {}
    }

    /// A store holding another schema version, to reach `cache:schema-mismatch`.
    final class OldSchemaCacheStore: DecisionCacheStore {
        func load() throws -> [DecisionCacheEntry] { throw StoreSchemaMismatch(found: .null) }
        func save(_ entries: [DecisionCacheEntry]) {}
    }

    private static func makeMOS(
        logs: LogRecorder,
        transport: FakeTransport,
        clock: FakeClock,
        identity: InMemoryIdentityStore,
        cache: any DecisionCacheStore = InMemoryDecisionCacheStore(),
        queue: InMemoryMeteringQueueStore = InMemoryMeteringQueueStore(),
        jwtProvider: (@Sendable () async -> String?)? = nil
    ) throws -> MOS {
        try MOS(config: MOSConfig(
            publicKey: TestKeys.publicKey, surface: "app-paywall", app: MOSConfig.App(name: "Herald", version: "2.1"),
            identity: MOSConfig.Identity(jwtProvider: jwtProvider, store: identity),
            offline: MOSConfig.Offline(maxEntries: 2),
            onLog: logs.onLog, transport: transport
        ).with(clock: clock).with(cache: cache, queue: queue))
    }

    @Test("log codes emitted and tokens absent from every logged string")
    func logCodesAndNoTokens() async throws {
        let logs = LogRecorder()
        let clock = FakeClock()
        let jwt = Tokens.jwt(sub: "user_42")
        let offerToken = Tokens.offer(expirationMsUtc: TestTime.base + TestTime.hour)
        let secretKey = "sk_live_env1_never"

        // Refused construction.
        _ = try? MOS(config: MOSConfig(publicKey: secretKey, surface: "s", app: MOSConfig.App(name: "A", version: "1"), onLog: logs.onLog))

        // Decisions, cache, identity change and queueing on one instance.
        let decisions = FakeTransport { request in
            if request.url.path == "/api/v1/counter-updates" { return .counterSuccess }
            if request.json["resource"]?["id"] == "article/down" { throw URLError(.notConnectedToInternet) }
            let signedIn = request.json["identity"]?["userJwt"] != nil
            return .json(Decisions.make(
                identifier: signedIn ? "user_42" : "mos-anon-v1-abc", isAuthenticated: signedIn, meters: [Decisions.Meter()],
                offerTokens: [offerToken]
            ))
        }
        let identity = InMemoryIdentityStore()
        let mos = try Self.makeMOS(
            logs: logs, transport: decisions, clock: clock, identity: identity, cache: CorruptCacheStore(),
            queue: InMemoryMeteringQueueStore([Decisions.queued(identityKey: "jwt:stale", resourceId: "article/stale")])
        )
        let decide = { (id: String, policy: CachePolicy) in
            _ = await mos.decide(resource: Resource(id: id), policy: policy)
            await mos.waitForBackgroundFlush()
        }
        await decide("article/1", .networkFirst)     // mint, persist, corrupt store, put
        await decide("article/2", .networkFirst)     // flush drops the stale JWT entry
        await decide("article/3", .networkFirst)     // evicted over maxEntries
        await decide("article/down", .networkFirst)  // failure, fallback, queued
        await decide("article/3", .cacheOnly)        // cache hit, queued
        await decide("article/3", .cacheOnly)        // deduped
        await mos.identify(userJWT: jwt)
        await decide("article/none", .cacheOnly)     // identity changed, cache cleared, unavailable
        await decide("article/4", .networkFirst)     // previous anon id delivered
        clock.advance(ms: 2 * TestTime.hour)
        await decide("article/4", .cacheOnly)        // evicted at the offer token's expiry

        // A flush that rejects one update and stops at the next.
        let counters = FakeTransport { request in
            request.json["resourceId"] == "article/rejected" ? .fixture("error-400.json", status: 400) : .text("busy", status: 503)
        }
        let flusher = try Self.makeMOS(
            logs: logs, transport: counters, clock: clock, identity: InMemoryIdentityStore(anonymousIdentifier: "mos-anon-v1-abc"),
            queue: InMemoryMeteringQueueStore([
                Decisions.queued(resourceId: "article/rejected", enqueuedAt: TestTime.base),
                Decisions.queued(resourceId: "article/later", enqueuedAt: TestTime.base + 1),
            ])
        )
        _ = await flusher.flush()

        // Redemptions and endpoints.
        func client(_ body: JSONValue, status: Int = 200) throws -> MOS {
            try Self.makeMOS(
                logs: logs, transport: FakeTransport { _ in .json(body, status: status) }, clock: clock,
                identity: InMemoryIdentityStore(anonymousIdentifier: "mos-anon-v1-abc")
            )
        }
        _ = try await client(Fixtures.json("redemption-navigate.json")).redeem(offerToken: offerToken)
        _ = try await client(Fixtures.json("redemption-failure.json")).redeem(offerToken: offerToken)
        _ = try await client(Fixtures.json("error-400.json"), status: 400).redeem(offerToken: offerToken)
        _ = try await client(["ok": true]).callEndpoint(path: "registration", body: ["userJwt": .string(jwt)])
        _ = try await client(Fixtures.json("error-404.json"), status: 404).callEndpoint(path: "registration", body: [:])
        _ = try await client(["ok": true]).app(namespace: "orders").call(path: "sync", headers: ["X-MOS-Key": "Bearer \(secretKey)"])

        // Fail-fast tier, coalescing and a stale response after a reset.
        let gate = Gate()
        let slow = FakeTransport { request in
            if request.url.path == "/api/v1/counter-updates" { return .counterSuccess }
            if request.json["resource"]?["id"] == "article/timeout" { throw URLError(.timedOut) }
            await gate.wait()
            return request.url.path == "/api/v1/offer-redemptions" ? .fixture("redemption-none.json") : .json(Decisions.make())
        }
        let concurrent = try Self.makeMOS(
            logs: logs, transport: slow, clock: clock, identity: InMemoryIdentityStore(anonymousIdentifier: "mos-anon-v1-abc"), cache: OldSchemaCacheStore()
        )
        _ = await concurrent.decide(resource: Resource(id: "article/timeout"))  // degraded, old cache schema
        async let firstDecision = concurrent.decide(resource: Resource(id: "article/5"))
        async let secondDecision = concurrent.decide(resource: Resource(id: "article/5"))
        async let firstRedeem = concurrent.redeem(offerToken: offerToken)
        async let secondRedeem = concurrent.redeem(offerToken: offerToken)
        await waitUntil { logs.count("decision:coalesced") == 1 && logs.count("redeem:coalesced") == 1 }
        await concurrent.reset()  // the decision lands stale
        await gate.open()
        _ = await (firstDecision, secondDecision, firstRedeem, secondRedeem)  // recovered

        let missing = Self.requiredCodes.subtracting(logs.codes)
        #expect(missing.isEmpty, "missing: \(missing.sorted())")

        let secrets = [jwt, String(jwt.split(separator: ".")[1]), offerToken, String(offerToken.split(separator: ".")[1]), TestKeys.publicKey, secretKey]
        for event in logs.all {
            for secret in secrets {
                #expect(!event.description.contains(secret), "\(event.code) leaked a secret")
            }
            if event.description.contains("mos-anon-v1-abc") {
                #expect(event.level == .debug, "\(event.code) logged the anon id above debug")
            }
        }
    }
}

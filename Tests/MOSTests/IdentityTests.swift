import Foundation
import Testing
@testable import MonetizationOS

@Suite("Identity")
struct IdentityTests {
    @Test("identity order and persistence: explicit, then jwtProvider, then persisted anon, then mint")
    func identityOrderAndPersistence() async throws {
        let providerToken = Box<String?>(nil)
        let harness = Harness(jwtProvider: { providerToken.get() })
        let sentIdentity = { harness.transport.requests.last?.json["identity"] }

        await harness.decide()
        #expect(sentIdentity() == ["createAnonymousIdentifier": true])
        #expect(harness.identity.anonymousIdentifier == "mos-anon-v1-abc")
        #expect(await harness.mos.anonymousIdentifier == "mos-anon-v1-abc")
        #expect(harness.logs.count("identity:anon-persisted") == 1)

        await harness.decide()
        #expect(sentIdentity() == ["anonymousIdentifier": "mos-anon-v1-abc"])

        providerToken.set("provider.jwt.token")
        await harness.decide()
        #expect(sentIdentity() == ["userJwt": "provider.jwt.token", "createAnonymousIdentifierFallback": true])

        await harness.mos.identify(userJWT: "explicit.jwt.token")
        await harness.decide()
        #expect(sentIdentity() == ["userJwt": "explicit.jwt.token", "createAnonymousIdentifierFallback": true])

        await harness.mos.identify(userJWT: nil)
        await harness.decide()
        #expect(sentIdentity() == ["userJwt": "provider.jwt.token", "createAnonymousIdentifierFallback": true])

        // Signed out again: the same persisted anon id, never minted again.
        providerToken.set(nil)
        await harness.decide()
        #expect(sentIdentity() == ["anonymousIdentifier": "mos-anon-v1-abc"])
        #expect(harness.transport.requests.filter { $0.json["identity"]?["createAnonymousIdentifier"] != nil }.count == 1)
    }

    @Test("an authenticated response persists nothing")
    func authenticatedResponseIsNotPersisted() async {
        let harness = Harness(handler: { _ in .json(Decisions.make(identifier: "user_42", isAuthenticated: true)) })
        await harness.mos.identify(userJWT: Tokens.jwt(sub: "user_42"))
        await harness.decide()
        #expect(harness.identity.anonymousIdentifier == nil)
        #expect(harness.logs.count("identity:anon-persisted") == 0)
    }

    @Test("JWT fallback persistence: a JWT request answered anonymously persists the minted id only when none is stored")
    func jwtFallbackPersistence() async {
        let harness = Harness(handler: { _ in .fixture("decision-success-jwt-fallback.json") })
        await harness.mos.identify(userJWT: Tokens.jwt(sub: "user_42"))
        await harness.decide()
        #expect(harness.identity.anonymousIdentifier == "mos-anon-v1-minted")
        // Not the signed-in user's decision, so it is not cached under their key.
        #expect(harness.cache.entries.isEmpty)

        // Every fallback mints a new id. Replacing the stored one would lose its meters and the purchases its
        // appAccountToken names once the user signs out.
        let stored = Harness(anonymousIdentifier: "mos-anon-v1-old", handler: { _ in .fixture("decision-success-jwt-fallback.json") })
        await stored.mos.identify(userJWT: Tokens.jwt(sub: "user_42"))
        await stored.decide()
        #expect(stored.identity.anonymousIdentifier == "mos-anon-v1-old")
        #expect(stored.logs.count("identity:anon-persisted") == 0)
    }

    @Test("identity key and hashing: anon:<id>, jwt:<sha256 of sub>, else sha256 of the token")
    func identityKeyAndHashing() {
        #expect(IdentityKey.anonymous("mos-anon-v1-abc") == "anon:mos-anon-v1-abc")

        let userKey = "jwt:573baabb5ca42a23f3a118d027eadd8dc9bed70e40708a1b1ed9410b00feed0e"
        #expect(IdentityKey.jwt(Tokens.jwt(sub: "user_42")) == userKey)
        // A refreshed token for the same subject keeps the key.
        let refreshed = Tokens.make(payload: ["sub": "user_42", "exp": 2_000_000_000])
        #expect(IdentityKey.jwt(refreshed) == userKey)

        let noSub = Tokens.jwt(sub: nil)
        #expect(IdentityKey.jwt(noSub) == "jwt:\(IdentityKey.sha256Hex(noSub))")
        #expect(IdentityKey.jwt("not-a-jwt") == "jwt:\(IdentityKey.sha256Hex("not-a-jwt"))")
        #expect(IdentityKey.jwt("a.bm90LWpzb24.c") == "jwt:\(IdentityKey.sha256Hex("a.bm90LWpzb24.c"))")
        #expect(IdentityKey.sha256Hex("mos-anon-v1-abc") == "4cbd6340273b4c1d00124eb5741859d22c46cd9a91ca4e25359a784ca72c366e")
    }

    @Test("identity key from claimKey: a string as is, a number as JavaScript prints it, anything else the whole token")
    func identityKeyFromClaimKey() {
        func key(_ payload: JSONValue, _ claimKey: String = "uid") -> String { IdentityKey.jwt(Tokens.make(payload: payload), claimKey: claimKey) }
        func whole(_ payload: JSONValue) -> String { "jwt:\(IdentityKey.sha256Hex(Tokens.make(payload: payload)))" }
        #expect(key(["uid": "user_42", "sub": "other"]) == "jwt:\(IdentityKey.sha256Hex("user_42"))")
        #expect(key(["uid": 123]) == "jwt:\(IdentityKey.sha256Hex("123"))")
        #expect(key(["uid": 1.5]) == "jwt:\(IdentityKey.sha256Hex("1.5"))")
        #expect(key(["sub": "user_42"], "sub") == "jwt:573baabb5ca42a23f3a118d027eadd8dc9bed70e40708a1b1ed9410b00feed0e")
        for payload: JSONValue in [["sub": "user_42"], ["uid": ""], ["uid": true], ["uid": .null], ["uid": ["id": 1]], ["uid": [1]]] {
            #expect(key(payload) == whole(payload))
        }
    }

    @Test("a number claim is rendered like JavaScript's Number.prototype.toString", arguments: [
        (123.0, "123"), (-5.0, "-5"), (0.0, "0"), (-0.0, "0"), (1.5, "1.5"), (0.1, "0.1"), (123.456, "123.456"),
        (123_456_789_012.0, "123456789012"), (9_007_199_254_740_992.0, "9007199254740992"), (1e20, "100000000000000000000"),
        (1e21, "1e+21"), (1.2345e25, "1.2345e+25"), (0.000001, "0.000001"), (0.0000015, "0.0000015"), (1e-7, "1e-7"),
        (1.5e-10, "1.5e-10"), (5e-324, "5e-324"), (1.7976931348623157e308, "1.7976931348623157e+308"),
    ])
    func javaScriptNumberString(value: Double, expected: String) {
        #expect(JWT.javaScriptString(value) == expected)
    }

    @Test("claimKey: a refreshed token for the same user is the same identity, so the cache and queue survive")
    func refreshWithClaimKeyKeepsTheIdentity() async {
        let token = Box<String?>(Tokens.make(payload: ["uid": 42, "exp": 1_900_000_000]))
        let meter = Decisions.Meter(consumedUnits: 1, totalUnits: 10)
        let harness = Harness(jwtProvider: { token.get() }, claimKey: "uid", handler: route(decision: { _ in
            .json(Decisions.make(identifier: "42", isAuthenticated: true, meters: [meter]))
        }))
        await harness.decide()
        harness.transport.respond(networkDown)
        await harness.decide("article/2")  // served from the cache: queued
        #expect(harness.queue.entries.count == 1)

        token.set(Tokens.make(payload: ["uid": 42, "exp": 1_900_000_600]))
        harness.transport.respond { _ in .counterSuccess }
        let result = await harness.mos.flush()
        #expect(result == FlushResult(sent: 1, dropped: 0, remaining: 0, failure: nil))
        #expect(harness.cache.entries.count == 1)
        #expect(harness.logs.count("identity:changed") == 0)
    }

    @Test("a whitespace-only JWT counts as none, from identify and from jwtProvider")
    func blankJWTIsNone() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", jwtProvider: { " \n\t" })
        await harness.decide()
        #expect(harness.transport.requests.last?.json["identity"] == ["anonymousIdentifier": "mos-anon-v1-abc"])

        let result = await harness.mos.identify(userJWT: "   ")
        #expect(result == IdentifyResult(changed: false, previous: .anonymous, current: .anonymous, linkPending: false))
        await harness.decide()
        #expect(harness.transport.requests.last?.json["identity"] == ["anonymousIdentifier": "mos-anon-v1-abc"])
        #expect(harness.logs.count("identity:changed") == 0)
    }

    @Test("a whitespace-only anonymous id counts as none, stored or returned by the server")
    func blankAnonymousIdentifierIsNone() async {
        let harness = Harness(anonymousIdentifier: " \n\t")
        #expect(await harness.mos.anonymousIdentifier == nil)
        await harness.decide()
        #expect(harness.transport.requests.last?.json["identity"] == ["createAnonymousIdentifier": true])
        #expect(harness.identity.anonymousIdentifier == "mos-anon-v1-abc")
        #expect(await harness.mos.anonymousIdentifier == "mos-anon-v1-abc")

        let blankAnswer = Harness(handler: { _ in .json(Decisions.make(identifier: "  ")) })
        await blankAnswer.decide()
        #expect(blankAnswer.identity.anonymousIdentifier == nil)
        #expect(await blankAnswer.mos.anonymousIdentifier == nil)
        #expect(blankAnswer.cache.entries.isEmpty)
        #expect(blankAnswer.logs.count("identity:anon-persisted") == 0)
    }

    @Test("an identity store that cannot write: the minted id is kept in memory, logged once, never reported as persisted")
    func identityStoreWriteFailure() async {
        let minted = Box<Int>(0)
        let transport = FakeTransport { request in
            if let anonymous = request.json["identity"]?["anonymousIdentifier"] { return .json(Decisions.make(identifier: anonymous.stringValue!)) }
            minted.set(minted.get() + 1)
            return .json(Decisions.make(identifier: "mos-anon-v1-\(minted.get())"))
        }
        let logs = LogRecorder()
        let cache = InMemoryDecisionCacheStore()
        let mos = try! MOS(config: MOSConfig(
            publicKey: TestKeys.publicKey, surface: "app-paywall", app: MOSConfig.App(name: "Herald", version: "2.1"),
            identity: MOSConfig.Identity(store: WriteFailingIdentityStore()), onLog: logs.onLog, transport: transport
        ).with(clock: FakeClock()).with(cache: cache, queue: InMemoryMeteringQueueStore()))

        for id in ["article/1", "article/2", "article/3"] { _ = await mos.decide(resource: Resource(id: id)) }
        #expect(minted.get() == 1)
        #expect(transport.requests.dropFirst().allSatisfy { $0.json["identity"] == ["anonymousIdentifier": "mos-anon-v1-1"] })
        #expect(await mos.anonymousIdentifier == "mos-anon-v1-1")
        #expect(Set(cache.entries.map(\.identityKey)) == ["anon:mos-anon-v1-1"])
        let failed = logs.events("identity:store-failed")
        #expect(failed.map(\.context) == [["store": "identity"]])
        #expect(failed.first?.level == .warn)
        #expect(logs.count("identity:anon-persisted") == 0)

        // reset() forgets the in-memory id too; the next mint fails again and is logged again.
        await mos.reset()
        #expect(await mos.anonymousIdentifier == nil)
        _ = await mos.decide(resource: Resource(id: "article/1"))
        #expect(minted.get() == 2)
        #expect(logs.count("identity:store-failed") == 2)
    }

    @Test("identity state keys are the default store's Keychain accounts, so stored state reads back unchanged")
    func identityStoreKeys() async {
        #expect(IdentityStoreKey.anonymousIdentifier == "anonymousIdentifier")
        #expect(IdentityStoreKey.lastIdentityKey == "lastIdentityKey")
        #expect(IdentityStoreKey.pendingPreviousAnonymousIdentifier == "pendingPreviousAnonymousIdentifier")

        let jwt = Tokens.jwt(sub: "user_42")
        let harness = Harness()
        await harness.decide()
        await harness.mos.identify(userJWT: jwt)
        #expect(harness.identity.value(forKey: "anonymousIdentifier") == "mos-anon-v1-abc")
        #expect(harness.identity.value(forKey: "lastIdentityKey") == IdentityKey.jwt(jwt))
        #expect(harness.identity.value(forKey: "pendingPreviousAnonymousIdentifier") == "mos-anon-v1-abc")

        let transport = FakeTransport()
        let logs = LogRecorder()
        let store = InMemoryIdentityStore([
            "anonymousIdentifier": "mos-anon-v1-abc", "lastIdentityKey": "anon:mos-anon-v1-abc", "pendingPreviousAnonymousIdentifier": "mos-anon-v1-old",
        ])
        let mos = try! MOS(config: MOSConfig(
            publicKey: TestKeys.publicKey, surface: "app-paywall", app: MOSConfig.App(name: "Herald", version: "2.1"),
            identity: MOSConfig.Identity(store: store), onLog: logs.onLog, transport: transport
        ).with(clock: FakeClock()).with(cache: InMemoryDecisionCacheStore(), queue: InMemoryMeteringQueueStore()))
        _ = await mos.decide(resource: Resource(id: "article/1"))
        #expect(transport.requests.first?.json["identity"] == ["anonymousIdentifier": "mos-anon-v1-abc"])
        #expect(transport.requests.first?.json["properties"]?["previousAnonymousIdentifier"] == "mos-anon-v1-old")
        #expect(logs.count("identity:changed") == 0)
    }

    @Test("identity change purges cache and sends previousAnonymousIdentifier exactly once")
    func identityChangePurgesCacheAndSendsPreviousAnonymousIdentifierOnce() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc")
        await harness.decide("article/1")
        #expect(harness.cache.entries.count == 1)

        await harness.mos.identify(userJWT: Tokens.jwt(sub: "user_42"))
        let cached = await harness.decide("article/1", policy: .cacheOnly)
        #expect(cached.source == .unavailable)
        #expect(harness.cache.entries.isEmpty)
        let changed = harness.logs.events("identity:changed")
        #expect(changed.count == 1)
        #expect(changed.first?.context == ["from": "anon", "to": "jwt"])

        harness.transport.respond { _ in .json(Decisions.make(identifier: "user_42", isAuthenticated: true)) }
        await harness.decide("article/2")
        #expect(harness.transport.requests.last?.json["properties"] == ["platform": "ios", "previousAnonymousIdentifier": "mos-anon-v1-abc"])
        await harness.decide("article/3")
        #expect(harness.transport.requests.last?.json["properties"] == ["platform": "ios"])
        #expect(harness.transport.requests.filter { $0.json["properties"]?["previousAnonymousIdentifier"] != nil }.count == 1)
        #expect(harness.logs.count("identity:previous-anon-sent") == 1)
    }

    @Test("previousAnonymousIdentifier rides every decision until one is answered for the signed-in user")
    func previousAnonymousIdentifierRidesUntilAccepted() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc")
        await harness.decide()
        await harness.mos.identify(userJWT: Tokens.jwt(sub: "user_42"))

        harness.transport.respond { _ in .text("down", status: 503) }
        await harness.decide()
        harness.transport.respond { _ in .json(["status": "error", "statusCode": 400, "message": "bad"]) }
        await harness.decide()
        harness.transport.respond { _ in .json(Decisions.make(identifier: "user_42", isAuthenticated: true)) }
        await harness.decide()
        await harness.decide()

        let carried = harness.transport.requests.map { $0.json["properties"]?["previousAnonymousIdentifier"] }
        #expect(carried == [nil, "mos-anon-v1-abc", "mos-anon-v1-abc", "mos-anon-v1-abc", nil])
    }

    @Test("an expired token answered anonymously keeps the link pending; the next signed-in decision resends it, then it clears")
    func anonymousAnswerKeepsTheLinkPending() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc")
        await harness.decide()
        await harness.mos.identify(userJWT: Tokens.jwt(sub: "user_42"))

        // The host returns its last, expired token; the server falls back to a fresh anonymous id.
        harness.transport.respond { _ in .fixture("decision-success-jwt-fallback.json") }
        let anonymous = await harness.decide()
        #expect(anonymous.source == .network)
        #expect(!anonymous.linkedAnonymousIdentifier)
        #expect(harness.identity.pendingPreviousAnonymousIdentifier == "mos-anon-v1-abc")
        #expect(harness.logs.count("identity:previous-anon-sent") == 0)

        harness.transport.respond { _ in .json(Decisions.make(identifier: "user_42", isAuthenticated: true)) }
        let linked = await harness.decide()
        #expect(linked.linkedAnonymousIdentifier)
        #expect(harness.identity.pendingPreviousAnonymousIdentifier == nil)
        await harness.decide()

        let carried = harness.transport.requests.map { $0.json["properties"]?["previousAnonymousIdentifier"] }
        #expect(carried == [nil, "mos-anon-v1-abc", "mos-anon-v1-abc", nil])
        #expect(harness.logs.count("identity:previous-anon-sent") == 1)
    }

    @Test("host properties are sent as given, platform included; the SDK owns previousAnonymousIdentifier")
    func hostPropertiesMergeButSDKOwnsPreviousAnonymousIdentifier() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc")
        await harness.decide(properties: ["plan": "trial", "previousAnonymousIdentifier": "host-value"])
        #expect(harness.transport.requests.last?.json["properties"] == ["platform": "ios", "plan": "trial", "previousAnonymousIdentifier": "host-value"])

        await harness.mos.identify(userJWT: Tokens.jwt(sub: "user_42"))
        await harness.decide(properties: ["plan": "trial", "platform": "ipados", "previousAnonymousIdentifier": "host-value"])
        #expect(harness.transport.requests.last?.json["properties"] == ["platform": "ipados", "plan": "trial", "previousAnonymousIdentifier": "mos-anon-v1-abc"])
    }

    @Test("a freshly minted id is the identity its first decision is cached under")
    func mintedIdentityKeysTheFirstEntry() async {
        let harness = Harness()
        await harness.decide("article/1")
        #expect(harness.cache.entries.map(\.identityKey) == ["anon:mos-anon-v1-abc"])
        let cached = await harness.decide("article/1", policy: .cacheOnly)
        #expect(cached.source == .cache(ageMs: 0))
        #expect(harness.logs.count("identity:changed") == 0)
    }

    @Test("identify result fields for anon→jwt, jwt→jwt', jwt→nil and same-token, with no network call")
    func identifyResultFields() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", handler: { _ in .json(Decisions.make(identifier: "user_42", isAuthenticated: true)) })
        await harness.decide()
        let requests = harness.transport.count

        let user42 = Tokens.jwt(sub: "user_42")
        let signIn = await harness.mos.identify(userJWT: user42)
        #expect(signIn == IdentifyResult(changed: true, previous: .anonymous, current: .jwt, linkPending: true))
        #expect(harness.logs.count("identity:changed") == 1)
        #expect(harness.cache.entries.isEmpty)

        // A refreshed token for the same subject is the same identity.
        let refreshed = await harness.mos.identify(userJWT: Tokens.make(payload: ["sub": "user_42", "exp": 2_000_000_000]))
        #expect(refreshed == IdentifyResult(changed: false, previous: .jwt, current: .jwt, linkPending: true))
        #expect(harness.transport.count == requests)

        await harness.decide()  // delivers the link
        let sameToken = await harness.mos.identify(userJWT: user42)
        #expect(sameToken == IdentifyResult(changed: false, previous: .jwt, current: .jwt, linkPending: false))

        let otherUser = await harness.mos.identify(userJWT: Tokens.jwt(sub: "user_43"))
        #expect(otherUser == IdentifyResult(changed: true, previous: .jwt, current: .jwt, linkPending: false))

        let signOut = await harness.mos.identify(userJWT: nil)
        #expect(signOut == IdentifyResult(changed: true, previous: .jwt, current: .anonymous, linkPending: false))
        #expect(harness.logs.count("identity:changed") == 3)
    }

    @Test("no self-link: anon A, identify(jwt), identify(nil) with no decision between clears the pending id unsent")
    func noSelfLink() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc")
        await harness.decide()
        #expect(await harness.mos.identify(userJWT: Tokens.jwt(sub: "user_42")).linkPending)
        let signedOut = await harness.mos.identify(userJWT: nil)
        #expect(signedOut == IdentifyResult(changed: true, previous: .jwt, current: .anonymous, linkPending: false))
        #expect(harness.identity.pendingPreviousAnonymousIdentifier == nil)
        let result = await harness.decide()
        #expect(harness.transport.requests.last?.json["properties"] == ["platform": "ios"])
        #expect(!result.linkedAnonymousIdentifier)
        #expect(harness.logs.count("identity:previous-anon-sent") == 0)
    }

    @Test("identify(nil) resolves through jwtProvider; a fresh install has no previous and nothing to mint yet")
    func identifyResolvesWithTheNormalOrder() async {
        let provider = Box<String?>(Tokens.jwt(sub: "user_42"))
        let harness = Harness(jwtProvider: { provider.get() })
        #expect(await harness.mos.identify(userJWT: nil) == IdentifyResult(changed: false, previous: nil, current: .jwt, linkPending: false))
        provider.set(nil)
        #expect(await harness.mos.identify(userJWT: nil) == IdentifyResult(changed: true, previous: .jwt, current: nil, linkPending: false))
        #expect(harness.identity.lastIdentityKey == nil)
        #expect(harness.logs.events("identity:changed").map(\.context) == [["from": "jwt", "to": "none"]])
        #expect(harness.transport.count == 0)
    }

    @Test("identify(userJWT:) during a suspended jwtProvider wins: the stale anonymous resolution is not applied")
    func identifyDuringProviderAwait() async {
        let gate = Box<Gate>(Gate())
        let entered = Box<Int>(0)
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", jwtProvider: {
            entered.set(entered.get() + 1)
            await gate.get().wait()
            return nil
        })
        await gate.get().open()
        await harness.decide()
        gate.set(Gate())
        let before = entered.get()

        let user42 = Tokens.jwt(sub: "user_42")
        let pending = Task { await harness.mos.decide(resource: Resource(id: "article/1")) }
        await waitUntil { entered.get() == before + 1 }
        #expect(await harness.mos.identify(userJWT: user42).changed)
        await gate.get().open()
        _ = await pending.value
        await harness.mos.waitForBackgroundFlush()

        #expect(harness.transport.requests.last?.json["identity"]?["userJwt"] == .string(user42))
        #expect(harness.identity.lastIdentityKey == IdentityKey.jwt(user42))
        #expect(harness.logs.count("identity:changed") == 1)
    }

    @Test("reset() during a suspended jwtProvider re-resolves instead of applying the stale identity")
    func resetDuringProviderAwait() async {
        let gate = Box<Gate>(Gate())
        let entered = Box<Int>(0)
        let token = Box<String?>(Tokens.jwt(sub: "user_42"))
        let harness = Harness(jwtProvider: {
            entered.set(entered.get() + 1)
            let current = token.get()
            await gate.get().wait()
            return current
        })
        await gate.get().open()
        await harness.decide()
        gate.set(Gate())
        let before = entered.get()

        let pending = Task { await harness.mos.decide(resource: Resource(id: "article/1")) }
        await waitUntil { entered.get() == before + 1 }
        token.set(nil)
        await harness.mos.reset()
        await gate.get().open()
        _ = await pending.value
        await harness.mos.waitForBackgroundFlush()

        #expect(harness.transport.requests.last?.json["identity"] == ["createAnonymousIdentifier": true])
        #expect(harness.logs.count("identity:changed") == 0)
    }

    @Test("jwt to a different jwt drops the pending link: anon history never attaches to the second account")
    func jwtToJwtDropsPendingLink() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc")
        await harness.decide()
        #expect(await harness.mos.identify(userJWT: Tokens.jwt(sub: "user_42")).linkPending)
        let other = await harness.mos.identify(userJWT: Tokens.jwt(sub: "user_43"))
        #expect(other == IdentifyResult(changed: true, previous: .jwt, current: .jwt, linkPending: false))
        #expect(harness.identity.pendingPreviousAnonymousIdentifier == nil)
        await harness.decide()
        #expect(harness.transport.requests.last?.json["properties"] == ["platform": "ios"])
        #expect(harness.logs.count("identity:previous-anon-sent") == 0)
    }

    @Test("reset() clears the explicit identity: a signed-out user is not sent as the old JWT")
    func resetClearsExplicitJwt() async {
        let harness = Harness()
        let user42 = Tokens.jwt(sub: "user_42")
        await harness.mos.identify(userJWT: user42)
        await harness.decide()
        #expect(harness.transport.requests.last?.json["identity"]?["userJwt"] == .string(user42))
        await harness.mos.reset()
        await harness.decide()
        #expect(harness.transport.requests.last?.json["identity"] == ["createAnonymousIdentifier": true])
    }

    @Test("linkedAnonymousIdentifier: true only on the accepted network result that carried the link")
    func linkedAnonymousIdentifier() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc")
        #expect(await harness.decide("article/1").linkedAnonymousIdentifier == false)
        await harness.mos.identify(userJWT: Tokens.jwt(sub: "user_42"))

        harness.transport.respond { _ in .text("down", status: 503) }
        let failed = await harness.decide("article/1")
        #expect(failed.linkedAnonymousIdentifier == false)

        harness.transport.respond { _ in .json(Decisions.make(identifier: "user_42", isAuthenticated: true)) }
        let linked = await harness.decide("article/1")
        #expect(linked.source == .network)
        #expect(linked.linkedAnonymousIdentifier == true)

        #expect(await harness.decide("article/1").linkedAnonymousIdentifier == false)
        #expect(await harness.decide("article/1", policy: .cacheOnly).linkedAnonymousIdentifier == false)
    }

    @Test("persisted last identity key survives a new MOS instance: the purge and the link happen after relaunch")
    func persistedLastIdentityKeySurvivesRelaunch() async {
        let first = Harness(anonymousIdentifier: "mos-anon-v1-abc")
        await first.decide("article/1")
        #expect(first.identity.lastIdentityKey == "anon:mos-anon-v1-abc")
        #expect(first.cache.entries.count == 1)

        // Signed in through the provider, then killed before any call noticed.
        let jwt = Tokens.jwt(sub: "user_42")
        let relaunched = Harness(jwtProvider: { jwt }, sharing: first, handler: { _ in .json(Decisions.make(identifier: "user_42", isAuthenticated: true)) })
        let cached = await relaunched.decide("article/1", policy: .cacheOnly)
        #expect(cached.source == .unavailable)
        #expect(relaunched.cache.entries.isEmpty)
        #expect(relaunched.logs.events("identity:changed").map(\.context) == [["from": "anon", "to": "jwt"]])
        #expect(relaunched.identity.pendingPreviousAnonymousIdentifier == "mos-anon-v1-abc")

        await relaunched.decide("article/1")
        #expect(relaunched.transport.requests.last?.json["properties"] == ["platform": "ios", "previousAnonymousIdentifier": "mos-anon-v1-abc"])
        #expect(relaunched.identity.pendingPreviousAnonymousIdentifier == nil)
        #expect(relaunched.identity.lastIdentityKey == IdentityKey.jwt(jwt))
    }

    @Test("persisted pending link survives a new MOS instance and is sent exactly once after relaunch")
    func persistedPendingLinkSurvivesRelaunch() async {
        let jwt = Tokens.jwt(sub: "user_42")
        let first = Harness(anonymousIdentifier: "mos-anon-v1-abc")
        await first.decide("article/1")
        #expect(await first.mos.identify(userJWT: jwt).linkPending)
        #expect(first.identity.pendingPreviousAnonymousIdentifier == "mos-anon-v1-abc")

        let relaunched = Harness(sharing: first, handler: { _ in .json(Decisions.make(identifier: "user_42", isAuthenticated: true)) })
        let identified = await relaunched.mos.identify(userJWT: jwt)
        #expect(identified == IdentifyResult(changed: false, previous: .jwt, current: .jwt, linkPending: true))
        await relaunched.decide("article/2")
        await relaunched.decide("article/3")
        let carried = relaunched.transport.requests.map { $0.json["properties"]?["previousAnonymousIdentifier"] }
        #expect(carried == ["mos-anon-v1-abc", nil])
        #expect(relaunched.logs.count("identity:previous-anon-sent") == 1)
    }

    @Test("reset forgets the anon id, cache and queue")
    func resetForgetsEverything() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", queued: [Decisions.queued()], handler: route(counter: networkDown))
        await harness.decide()
        #expect(!harness.cache.entries.isEmpty)
        #expect(!harness.queue.entries.isEmpty)

        await harness.mos.identify(userJWT: Tokens.jwt(sub: "user_42"))
        #expect(harness.identity.pendingPreviousAnonymousIdentifier != nil)
        await harness.mos.identify(userJWT: nil)
        await harness.mos.reset()
        #expect(harness.identity.anonymousIdentifier == nil)
        #expect(harness.identity.lastIdentityKey == nil)
        #expect(harness.identity.pendingPreviousAnonymousIdentifier == nil)
        #expect(await harness.mos.anonymousIdentifier == nil)
        #expect(harness.cache.entries.isEmpty)
        #expect(harness.queue.entries.isEmpty)
        #expect(harness.logs.events("cache:cleared").last?.context == ["reason": "reset"])

        await harness.decide()
        #expect(harness.transport.requests(to: "/api/v1/surface-decisions").last?.json["identity"] == ["createAnonymousIdentifier": true])
    }
}

/// A store whose writes never stick, like a Keychain the app cannot write to.
final class WriteFailingIdentityStore: IdentityStore {
    func value(forKey key: String) -> String? { nil }
    func setValue(_ value: String?, forKey key: String) {}
}

import Foundation
import Testing
@testable import MonetizationOS

@Suite("Deferred metering")
struct MeteringTests {
    private static let anon = "anon:mos-anon-v1-abc"
    private static let counterPath = "/api/v1/counter-updates"

    private func cachedEntry(_ meters: [Decisions.Meter], resourceId: String = "article/1") -> DecisionCacheEntry {
        Decisions.entry(resourceId: resourceId, identityKey: Self.anon, decision: Decisions.make(meters: meters))
    }

    @Test("metering enqueue: a cache serve queues each consumed, granted meter")
    func enqueueOnCacheServe() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", now: TestTime.base + 1_000, cached: [cachedEntry([
            Decisions.Meter(),
            Decisions.Meter(feature: "video", counterId: "default:feat_video.minutes", consumedUnitsInRequest: 3),
            Decisions.Meter(feature: "audio", counterId: "default:feat_audio.enabled", consumedUnitsInRequest: nil),
        ])], handler: networkDown)
        await harness.decide("article/1")
        #expect(harness.queue.entries == [
            QueuedCounterUpdate(identityKey: Self.anon, anonymousIdentifier: "mos-anon-v1-abc", counterId: "default:feat_article.enabled", resourceId: "article/1", update: 1, enqueuedAt: TestTime.base + 1_000),
            QueuedCounterUpdate(identityKey: Self.anon, anonymousIdentifier: "mos-anon-v1-abc", counterId: "default:feat_audio.enabled", resourceId: "article/1", update: 1, enqueuedAt: TestTime.base + 1_000),
            QueuedCounterUpdate(identityKey: Self.anon, anonymousIdentifier: "mos-anon-v1-abc", counterId: "default:feat_video.minutes", resourceId: "article/1", update: 3, enqueuedAt: TestTime.base + 1_000),
        ].sorted { $0.counterId < $1.counterId })
        #expect(harness.logs.count("metering:queued") == 3)
    }

    @Test("metering enqueue: a fallback serve queues against the requested resource")
    func enqueueOnFallback() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", cached: [cachedEntry([Decisions.Meter()], resourceId: "article/1")])
        await harness.decide("article/2", policy: .cacheOnly)
        #expect(harness.queue.entries.map(\.resourceId) == ["article/2"])
    }

    @Test("metering enqueue: never for a network decision")
    func notOnNetwork() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", handler: { _ in .json(Decisions.make(meters: [Decisions.Meter()])) })
        await harness.decide("article/1")
        #expect(harness.queue.entries.isEmpty)
        #expect(harness.logs.count("metering:queued") == 0)
    }

    @Test("metering enqueue: not when hasAccess is false")
    func notWhenAccessDenied() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", cached: [cachedEntry([Decisions.Meter(hasAccess: false)])])
        await harness.decide("article/1", policy: .cacheOnly)
        #expect(harness.queue.entries.isEmpty)
    }

    @Test("metering enqueue: not when consumedInRequest is false or missing")
    func notWhenNotConsumed() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", cached: [cachedEntry([
            Decisions.Meter(consumedInRequest: false),
            Decisions.Meter(feature: "video", counterId: "default:feat_video.enabled", consumedInRequest: nil),
        ])])
        await harness.decide("article/1", policy: .cacheOnly)
        #expect(harness.queue.entries.isEmpty)
    }

    @Test("metering enqueue: not for a meter without a counterId")
    func notWithoutCounterId() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", cached: [cachedEntry([Decisions.Meter(counterId: nil)])])
        await harness.decide("article/1", policy: .cacheOnly)
        #expect(harness.queue.entries.isEmpty)
    }

    @Test("metering dedupe: the same identity, counter and resource is queued once")
    func dedupe() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", cached: [cachedEntry([Decisions.Meter()])])
        await harness.decide("article/1", policy: .cacheOnly)
        harness.clock.advance(ms: 1_000)
        await harness.decide("article/1", policy: .cacheOnly)
        #expect(harness.queue.entries.count == 1)
        #expect(harness.logs.count("metering:deduped") == 1)
    }

    @Test("metering queue holds 500 entries and drops the oldest")
    func queueLimit() async {
        let full = (0..<500).map { Decisions.queued(resourceId: "article/q\($0)", enqueuedAt: TestTime.base + Int64($0)) }
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", now: TestTime.base + 1_000, cached: [cachedEntry([Decisions.Meter()])], queued: full)
        await harness.decide("article/1", policy: .cacheOnly)
        #expect(harness.queue.entries.count == 500)
        #expect(!harness.queue.entries.contains { $0.resourceId == "article/q0" })
        #expect(harness.queue.entries.last?.resourceId == "article/1")
        #expect(harness.logs.events("metering:dropped").first?.context == ["count": 1, "reason": "limit"])
    }

    @Test("flush drops entries older than seven days")
    func staleEntriesDropped() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", now: TestTime.base + 7 * TestTime.day + 1, queued: [
            Decisions.queued(resourceId: "article/old", enqueuedAt: TestTime.base),
            Decisions.queued(resourceId: "article/new", enqueuedAt: TestTime.base + TestTime.day),
        ], handler: { _ in .counterSuccess })
        let result = await harness.mos.flush()
        #expect(result == FlushResult(sent: 1, dropped: 1, remaining: 0, failure: nil))
        #expect(harness.transport.requests.map { $0.json["resourceId"] } == ["article/new"])
        #expect(harness.logs.events("metering:dropped").first?.context == ["count": 1, "reason": "expired"])
    }

    struct FlushCase: Sendable, CustomTestStringConvertible {
        let name: String
        let response: FakeTransport.Handler
        let removed: Bool
        let failure: Failure.Reason?
        var testDescription: String { name }
    }

    static let flushCases: [FlushCase] = [
        FlushCase(name: "2xx success", response: { _ in .counterSuccess }, removed: true, failure: nil),
        FlushCase(name: "2xx empty object", response: { _ in .json([:]) }, removed: true, failure: nil),
        FlushCase(name: "2xx empty body", response: { _ in .text("", status: 200) }, removed: true, failure: nil),
        FlushCase(name: "400", response: { _ in .fixture("error-400.json", status: 400) }, removed: true, failure: nil),
        FlushCase(name: "404", response: { _ in .fixture("error-404.json", status: 404) }, removed: true, failure: nil),
        FlushCase(name: "400 envelope on 200", response: { _ in .fixture("error-400.json") }, removed: true, failure: nil),
        FlushCase(name: "401", response: { _ in .fixture("error-401.json", status: 401) }, removed: false, failure: .unauthorized),
        FlushCase(name: "401 envelope on 200", response: { _ in .fixture("error-401.json") }, removed: false, failure: .unauthorized),
        FlushCase(name: "429", response: { _ in .fixture("error-429.json", status: 429) }, removed: false, failure: .rateLimited),
        // Either the HTTP status or the envelope's statusCode being 401 or 429 keeps the entry.
        FlushCase(name: "401 with a 400 envelope", response: { _ in .fixture("error-400.json", status: 401) }, removed: false, failure: .unauthorized),
        FlushCase(name: "429 with a 400 envelope", response: { _ in .fixture("error-400.json", status: 429) }, removed: false, failure: .rateLimited),
        FlushCase(name: "400 with a 401 envelope", response: { _ in .fixture("error-401.json", status: 400) }, removed: false, failure: .unauthorized),
        FlushCase(name: "400 with a 429 envelope", response: { _ in .fixture("error-429.json", status: 400) }, removed: false, failure: .rateLimited),
        FlushCase(name: "500", response: { _ in .text("oops", status: 500) }, removed: false, failure: .httpError),
        FlushCase(name: "531", response: { _ in .fixture("error-531.json", status: 531) }, removed: false, failure: .apiError),
        FlushCase(name: "network error", response: networkDown, removed: false, failure: .requestFailed),
        FlushCase(name: "timeout", response: { _ in throw URLError(.timedOut) }, removed: false, failure: .timeout),
    ]

    @Test("flush outcomes per status: 2xx and 4xx remove; 401, 429, 5xx, network error and timeout stop and keep the rest", arguments: flushCases)
    func flushOutcomes(_ flushCase: FlushCase) async {
        let queued = [
            Decisions.queued(resourceId: "article/a", enqueuedAt: TestTime.base),
            Decisions.queued(resourceId: "article/b", enqueuedAt: TestTime.base + 1),
            Decisions.queued(resourceId: "article/c", enqueuedAt: TestTime.base + 2),
        ]
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", queued: queued, handler: flushCase.response)
        let result = await harness.mos.flush()

        if flushCase.removed {
            #expect(harness.queue.entries.isEmpty)
            #expect(harness.transport.requests.map { $0.json["resourceId"] } == ["article/a", "article/b", "article/c"])
            #expect(result.remaining == 0)
            #expect(result.failure == nil)
            let rejected = flushCase.name == "2xx success" ? 0 : 3
            #expect(result.sent == 3 - rejected)
            #expect(result.dropped == rejected)
            #expect(harness.logs.count("metering:rejected") == rejected)
            #expect(harness.logs.count("metering:flushed") == 1)
        } else {
            #expect(harness.queue.entries == queued)
            #expect(harness.transport.count == 1)
            #expect(result == FlushResult(sent: 0, dropped: 0, remaining: 3, failure: result.failure))
            #expect(result.failure?.reason == flushCase.failure)
            #expect(harness.logs.count("metering:flush-failed") == 1)
        }
    }

    @Test("flush sends oldest first and stops at the first retryable failure")
    func flushStopsMidway() async {
        let queued = [
            Decisions.queued(resourceId: "article/b", enqueuedAt: TestTime.base + 1),
            Decisions.queued(resourceId: "article/a", enqueuedAt: TestTime.base),
            Decisions.queued(resourceId: "article/c", enqueuedAt: TestTime.base + 2),
        ]
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", queued: queued, handler: { request in
            request.json["resourceId"] == "article/b" ? .text("unavailable", status: 503) : .counterSuccess
        })
        let result = await harness.mos.flush()
        #expect(harness.transport.requests.map { $0.json["resourceId"] } == ["article/a", "article/b"])
        #expect(harness.queue.entries.map(\.resourceId) == ["article/b", "article/c"])
        #expect(result == FlushResult(sent: 1, dropped: 0, remaining: 2, failure: result.failure))
        #expect(result.failure?.reason == .httpError)
        #expect(result.failure?.status == 503)
    }

    @Test("flush request body carries the snapshot identity, counter, update and resource")
    func flushRequestBody() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", queued: [Decisions.queued(update: 2)], handler: { _ in .counterSuccess })
        await harness.mos.flush()
        let request = harness.transport.requests.first
        #expect(request?.url.absoluteString == "https://api.example.com/api/v1/counter-updates")
        #expect(request?.json == [
            "identity": ["anonymousIdentifier": "mos-anon-v1-abc"],
            "counterId": "default:feat_article.enabled",
            "update": 2,
            "resourceId": "article/1",
        ])
    }

    @Test("auto-flush after a network decision, in the background, without delaying the decision", .timeLimit(.minutes(1)))
    func autoFlushAfterNetworkDecision() async {
        let gate = Gate()
        let harness = Harness(
            anonymousIdentifier: "mos-anon-v1-abc",
            queued: [Decisions.queued()],
            handler: route(counter: { _ in
                await gate.wait()
                return .counterSuccess
            })
        )
        // The decision returns while its flush is still held at the gate.
        let result = await harness.mos.decide(resource: Resource(id: "article/2"))
        #expect(result.source == .network)
        #expect(harness.queue.entries.count == 1)

        await gate.open()
        await harness.mos.waitForBackgroundFlush()
        #expect(harness.queue.entries.isEmpty)
        #expect(harness.transport.requests(to: Self.counterPath).count == 1)
    }

    @Test("no auto-flush after a network decision when the queue is empty: jwtProvider is asked once")
    func noAutoFlushWithEmptyQueue() async {
        let jwt = Tokens.jwt(sub: "user_42")
        let calls = Box(0)
        let harness = Harness(jwtProvider: {
            calls.set(calls.get() + 1)
            return jwt
        }, handler: { _ in .json(Decisions.make(identifier: "user_42", isAuthenticated: true)) })
        let result = await harness.decide()
        #expect(result.source == .network)
        #expect(calls.get() == 1)
        #expect(harness.transport.requests(to: Self.counterPath).isEmpty)
        #expect(harness.logs.count("metering:flushed") == 0)
    }

    @Test("no auto-flush after a cache serve")
    func noAutoFlushFromCache() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", cached: [cachedEntry([Decisions.Meter()])], handler: networkDown)
        await harness.decide("article/1")
        #expect(harness.transport.requests(to: Self.counterPath).isEmpty)
        #expect(harness.queue.entries.count == 1)
    }

    @Test("identity scoping at flush: other anon ids kept, stale JWT ids dropped, current id sent")
    func identityScopingAtFlush() async {
        let jwt = Tokens.jwt(sub: "user_42")
        let jwtKey = IdentityKey.jwt(jwt)
        let queued = [
            Decisions.queued(identityKey: "anon:someone-else", resourceId: "article/other"),
            Decisions.queued(identityKey: "jwt:0000", resourceId: "article/old-jwt"),
            Decisions.queued(identityKey: Self.anon, resourceId: "article/mine"),
            Decisions.queued(identityKey: jwtKey, resourceId: "article/jwt"),
        ]
        let anonymous = Harness(anonymousIdentifier: "mos-anon-v1-abc", queued: queued, handler: { _ in .counterSuccess })
        let result = await anonymous.mos.flush()
        #expect(result == FlushResult(sent: 1, dropped: 2, remaining: 0, failure: nil))
        #expect(anonymous.transport.requests.map { $0.json["identity"] } == [["anonymousIdentifier": "mos-anon-v1-abc"]])
        #expect(anonymous.queue.entries.map(\.resourceId) == ["article/other"])
        #expect(anonymous.logs.events("metering:dropped").first?.context == ["count": 2, "reason": "identity-gone"])

        let signedIn = Harness(anonymousIdentifier: "mos-anon-v1-abc", jwtProvider: { jwt }, queued: queued, handler: { _ in .counterSuccess })
        let jwtResult = await signedIn.mos.flush()
        #expect(jwtResult.sent == 1)
        #expect(signedIn.transport.requests.map { $0.json["identity"] } == [["userJwt": .string(jwt)]])
        #expect(signedIn.transport.requests.map { $0.json["resourceId"] } == ["article/jwt"])
        #expect(signedIn.queue.entries.map(\.resourceId).sorted() == ["article/mine", "article/other"])
    }

    @Test("JWT identities queue no token")
    func jwtSnapshotStoresNoToken() async {
        let jwt = Tokens.jwt(sub: "user_42")
        let entry = Decisions.entry(identityKey: IdentityKey.jwt(jwt), decision: Decisions.make(meters: [Decisions.Meter()]))
        let harness = Harness(jwtProvider: { jwt }, cached: [entry])
        await harness.decide("article/1", policy: .cacheOnly)
        #expect(harness.queue.entries.count == 1)
        #expect(harness.queue.entries.first?.anonymousIdentifier == nil)
        #expect(!String(decoding: JSONEncoder().encodeOrEmpty(harness.queue.entries), as: UTF8.self).contains(jwt))
    }

    @Test("metering log levels and contexts, the same on both platforms")
    func meteringLogContexts() async {
        let queuing = Harness(anonymousIdentifier: "mos-anon-v1-abc", cached: [cachedEntry([Decisions.Meter()])], handler: networkDown)
        await queuing.decide("article/1", policy: .cacheOnly)
        let queued = queuing.logs.events("metering:queued")
        #expect(queued.map(\.context) == [["counterId": "default:feat_article.enabled", "resourceId": "article/1", "update": 1]])
        #expect(queued.map(\.level) == [.debug])

        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", queued: [
            Decisions.queued(resourceId: "article/sent", enqueuedAt: TestTime.base),
            Decisions.queued(resourceId: "article/rejected", enqueuedAt: TestTime.base + 1),
            Decisions.queued(resourceId: "article/later", enqueuedAt: TestTime.base + 2),
        ], handler: { request in
            switch request.json["resourceId"] {
            case "article/sent": .counterSuccess
            case "article/rejected": .fixture("error-400.json", status: 400)
            default: .text("busy", status: 503)
            }
        })
        await harness.mos.flush()
        let rejected = harness.logs.events("metering:rejected")
        #expect(rejected.map(\.context) == [[
            "counterId": "default:feat_article.enabled", "resourceId": "article/rejected", "status": 400, "statusCode": 400,
        ]])
        #expect(rejected.map(\.level) == [.warn])
        let failed = harness.logs.events("metering:flush-failed")
        #expect(failed.map(\.context) == [["reason": "httpError", "status": 503, "sent": 1, "remaining": 1]])
        #expect(failed.map(\.level) == [.warn])

        harness.transport.respond { _ in .counterSuccess }
        await harness.mos.flush()
        let flushed = harness.logs.events("metering:flushed")
        #expect(flushed.map(\.context) == [["sent": 1, "remaining": 0, "dropped": 0]])
        #expect(flushed.map(\.level) == [.info])
    }

    @Test("concurrent flushes share one pass, so nothing is sent twice")
    func concurrentFlushesShareOnePass() async {
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", queued: [
            Decisions.queued(resourceId: "article/a"),
            Decisions.queued(resourceId: "article/b", enqueuedAt: TestTime.base + 1),
        ], handler: { _ in .counterSuccess })
        async let first = harness.mos.flush()
        async let second = harness.mos.flush()
        _ = await (first, second)
        #expect(harness.transport.count == 2)
        #expect(harness.queue.entries.isEmpty)
    }
}

extension JSONEncoder {
    func encodeOrEmpty<T: Encodable>(_ value: T) -> Data {
        (try? encode(value)) ?? Data()
    }
}

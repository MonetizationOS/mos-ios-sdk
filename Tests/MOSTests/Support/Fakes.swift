import Foundation
import os
import Testing
@testable import MonetizationOS

/// Records every request and answers from a swappable handler. Never retries, never sleeps.
final class FakeTransport: HTTPTransport {
    typealias Handler = @Sendable (HTTPRequest) async throws -> HTTPResponse

    private struct State {
        var requests: [HTTPRequest] = []
        var handler: Handler
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ handler: @escaping Handler = { _ in .json(Decisions.make()) }) {
        state = OSAllocatedUnfairLock(initialState: State(handler: handler))
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let handler = state.withLock { state in
            state.requests.append(request)
            return state.handler
        }
        return try await handler(request)
    }

    func respond(_ handler: @escaping Handler) {
        state.withLock { $0.handler = handler }
    }

    var requests: [HTTPRequest] { state.withLock { $0.requests } }
    var count: Int { requests.count }

    func requests(to path: String) -> [HTTPRequest] {
        requests.filter { $0.url.path == path }
    }
}

final class FakeClock: MOSClock {
    private let now: OSAllocatedUnfairLock<Int64>

    init(_ start: Int64 = TestTime.base) {
        now = OSAllocatedUnfairLock(initialState: start)
    }

    func nowMs() -> Int64 { now.withLock { $0 } }
    func advance(ms: Int64) { now.withLock { $0 += ms } }
    func set(_ value: Int64) { now.withLock { $0 = value } }
}

final class LogRecorder: Sendable {
    private let events = OSAllocatedUnfairLock<[LogEvent]>(initialState: [])

    var all: [LogEvent] { events.withLock { $0 } }
    var codes: [String] { all.map(\.code) }
    func count(_ code: String) -> Int { codes.filter { $0 == code }.count }
    func events(_ code: String) -> [LogEvent] { all.filter { $0.code == code } }

    var onLog: @Sendable (LogEvent) -> Void {
        { [events] event in events.withLock { $0.append(event) } }
    }
}

extension MOSConfig {
    func with(clock: any MOSClock) -> MOSConfig {
        var config = self
        config.clock = clock
        return config
    }

    func with(cache: any DecisionCacheStore, queue: any MeteringQueueStore, meters: any MeterLedgerStore = InMemoryMeterLedgerStore()) -> MOSConfig {
        var config = self
        config.cacheStore = cache
        config.queueStore = queue
        config.meterStore = meters
        return config
    }
}

extension InMemoryIdentityStore {
    /// Holds `anonymousIdentifier`, if given, under the SDK's key.
    convenience init(anonymousIdentifier: String?) {
        self.init(anonymousIdentifier.map { [IdentityStoreKey.anonymousIdentifier: $0] } ?? [:])
    }
}

extension IdentityStore {
    var anonymousIdentifier: String? { value(forKey: IdentityStoreKey.anonymousIdentifier) }
    var lastIdentityKey: String? { value(forKey: IdentityStoreKey.lastIdentityKey) }
    var pendingPreviousAnonymousIdentifier: String? { value(forKey: IdentityStoreKey.pendingPreviousAnonymousIdentifier) }
}

/// A value the test can change after construction, for `jwtProvider`.
final class Box<Value: Sendable>: Sendable {
    private let value: OSAllocatedUnfairLock<Value>
    init(_ value: Value) { self.value = OSAllocatedUnfairLock(initialState: value) }
    func get() -> Value { value.withLock { $0 } }
    func set(_ newValue: Value) { value.withLock { $0 = newValue } }
}

/// Holds a request open until the test opens it.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// Polls until `condition` holds, so a test can wait for concurrent calls to reach a point.
func waitUntil(_ condition: @Sendable () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
    for _ in 0..<1_000 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("The condition never held", sourceLocation: sourceLocation)
}

enum TestTime {
    /// 2023-11-14, after every expired fixture token and before the future one.
    static let base: Int64 = 1_700_000_000_000
    /// 2017-07-14, before every fixture token expiry.
    static let before2020: Int64 = 1_500_000_000_000
    static let minute: Int64 = 60_000
    static let hour: Int64 = 3_600_000
    static let day: Int64 = 86_400_000
}

enum TestKeys {
    static let publicKey = "pk_test_env1_s3cr3t_part"
}

/// A full MOS wired to in-memory stores, a fake transport and a fake clock.
struct Harness {
    let transport: FakeTransport
    let clock: FakeClock
    let identity: InMemoryIdentityStore
    let cache: InMemoryDecisionCacheStore
    let queue: InMemoryMeteringQueueStore
    let meters: InMemoryMeterLedgerStore
    let logs = LogRecorder()
    let mos: MOS

    init(
        anonymousIdentifier: String? = nil,
        offline: MOSConfig.Offline = MOSConfig.Offline(),
        jwtProvider: (@Sendable () async -> String?)? = nil,
        claimKey: String = "sub",
        now: Int64 = TestTime.base,
        cached: [DecisionCacheEntry] = [],
        queued: [QueuedCounterUpdate] = [],
        ledger: [MeterLedgerEntry] = [],
        publicKey: String = TestKeys.publicKey,
        apiBaseURL: String = "https://api.example.com",
        requestTimeout: Duration = .seconds(5),
        sharing other: Harness? = nil,
        handler: @escaping FakeTransport.Handler = { _ in .json(Decisions.make()) }
    ) {
        transport = FakeTransport(handler)
        clock = other?.clock ?? FakeClock(now)
        identity = other?.identity ?? InMemoryIdentityStore(anonymousIdentifier: anonymousIdentifier)
        cache = other?.cache ?? InMemoryDecisionCacheStore(cached)
        queue = other?.queue ?? InMemoryMeteringQueueStore(queued)
        meters = other?.meters ?? InMemoryMeterLedgerStore(ledger)
        mos = try! MOS(config: MOSConfig(
            publicKey: publicKey,
            surface: "app-paywall",
            app: MOSConfig.App(name: "Herald", version: "2.1"),
            apiBaseURL: apiBaseURL,
            identity: MOSConfig.Identity(jwtProvider: jwtProvider, store: identity, claimKey: claimKey),
            offline: offline,
            requestTimeout: requestTimeout,
            onLog: logs.onLog,
            transport: transport
        ).with(clock: clock).with(cache: cache, queue: queue, meters: meters))
    }

    /// One decision through the network, then waits for its background flush.
    @discardableResult
    func decide(_ resourceId: String = "article/1", properties: [String: JSONValue]? = nil, policy: CachePolicy = .networkFirst) async -> DecisionResult {
        let result = await mos.decide(resource: Resource(id: resourceId), properties: properties, policy: policy)
        await mos.waitForBackgroundFlush()
        return result
    }
}

extension HTTPResponse {
    static func json(_ value: JSONValue, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: value.encoded())
    }

    static func text(_ body: String, status: Int) -> HTTPResponse {
        HTTPResponse(status: status, body: Data(body.utf8))
    }

    static func fixture(_ name: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: Fixtures.data(name))
    }

    static let counterSuccess = HTTPResponse.json(["status": "success"])
}

extension HTTPRequest {
    var json: JSONValue { JSONValue.parse(body) ?? .null }
}

/// Routes by path so a decision and its background flush can answer differently.
func route(
    decision: @escaping FakeTransport.Handler = { _ in .json(Decisions.make()) },
    counter: @escaping FakeTransport.Handler = { _ in .counterSuccess }
) -> FakeTransport.Handler {
    { request in
        request.url.path == "/api/v1/counter-updates" ? try await counter(request) : try await decision(request)
    }
}

enum Fixtures {
    static let directory: URL = {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent("fixtures")
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path),
               FileManager.default.fileExists(atPath: candidate.path)
            {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        fatalError("fixtures/ not found above \(#filePath)")
    }()

    static func data(_ name: String) -> Data {
        try! Data(contentsOf: directory.appendingPathComponent(name))
    }

    static func json(_ name: String) -> JSONValue {
        JSONValue.parse(data(name))!
    }

    static var fileNames: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.filter { $0 != "README.md" }.sorted() ?? []
    }
}

enum Tokens {
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func make(payload: JSONValue) -> String {
        let header = base64URL(Data(#"{"alg":"ES256","typ":"JWT"}"#.utf8))
        return "\(header).\(base64URL(payload.encoded())).\(base64URL(Data("signature".utf8)))"
    }

    static func offer(expirationMsUtc: Int64?) -> String {
        make(payload: [
            "id": "offer_1",
            "presentation": ["productId": "com.example.monthly"],
            "redemptionSchema": "custom:purchase",
            "expirationMsUtc": expirationMsUtc.map { .number(Double($0)) } ?? .null,
            "redemption": "ZW5jcnlwdGVk",
        ])
    }

    static func jwt(sub: String?) -> String {
        var payload: [String: JSONValue] = ["iss": "https://auth.example.com", "exp": 1_900_000_000]
        if let sub { payload["sub"] = .string(sub) }
        return make(payload: .object(payload))
    }
}

enum Decisions {
    struct Meter {
        var feature = "article"
        var property = "enabled"
        var counterId: String? = "default:feat_article.enabled"
        var hasAccess = true
        var consumedInRequest: Bool? = true
        var consumedUnitsInRequest: Double? = 1
        /// A counted meter, as the server sends for a meter that is neither `on` nor `off`.
        var consumedUnits: Double?
        var totalUnits: Double?
        var uniqueResources: Bool?
        var resourceIdUsed: Bool?
        var periodStart: String?
    }

    static func make(
        identifier: String = "mos-anon-v1-abc",
        isAuthenticated: Bool = false,
        eventId: String = "evt-1",
        meters: [Meter] = [],
        offerTokens: [String] = [],
        surfaceProperties: [String: JSONValue] = [:]
    ) -> JSONValue {
        var features: [String: JSONValue] = [:]
        for meter in meters {
            var property: [String: JSONValue] = [
                "type": "meterable", "isFallback": false, "hasAccess": .bool(meter.hasAccess),
            ]
            if let counterId = meter.counterId { property["counterId"] = .string(counterId) }
            if let consumed = meter.consumedInRequest { property["consumedInRequest"] = .bool(consumed) }
            if let units = meter.consumedUnitsInRequest { property["consumedUnitsInRequest"] = .number(units) }
            if let consumed = meter.consumedUnits { property["consumedUnits"] = .number(consumed) }
            if let total = meter.totalUnits {
                property["totalUnits"] = .number(total)
                property["remainingUnits"] = .number(max(0, total - (meter.consumedUnits ?? 0)))
            }
            if let unique = meter.uniqueResources { property["uniqueResources"] = .bool(unique) }
            if let used = meter.resourceIdUsed { property["resourceIdUsed"] = .bool(used) }
            if let periodStart = meter.periodStart { property["periodStart"] = .string(periodStart) }
            var feature = features[meter.feature]?.objectValue ?? [
                "featureId": .string("feat_\(meter.feature)"), "featureSlug": .string(meter.feature), "properties": [:],
            ]
            var properties = feature["properties"]?.objectValue ?? [:]
            properties[meter.property] = .object(property)
            feature["properties"] = .object(properties)
            features[meter.feature] = .object(feature)
        }
        var properties = surfaceProperties
        if !offerTokens.isEmpty {
            properties["mos-offer-slots"] = .array(offerTokens.map { ["type": "single", "offer": ["id": "offer_1", "token": .string($0)]] })
        }
        return [
            "status": "success",
            "eventId": .string(eventId),
            "identity": [
                "identifier": .string(identifier), "isAuthenticated": .bool(isAuthenticated),
                "authType": isAuthenticated ? "jwt" : "anonymous", "jwtClaims": [:],
            ],
            "customer": ["isCustomer": false, "hasProducts": false, "customerIdentifiers": []],
            "features": .object(features),
            "surfaceBehavior": ["properties": .object(properties)],
            "componentsSkipped": false,
            "componentBehaviors": [:],
        ]
    }

    static func entry(
        resourceId: String = "article/1",
        identityKey: String = "anon:mos-anon-v1-abc",
        surface: String = "app-paywall",
        components: [String]? = nil,
        decision: JSONValue = make(),
        storedAt: Int64 = TestTime.base,
        expiresAt: Int64 = TestTime.base + TestTime.day
    ) -> DecisionCacheEntry {
        DecisionCacheEntry(
            surface: surface, identityKey: identityKey, resourceId: resourceId, components: components, decision: decision, storedAt: storedAt,
            expiresAt: expiresAt
        )
    }

    static func queued(
        identityKey: String = "anon:mos-anon-v1-abc",
        counterId: String = "default:feat_article.enabled",
        resourceId: String = "article/1",
        update: Double = 1,
        enqueuedAt: Int64 = TestTime.base
    ) -> QueuedCounterUpdate {
        QueuedCounterUpdate(
            identityKey: identityKey,
            anonymousIdentifier: identityKey.hasPrefix("anon:") ? String(identityKey.dropFirst(5)) : nil,
            counterId: counterId,
            resourceId: resourceId,
            update: update,
            enqueuedAt: enqueuedAt
        )
    }
}

let networkDown: FakeTransport.Handler = { _ in throw URLError(.notConnectedToInternet) }

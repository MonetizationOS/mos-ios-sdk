import Foundation

public enum MOSError: Error, Equatable {
    /// The key is not a public (`pk_`) key. A secret key must never ship in an app.
    case invalidPublicKey
}

/// The identity sent with a request, in resolution order.
enum RequestIdentity: Sendable, Equatable {
    /// `key` is `IdentityKey.jwt` with the configured claim key.
    case jwt(String, key: String)
    case anonymous(String)
    case createAnonymous

    /// Scopes the cache and queue. nil until the server mints an anonymous id.
    var key: String? {
        switch self {
        case .jwt(_, let key): key
        case .anonymous(let identifier): IdentityKey.anonymous(identifier)
        case .createAnonymous: nil
        }
    }

    var kind: String {
        switch self {
        case .jwt: "jwt"
        case .anonymous: "anon"
        case .createAnonymous: "create"
        }
    }

    /// `anonymousFallback` is for `surface-decisions` only. Elsewhere a bad JWT must fail with
    /// 401 rather than have its consumption or redemption land on a freshly minted anon id.
    func json(anonymousFallback: Bool) -> JSONValue {
        switch self {
        case .jwt(let token, _) where anonymousFallback: ["userJwt": .string(token), "createAnonymousIdentifierFallback": true]
        case .jwt(let token, _): ["userJwt": .string(token)]
        case .anonymous(let identifier): ["anonymousIdentifier": .string(identifier)]
        case .createAnonymous: ["createAnonymousIdentifier": true]
        }
    }
}

/// The MonetizationOS client. Methods never throw: failures come back in the result, and
/// `surface-decisions` is never retried because it consumes meters with no idempotency key.
/// Use one instance per app; instances sharing the default stores overwrite each other's files.
public actor MOS {
    let config: MOSConfig
    let userAgent: String
    let environment: String?
    let requests: APIRequests
    let transport: any HTTPTransport
    let clock: any MOSClock
    let identityStore: any IdentityStore
    let cacheStore: any DecisionCacheStore
    let queueStore: any MeteringQueueStore
    let meterStore: any MeterLedgerStore

    var explicitJWT: String?
    var lastIdentityKey: String?
    var pendingPreviousAnonymousIdentifier: String?
    /// A pending id dropped by an account switch, so a request already carrying it still reports the link.
    var droppedPreviousAnonymousIdentifier: String?
    var identityStateLoaded = false
    /// A minted id the identity store did not keep, used for the rest of the process while the store returns nothing.
    var unpersistedAnonymousIdentifier: String?
    /// The key of the latest resolution, nil for `createAnonymous`. A response is applied only
    /// while this still equals the key its request was sent under.
    var currentIdentityKey: String?
    var loadedCache: DecisionCache?
    var loadedQueue: MeteringQueue?
    var loadedLedger: MeterLedger?
    var flushTask: Task<FlushResult, Never>?
    /// Bumped by `reset()`, so a response that lands afterwards persists nothing.
    var generation = 0
    var cacheEpoch = 0
    var inFlightDecisions: [Data: InFlight<DecisionOutcome>] = [:]
    var inFlightRedemptions: [Data: InFlight<RedemptionResult>] = [:]
    var nextInFlightId: UInt64 = 0
    /// When fail-fast was entered; nil outside it.
    var failFastSince: Int64?

    public init(config: MOSConfig) throws {
        guard config.publicKey.hasPrefix("pk_") else {
            config.onLog(LogEvent(
                level: .error,
                code: "config:invalid-key",
                message: "MOS needs a public (pk_) key. A secret key must never ship in an app."
            ))
            throw MOSError.invalidPublicKey
        }
        self.config = config
        userAgent = UserAgent.make(appName: config.app.name, appVersion: config.app.version)
        environment = APIRequests.environment(fromPublicKey: config.publicKey)
        requests = APIRequests(
            apiBaseURL: config.apiBaseURL,
            publicKey: config.publicKey,
            userAgent: userAgent,
            timeout: config.requestTimeout.seconds
        )
        transport = config.transport ?? URLSessionTransport()
        clock = config.clock ?? SystemClock()
        // Scoped by the key's environment, so a staging and a production key in one install share nothing.
        identityStore = config.identity.store ?? KeychainIdentityStore(publicKey: config.publicKey)
        let directory = MOSStorage.defaultDirectory(environment: MOSStorage.environment(publicKey: config.publicKey))
        cacheStore = config.cacheStore ?? FileDecisionCacheStore(directory: directory)
        queueStore = config.queueStore ?? FileMeteringQueueStore(directory: directory)
        meterStore = config.meterStore ?? FileMeterLedgerStore(directory: directory)
    }

    /// The anonymous id in use, if any: the persisted one, else one the identity store failed to keep.
    public var anonymousIdentifier: String? {
        storedAnonymousIdentifier()
    }

    /// Sets the explicit identity, which beats `jwtProvider` (nil clears it), then resolves
    /// identity at once and applies the identity-change rules. No network call. Kept in memory
    /// only: call it at every launch before anything else, or use `jwtProvider`.
    @discardableResult
    public func identify(userJWT: String?) async -> IdentifyResult {
        explicitJWT = userJWT.flatMap(Self.nonBlank)
        let resolution = await resolve()
        return IdentifyResult(
            changed: resolution.changed,
            previous: IdentityKind(key: resolution.previousKey),
            current: IdentityKind(key: resolution.identity.key),
            linkPending: pendingPreviousAnonymousIdentifier != nil
        )
    }

    /// Forgets the anonymous id, the identity state, the cache, the queue and the offline meter
    /// counts (sign-out, demo reset).
    public func reset() {
        generation += 1
        explicitJWT = nil
        identityStore.setValue(nil, forKey: IdentityStoreKey.anonymousIdentifier)
        identityStore.setValue(nil, forKey: IdentityStoreKey.lastIdentityKey)
        identityStore.setValue(nil, forKey: IdentityStoreKey.pendingPreviousAnonymousIdentifier)
        unpersistedAnonymousIdentifier = nil
        identityStateLoaded = true
        lastIdentityKey = nil
        pendingPreviousAnonymousIdentifier = nil
        droppedPreviousAnonymousIdentifier = nil
        currentIdentityKey = nil
        inFlightDecisions = [:]
        inFlightRedemptions = [:]
        clearCache(reason: "reset")
        loadedQueue = MeteringQueue(entries: [])
        queueStore.save([])
        saveLedger(MeterLedger(entries: []))
    }

    /// Drops cached decisions for every identity, e.g. after a purchase changed entitlements.
    public func clearCache() {
        cacheEpoch += 1
        inFlightDecisions = [:]
        clearCache(reason: "entitlements-changed")
    }

    // MARK: Decisions

    /// `surface` overrides `config.surface` for this call: its slug, cache entries, fallback and
    /// coalescing. An empty one fails with `requestFailed` without sending.
    /// `components` names the surface's components to run: nil runs them all, empty runs only the
    /// surface workflow, unknown slugs are ignored. Each selection has its own cache entries and
    /// fallback; order and duplicates do not matter.
    public func decide(
        resource: Resource, properties: [String: JSONValue]? = nil, policy: CachePolicy = .networkFirst, surface: String? = nil,
        components: [String]? = nil
    ) async -> DecisionResult {
        let surface = surface ?? config.surface
        let components = components.map { Array(Set($0)).sorted() }
        guard !surface.isEmpty else {
            let failure = Failure(reason: .requestFailed, message: "The surface slug is empty.")
            log(.warn, "decision:error", "The surface decision failed (requestFailed).", [
                "reason": .string(failure.reason.rawValue), "status": .null, "surface": .string(surface),
            ])
            return unavailable(resource: resource, surface: surface, failure: failure)
        }
        let identity = await resolveIdentity()
        switch policy {
        case .cacheOnly:
            return serveFromCache(resource: resource, surface: surface, components: components, identityKey: identity.key, failure: nil)
        case .cacheFirst(let maxAge):
            let now = clock.nowMs()
            if let key = identity.key,
               let entry = readCache(now: now).exact(surface: surface, identityKey: key, resourceId: resource.id, components: components),
               now - entry.storedAt <= maxAge.milliseconds,
               let served = serve(entry, exact: true, resource: resource, surface: surface, identityKey: key, failure: nil, now: now)
            {
                return served
            }
        case .networkFirst, .networkOnly:
            break
        }

        let outcome = await requestDecision(
            identity: identity, resource: resource, properties: properties, surface: surface, components: components
        )
        switch outcome.result {
        case .success(let decision):
            return DecisionResult(
                decision: decision, source: .network, failure: nil,
                linkedAnonymousIdentifier: outcome.linkedAnonymousIdentifier, failOpen: config.offline.failOpen
            )
        case .failure(let failure):
            if policy == .networkOnly { return unavailable(resource: resource, surface: surface, failure: failure) }
            return serveFromCache(resource: resource, surface: surface, components: components, identityKey: identity.key, failure: failure)
        }
    }

    /// Joins an identical request already in flight, else sends one. Joiners apply their own
    /// policy fallback to the shared outcome.
    /// The body includes `surfaceSlug` and `components`, so requests for different surfaces or
    /// selections never coalesce.
    private func requestDecision(
        identity: RequestIdentity, resource: Resource, properties: [String: JSONValue]?, surface: String, components: [String]?
    ) async -> DecisionOutcome {
        let previousAnonymous = pendingPreviousAnonymousIdentifier
        // `platform` lets one surface's workflow pick per-store copy; a host value wins.
        var merged: [String: JSONValue] = ["platform": "ios"].merging(properties ?? [:]) { _, host in host }
        if let previousAnonymous { merged["previousAnonymousIdentifier"] = .string(previousAnonymous) }
        var body: [String: JSONValue] = [
            "surfaceSlug": .string(surface),
            "identity": identity.json(anonymousFallback: true),
            "resource": resource.json,
            "properties": .object(merged),
        ]
        if let components { body["components"] = .array(components.map(JSONValue.string)) }
        let json = JSONValue.object(body)
        let key = json.encoded()
        if let inFlight = inFlightDecisions[key] {
            log(.debug, "decision:coalesced", "Joined an identical decision request already in flight.", [
                "surface": .string(surface), "resourceId": .string(resource.id),
            ])
            // Only the sender reports the link; it is delivered once.
            let shared = await inFlight.task.value
            return DecisionOutcome(result: shared.result, linkedAnonymousIdentifier: false)
        }
        let id = makeInFlightId()
        let task = Task {
            await self.sendDecision(
                json, key: key, id: id, identity: identity, resource: resource, surface: surface, components: components,
                previousAnonymous: previousAnonymous
            )
        }
        inFlightDecisions[key] = InFlight(id: id, task: task)
        return await task.value
    }

    private func sendDecision(
        _ body: JSONValue, key: Data, id: UInt64, identity: RequestIdentity, resource: Resource, surface: String, components: [String]?,
        previousAnonymous: String?
    ) async -> DecisionOutcome {
        log(.debug, "decision:start", "Requesting a surface decision.", [
            "surface": .string(surface), "resourceId": .string(resource.id), "identity": .string(identity.kind),
        ])

        let startedAt = clock.nowMs()
        let generationAtStart = generation
        let cacheEpochAtStart = cacheEpoch
        let result = await send(requests.api("/api/v1/surface-decisions", body: body)).flatMap { response in
            APIResponse.interpret(response).flatMap { json in
                Decision(json: json).map { .success($0) } ?? .failure(APIResponse.invalidResponse(status: response.status))
            }
        }
        if inFlightDecisions[key]?.id == id { inFlightDecisions[key] = nil }
        let latencyMs = JSONValue.int(clock.nowMs() - startedAt)

        switch result {
        case .failure(let failure):
            log(.warn, "decision:error", "The surface decision failed (\(failure.reason.rawValue)).", [
                "reason": .string(failure.reason.rawValue), "status": .int(failure.status),
                "statusCode": .int(failure.statusCode), "latencyMs": latencyMs, "surface": .string(surface),
            ])
            return DecisionOutcome(result: result, linkedAnonymousIdentifier: false)
        case .success(let decision):
            log(.info, "decision:success", "Received a surface decision.", [
                "latencyMs": latencyMs, "eventId": decision.eventID.map(JSONValue.string) ?? .null, "source": "network",
                "surface": .string(surface),
            ])
            // The server saw the link even if the identity has moved on since; only a reset voids it. An
            // anonymous answer (an expired token) cannot link, so the id stays pending for the next decision.
            let linked = previousAnonymous != nil && decision.identity.isAuthenticated && generation == generationAtStart
                && [pendingPreviousAnonymousIdentifier, droppedPreviousAnonymousIdentifier].contains(previousAnonymous)
            if linked {
                setPendingPreviousAnonymousIdentifier(nil)
                log(.info, "identity:previous-anon-sent", "The previous anonymous identifier reached the server.")
            }
            if let reason = staleReason(identity: identity, generationAtStart: generationAtStart) {
                log(.debug, "identity:stale-response", "The response no longer belongs to the current identity; it was not applied.", [
                    "reason": .string(reason),
                ])
            } else {
                didReceive(
                    decision, identity: identity, resource: resource, surface: surface, components: components,
                    cacheable: cacheEpoch == cacheEpochAtStart
                )
            }
            return DecisionOutcome(result: result, linkedAnonymousIdentifier: linked)
        }
    }

    /// Why a response may not be applied, or nil when it still belongs to the current identity.
    private func staleReason(identity: RequestIdentity, generationAtStart: Int) -> String? {
        if generation != generationAtStart { return "reset" }
        if identity == .createAnonymous, storedAnonymousIdentifier() != nil { return "anonymous-already-stored" }
        if currentIdentityKey != identity.key { return "identity-changed" }
        return nil
    }

    /// `cacheable` is false when `clearCache()` ran while the request was in flight: it may
    /// predate the entitlement change.
    private func didReceive(
        _ decision: Decision, identity: RequestIdentity, resource: Resource, surface: String, components: [String]?, cacheable: Bool
    ) {
        var effectiveKey = identity.key
        if !decision.identity.isAuthenticated, let identifier = decision.identity.identifier.flatMap(Self.nonBlank) {
            let stored = storedAnonymousIdentifier()
            // A JWT answered anonymously gets a fresh id each time; it must not replace the device's own.
            var keepStored = false
            if case .jwt = identity, stored != nil { keepStored = true }
            if stored != identifier, !keepStored { persistAnonymousIdentifier(identifier) }
            // A JWT request stays keyed by its JWT; an anonymous one is keyed by what the server
            // returned, which is how a freshly minted id gets its first cache entry.
            if case .jwt = identity {} else { effectiveKey = IdentityKey.anonymous(identifier) }
        }
        guard let effectiveKey else { return }
        if effectiveKey != identity.key { noteIdentityKey(effectiveKey) }
        if case .jwt = identity, !decision.identity.isAuthenticated {
            // An expired token or a server fallback: not the signed-in user's decision or meter counts.
            log(.debug, "cache:skipped", "Did not cache an anonymous answer to a signed-in request.", [
                "reason": "anonymous-answer", "surface": .string(surface),
            ])
        } else if cacheable {
            putInCache(decision.raw, surface: surface, components: components, identityKey: effectiveKey, resourceId: resource.id)
            recordMeters(from: decision, identityKey: effectiveKey, resourceId: resource.id, now: clock.nowMs())
        }
        // A flush resolves the identity again (another `jwtProvider` call), so only start one with something
        // queued. A minted id has nothing queued yet.
        if identity.key != nil, !loadQueue().entries.isEmpty { startFlush() }
    }

    // MARK: Identity

    /// Explicit `identify()` value, then `jwtProvider`, then the persisted anonymous id, then
    /// ask the server to mint one.
    func resolveIdentity() async -> RequestIdentity {
        await resolve().identity
    }

    func resolve() async -> (identity: RequestIdentity, previousKey: String?, changed: Bool) {
        loadIdentityState()
        let identity: RequestIdentity
        while true {
            // The provider may suspend: an `identify()` meanwhile wins, a `reset()` meanwhile voids its answer.
            let generationAtStart = generation
            var token: String?
            if explicitJWT == nil { token = await config.identity.jwtProvider?() }
            if generation != generationAtStart { continue }
            if let jwt = (explicitJWT ?? token).flatMap(Self.nonBlank) {
                identity = .jwt(jwt, key: IdentityKey.jwt(jwt, claimKey: config.identity.claimKey))
            } else if let anonymous = storedAnonymousIdentifier() {
                identity = .anonymous(anonymous)
            } else {
                identity = .createAnonymous
            }
            break
        }
        let previousKey = lastIdentityKey
        let changed = noteIdentityKey(identity.key)
        return (identity, previousKey, changed)
    }

    /// A whitespace-only token or identifier counts as none.
    private static func nonBlank(_ value: String) -> String? {
        value.allSatisfy(\.isWhitespace) ? nil : value
    }

    func storedAnonymousIdentifier() -> String? {
        if let stored = identityStore.value(forKey: IdentityStoreKey.anonymousIdentifier).flatMap(Self.nonBlank) { return stored }
        return unpersistedAnonymousIdentifier
    }

    /// Reads the id back: one the store did not keep stays in memory, so the next decision does not mint again.
    private func persistAnonymousIdentifier(_ identifier: String) {
        identityStore.setValue(identifier, forKey: IdentityStoreKey.anonymousIdentifier)
        if identityStore.value(forKey: IdentityStoreKey.anonymousIdentifier) == identifier {
            unpersistedAnonymousIdentifier = nil
            log(.debug, "identity:anon-persisted", "Persisted the anonymous identifier.", ["anonymousIdentifier": .string(identifier)])
        } else {
            unpersistedAnonymousIdentifier = identifier
            log(.warn, "identity:store-failed", "The identity store did not keep the anonymous identifier; using it from memory.", [
                "store": "identity",
            ])
        }
    }

    /// Lazy so construction never touches the Keychain.
    func loadIdentityState() {
        guard !identityStateLoaded else { return }
        identityStateLoaded = true
        lastIdentityKey = identityStore.value(forKey: IdentityStoreKey.lastIdentityKey)
        pendingPreviousAnonymousIdentifier = identityStore.value(forKey: IdentityStoreKey.pendingPreviousAnonymousIdentifier)
    }

    /// Records the current key and applies the identity-change rules. Returns whether it changed.
    @discardableResult
    func noteIdentityKey(_ key: String?) -> Bool {
        currentIdentityKey = key
        // No self-link: back on the pending anon id (sign in, sign out, no decision between).
        defer {
            if let key, let pending = pendingPreviousAnonymousIdentifier, key == IdentityKey.anonymous(pending) {
                setPendingPreviousAnonymousIdentifier(nil)
            }
        }
        let previous = lastIdentityKey
        guard previous != key else { return false }
        lastIdentityKey = key
        identityStore.setValue(key, forKey: IdentityStoreKey.lastIdentityKey)
        guard let previous else { return false }
        clearCache(reason: "identity-changed")
        log(.info, "identity:changed", "The identity changed; the decision cache was purged.", [
            "from": .string(IdentityKey.prefix(previous)), "to": .string(key.map(IdentityKey.prefix) ?? "none"),
        ])
        if previous.hasPrefix("anon:") {
            setPendingPreviousAnonymousIdentifier(String(previous.dropFirst("anon:".count)))
        } else if previous.hasPrefix("jwt:"), key?.hasPrefix("jwt:") == true {
            // Anon history is linked to the first account only, never to the next one.
            let dropped = pendingPreviousAnonymousIdentifier
            setPendingPreviousAnonymousIdentifier(nil)
            droppedPreviousAnonymousIdentifier = dropped
        }
        return true
    }

    private func setPendingPreviousAnonymousIdentifier(_ identifier: String?) {
        droppedPreviousAnonymousIdentifier = nil
        pendingPreviousAnonymousIdentifier = identifier
        identityStore.setValue(identifier, forKey: IdentityStoreKey.pendingPreviousAnonymousIdentifier)
    }

    // MARK: Redemption and endpoints

    /// Identical concurrent redemptions (a double-tap) send once and share the result. A `redeemed` result
    /// clears the decision cache as `clearCache()` does, since the workflow may have changed entitlements.
    /// Always uses the full `requestTimeout`, even in fail-fast.
    public func redeem(offerToken: String, properties: [String: JSONValue]? = nil) async -> RedemptionResult {
        let identity = await resolveIdentity()
        guard identity != .createAnonymous else {
            let result = RedemptionResult.failed(Failure(reason: .notConfigured, message: "There is no anonymous identifier or JWT yet; make a decision first."))
            logRedemption(result)
            return result
        }
        var body: [String: JSONValue] = ["identity": identity.json(anonymousFallback: false), "offerToken": .string(offerToken)]
        if let properties { body["properties"] = .object(properties) }
        let json = JSONValue.object(body)
        let key = json.encoded()
        if let inFlight = inFlightRedemptions[key] {
            log(.debug, "redeem:coalesced", "Joined an identical redemption already in flight.")
            return await inFlight.task.value
        }
        let id = makeInFlightId()
        let task = Task { await self.sendRedemption(json, key: key, id: id) }
        inFlightRedemptions[key] = InFlight(id: id, task: task)
        return await task.value
    }

    private func sendRedemption(_ body: JSONValue, key: Data, id: UInt64) async -> RedemptionResult {
        // Cut short, a redemption the server ran would be reported as a timeout.
        let response = await send(requests.api("/api/v1/offer-redemptions", body: body), timeout: config.requestTimeout)
        if inFlightRedemptions[key]?.id == id { inFlightRedemptions[key] = nil }
        let result: RedemptionResult
        switch response {
        case .failure(let failure): result = .failed(failure)
        case .success(let response): result = Self.redemptionResult(response)
        }
        logRedemption(result)
        if case .redeemed = result { clearCache() }
        return result
    }

    private func logRedemption(_ result: RedemptionResult) {
        switch result {
        case .redeemed(let action, let eventID, _):
            log(.info, "redeem:success", "The offer was redeemed.", [
                "eventId": eventID.map(JSONValue.string) ?? .null, "action": .string(action.type),
            ])
        case .declined(let message, let statusCode, let eventID):
            log(.info, "redeem:declined", "The offer redemption was declined.", [
                "eventId": eventID.map(JSONValue.string) ?? .null, "statusCode": .int(statusCode),
                "message": message.map(JSONValue.string) ?? .null,
            ])
        case .failed(let failure):
            log(.warn, "redeem:error", "The offer redemption failed (\(failure.reason.rawValue)).", [
                "reason": .string(failure.reason.rawValue), "status": .int(failure.status),
            ])
        }
    }

    static func redemptionResult(_ response: HTTPResponse) -> RedemptionResult {
        if let json = JSONValue.parse(response.body), json["status"]?.stringValue == "failure" {
            return .declined(
                message: json["message"]?.stringValue,
                statusCode: json["statusCode"]?.intValue ?? response.status,
                eventID: json["eventId"]?.stringValue
            )
        }
        switch APIResponse.interpret(response) {
        case .failure(let failure):
            return .failed(failure)
        case .success(let json):
            guard json["status"]?.stringValue == "success" else { return .failed(APIResponse.invalidResponse(status: response.status)) }
            return .redeemed(
                action: Action(json: json["action"]),
                eventID: json["eventId"]?.stringValue,
                statusCode: json["statusCode"]?.intValue ?? response.status
            )
        }
    }

    // MARK: Plumbing

    /// An explicit `timeout` is used exactly and its own timeout does not enter the fail-fast tier; redemptions
    /// and endpoint calls always pass one.
    func send(_ request: HTTPRequest?, timeout: Duration? = nil) async -> Result<HTTPResponse, Failure> {
        guard let request else { return .failure(Failure(reason: .requestFailed, message: "The request URL is not valid.")) }
        do {
            let response = try await transport.send(request.withTimeout(timeout?.seconds ?? currentTimeout()))
            if failFastSince != nil { leaveFailFast(reason: "response") }
            return .success(response)
        } catch {
            let failure = APIResponse.failure(from: error)
            if failure.reason == .timeout, timeout == nil { enterFailFast() }
            return .failure(failure)
        }
    }

    static let failFastTimeout: Duration = .seconds(2)
    static let failFastWindowMs: Int64 = 10 * 60 * 1000

    /// `requestTimeout`, or `min(requestTimeout, 2s)` for ten minutes after a timeout enters fail-fast,
    /// so an app on a dead network stops waiting the full timeout on every call. Timeouts inside the
    /// window do not extend it, so a slow network gets the full timeout again when it ends.
    func currentTimeout() -> TimeInterval {
        if let failFastSince, clock.nowMs() - failFastSince >= Self.failFastWindowMs {
            leaveFailFast(reason: "expired")
        }
        guard failFastSince != nil else { return config.requestTimeout.seconds }
        return min(config.requestTimeout, Self.failFastTimeout).seconds
    }

    private func enterFailFast() {
        guard failFastSince == nil else { return }
        failFastSince = clock.nowMs()
        log(.info, "transport:degraded", "A request timed out; using the shorter fail-fast timeout.", [
            "timeoutMs": .int(min(config.requestTimeout, Self.failFastTimeout).milliseconds),
        ])
    }

    private func leaveFailFast(reason: String) {
        failFastSince = nil
        log(.info, "transport:recovered", "Back to the full request timeout.", ["reason": .string(reason)])
    }

    func makeInFlightId() -> UInt64 {
        nextInFlightId += 1
        return nextInFlightId
    }

    /// `package` so MonetizationOSUI logs through the host's `onLog`.
    package func log(_ level: LogEvent.Level, _ code: String, _ message: String, _ context: [String: JSONValue] = [:]) {
        config.onLog(LogEvent(level: level, code: code, message: message, context: .object(context)))
    }
}

/// A shared request: joiners await `task`; `id` stops a finished request from removing a
/// newer entry for the same body.
struct InFlight<Value: Sendable>: Sendable {
    let id: UInt64
    let task: Task<Value, Never>
}

struct DecisionOutcome: Sendable {
    let result: Result<Decision, Failure>
    let linkedAnonymousIdentifier: Bool
}

extension JSONValue {
    static func int(_ value: Int64) -> JSONValue { .number(Double(value)) }
    package static func int(_ value: Int) -> JSONValue { .number(Double(value)) }
    static func int(_ value: Int?) -> JSONValue { value.map { .number(Double($0)) } ?? .null }
}

import Foundation

/// Milliseconds since the Unix epoch. Injectable so tests control expiry and ages.
protocol MOSClock: Sendable {
    func nowMs() -> Int64
}

struct SystemClock: MOSClock {
    func nowMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }
}

public struct MOSConfig: Sendable {
    /// For the User-Agent; both required.
    public struct App: Sendable {
        public var name: String
        public var version: String

        public init(name: String, version: String) {
            self.name = name
            self.version = version
        }
    }

    public struct Identity: Sendable {
        /// Read fresh at each call. Return nil only when the user is signed out: nil switches to the anonymous
        /// identity, which purges the decision cache and drops that user's queued counter updates. If a refresh
        /// fails, return the last token, even an expired one: the server answers that decision anonymously and
        /// the SDK keeps the user.
        public var jwtProvider: (@Sendable () async -> String?)?
        /// Where the anonymous identifier and the rest of the identity state are kept. nil means the Keychain.
        public var store: (any IdentityStore)?
        /// The JWT claim MOS identifies users by, `sub` by default. Set it to the claim key of your JWT
        /// integration in MOS.
        public var claimKey: String

        public init(jwtProvider: (@Sendable () async -> String?)? = nil, store: (any IdentityStore)? = nil, claimKey: String = "sub") {
            self.jwtProvider = jwtProvider
            self.store = store
            self.claimKey = claimKey
        }
    }

    public struct Offline: Sendable {
        public var ttl: Duration
        /// What `hasAccess` answers when there is no decision or no such property.
        public var failOpen: Bool
        /// On failure with no exact entry, serve the latest entry for this surface and identity.
        public var fallbackToLatest: Bool
        public var maxEntries: Int
        /// Turn a meter's access off offline once the reads counted on this device since the last
        /// network decision use it up. The cached decision has no paywall for that, so show your own.
        public var enforceMeters: Bool

        public init(
            ttl: Duration = .seconds(24 * 60 * 60), failOpen: Bool = true, fallbackToLatest: Bool = true, maxEntries: Int = 50,
            enforceMeters: Bool = false
        ) {
            self.ttl = ttl
            self.failOpen = failOpen
            self.fallbackToLatest = fallbackToLatest
            self.maxEntries = maxEntries
            self.enforceMeters = enforceMeters
        }
    }

    public var publicKey: String
    public var surface: String
    public var apiBaseURL: String
    public var app: App
    public var identity: Identity
    public var offline: Offline
    /// End to end per API call. A timeout enters fail-fast: decisions and counter updates use
    /// `min(requestTimeout, 2s)` for the ten minutes that follow, or until any response. Redemptions and
    /// endpoint calls always get the full timeout, and their timeouts do not enter fail-fast.
    public var requestTimeout: Duration
    /// The SDK's own cache, queue and meter files; tests inject others.
    var cacheStore: (any DecisionCacheStore)?
    var queueStore: (any MeteringQueueStore)?
    var meterStore: (any MeterLedgerStore)?
    /// Receives every `LogEvent`. Defaults to discarding them.
    public var onLog: @Sendable (LogEvent) -> Void
    public var transport: (any HTTPTransport)?
    var clock: (any MOSClock)?

    public init(
        publicKey: String,
        surface: String,
        app: App,
        apiBaseURL: String = "https://api.monetizationos.com",
        identity: Identity = Identity(),
        offline: Offline = Offline(),
        requestTimeout: Duration = .seconds(5),
        onLog: @escaping @Sendable (LogEvent) -> Void = { _ in },
        transport: (any HTTPTransport)? = nil
    ) {
        self.publicKey = publicKey
        self.surface = surface
        self.app = app
        self.apiBaseURL = apiBaseURL
        self.identity = identity
        self.offline = offline
        self.requestTimeout = requestTimeout
        self.onLog = onLog
        self.transport = transport
    }
}

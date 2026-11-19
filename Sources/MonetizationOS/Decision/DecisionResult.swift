import Foundation

/// What a decision request is about. `extra` keys are merged into the resource object at the
/// top level; `id` and `meta` win over `extra` on collision.
public struct Resource: Sendable, Equatable {
    public var id: String
    public var meta: [String: String]?
    public var extra: [String: JSONValue]

    public init(id: String, meta: [String: String]? = nil, extra: [String: JSONValue] = [:]) {
        self.id = id
        self.meta = meta
        self.extra = extra
    }

    var json: JSONValue {
        var object = extra
        object["id"] = .string(id)
        if let meta { object["meta"] = .object(meta.mapValues(JSONValue.string)) }
        return .object(object)
    }
}

public enum CachePolicy: Sendable, Equatable {
    /// Request; on any failure serve the exact cached entry, else the latest for this identity.
    case networkFirst
    /// Serve the exact entry when it is no older than `maxAge`, else behave as `networkFirst`.
    case cacheFirst(maxAge: Duration)
    /// No cache read; the cache is still written on success.
    case networkOnly
    /// Never touch the network.
    case cacheOnly
}

public enum DecisionSource: Sendable, Equatable {
    case network
    case cache(ageMs: Int64)
    case fallback(ageMs: Int64, fromResourceID: String)
    case unavailable
}

public struct Failure: Error, Sendable, Equatable {
    public enum Reason: String, Sendable, Equatable {
        case requestFailed, timeout
        /// Raw value `invalidJson`, as the Android SDK reports it.
        case invalidJSON = "invalidJson"
        case apiError, httpError, invalidResponse, rateLimited, unauthorized, notConfigured
    }

    public let reason: Reason
    /// The HTTP status, when a response arrived.
    public let status: Int?
    /// The `statusCode` from an error envelope, or the HTTP status when the envelope has none.
    public let statusCode: Int?
    public let message: String

    public init(reason: Reason, status: Int? = nil, statusCode: Int? = nil, message: String) {
        self.reason = reason
        self.status = status
        self.statusCode = statusCode
        self.message = message
    }
}

public struct DecisionResult: Sendable, Equatable {
    public let decision: Decision?
    public let source: DecisionSource
    /// Present whenever the network was tried and failed, even when the cache served.
    public let failure: Failure?
    /// True only on the network result whose request carried `previousAnonymousIdentifier`
    /// and was answered for the signed-in user.
    public let linkedAnonymousIdentifier: Bool
    let failOpen: Bool

    init(decision: Decision?, source: DecisionSource, failure: Failure?, linkedAnonymousIdentifier: Bool = false, failOpen: Bool) {
        self.decision = decision
        self.source = source
        self.failure = failure
        self.linkedAnonymousIdentifier = linkedAnonymousIdentifier
        self.failOpen = failOpen
    }

    /// The property's access when a decision exists: a meterable's `hasAccess` or a boolean's
    /// value. Falls back to `offline.failOpen` when there is no decision, the property is
    /// missing, or it carries no access value.
    public func hasAccess(feature: String, property: String) -> Bool {
        switch decision?.features[feature]?.properties[property] {
        case .meterable(let meterable): meterable.hasAccess
        case .boolean(let value?, _): value
        // A malformed property that still says whether access is granted, e.g. a meterable without its
        // counterId: never fail open against an explicit answer.
        case .unknown(_, let json): json["hasAccess"]?.boolValue ?? failOpen
        default: failOpen
        }
    }
}

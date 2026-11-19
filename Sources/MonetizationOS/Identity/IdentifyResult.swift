/// The kind of an identity key: `anon:` or `jwt:`.
public enum IdentityKind: String, Sendable, Equatable {
    case anonymous
    case jwt

    init?(key: String?) {
        guard let key else { return nil }
        if key.hasPrefix("anon:") { self = .anonymous } else if key.hasPrefix("jwt:") { self = .jwt } else { return nil }
    }
}

/// What `identify(userJWT:)` did to the identity.
public struct IdentifyResult: Sendable, Equatable {
    /// The identity key changed, so the cache was purged.
    public let changed: Bool
    /// nil when nothing had been resolved yet.
    public let previous: IdentityKind?
    /// nil when the server will mint an anonymous id on the next decision.
    public let current: IdentityKind?
    /// A `previousAnonymousIdentifier` is waiting to ride the next decision.
    public let linkPending: Bool

    public init(changed: Bool, previous: IdentityKind?, current: IdentityKind?, linkPending: Bool) {
        self.changed = changed
        self.previous = previous
        self.current = current
        self.linkPending = linkPending
    }
}

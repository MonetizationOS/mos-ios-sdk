import Foundation

/// The in-memory cache rules. `MOS` owns one, logs what it reports and persists after changes.
struct DecisionCache {
    var entries: [DecisionCacheEntry]

    /// Expiry is the earlier of the ttl and every offer token's `expirationMsUtc`, so a cached
    /// paywall never outlives the offers it shows.
    static func expiresAt(storedAt: Int64, ttlMs: Int64, decision: JSONValue) -> Int64 {
        let (sum, overflow) = storedAt.addingReportingOverflow(ttlMs)
        let ttlExpiry = overflow ? (ttlMs < 0 ? Int64.min : Int64.max) : sum
        guard let tokenExpiry = OfferTokens.earliestExpiry(in: decision) else { return ttlExpiry }
        return min(ttlExpiry, tokenExpiry)
    }

    /// The cache is a file on disk; `identity.jwtClaims` often holds an email or a name and
    /// nothing reads it from a cached decision, so it is never written.
    static func withoutClaims(_ decision: JSONValue) -> JSONValue {
        guard var body = decision.objectValue, var identity = body["identity"]?.objectValue, identity["jwtClaims"] != nil else { return decision }
        identity["jwtClaims"] = nil
        body["identity"] = .object(identity)
        return .object(body)
    }

    /// Removes every expired entry and returns how many went.
    mutating func evictExpired(now: Int64) -> Int {
        let before = entries.count
        entries.removeAll { $0.expiresAt <= now }
        return before - entries.count
    }

    func exact(surface: String, identityKey: String, resourceId: String, components: [String]?) -> DecisionCacheEntry? {
        entries.first { $0.surface == surface && $0.identityKey == identityKey && $0.resourceId == resourceId && $0.components == components }
    }

    func latest(surface: String, identityKey: String, components: [String]?) -> DecisionCacheEntry? {
        entries.filter { $0.surface == surface && $0.identityKey == identityKey && $0.components == components }.max { $0.storedAt < $1.storedAt }
    }

    /// Inserts or replaces, then evicts the oldest `storedAt` beyond `maxEntries`. Returns the
    /// number evicted.
    mutating func put(_ entry: DecisionCacheEntry, maxEntries: Int) -> Int {
        entries.removeAll {
            $0.surface == entry.surface && $0.identityKey == entry.identityKey && $0.resourceId == entry.resourceId
                && $0.components == entry.components
        }
        entries.append(entry)
        var evicted = 0
        while entries.count > max(maxEntries, 0), let oldest = entries.indices.min(by: { entries[$0].storedAt < entries[$1].storedAt }) {
            entries.remove(at: oldest)
            evicted += 1
        }
        return evicted
    }
}

import Foundation

extension MOS {
    /// The exact entry, else the latest for this identity when `fallbackToLatest`, else nothing.
    /// Both lookups stay within `surface` and the component selection.
    func serveFromCache(resource: Resource, surface: String, components: [String]?, identityKey: String?, failure: Failure?) -> DecisionResult {
        let now = clock.nowMs()
        guard let identityKey else { return unavailable(resource: resource, surface: surface, failure: failure) }
        let cache = readCache(now: now)
        if let entry = cache.exact(surface: surface, identityKey: identityKey, resourceId: resource.id, components: components),
           let served = serve(entry, exact: true, resource: resource, surface: surface, identityKey: identityKey, failure: failure, now: now)
        {
            return served
        }
        if config.offline.fallbackToLatest,
           let entry = cache.latest(surface: surface, identityKey: identityKey, components: components),
           let served = serve(entry, exact: false, resource: resource, surface: surface, identityKey: identityKey, failure: failure, now: now)
        {
            return served
        }
        return unavailable(resource: resource, surface: surface, failure: failure)
    }

    /// Serving from the cache stands in for a consuming request; see `applyOfflineMeters`.
    func serve(
        _ entry: DecisionCacheEntry, exact: Bool, resource: Resource, surface: String, identityKey: String, failure: Failure?, now: Int64
    ) -> DecisionResult? {
        guard let decision = Decision(json: entry.decision) else { return nil }
        let ageMs = now - entry.storedAt
        let source: DecisionSource
        if exact {
            source = .cache(ageMs: ageMs)
            log(.info, "decision:cache-hit", "Served the decision from the cache.", [
                "ageMs": .int(ageMs), "resourceId": .string(resource.id), "surface": .string(surface),
            ])
        } else {
            source = .fallback(ageMs: ageMs, fromResourceID: entry.resourceId)
            log(.info, "decision:fallback", "Served the latest cached decision for another resource.", [
                "ageMs": .int(ageMs), "fromResourceId": .string(entry.resourceId), "resourceId": .string(resource.id),
                "surface": .string(surface),
            ])
        }
        let metered = applyOfflineMeters(to: decision, identityKey: identityKey, resourceId: resource.id, now: now)
        return DecisionResult(decision: metered, source: source, failure: failure, failOpen: config.offline.failOpen)
    }

    func unavailable(resource: Resource, surface: String, failure: Failure?) -> DecisionResult {
        log(.warn, "decision:unavailable", "No decision is available.", ["resourceId": .string(resource.id), "surface": .string(surface)])
        return DecisionResult(decision: nil, source: .unavailable, failure: failure, failOpen: config.offline.failOpen)
    }

    /// Read once; a corrupt store starts empty.
    func loadCache() -> DecisionCache {
        if let loadedCache { return loadedCache }
        let cache = DecisionCache(entries: loadStore("cache", cacheStore.load))
        loadedCache = cache
        return cache
    }

    /// A corrupt store or one from another schema version starts empty; the next save
    /// overwrites it.
    func loadStore<Entry>(_ store: String, _ load: () throws -> [Entry]) -> [Entry] {
        do {
            return try load()
        } catch let mismatch as StoreSchemaMismatch {
            log(.warn, "cache:schema-mismatch", "The \(store) file is another schema version; starting empty.", [
                "store": .string(store), "found": mismatch.found,
            ])
        } catch {
            log(.warn, "cache:corrupt", "The \(store) file could not be read; starting empty.", ["store": .string(store)])
        }
        return []
    }

    /// The cache with expired entries evicted. Eviction is lazy, on read.
    func readCache(now: Int64) -> DecisionCache {
        var cache = loadCache()
        let evicted = cache.evictExpired(now: now)
        if evicted > 0 {
            loadedCache = cache
            cacheStore.save(cache.entries)
            log(.debug, "cache:evicted", "Evicted expired decisions.", ["count": .int(evicted), "reason": "expired"])
        }
        return cache
    }

    func putInCache(_ decision: JSONValue, surface: String, components: [String]?, identityKey: String, resourceId: String) {
        let decision = DecisionCache.withoutClaims(decision)
        var cache = loadCache()
        let storedAt = clock.nowMs()
        let expiresAt = DecisionCache.expiresAt(storedAt: storedAt, ttlMs: config.offline.ttl.milliseconds, decision: decision)
        let entry = DecisionCacheEntry(
            surface: surface,
            identityKey: identityKey,
            resourceId: resourceId,
            components: components,
            decision: decision,
            storedAt: storedAt,
            expiresAt: expiresAt
        )
        let evicted = cache.put(entry, maxEntries: config.offline.maxEntries)
        loadedCache = cache
        cacheStore.save(cache.entries)
        log(.debug, "cache:put", "Cached the decision.", [
            "surface": .string(surface), "resourceId": .string(resourceId), "expiresAt": .int(expiresAt),
        ])
        if evicted > 0 {
            log(.debug, "cache:evicted", "Evicted the oldest decisions over maxEntries.", ["count": .int(evicted), "reason": "max-entries"])
        }
    }

    func clearCache(reason: String) {
        loadedCache = DecisionCache(entries: [])
        cacheStore.save([])
        log(.info, "cache:cleared", "Cleared the decision cache.", ["reason": .string(reason)])
    }
}

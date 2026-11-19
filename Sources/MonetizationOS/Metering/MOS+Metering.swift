import Foundation

extension MOS {
    /// Sends queued counter updates for the current identity, oldest first. Call it when the
    /// app comes to the foreground or regains connectivity. Concurrent calls share one flush.
    @discardableResult
    public func flush() async -> FlushResult {
        await startFlush().value
    }

    @discardableResult
    func startFlush() -> Task<FlushResult, Never> {
        if let flushTask { return flushTask }
        let task = Task { await self.performFlush() }
        flushTask = task
        return task
    }

    /// Lets tests await the flush a network decision starts in the background.
    func waitForBackgroundFlush() async {
        _ = await flushTask?.value
    }

    func loadQueue() -> MeteringQueue {
        if let loadedQueue { return loadedQueue }
        let queue = MeteringQueue(entries: loadStore("queue", queueStore.load))
        loadedQueue = queue
        return queue
    }

    private func saveQueue(_ queue: MeteringQueue) {
        loadedQueue = queue
        queueStore.save(queue.entries)
    }

    func loadLedger() -> MeterLedger {
        if let loadedLedger { return loadedLedger }
        let ledger = MeterLedger(entries: loadStore("meters", meterStore.load))
        loadedLedger = ledger
        return ledger
    }

    func saveLedger(_ ledger: MeterLedger) {
        loadedLedger = ledger
        meterStore.save(ledger.entries)
    }

    /// A network decision resets each of its meters to the server's count, plus the updates still
    /// queued, which the server has not counted.
    func recordMeters(from decision: Decision, identityKey: String, resourceId: String, now: Int64) {
        var ledger = loadLedger()
        let ttl = config.offline.ttl.milliseconds
        let (cutoff, overflow) = now.subtractingReportingOverflow(ttl)
        var changed = ledger.prune(takenBefore: overflow ? (ttl < 0 ? Int64.max : Int64.min) : cutoff)
        let queued = loadQueue().entries.filter { $0.identityKey == identityKey }
        for (_, _, meter) in decision.meterables {
            guard let consumed = meter.consumedUnits, let total = meter.totalUnits else { continue }
            let unique = meter.uniqueResources ?? false
            let countedHere = meter.consumedInRequest == true || meter.resourceIDUsed == true
            let periodStart = MeterLedger.periodStartMs(meter.periodStart)
            var entry = MeterLedgerEntry(
                identityKey: identityKey, counterId: meter.counterID, serverConsumedUnits: consumed, totalUnits: total,
                uniqueResources: unique, takenAt: now, localUnits: 0,
                resources: (ledger.entry(identityKey: identityKey, counterId: meter.counterID)?.resources ?? [])
                    .filter { periodStart == nil || $0.at >= periodStart! }
            )
            if countedHere { entry.addResource(resourceId, at: now) }
            entry.localUnits = queued
                .filter { $0.counterId == meter.counterID && !(unique && countedHere && $0.resourceId == resourceId) }
                .reduce(0) { $0 + $1.update }
            ledger.put(entry)
            changed = true
        }
        if changed { saveLedger(ledger) }
    }

    /// Serving from the cache stands in for a consuming request: each meter the cached decision consumed
    /// is queued for the server and counted on the device. A meter the ledger knows also shows that count,
    /// and with `offline.enforceMeters` loses access once it is used up.
    func applyOfflineMeters(to decision: Decision, identityKey: String, resourceId: String, now: Int64) -> Decision {
        let anonymousIdentifier = identityKey.hasPrefix("anon:") ? String(identityKey.dropFirst("anon:".count)) : nil
        var queue = loadQueue()
        var ledger = loadLedger()
        var queueChanged = false
        var ledgerChanged = false
        var raw = decision.raw

        for (featureSlug, propertySlug, meter) in decision.meterables {
            // Only a meter with a count: an `on` or `off` meter carries none and stays as the server set it.
            let entry = meter.totalUnits == nil ? nil : ledger.entry(identityKey: identityKey, counterId: meter.counterID)
            // A resource already counted this period stays open, as it was paid for.
            let seen = entry?.counted(resourceId) ?? false
            let locked = config.offline.enforceMeters && meter.hasAccess && !seen
                && entry.map { $0.consumedUnits >= $0.totalUnits } == true
            var counted: Double = 0
            if meter.consumedInRequest == true, meter.hasAccess, !locked, !seen {
                let units = entry?.uniqueResources == true ? 1 : meter.consumedUnitsInRequest ?? 1
                let update = QueuedCounterUpdate(
                    identityKey: identityKey, anonymousIdentifier: anonymousIdentifier, counterId: meter.counterID,
                    resourceId: resourceId, update: units, enqueuedAt: now
                )
                let context: [String: JSONValue] = ["counterId": .string(meter.counterID), "resourceId": .string(resourceId)]
                switch queue.enqueue(update) {
                case .deduped:
                    log(.debug, "metering:deduped", "This counter update is already queued.", context)
                case .queued(let droppedOldest):
                    queueChanged = true
                    counted = units
                    log(.debug, "metering:queued", "Queued a counter update for a decision served offline.", context.merging(["update": .number(units)]) { a, _ in a })
                    if droppedOldest > 0 {
                        log(.warn, "metering:dropped", "The metering queue is full; dropped the oldest updates.", ["count": .int(droppedOldest), "reason": "limit"])
                    }
                }
            }
            guard var known = entry else { continue }
            let historic = known.consumedUnits
            if counted > 0 {
                known.localUnits += counted
                known.addResource(resourceId, at: now)
                ledger.put(known)
                ledgerChanged = true
            }
            if locked {
                log(.info, "metering:locked", "Reads counted on this device used up the meter; access is off until a network decision.", [
                    "counterId": .string(meter.counterID), "resourceId": .string(resourceId),
                    "consumedUnits": .number(historic), "totalUnits": .number(known.totalUnits),
                ])
            }
            var property = raw["features"]?[featureSlug]?["properties"]?[propertySlug]?.objectValue ?? [:]
            property["hasAccess"] = .bool(meter.hasAccess && !locked)
            property["consumedUnits"] = .number(historic + counted)
            property["remainingUnits"] = .number(max(0, known.totalUnits - historic - counted))
            property["totalUnits"] = .number(known.totalUnits)
            property["uniqueResources"] = .bool(known.uniqueResources)
            property["consumedInRequest"] = .bool(counted > 0)
            property["consumedUnitsInRequest"] = .number(counted)
            if known.uniqueResources { property["resourceIdUsed"] = .bool(seen) }
            if locked { property["lockedOffline"] = true }
            raw = raw.setting(.object(property), at: ["features", featureSlug, "properties", propertySlug])
        }
        if queueChanged { saveQueue(queue) }
        if ledgerChanged { saveLedger(ledger) }
        return raw == decision.raw ? decision : Decision(json: raw) ?? decision
    }

    private enum CounterOutcome {
        case sent
        case rejected(Failure)
        case retryLater(Failure)
    }

    private func performFlush() async -> FlushResult {
        defer { flushTask = nil }
        let generationAtStart = generation
        let identity = await resolveIdentity()
        let currentKey = identity.key
        let now = clock.nowMs()

        // Stale entries go, and so do entries for a JWT that is no longer current: there is no
        // token to send them with. Other anonymous identities are kept; that user may return.
        var queue = loadQueue()
        let isStale: (QueuedCounterUpdate) -> Bool = { now - $0.enqueuedAt > MeteringQueue.maxAgeMs }
        let isOrphaned: (QueuedCounterUpdate) -> Bool = { $0.identityKey.hasPrefix("jwt:") && $0.identityKey != currentKey }
        let stale = queue.entries.filter(isStale).count
        let orphaned = queue.entries.filter { !isStale($0) && isOrphaned($0) }.count
        var dropped = stale + orphaned
        if dropped > 0 {
            queue.entries.removeAll { isStale($0) || isOrphaned($0) }
            saveQueue(queue)
            if stale > 0 { log(.warn, "metering:dropped", "Dropped counter updates older than seven days.", ["count": .int(stale), "reason": "expired"]) }
            if orphaned > 0 { log(.warn, "metering:dropped", "Dropped counter updates for a signed-out identity.", ["count": .int(orphaned), "reason": "identity-gone"]) }
        }

        var sent = 0
        var failure: Failure?
        let due = queue.entries.filter { $0.identityKey == currentKey }.sorted { $0.enqueuedAt < $1.enqueuedAt }
        for entry in due {
            let requestIdentity: RequestIdentity
            if case .jwt = identity {
                requestIdentity = identity
            } else {
                requestIdentity = .anonymous(entry.anonymousIdentifier ?? String(entry.identityKey.dropFirst("anon:".count)))
            }
            let body: JSONValue = [
                "identity": requestIdentity.json(anonymousFallback: false),
                "counterId": .string(entry.counterId),
                "update": .number(entry.update),
                "resourceId": .string(entry.resourceId),
            ]
            let outcome = Self.counterOutcome(await send(requests.api("/api/v1/counter-updates", body: body)))
            guard generation == generationAtStart else { break }

            switch outcome {
            case .sent:
                var current = loadQueue()
                current.remove(entry)
                saveQueue(current)
                sent += 1
            case .rejected(let rejection):
                var current = loadQueue()
                current.remove(entry)
                saveQueue(current)
                dropped += 1
                log(.warn, "metering:rejected", "The server rejected a counter update; it was dropped.", [
                    "counterId": .string(entry.counterId), "resourceId": .string(entry.resourceId),
                    "status": .int(rejection.status), "statusCode": .int(rejection.statusCode),
                ])
            case .retryLater(let retry):
                failure = retry
            }
            if failure != nil { break }
        }

        let remaining = loadQueue().entries.filter { $0.identityKey == currentKey }.count
        if let failure {
            log(.warn, "metering:flush-failed", "The flush stopped (\(failure.reason.rawValue)); the rest stays queued.", [
                "reason": .string(failure.reason.rawValue), "status": .int(failure.status),
                "sent": .int(sent), "remaining": .int(remaining),
            ])
        } else if sent > 0 || dropped > 0 {
            log(.info, "metering:flushed", "Flushed queued counter updates.", [
                "sent": .int(sent), "remaining": .int(remaining), "dropped": .int(dropped),
            ])
        }
        return FlushResult(sent: sent, dropped: dropped, remaining: remaining, failure: failure)
    }

    /// 2xx `success` is sent; a 2xx without it and 4xx other than 401 and 429 are rejected for
    /// good. 401 (the host may refresh an expired token), 429, 5xx and transport failures stop
    /// the flush, entry kept.
    private static func counterOutcome(_ response: Result<HTTPResponse, Failure>) -> CounterOutcome {
        switch response {
        case .failure(let failure):
            return .retryLater(failure)
        case .success(let http):
            switch APIResponse.interpret(http) {
            case .success(let json):
                return json["status"]?.stringValue == "success" ? .sent : .rejected(APIResponse.invalidResponse(status: http.status))
            case .failure(let failure):
                // A 2xx that is not JSON never succeeds on retry either.
                if failure.reason == .invalidJSON { return .rejected(failure) }
                let code = failure.statusCode ?? failure.status ?? 0
                let retryable = failure.reason == .rateLimited || failure.reason == .unauthorized
                if !retryable, (400..<500).contains(code) { return .rejected(failure) }
                return .retryLater(failure)
            }
        }
    }
}

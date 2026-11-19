import Foundation
import Testing
@testable import MonetizationOS

@Suite("Offline meter counts")
struct OfflineMeterTests {
    private static let anon = "anon:mos-anon-v1-abc"
    private static let counter = "default:feat_article.enabled"

    /// The server's answer for a counted meter: `consumed` of `total` used, this request included.
    private static func counted(
        consumed: Double, total: Double = 5, unique: Bool = false, consumedInRequest: Bool = true, resourceIdUsed: Bool = false,
        periodStart: String? = nil
    ) -> JSONValue {
        Decisions.make(meters: [Decisions.Meter(
            hasAccess: consumed - (consumedInRequest ? 1 : 0) < total, consumedInRequest: consumedInRequest,
            consumedUnitsInRequest: consumedInRequest ? 1 : 0, consumedUnits: consumed, totalUnits: total, uniqueResources: unique,
            resourceIdUsed: resourceIdUsed, periodStart: periodStart
        )])
    }

    private static func meter(_ result: DecisionResult) -> Meterable? {
        guard case .meterable(let meter) = result.decision?.features["article"]?.properties["enabled"] else { return nil }
        return meter
    }

    private static func entry(
        consumed: Double, total: Double = 5, unique: Bool = false, local: Double = 0, resources: [String] = [], takenAt: Int64 = TestTime.base
    ) -> MeterLedgerEntry {
        MeterLedgerEntry(
            identityKey: anon, counterId: counter, serverConsumedUnits: consumed, totalUnits: total, uniqueResources: unique,
            takenAt: takenAt, localUnits: local, resources: resources.map { CountedResource(id: $0, at: takenAt) }
        )
    }

    /// A harness whose cache holds `decision` for article/1 and whose network is down.
    private static func offline(
        _ decision: JSONValue, ledger: [MeterLedgerEntry], enforce: Bool = false, queued: [QueuedCounterUpdate] = []
    ) -> Harness {
        Harness(
            anonymousIdentifier: "mos-anon-v1-abc", offline: MOSConfig.Offline(enforceMeters: enforce), now: TestTime.base + 1_000,
            cached: [Decisions.entry(decision: decision)], queued: queued, ledger: ledger, handler: networkDown
        )
    }

    @Test("a network decision sets the server count, plus the updates still queued")
    func networkSetsCount() async {
        let harness = Harness(
            anonymousIdentifier: "mos-anon-v1-abc", queued: [Decisions.queued(resourceId: "article/q")],
            handler: route(decision: { _ in .json(Self.counted(consumed: 2)) })
        )
        await harness.decide("article/1")
        #expect(harness.meters.entries == [Self.entry(consumed: 2, local: 1)])
        #expect(harness.queue.entries.isEmpty)
    }

    @Test("reads served from the cache count the meter down")
    func countsDown() async {
        let harness = Self.offline(Self.counted(consumed: 2), ledger: [Self.entry(consumed: 2)])
        let first = await harness.decide("article/2")
        #expect(Self.meter(first)?.consumedUnits == 3)
        #expect(Self.meter(first)?.remainingUnits == 2)
        #expect(Self.meter(first)?.consumedInRequest == true)
        let second = await harness.decide("article/3")
        #expect(Self.meter(second)?.remainingUnits == 1)
        #expect(harness.meters.entries.first?.localUnits == 2)
        #expect(harness.queue.entries.map(\.resourceId) == ["article/2", "article/3"])
    }

    @Test("without enforceMeters, access stays on past the limit and reads still queue")
    func notEnforced() async {
        let harness = Self.offline(Self.counted(consumed: 5), ledger: [Self.entry(consumed: 5)])
        let result = await harness.decide("article/2")
        #expect(result.hasAccess(feature: "article", property: "enabled"))
        #expect(Self.meter(result)?.remainingUnits == 0)
        #expect(Self.meter(result)?.lockedOffline == false)
        #expect(harness.queue.entries.count == 1)
    }

    @Test("with enforceMeters, a used-up meter locks: no access, lockedOffline, nothing queued")
    func enforced() async {
        let harness = Self.offline(Self.counted(consumed: 4), ledger: [Self.entry(consumed: 4)], enforce: true)
        let last = await harness.decide("article/2")
        #expect(last.hasAccess(feature: "article", property: "enabled"))
        #expect(Self.meter(last)?.remainingUnits == 0)

        let locked = await harness.decide("article/3")
        #expect(!locked.hasAccess(feature: "article", property: "enabled"))
        #expect(Self.meter(locked)?.lockedOffline == true)
        #expect(Self.meter(locked)?.consumedInRequest == false)
        #expect(Self.meter(locked)?.consumedUnits == 5)
        #expect(harness.queue.entries.map(\.resourceId) == ["article/2"])
        #expect(harness.logs.events("metering:locked").first?.context == [
            "counterId": .string(Self.counter), "resourceId": "article/3", "consumedUnits": 5, "totalUnits": 5,
        ])
    }

    @Test("a unique-resource re-read counts nothing and stays open when the meter is used up")
    func uniqueReread() async {
        let harness = Self.offline(Self.counted(consumed: 4, unique: true), ledger: [Self.entry(consumed: 4, unique: true)], enforce: true)
        await harness.decide("article/2")
        let reread = await harness.decide("article/2")
        #expect(reread.hasAccess(feature: "article", property: "enabled"))
        #expect(Self.meter(reread)?.consumedInRequest == false)
        #expect(Self.meter(reread)?.resourceIDUsed == true)
        #expect(Self.meter(reread)?.consumedUnits == 5)
        #expect(harness.meters.entries.first?.localUnits == 1)
        #expect(harness.queue.entries.count == 1)
    }

    @Test("a non-unique meter counts what is queued, so a deduped re-read counts nothing")
    func dedupedReread() async {
        let harness = Self.offline(Self.counted(consumed: 1), ledger: [Self.entry(consumed: 1)])
        await harness.decide("article/2")
        let reread = await harness.decide("article/2")
        #expect(Self.meter(reread)?.consumedUnits == 2)
        #expect(Self.meter(reread)?.consumedInRequest == false)
    }

    @Test("a flush keeps the local count until the next network decision")
    func flushKeepsCount() async {
        let harness = Self.offline(Self.counted(consumed: 2), ledger: [Self.entry(consumed: 2)])
        await harness.decide("article/2")
        harness.transport.respond(route(decision: networkDown))
        let flushed = await harness.mos.flush()
        #expect(flushed.sent == 1)
        harness.transport.respond(networkDown)
        let after = await harness.decide("article/3")
        #expect(Self.meter(after)?.consumedUnits == 4)

        // Online again, the server has counted article/2 and article/4 but not article/3, still queued.
        harness.transport.respond(route(decision: { _ in .json(Self.counted(consumed: 4)) }, counter: networkDown))
        await harness.decide("article/4")
        #expect(harness.meters.entries == [Self.entry(consumed: 4, local: 1, takenAt: TestTime.base + 1_000)])
    }

    @Test("an update queued for the resource the server just counted is not counted twice")
    func queuedResourceCountedByServer() async {
        let harness = Harness(
            anonymousIdentifier: "mos-anon-v1-abc",
            queued: [Decisions.queued(resourceId: "article/1"), Decisions.queued(resourceId: "article/2")],
            handler: route(decision: { _ in .json(Self.counted(consumed: 3, unique: true)) }, counter: networkDown)
        )
        await harness.decide("article/1")
        #expect(harness.meters.entries.first?.localUnits == 1)
        #expect(harness.meters.entries.first?.resources.map(\.id) == ["article/1"])
    }

    @Test("a meter without a count, on or off, is left as the server set it")
    func uncountedMeterUntouched() async {
        let decision = Decisions.make(meters: [Decisions.Meter(hasAccess: true, consumedInRequest: nil, consumedUnitsInRequest: nil)])
        let harness = Self.offline(decision, ledger: [Self.entry(consumed: 9)], enforce: true)
        let result = await harness.decide("article/2")
        #expect(result.hasAccess(feature: "article", property: "enabled"))
        #expect(result.decision?.raw == decision)
    }

    @Test("a meter the cached decision did not consume shows the count without adding to it")
    func displayOnly() async {
        let harness = Self.offline(Self.counted(consumed: 1, consumedInRequest: false), ledger: [Self.entry(consumed: 1, local: 2)])
        let result = await harness.decide("home")
        #expect(Self.meter(result)?.remainingUnits == 2)
        #expect(Self.meter(result)?.consumedInRequest == false)
        #expect(harness.queue.entries.isEmpty)
    }

    @Test("a meter without a ledger entry is queued as before and not rewritten")
    func noLedgerEntry() async {
        let decision = Self.counted(consumed: 5)
        let harness = Self.offline(decision, ledger: [], enforce: true)
        let result = await harness.decide("article/2")
        #expect(result.hasAccess(feature: "article", property: "enabled"))
        #expect(result.decision?.raw == decision)
        #expect(harness.queue.entries.count == 1)
    }

    @Test("a new period drops the resources counted before it")
    func periodStartPrunes() async {
        let old = MeterLedgerEntry(
            identityKey: Self.anon, counterId: Self.counter, serverConsumedUnits: 1, totalUnits: 5, uniqueResources: true,
            takenAt: TestTime.base - TestTime.day, localUnits: 0,
            resources: [CountedResource(id: "article/old", at: TestTime.base - TestTime.day)]
        )
        // TestTime.base is Tue, 14 Nov 2023 22:13:20 GMT.
        let harness = Harness(
            anonymousIdentifier: "mos-anon-v1-abc", ledger: [old],
            handler: route(decision: { _ in .json(Self.counted(consumed: 1, unique: true, periodStart: "Tue, 14 Nov 2023 00:00:00 GMT")) })
        )
        await harness.decide("article/1")
        #expect(harness.meters.entries.first?.resources.map(\.id) == ["article/1"])
    }

    @Test("periodStart parses as an HTTP date")
    func periodStartParses() {
        #expect(MeterLedger.periodStartMs("Tue, 14 Nov 2023 00:00:00 GMT") == 1_699_920_000_000)
        #expect(MeterLedger.periodStartMs("not a date") == nil)
    }

    @Test("a network decision drops ledger entries older than the cache ttl")
    func ledgerPrunedAfterTTL() async {
        let stale = MeterLedgerEntry(
            identityKey: Self.anon, counterId: "default:feat_video.enabled", serverConsumedUnits: 1, totalUnits: 5, uniqueResources: false,
            takenAt: TestTime.base - TestTime.day - 1, localUnits: 0, resources: []
        )
        let harness = Harness(anonymousIdentifier: "mos-anon-v1-abc", ledger: [stale], handler: route(decision: { _ in .json(Self.counted(consumed: 1)) }))
        await harness.decide("article/1")
        #expect(harness.meters.entries.map(\.counterId) == [Self.counter])
    }

    @Test("reset forgets the offline counts")
    func resetClears() async {
        let harness = Self.offline(Self.counted(consumed: 2), ledger: [Self.entry(consumed: 2)])
        await harness.mos.reset()
        #expect(harness.meters.entries.isEmpty)
    }
}

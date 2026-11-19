import Foundation
import os

/// One counter's count for one identity: the server's from the latest network decision, plus the
/// units this device counted since, which the server has not counted yet.
struct MeterLedgerEntry: Codable, Sendable, Equatable {
    var identityKey: String
    var counterId: String
    var serverConsumedUnits: Double
    var totalUnits: Double
    var uniqueResources: Bool
    var takenAt: Int64
    var localUnits: Double
    /// For a unique-resource meter, the resources counted this period, so a re-read counts nothing.
    var resources: [CountedResource]

    var consumedUnits: Double { serverConsumedUnits + localUnits }

    func counted(_ resourceId: String) -> Bool {
        uniqueResources && resources.contains { $0.id == resourceId }
    }

    mutating func addResource(_ resourceId: String, at: Int64) {
        guard uniqueResources, !counted(resourceId) else { return }
        resources.append(CountedResource(id: resourceId, at: at))
        if resources.count > MeterLedger.maxResources { resources.removeFirst(resources.count - MeterLedger.maxResources) }
    }
}

struct CountedResource: Codable, Sendable, Equatable {
    var id: String
    /// When the SDK learned it was counted.
    var at: Int64
}

struct MeterLedger {
    static let maxResources = 200

    var entries: [MeterLedgerEntry]

    func entry(identityKey: String, counterId: String) -> MeterLedgerEntry? {
        entries.first { $0.identityKey == identityKey && $0.counterId == counterId }
    }

    mutating func put(_ entry: MeterLedgerEntry) {
        entries.removeAll { $0.identityKey == entry.identityKey && $0.counterId == entry.counterId }
        entries.append(entry)
    }

    /// Drops entries taken before `cutoff`. Returns whether any went.
    mutating func prune(takenBefore cutoff: Int64) -> Bool {
        let before = entries.count
        entries.removeAll { $0.takenAt < cutoff }
        return entries.count != before
    }

    /// A meter's `periodStart`, an HTTP date such as `Sun, 22 Nov 2026 00:00:00 GMT`, in ms.
    static func periodStartMs(_ value: String?) -> Int64? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
    }
}

/// Persists the meter ledger. Same contract as `DecisionCacheStore`.
protocol MeterLedgerStore: Sendable {
    func load() throws -> [MeterLedgerEntry]
    func save(_ entries: [MeterLedgerEntry])
}

final class InMemoryMeterLedgerStore: MeterLedgerStore {
    private let state: OSAllocatedUnfairLock<[MeterLedgerEntry]>

    init(_ entries: [MeterLedgerEntry] = []) {
        state = OSAllocatedUnfairLock(initialState: entries)
    }

    var entries: [MeterLedgerEntry] { state.withLock { $0 } }
    func load() throws -> [MeterLedgerEntry] { entries }
    func save(_ entries: [MeterLedgerEntry]) { state.withLock { $0 = entries } }
}

/// `meters.json` in `directory`, next to the cache.
struct FileMeterLedgerStore: MeterLedgerStore {
    let file: JSONFile<MeterLedgerEntry>

    init(directory: URL) {
        file = JSONFile(url: directory.appendingPathComponent("meters.json"))
    }

    func load() throws -> [MeterLedgerEntry] { try file.read() }
    func save(_ entries: [MeterLedgerEntry]) { file.write(entries) }
}

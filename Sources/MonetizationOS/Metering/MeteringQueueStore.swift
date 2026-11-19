import Foundation
import os

/// A deferred `counter-updates` call for a decision that was served offline.
struct QueuedCounterUpdate: Codable, Sendable, Equatable {
    var identityKey: String
    /// The anonymous id for `anon:` entries. JWT identities store no token.
    var anonymousIdentifier: String?
    var counterId: String
    var resourceId: String
    var update: Double
    var enqueuedAt: Int64

    init(identityKey: String, anonymousIdentifier: String?, counterId: String, resourceId: String, update: Double, enqueuedAt: Int64) {
        self.identityKey = identityKey
        self.anonymousIdentifier = anonymousIdentifier
        self.counterId = counterId
        self.resourceId = resourceId
        self.update = update
        self.enqueuedAt = enqueuedAt
    }

    func isSameUpdate(as other: QueuedCounterUpdate) -> Bool {
        identityKey == other.identityKey && counterId == other.counterId && resourceId == other.resourceId
    }
}

/// Persists the metering queue. Same contract as `DecisionCacheStore`.
protocol MeteringQueueStore: Sendable {
    /// The persisted entries, oldest first. Throws like `DecisionCacheStore.load()`.
    func load() throws -> [QueuedCounterUpdate]
    func save(_ entries: [QueuedCounterUpdate])
}

final class InMemoryMeteringQueueStore: MeteringQueueStore {
    private let state: OSAllocatedUnfairLock<[QueuedCounterUpdate]>

    init(_ entries: [QueuedCounterUpdate] = []) {
        state = OSAllocatedUnfairLock(initialState: entries)
    }

    var entries: [QueuedCounterUpdate] { state.withLock { $0 } }
    func load() throws -> [QueuedCounterUpdate] { entries }
    func save(_ entries: [QueuedCounterUpdate]) { state.withLock { $0 = entries } }
}

/// `queue.json` in `directory`, next to the cache.
struct FileMeteringQueueStore: MeteringQueueStore {
    let file: JSONFile<QueuedCounterUpdate>

    init(directory: URL) {
        file = JSONFile(url: directory.appendingPathComponent("queue.json"))
    }

    func load() throws -> [QueuedCounterUpdate] { try file.read() }
    func save(_ entries: [QueuedCounterUpdate]) { file.write(entries) }
}

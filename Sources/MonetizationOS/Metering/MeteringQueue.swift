import Foundation

/// The in-memory queue rules: client-side dedupe and a bounded size.
struct MeteringQueue {
    static let maxEntries = 500
    static let maxAgeMs: Int64 = 7 * 24 * 60 * 60 * 1000

    var entries: [QueuedCounterUpdate]

    enum EnqueueOutcome: Equatable {
        case queued(droppedOldest: Int)
        case deduped
    }

    mutating func enqueue(_ update: QueuedCounterUpdate) -> EnqueueOutcome {
        if entries.contains(where: { $0.isSameUpdate(as: update) }) { return .deduped }
        entries.append(update)
        var dropped = 0
        while entries.count > Self.maxEntries, let oldest = entries.indices.min(by: { entries[$0].enqueuedAt < entries[$1].enqueuedAt }) {
            entries.remove(at: oldest)
            dropped += 1
        }
        return .queued(droppedOldest: dropped)
    }

    mutating func remove(_ update: QueuedCounterUpdate) {
        entries.removeAll { $0.isSameUpdate(as: update) }
    }
}

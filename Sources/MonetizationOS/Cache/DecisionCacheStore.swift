import Foundation
import os

/// One cached decision, keyed by `(surface, identityKey, resourceId, components)`.
struct DecisionCacheEntry: Codable, Sendable, Equatable {
    var surface: String
    var identityKey: String
    var resourceId: String
    /// The component slugs the request selected, sorted; nil when it named none and all ran.
    var components: [String]?
    /// The raw decision body.
    var decision: JSONValue
    var storedAt: Int64
    var expiresAt: Int64

    init(
        surface: String, identityKey: String, resourceId: String, components: [String]? = nil, decision: JSONValue, storedAt: Int64,
        expiresAt: Int64
    ) {
        self.surface = surface
        self.identityKey = identityKey
        self.resourceId = resourceId
        self.components = components
        self.decision = decision
        self.storedAt = storedAt
        self.expiresAt = expiresAt
    }
}

/// Persists the decision cache. `MOS` loads once and saves the whole set after each change,
/// so one store should back one `MOS` instance.
protocol DecisionCacheStore: Sendable {
    /// The persisted entries, or empty when nothing is stored. Throws `StoreSchemaMismatch` when
    /// the data is another schema version, and any other error when it is corrupt.
    func load() throws -> [DecisionCacheEntry]
    func save(_ entries: [DecisionCacheEntry])
}

final class InMemoryDecisionCacheStore: DecisionCacheStore {
    private let state: OSAllocatedUnfairLock<[DecisionCacheEntry]>

    init(_ entries: [DecisionCacheEntry] = []) {
        state = OSAllocatedUnfairLock(initialState: entries)
    }

    var entries: [DecisionCacheEntry] { state.withLock { $0 } }
    func load() throws -> [DecisionCacheEntry] { entries }
    func save(_ entries: [DecisionCacheEntry]) { state.withLock { $0 = entries } }
}

/// `cache.json` in `directory`, written by atomic replace.
struct FileDecisionCacheStore: DecisionCacheStore {
    let file: JSONFile<DecisionCacheEntry>

    init(directory: URL) {
        file = JSONFile(url: directory.appendingPathComponent("cache.json"))
    }

    func load() throws -> [DecisionCacheEntry] { try file.read() }
    func save(_ entries: [DecisionCacheEntry]) { file.write(entries) }
}

/// Where the default stores keep their data, scoped by the public key's environment.
enum MOSStorage {
    static let name = "com.monetizationos.sdk"

    /// The public key's environment, `default` when it names none.
    static func environment(publicKey: String) -> String {
        APIRequests.environment(fromPublicKey: publicKey) ?? "default"
    }

    /// The environment as a path or Keychain service segment: each character outside `[A-Za-z0-9_-]`
    /// becomes `_`, so a malformed key cannot leave the SDK's directory; empty gives `default`.
    static func segment(_ environment: String) -> String {
        let characters = environment.unicodeScalars.map { scalar -> Character in
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", "_", "-": Character(scalar)
            default: "_"
            }
        }
        return characters.isEmpty ? "default" : String(characters)
    }

    /// The bundle identifier on macOS, where unsandboxed apps share Application Support and the login
    /// Keychain; nil on iOS, where both are per app.
    static var appScope: String? {
        #if os(macOS) || targetEnvironment(macCatalyst)
        Bundle.main.bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 }
        #else
        nil
        #endif
    }

    /// `Application Support/com.monetizationos.sdk/<environment>/`; on macOS
    /// `Application Support/<bundle id>/com.monetizationos.sdk/<environment>/`.
    static func defaultDirectory(environment: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return directory(in: base, environment: environment, appScope: appScope)
    }

    static func directory(in base: URL, environment: String, appScope: String?) -> URL {
        var directory = base
        if let appScope { directory.appendPathComponent(appScope, isDirectory: true) }
        return directory.appendingPathComponent(name, isDirectory: true).appendingPathComponent(segment(environment), isDirectory: true)
    }
}

/// Thrown by a store whose data is valid JSON but not the current schema version. `MOS`
/// starts empty and the next save overwrites it.
struct StoreSchemaMismatch: Error, Sendable, Equatable {
    /// The `schemaVersion` found, or `null` when there was none (an older bare-array format).
    let found: JSONValue

    init(found: JSONValue) {
        self.found = found
    }
}

/// `{ "schemaVersion": 1, "entries": [...] }`, written by atomic replace.
struct JSONFile<Entry: Codable & Sendable>: Sendable {
    static var schemaVersion: Int { 1 }

    private struct Envelope: Codable {
        var schemaVersion: Int
        var entries: [Entry]
    }

    let url: URL

    /// Empty when the file does not exist; throws `StoreSchemaMismatch` for another version
    /// and a decoding error when the file is corrupt.
    func read() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard let json = JSONValue.parse(data) else { throw CocoaError(.fileReadCorruptFile) }
        let found = json["schemaVersion"] ?? .null
        guard found.intValue == Self.schemaVersion else { throw StoreSchemaMismatch(found: found) }
        return try JSONDecoder().decode(Envelope.self, from: data).entries
    }

    func write(_ entries: [Entry]) {
        do {
            var directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // A cache and a retry queue: nothing worth restoring to another device.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(Envelope(schemaVersion: Self.schemaVersion, entries: entries)).write(to: url, options: .atomic)
        } catch {
            // Best effort: a failed write leaves the previous file, and memory stays correct.
        }
    }
}

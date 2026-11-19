import Foundation
import Security
import Testing
@testable import MonetizationOS

@Suite("Stores")
struct StoreTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mos-sdk-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeMOS(directory: URL, logs: LogRecorder, transport: FakeTransport, anonymousIdentifier: String = "mos-anon-v1-abc", clock: FakeClock = FakeClock()) -> MOS {
        try! MOS(config: MOSConfig(
            publicKey: TestKeys.publicKey,
            surface: "app-paywall",
            app: MOSConfig.App(name: "Herald", version: "2.1"),
            identity: MOSConfig.Identity(store: InMemoryIdentityStore(anonymousIdentifier: anonymousIdentifier)),
            onLog: logs.onLog,
            transport: transport
        ).with(clock: clock).with(
            cache: FileDecisionCacheStore(directory: directory), queue: FileMeteringQueueStore(directory: directory),
            meters: FileMeterLedgerStore(directory: directory)
        ))
    }

    @Test("store corruption: a corrupt cache.json starts empty, logs cache:corrupt, and is replaced on the next put")
    func corruptCache() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("cache.json")
        try Data("{ not json".utf8).write(to: file)

        let logs = LogRecorder()
        let transport = FakeTransport()
        let mos = makeMOS(directory: directory, logs: logs, transport: transport)
        let result = await mos.decide(resource: Resource(id: "article/1"), policy: .cacheOnly)
        #expect(result.source == .unavailable)
        #expect(logs.events("cache:corrupt").map(\.context) == [["store": "cache"]])

        _ = await mos.decide(resource: Resource(id: "article/1"))
        let stored = try #require(JSONValue.parse(Data(contentsOf: file)))
        #expect(stored["schemaVersion"] == 1)
        #expect(stored["entries"]?.arrayValue?.map { $0["resourceId"] } == ["article/1"])
        #expect(logs.count("cache:corrupt") == 1)
    }

    @Test("store corruption: a corrupt queue.json starts empty and logs cache:corrupt")
    func corruptQueue() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion": 1, "entries": [{"identityKey": 1}]}"#.utf8).write(to: directory.appendingPathComponent("queue.json"))

        let logs = LogRecorder()
        let mos = makeMOS(directory: directory, logs: logs, transport: FakeTransport { _ in .counterSuccess })
        let result = await mos.flush()
        #expect(result == FlushResult(sent: 0, dropped: 0, remaining: 0, failure: nil))
        #expect(logs.events("cache:corrupt").map(\.context) == [["store": "queue"]])
    }

    @Test("schema mismatch for cache and queue, including an older bare array: start empty, log, overwrite on save", arguments: [
        (#"[{"surface": "s"}]"#, JSONValue.null),
        (#"{"entries": []}"#, JSONValue.null),
        (#"{"schemaVersion": 2, "entries": []}"#, JSONValue.number(2)),
        (#"{"schemaVersion": "1", "entries": []}"#, JSONValue.string("1")),
    ])
    func schemaMismatch(contents: String, found: JSONValue) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cacheFile = directory.appendingPathComponent("cache.json")
        let queueFile = directory.appendingPathComponent("queue.json")
        try Data(contents.utf8).write(to: cacheFile)
        try Data(contents.utf8).write(to: queueFile)
        #expect(throws: StoreSchemaMismatch(found: found)) { try FileDecisionCacheStore(directory: directory).load() }
        #expect(throws: StoreSchemaMismatch(found: found)) { try FileMeteringQueueStore(directory: directory).load() }

        let logs = LogRecorder()
        let mos = makeMOS(directory: directory, logs: logs, transport: FakeTransport(networkDown))
        #expect(await mos.decide(resource: Resource(id: "article/1"), policy: .cacheOnly).source == .unavailable)
        #expect(await mos.flush() == FlushResult(sent: 0, dropped: 0, remaining: 0, failure: nil))
        let mismatches = logs.events("cache:schema-mismatch")
        #expect(mismatches.map(\.context) == [["store": "cache", "found": found], ["store": "queue", "found": found]])
        #expect(mismatches.allSatisfy { $0.level == .warn })
        #expect(logs.count("cache:corrupt") == 0)

        // The next save writes the current shape over the old file.
        FileDecisionCacheStore(directory: directory).save([Decisions.entry()])
        FileMeteringQueueStore(directory: directory).save([Decisions.queued()])
        #expect(try FileDecisionCacheStore(directory: directory).load() == [Decisions.entry()])
        #expect(try FileMeteringQueueStore(directory: directory).load() == [Decisions.queued()])
        #expect(JSONValue.parse(try Data(contentsOf: queueFile))?["schemaVersion"] == 1)
    }

    @Test("file stores persist across instances, read once, written on change")
    func fileStoresRoundTrip() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = FakeClock()
        let entry = Decisions.entry(resourceId: "article/1", decision: Decisions.make(meters: [Decisions.Meter()]))
        FileDecisionCacheStore(directory: directory).save([entry])

        let first = makeMOS(directory: directory, logs: LogRecorder(), transport: FakeTransport(networkDown), clock: clock)
        #expect(await first.decide(resource: Resource(id: "article/1")).source == .cache(ageMs: 0))
        let queued = try FileMeteringQueueStore(directory: directory).load()
        #expect(queued.map(\.counterId) == ["default:feat_article.enabled"])

        let transport = FakeTransport { _ in .counterSuccess }
        let second = makeMOS(directory: directory, logs: LogRecorder(), transport: transport, clock: clock)
        #expect(await second.flush().sent == 1)
        #expect(try FileMeteringQueueStore(directory: directory).load().isEmpty)
        #expect(try FileDecisionCacheStore(directory: directory).load() == [entry])
        // A cache and a retry queue: kept out of device backups.
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test("meters.json keeps the offline count across instances")
    func meterLedgerRoundTrip() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = FakeClock()
        let counted = Decisions.make(meters: [Decisions.Meter(consumedUnits: 2, totalUnits: 5)])
        let online = makeMOS(directory: directory, logs: LogRecorder(), transport: FakeTransport { _ in .json(counted) }, clock: clock)
        _ = await online.decide(resource: Resource(id: "article/1"))
        #expect(try FileMeterLedgerStore(directory: directory).load().map(\.serverConsumedUnits) == [2])

        let offline = makeMOS(directory: directory, logs: LogRecorder(), transport: FakeTransport(networkDown), clock: clock)
        let result = await offline.decide(resource: Resource(id: "article/2"))
        guard case .meterable(let meter) = result.decision?.features["article"]?.properties["enabled"] else {
            Issue.record("no meter")
            return
        }
        #expect(meter.remainingUnits == 2)
        #expect(try FileMeterLedgerStore(directory: directory).load().map(\.localUnits) == [1])
    }

    @Test("default stores are scoped by the key's environment: a staging and a production key share no file or Keychain item")
    func defaultStoresScopedByEnvironment() async throws {
        func stores(_ publicKey: String) async throws -> (directories: Set<URL>, service: String?) {
            let mos = try MOS(config: MOSConfig(publicKey: publicKey, surface: "s", app: MOSConfig.App(name: "A", version: "1")))
            let files = [
                (await mos.cacheStore as? FileDecisionCacheStore)?.file.url,
                (await mos.queueStore as? FileMeteringQueueStore)?.file.url,
                (await mos.meterStore as? FileMeterLedgerStore)?.file.url,
            ]
            #expect(files.map { $0?.lastPathComponent } == ["cache.json", "queue.json", "meters.json"])
            return (Set(files.compactMap { $0?.deletingLastPathComponent().standardizedFileURL }), (await mos.identityStore as? KeychainIdentityStore)?.service)
        }
        let base = try #require(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let scope = MOSStorage.appScope
        for (publicKey, environment) in [("pk_test_env1_s3cr3t", "test_env1"), ("pk_live_env2_s3cr3t", "live_env2"), ("pk_nosegments", "default")] {
            let (directories, service) = try await stores(publicKey)
            #expect(directories == [MOSStorage.directory(in: base, environment: environment, appScope: scope).standardizedFileURL])
            #expect(service == KeychainIdentityStore.service(environment: environment, appScope: scope))
        }
        #expect(KeychainIdentityStore(publicKey: "pk_test_env1_s3cr3t").service != KeychainIdentityStore(publicKey: "pk_live_env2_s3cr3t").service)
    }

    @Test("store paths and Keychain service: the environment last, the bundle identifier in front on macOS")
    func storeScopeLayout() {
        let base = URL(fileURLWithPath: "/Library/Application Support", isDirectory: true)
        #expect(MOSStorage.directory(in: base, environment: "live_abc", appScope: nil).path
            == "/Library/Application Support/com.monetizationos.sdk/live_abc")
        #expect(MOSStorage.directory(in: base, environment: "live_abc", appScope: "com.example.herald").path
            == "/Library/Application Support/com.example.herald/com.monetizationos.sdk/live_abc")
        #expect(KeychainIdentityStore.service(environment: "live_abc", appScope: nil) == "com.monetizationos.sdk.live_abc")
        #expect(KeychainIdentityStore.service(environment: "live_abc", appScope: "com.example.herald") == "com.monetizationos.sdk.com.example.herald.live_abc")
        #if os(macOS)
        #expect(MOSStorage.appScope == Bundle.main.bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 })
        #else
        #expect(MOSStorage.appScope == nil)
        #endif
    }

    @Test("the environment is sanitised for paths and the Keychain service: a malformed key cannot leave the SDK's directory")
    func environmentSegmentIsSanitised() async throws {
        #expect(MOSStorage.segment("live_abc-1") == "live_abc-1")
        #expect(MOSStorage.segment("../..") == "_____")
        #expect(MOSStorage.segment("a/b.c é") == "a_b_c__")
        #expect(MOSStorage.segment("") == "default")

        let publicKey = "pk_../.._a/b_s3cr3t"
        #expect(MOSStorage.environment(publicKey: publicKey) == "../.._a/b")
        let mos = try MOS(config: MOSConfig(publicKey: publicKey, surface: "s", app: MOSConfig.App(name: "A", version: "1")))
        let file = try #require((await mos.cacheStore as? FileDecisionCacheStore)?.file.url)
        let base = try #require(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        var sdkDirectory = base
        if let scope = MOSStorage.appScope { sdkDirectory.appendPathComponent(scope, isDirectory: true) }
        sdkDirectory.appendPathComponent(MOSStorage.name, isDirectory: true)
        let directory = file.deletingLastPathComponent().standardizedFileURL
        #expect(directory.lastPathComponent == "______a_b")
        #expect(directory.deletingLastPathComponent() == sdkDirectory.standardizedFileURL)
        let service = try #require((await mos.identityStore as? KeychainIdentityStore)?.service)
        #expect(service == [MOSStorage.name, MOSStorage.appScope, "______a_b"].compactMap { $0 }.joined(separator: "."))
    }

    @Test("a missing file is an empty store, not corruption")
    func missingFiles() throws {
        let directory = temporaryDirectory()
        #expect(try FileDecisionCacheStore(directory: directory).load().isEmpty)
        #expect(try FileMeteringQueueStore(directory: directory).load().isEmpty)
        #expect(try FileMeterLedgerStore(directory: directory).load().isEmpty)
    }

    @Test("privacy manifest present in the built bundle, declaring what the spec says")
    func privacyManifest() throws {
        let url = try #require(Bundle.module.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let plist = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        #expect(plist["NSPrivacyTracking"] as? Bool == false)
        #expect((plist["NSPrivacyTrackingDomains"] as? [Any])?.isEmpty == true)
        #expect((plist["NSPrivacyAccessedAPITypes"] as? [Any])?.isEmpty == true)
        let collected = try #require(plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        #expect(collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String } == [
            "NSPrivacyCollectedDataTypeUserID", "NSPrivacyCollectedDataTypeProductInteraction",
        ])
        for type in collected {
            #expect(type["NSPrivacyCollectedDataTypeLinked"] as? Bool == true)
            #expect(type["NSPrivacyCollectedDataTypeTracking"] as? Bool == false)
            #expect(type["NSPrivacyCollectedDataTypePurposes"] as? [String] == ["NSPrivacyCollectedDataTypePurposeAppFunctionality"])
        }
    }
}

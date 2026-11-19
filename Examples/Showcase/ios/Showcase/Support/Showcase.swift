import Foundation
import MonetizationOS
import Observation

/// App-wide plumbing every screen shares: the MOS instance built from Settings, the Offline switch
/// and the live rows on Home. Screens make their MOS calls themselves, on `showcase.mos`.
@MainActor
@Observable
final class Showcase {
    private(set) var settings: ShowcaseSettings
    private(set) var mos: MOS
    /// Bumped whenever `mos` is rebuilt.
    private(set) var generation = 0
    private(set) var isOffline = false
    private(set) var lastSource: DecisionSource?
    private(set) var identity = "Anonymous, no id yet"
    /// Counter updates waiting for `flush()`, followed from the SDK's `metering:*` log events.
    private(set) var queuedUpdates = 0

    @ObservationIgnored private let offlineSwitch = OfflineSwitch()
    @ObservationIgnored private let logs: AsyncStream<LogEvent>.Continuation

    init() {
        let environment = ProcessInfo.processInfo.environment
        // UI tests start from a clean slate: fixture mode, new anonymous reader.
        let resetAtLaunch = environment["SHOWCASE_RESET"] == "1"
        if resetAtLaunch {
            ShowcaseSettings.clear()
            ShowcaseSettings.fixtureDefaults.save()
        }
        let settings = ShowcaseSettings.load()
        let (stream, logs) = AsyncStream.makeStream(of: LogEvent.self)
        self.logs = logs
        self.settings = settings
        let built = (try? Self.makeMOS(settings, offline: offlineSwitch, logs: logs))
            ?? (try! Self.makeMOS(ShowcaseSettings.fixtureDefaults, offline: offlineSwitch, logs: logs))
        mos = built
        Task { [weak self] in
            for await event in stream { self?.handle(event) }
        }
        Task {
            if resetAtLaunch { await built.reset() }
            await refreshIdentity()
        }
    }

    var modeLabel: String {
        switch settings.mode {
        case .fixture: "Fixture"
        case .live: "Live · \(URL(string: settings.apiBaseUrl)?.host() ?? settings.apiBaseUrl)"
        }
    }

    /// Rebuilds MOS for new settings. Another mode, key or host is another environment, so the old
    /// instance forgets its identity, cache and queue first. Returns an error message for a bad key.
    func apply(_ new: ShowcaseSettings) async -> String? {
        let rebuild = new.mode != settings.mode || new.effectivePublicKey != settings.effectivePublicKey
            || new.effectiveApiBaseUrl != settings.effectiveApiBaseUrl
        guard rebuild else {
            settings = new
            new.save()
            return nil
        }
        let built: MOS
        do {
            built = try Self.makeMOS(new, offline: offlineSwitch, logs: logs)
        } catch {
            return "The public key must start with pk_."
        }
        await mos.reset()
        settings = new
        new.save()
        mos = built
        generation += 1
        lastSource = nil
        queuedUpdates = 0
        await refreshIdentity()
        return nil
    }

    func setOffline(_ on: Bool) {
        offlineSwitch.isOn = on
        isOffline = on
    }

    /// Screens report each decision here for the Home rows.
    func didDecide(_ result: DecisionResult) {
        lastSource = result.source
        if let identity = result.decision?.identity {
            let id = identity.identifier ?? "?"
            self.identity = identity.isAuthenticated ? "Signed in: \(id)" : "Anonymous: \(id)"
        }
    }

    /// A new anonymous reader: the SDK forgets the anonymous id, the identity state, the cache and the queue.
    func resetIdentity() async {
        await mos.identify(userJWT: nil)
        await mos.reset()
        lastSource = nil
        queuedUpdates = 0
        await refreshIdentity()
    }

    func refreshIdentity() async {
        identity = await mos.anonymousIdentifier.map { "Anonymous: \($0)" } ?? "Anonymous, no id yet"
    }

    private func handle(_ event: LogEvent) {
        switch event.code {
        case "metering:queued":
            queuedUpdates += 1
        case "metering:flushed", "metering:flush-failed":
            if let remaining = event.context["remaining"]?.intValue { queuedUpdates = remaining }
        default:
            break
        }
    }
}

extension DecisionSource {
    var label: String {
        switch self {
        case .network: "network"
        case .cache(let ageMs): "cache (\(ageMs / 1000) s old)"
        case .fallback(_, let resourceId): "fallback (from \(resourceId))"
        case .unavailable: "unavailable"
        }
    }
}

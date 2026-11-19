import Foundation

/// What the Settings screen edits, kept in UserDefaults. The live fields are prefilled from
/// Config.local.xcconfig through Info.plist; the first run is live when that sets a public key, fixture mode otherwise.
struct ShowcaseSettings: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable {
        case fixture, live
    }

    var mode = Mode.fixture
    var publicKey: String
    var apiBaseUrl: String
    var namespace: String

    /// Fixture mode never sends this key anywhere; it only names the environment `test_showcase`.
    static let fixturePublicKey = "pk_test_showcase_fixtures"
    /// Never contacted: the fixture transport answers.
    static let fixtureApiBaseUrl = "https://fixtures.showcase.invalid"
    private static let storageKey = "showcase.settings"

    var effectivePublicKey: String { mode == .fixture ? Self.fixturePublicKey : publicKey }
    var effectiveApiBaseUrl: String { mode == .fixture ? Self.fixtureApiBaseUrl : apiBaseUrl }

    static var defaults: ShowcaseSettings {
        let info = Bundle.main.infoDictionary ?? [:]
        func value(_ key: String) -> String? { (info[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let publicKey = value("MOS_PUBLIC_KEY")
        return ShowcaseSettings(
            mode: publicKey == nil ? .fixture : .live,
            publicKey: publicKey ?? "",
            apiBaseUrl: value("MOS_API_BASE_URL") ?? "https://api.monetizationos.com",
            namespace: value("MOS_ENDPOINT_NAMESPACE") ?? "showcase"
        )
    }

    /// `defaults` in fixture mode: UI tests, and the fallback when live settings fail to build.
    static var fixtureDefaults: ShowcaseSettings {
        var settings = defaults
        settings.mode = .fixture
        return settings
    }

    static func load() -> ShowcaseSettings {
        UserDefaults.standard.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(ShowcaseSettings.self, from: $0) } ?? defaults
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.storageKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}

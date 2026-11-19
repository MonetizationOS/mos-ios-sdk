import Foundation

public enum RedemptionResult: Sendable, Equatable {
    case redeemed(action: Action, eventID: String?, statusCode: Int)
    case declined(message: String?, statusCode: Int, eventID: String?)
    case failed(Failure)
}

/// What the host should do after a redemption: open a URL, hand a `custom` or `custom:*` action
/// to its own handler (a store purchase, say), or nothing.
public enum Action: Sendable, Equatable {
    case navigate(url: URL, properties: JSONValue)
    case custom(type: String, properties: JSONValue)
    /// The server's `none`. Not `.none`, which an `Action?` would read as `Optional.none`.
    case noAction(properties: JSONValue)

    /// An unknown type, or `navigate` without a usable URL, maps to `noAction`.
    init(json: JSONValue?) {
        let type = json?["type"]?.stringValue ?? "none"
        let properties = json?["properties"].flatMap { $0.objectValue == nil ? nil : $0 } ?? .object([:])
        if type == "navigate", let url = json?["url"]?.stringValue.flatMap(URL.init(string:)) {
            self = .navigate(url: url, properties: properties)
        } else if type == "custom" || type.hasPrefix("custom:") {
            self = .custom(type: type, properties: properties)
        } else {
            self = .noAction(properties: properties)
        }
    }

    var type: String {
        switch self {
        case .navigate: "navigate"
        case .custom(let type, _): type
        case .noAction: "none"
        }
    }
}

public struct FlushResult: Sendable, Equatable {
    public let sent: Int
    /// Entries removed without being counted: rejected by the server, older than seven days,
    /// or belonging to a signed-out JWT identity.
    public let dropped: Int
    /// Entries still queued for the current identity.
    public let remaining: Int
    public let failure: Failure?
}

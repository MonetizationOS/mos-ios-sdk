import Foundation

/// A structured SDK event with a stable `code`. Tokens, JWTs and offer tokens never appear in
/// one; identities appear as their key prefix (`anon`/`jwt`), and the anonymous id only at debug.
public struct LogEvent: Sendable, Equatable, CustomStringConvertible {
    public enum Level: String, Sendable, Equatable {
        case debug, info, warn, error
    }

    public let level: Level
    public let code: String
    public let message: String
    public let context: JSONValue

    public init(level: Level, code: String, message: String, context: JSONValue = .object([:])) {
        self.level = level
        self.code = code
        self.message = message
        self.context = context
    }

    public var description: String {
        "[mos] \(level.rawValue) \(code): \(message) \(context.jsonString)"
    }
}

/// Prints every event to standard output. The SDK never prints on its own; pass this as
/// `onLog` to see its events.
public let consoleLogger: @Sendable (LogEvent) -> Void = { event in
    print(event.description)
}

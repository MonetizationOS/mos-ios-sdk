import Foundation

public enum EndpointMethod: String, Sendable, Equatable, CaseIterable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
    case patch = "PATCH"

    var allowsBody: Bool { self == .post || self == .put || self == .patch }
}

/// Whatever the endpoint's workflow returned, whatever the status.
public struct EndpointResponse: Sendable, Equatable {
    public let status: Int
    /// Lowercased names; repeated headers joined with `, `.
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        var lowercased: [String: String] = [:]
        for name in headers.keys.sorted() {
            let key = name.lowercased()
            lowercased[key] = lowercased[key].map { "\($0), \(headers[name]!)" } ?? headers[name]
        }
        self.headers = lowercased
        self.body = body
    }

    /// The parsed body, or nil when it is not valid JSON.
    public var json: JSONValue? { JSONValue.parse(body) }
    /// The body as UTF-8, invalid bytes replaced.
    public var text: String { String(decoding: body, as: UTF8.self) }
    public var isSuccess: Bool { (200..<300).contains(status) }

}

public enum EndpointResult: Sendable, Equatable {
    /// Any HTTP response, whatever its status.
    case response(EndpointResponse)
    /// No HTTP response arrived: `requestFailed`, `timeout` or `notConfigured`.
    case failed(Failure)
}

/// Binds an app's namespace, which is install-time configuration, never a constant. Holds no
/// state; every call forwards to `MOS.callEndpoint`.
public struct AppClient: Sendable {
    public let namespace: String
    let mos: MOS

    public func call(
        path: String,
        method: EndpointMethod = .post,
        body: JSONValue? = nil,
        query: [String: String]? = nil,
        headers: [String: String]? = nil,
        timeout: Duration? = nil
    ) async -> EndpointResult {
        await mos.callEndpoint(
            path: path, method: method, body: body, query: query, headers: headers, namespace: namespace, timeout: timeout
        )
    }

    public func call(
        pathSegments: [String],
        method: EndpointMethod = .post,
        body: JSONValue? = nil,
        query: [String: String]? = nil,
        headers: [String: String]? = nil,
        timeout: Duration? = nil
    ) async -> EndpointResult {
        await mos.callEndpoint(
            pathSegments: pathSegments, method: method, body: body, query: query, headers: headers, namespace: namespace, timeout: timeout
        )
    }

}

enum EndpointURL {
    /// RFC 3986 unreserved characters; everything else is percent-encoded.
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    static func isRefused(_ segment: String) -> Bool { segment.isEmpty || segment == "." || segment == ".." }

    /// nil when there is no segment, or the path or namespace has an empty, `.` or `..` one.
    static func make(base: String, env: String, namespace: String?, segments: [String], query: [String: String]?) -> URL? {
        guard !segments.isEmpty, !segments.contains(where: isRefused) else { return nil }
        var url = "\(base)/api/v1/envs/\(encode(env))"
        if let namespace {
            guard !isRefused(namespace) else { return nil }
            url += "/namespaces/\(encode(namespace))"
        }
        url += "/endpoints/" + segments.map(encode).joined(separator: "/")
        if let query, !query.isEmpty {
            url += "?" + query.keys.sorted().map { "\(encode($0))=\(encode(query[$0]!))" }.joined(separator: "&")
        }
        return APIRequests.absoluteURL(url)
    }
}
